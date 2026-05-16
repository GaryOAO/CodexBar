import AppKit
import CodexBarCore
import KeyboardShortcuts
import Observation
import QuartzCore
import Security
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings: SettingsStore
    @State private var store: UsageStore
    @State private var managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    @State private var codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    private let preferencesSelection: PreferencesSelection
    private let account: AccountInfo

    init() {
        let env = ProcessInfo.processInfo.environment
        let storedLevel = CodexBarLog.parseLevel(UserDefaults.standard.string(forKey: "debugLogLevel")) ?? .verbose
        let level = CodexBarLog.parseLevel(env["CODEXBAR_LOG_LEVEL"]) ?? storedLevel
        CodexBarLog.bootstrapIfNeeded(.init(
            destination: .oslog(subsystem: "com.steipete.codexbar"),
            level: level,
            json: false))

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let gitCommit = Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String ?? "unknown"
        let buildTimestamp = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String ?? "unknown"
        CodexBarLog.logger(LogCategories.app).info(
            "CodexBar starting",
            metadata: [
                "version": version,
                "build": build,
                "git": gitCommit,
                "built": buildTimestamp,
            ])

        KeychainAccessGate.isDisabled = UserDefaults.standard.bool(forKey: "debugDisableKeychainAccess")
        KeychainPromptCoordinator.install()

        let preferencesSelection = PreferencesSelection()
        let settings = SettingsStore()
        Self.applyLanguagePreference(from: settings)
        let managedCodexAccountCoordinator = ManagedCodexAccountCoordinator()
        managedCodexAccountCoordinator.onManagedAccountsDidChange = {
            _ = settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()
        }
        _ = settings.persistResolvedCodexActiveSourceCorrectionIfNeeded()
        let fetcher = UsageFetcher()
        let browserDetection = BrowserDetection(cacheTTL: BrowserDetection.defaultCacheTTL)
        let account = fetcher.loadAccountInfo()
        let store = UsageStore(fetcher: fetcher, browserDetection: browserDetection, settings: settings)
        let codexAccountPromotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: settings,
            usageStore: store,
            managedAccountCoordinator: managedCodexAccountCoordinator)
        self.preferencesSelection = preferencesSelection
        _settings = State(wrappedValue: settings)
        _store = State(wrappedValue: store)
        _managedCodexAccountCoordinator = State(wrappedValue: managedCodexAccountCoordinator)
        _codexAccountPromotionCoordinator = State(wrappedValue: codexAccountPromotionCoordinator)
        self.account = account
        CodexBarLog.setLogLevel(settings.debugLogLevel)
        self.appDelegate.configure(.init(
            store: store,
            settings: settings,
            account: account,
            selection: preferencesSelection,
            managedCodexAccountCoordinator: managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: codexAccountPromotionCoordinator))
    }

    @SceneBuilder
    var body: some Scene {
        // Hidden 1×1 window to keep SwiftUI's lifecycle alive so `Settings` scene
        // shows the native toolbar tabs even though the UI is AppKit-based.
        WindowGroup("CodexBarLifecycleKeepalive") {
            HiddenWindowView()
        }
        .defaultSize(width: 20, height: 20)
        .windowStyle(.hiddenTitleBar)

        Settings {
            PreferencesView(
                settings: self.settings,
                store: self.store,
                updater: self.appDelegate.updaterController,
                selection: self.preferencesSelection,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                runProviderLoginFlow: { provider in
                    await self.appDelegate.runProviderLoginFlow(provider)
                })
        }
        .defaultSize(width: PreferencesTab.general.preferredWidth, height: PreferencesTab.general.preferredHeight)
        .windowResizability(.contentSize)
    }

    private func openSettings(tab: PreferencesTab) {
        self.preferencesSelection.tab = tab
        NSApp.activate(ignoringOtherApps: true)
        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    private static func applyLanguagePreference(from settings: SettingsStore) {
        let language = settings.appLanguage
        if language.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
    }
}

// MARK: - Updater abstraction

@MainActor
protocol UpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    var updateStatus: UpdateStatus { get }
    func checkForUpdates(_ sender: Any?)
    func installUpdate()
}

/// No-op updater used for debug builds and non-bundled runs to suppress Sparkle dialogs.
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates: Bool = false
    var automaticallyDownloadsUpdates: Bool = false
    let isAvailable: Bool = false
    let unavailableReason: String?
    let updateStatus = UpdateStatus()

    init(unavailableReason: String? = nil) {
        self.unavailableReason = unavailableReason
    }

    func checkForUpdates(_ sender: Any?) {}
    func installUpdate() {}
}

@MainActor
@Observable
final class UpdateStatus {
    static let disabled = UpdateStatus()
    var isUpdateReady: Bool

    init(isUpdateReady: Bool = false) {
        self.isUpdateReady = isUpdateReady
    }
}

#if canImport(Sparkle) && ENABLE_SPARKLE
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding, SPUUpdaterDelegate {
    private final class ImmediateInstallHandler: @unchecked Sendable {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func install() {
            self.handler()
        }
    }

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil)
    let updateStatus = UpdateStatus()
    let unavailableReason: String? = nil
    private var immediateInstallHandler: ImmediateInstallHandler?

    init(savedAutoUpdate: Bool) {
        super.init()
        let updater = self.controller.updater
        updater.automaticallyChecksForUpdates = savedAutoUpdate
        updater.automaticallyDownloadsUpdates = savedAutoUpdate
        self.controller.startUpdater()
    }

    var automaticallyChecksForUpdates: Bool {
        get { self.controller.updater.automaticallyChecksForUpdates }
        set { self.controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { self.controller.updater.automaticallyDownloadsUpdates }
        set { self.controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var isAvailable: Bool {
        true
    }

    func checkForUpdates(_ sender: Any?) {
        self.controller.checkForUpdates(sender)
    }

    func installUpdate() {
        guard let immediateInstallHandler else {
            self.controller.checkForUpdates(nil)
            return
        }

        immediateInstallHandler.install()
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        _ = updater
        _ = item
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        _ = updater
        _ = item
        _ = error
        Task { @MainActor in
            self.immediateInstallHandler = nil
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func userDidCancelDownload(_ updater: SPUUpdater) {
        _ = updater
        Task { @MainActor in
            self.immediateInstallHandler = nil
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void)
        -> Bool
    {
        _ = updater
        _ = item
        let installHandler = ImmediateInstallHandler(immediateInstallHandler)
        Task { @MainActor in
            self.immediateInstallHandler = installHandler
            self.updateStatus.isUpdateReady = true
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        _ = updater
        _ = error
        Task { @MainActor in
            self.immediateInstallHandler = nil
            self.updateStatus.isUpdateReady = false
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState)
    {
        let downloaded = state.stage == .downloaded
        Task { @MainActor in
            switch choice {
            case .install, .skip:
                self.immediateInstallHandler = nil
                self.updateStatus.isUpdateReady = false
            case .dismiss:
                self.updateStatus.isUpdateReady = downloaded
            @unknown default:
                self.immediateInstallHandler = nil
                self.updateStatus.isUpdateReady = false
            }
        }
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannel.current.allowedSparkleChannels
    }
}

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return false }

    if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
        return summary.hasPrefix("Developer ID Application:")
    }
    return false
}

@MainActor
private func makeUpdaterController() -> UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"
    guard isBundledApp else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    if InstallOrigin.isHomebrewCask(appBundleURL: bundleURL) {
        return DisabledUpdaterController(
            unavailableReason: "Updates managed by Homebrew. Run: brew upgrade --cask steipete/tap/codexbar")
    }

    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdaterController(unavailableReason: "Updates unavailable in this build.")
    }

    let defaults = UserDefaults.standard
    let autoUpdateKey = "autoUpdateEnabled"
    // Default to true for first launch; fall back to saved preference thereafter.
    let savedAutoUpdate = (defaults.object(forKey: autoUpdateKey) as? Bool) ?? true
    return SparkleUpdaterController(savedAutoUpdate: savedAutoUpdate)
}
#else
private func makeUpdaterController() -> UpdaterProviding {
    DisabledUpdaterController()
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    struct Dependencies {
        let store: UsageStore
        let settings: SettingsStore
        let account: AccountInfo
        let selection: PreferencesSelection
        let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
        let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    }

    let updaterController: UpdaterProviding = makeUpdaterController()
    private let confettiOverlayController = ScreenConfettiOverlayController()
    private let confettiLogger = CodexBarLog.logger(LogCategories.confetti)
    private let hooksLogger = CodexBarLog.logger("hooks")
    private var statusController: StatusItemControlling?
    private var store: UsageStore?
    private var settings: SettingsStore?
    private var account: AccountInfo?
    private var preferencesSelection: PreferencesSelection?
    private var managedCodexAccountCoordinator: ManagedCodexAccountCoordinator?
    private var codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator?
    private var hasInstalledWeeklyLimitResetObserver = false
    private var hookReceiver: HookEventReceiver?
    private var hookConsumerTask: Task<Void, Never>?
    private var petClient: PetBLEClient?
    private var petBridge: PetUsageBridge?
    private var petPushTimer: Timer?
    private var petLastMode: UInt8 = PetMode.idle.rawValue

    func configure(_ dependencies: Dependencies) {
        self.store = dependencies.store
        self.settings = dependencies.settings
        self.account = dependencies.account
        self.preferencesSelection = dependencies.selection
        self.managedCodexAccountCoordinator = dependencies.managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = dependencies.codexAccountPromotionCoordinator
        self.petBridge = PetUsageBridge(store: dependencies.store, settings: dependencies.settings)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        self.configureAppIconForMacOSVersion()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppNotifications.shared.requestAuthorizationOnStartup()
        self.ensureStatusController()
        KeyboardShortcuts.onKeyUp(for: .openMenu) { [weak self] in
            Task { @MainActor [weak self] in
                self?.statusController?.openMenuFromShortcut()
            }
        }
        if !self.hasInstalledWeeklyLimitResetObserver {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleWeeklyLimitResetNotification(_:)),
                name: .codexbarWeeklyLimitReset,
                object: nil)
            self.hasInstalledWeeklyLimitResetObserver = true
        }
        self.startHookReceiver()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.confettiOverlayController.dismiss()
        TTYCommandRunner.terminateActiveProcessesForAppShutdown()
        self.petPushTimer?.invalidate()
        self.petPushTimer = nil
        self.hookConsumerTask?.cancel()
        self.hookReceiver?.stop()
    }

    private func startHookReceiver() {
        guard self.hookReceiver == nil else { return }

        // Keep the on-disk shim script in sync with our embedded source. The
        // CLI side may already point at ~/.codexbar/bin/petbar-hook from a
        // previous install — re-writing here picks up any schema or socket-
        // path changes when CodexBar updates.
        do {
            try PetHookShim.ensureInstalled()
        } catch {
            self.hooksLogger.warning(
                "could not refresh hook shim",
                metadata: ["error": "\(error)"])
        }

        let receiver = HookEventReceiver()
        do {
            try receiver.start()
        } catch {
            self.hooksLogger.warning(
                "could not start hook receiver",
                metadata: ["error": "\(error)"])
            return
        }
        self.hookReceiver = receiver

        // Start the BLE central too. It scans for "ClawdPet" + the pet
        // service UUID; if no pet is present nothing bad happens (logs a
        // warning when Bluetooth itself is off). When the pet shows up,
        // subsequent hook events get pushed as PetStatus writes.
        let pet = PetBLEClient()
        pet.start()
        self.petClient = pet
        PetSharedAccess.client = pet

        // Periodically refresh the slow fields (5h%, week%, today_tokens,
        // epoch) so the pet's right-side dashboard isn't frozen between
        // hook events. The interval is user-configurable in Preferences;
        // we clamp to a sane window so a malformed value cannot starve or
        // flood the BLE link.
        let interval = max(1.0, min(60.0, self.settings?.petPushIntervalSeconds ?? 5.0))
        self.petPushTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushPetStatusPeriodic() }
        }
        // Push once immediately so the pet doesn't show zeros until the
        // first timer tick lands 5s later.
        self.pushPetStatusPeriodic()

        // Drain the AsyncStream and forward each event to the pet as a
        // PetStatus snapshot. Provider/usage stay zero for now (M2 will
        // wire ProviderState into this path); mode and req_counter are
        // the immediately useful signals to expose.
        self.hookConsumerTask = Task.detached { [weak self] in
            for await event in receiver.events {
                guard let self else { continue }
                await self.consumeHookEvent(event)
            }
        }
    }

    private func consumeHookEvent(_ event: HookEvent) {
        self.hooksLogger.debug(
            "consumed hook event",
            metadata: [
                "kind": event.kind.rawValue,
                "tool": event.toolName ?? "-",
                "source": event.source.rawValue,
            ])
        // Hook event only carries "what the user is doing right now" — the
        // mode. Numeric fields (5h%, week%, today_tokens) come from the
        // UsageStore via PetUsageBridge. Merge the two here so a single
        // BLE write covers both axes.
        let mode = PetMode.from(hookEvent: event)
        self.petLastMode = mode.rawValue
        let snapshot = self.petBridge?.snapshot() ?? PetStatus()
        var status = snapshot
        status.mode = mode.rawValue
        status.epochSeconds = UInt32(Date().timeIntervalSince1970)
        self.petClient?.pushStatus(status)
    }

    private func pushPetStatusPeriodic() {
        guard let client = self.petClient, let bridge = self.petBridge else { return }
        var status = bridge.snapshot()
        status.mode = self.petLastMode
        client.pushStatus(status)
    }

    func runProviderLoginFlow(_ provider: UsageProvider) async {
        self.ensureStatusController()
        guard let statusController else { return }
        await statusController.runLoginFlowFromSettings(provider: provider)
    }

    @objc private func handleWeeklyLimitResetNotification(_ notification: Notification) {
        guard let event = notification.object as? WeeklyLimitResetEvent else { return }
        guard self.settings?.confettiOnWeeklyLimitResetsEnabled == true else { return }
        let origin = self.statusController?.celebrationOriginPoint(for: event.provider)
        self.confettiLogger.info(
            "Triggering confetti",
            metadata: [
                "provider": event.provider.rawValue,
                "accountIdentifier": event.accountIdentifier,
                "originKnown": origin == nil ? "0" : "1",
            ])
        self.confettiOverlayController.play(originInScreen: origin)
    }

    /// Use the classic (non-Liquid Glass) app icon on macOS versions before 26.
    private func configureAppIconForMacOSVersion() {
        if #unavailable(macOS 26) {
            self.applyClassicAppIcon()
        }
    }

    private func applyClassicAppIcon() {
        guard let classicIcon = Self.loadClassicIcon() else { return }
        NSApp.applicationIconImage = classicIcon
    }

    private static func loadClassicIcon() -> NSImage? {
        guard let url = self.classicIconURL(),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        return image
    }

    private static func classicIconURL() -> URL? {
        Bundle.main.url(forResource: "Icon-classic", withExtension: "icns")
    }

    private func ensureStatusController() {
        if self.statusController != nil { return }

        if let store,
           let settings,
           let account,
           let selection = self.preferencesSelection,
           let managedCodexAccountCoordinator,
           let codexAccountPromotionCoordinator
        {
            self.statusController = StatusItemController.factory(
                store,
                settings,
                account,
                self.updaterController,
                selection,
                managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator)
            return
        }

        // Defensive fallback: this should not be hit in normal app lifecycle.
        CodexBarLog.logger(LogCategories.app)
            .error("StatusItemController fallback path used; settings/store mismatch likely.")
        assertionFailure("StatusItemController fallback path used; check app lifecycle wiring.")
        let fallbackSettings = SettingsStore()
        let fetcher = UsageFetcher()
        let browserDetection = BrowserDetection(cacheTTL: BrowserDetection.defaultCacheTTL)
        let fallbackAccount = fetcher.loadAccountInfo()
        let fallbackStore = UsageStore(fetcher: fetcher, browserDetection: browserDetection, settings: fallbackSettings)
        let fallbackManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator()
        let fallbackCodexAccountPromotionCoordinator = CodexAccountPromotionCoordinator(
            settingsStore: fallbackSettings,
            usageStore: fallbackStore,
            managedAccountCoordinator: fallbackManagedCodexAccountCoordinator)
        self.statusController = StatusItemController.factory(
            fallbackStore,
            fallbackSettings,
            fallbackAccount,
            self.updaterController,
            PreferencesSelection(),
            fallbackManagedCodexAccountCoordinator,
            fallbackCodexAccountPromotionCoordinator)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

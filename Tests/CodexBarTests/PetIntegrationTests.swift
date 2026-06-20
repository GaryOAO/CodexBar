import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PetIntegrationTests {
    @Test
    func `pet status encodes eighteen byte payload with one billion tokens`() {
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 90,
            usageWeekPct: 91,
            mode: PetMode.celebrating.rawValue,
            flags: PetStatus.flagBitFiveHourWarning | PetStatus.flagBitWeeklyWarning,
            presentation: 0x12,
            reset5hMinutes: 15,
            resetWeekMinutes: 120,
            todayTokens: 1_000_000_000,
            epochSeconds: 1_800_000_000)

        let data = status.encoded()

        #expect(data.count == PetStatus.wireSize)
        #expect(Array(data.prefix(6)) == [
            PetProvider.claude.rawValue,
            90,
            91,
            PetMode.celebrating.rawValue,
            PetStatus.flagBitFiveHourWarning | PetStatus.flagBitWeeklyWarning,
            0x12,
        ])
        #expect(data[10] == 0x00)
        #expect(data[11] == 0xCA)
        #expect(data[12] == 0x9A)
        #expect(data[13] == 0x3B)
    }

    @Test
    func `pet device state decodes sixteen byte little endian payload`() throws {
        let data = Data([
            0x29, 0x09, // 23.45 C
            56,
            87,
            0x75, 0x0E, // 3701 mV
            12,
            34,
            80,
            65,
            UInt8(bitPattern: Int8(-7)),
            44,
            11,
            PetDeviceState.sleepFlagLocalQuiet
                | PetDeviceState.sleepFlagSoftPowerOff
                | PetDeviceState.sleepFlagPanelSleepActive,
            0x4D, 0x0E, // 3661 s
        ])

        let state = try #require(PetDeviceState.decode(data))

        #expect(state.tempCentiC == 2345)
        #expect(state.temperatureCelsius == 23.45)
        #expect(state.humidityPct == 56)
        #expect(state.batteryPct == 87)
        #expect(state.batteryMv == 3701)
        #expect(state.batteryVolts == 3.701)
        #expect(state.petLevel == 12)
        #expect(state.hunger == 34)
        #expect(state.happiness == 80)
        #expect(state.energy == 65)
        #expect(state.mood == -7)
        #expect(state.bond == 44)
        #expect(state.stress == 11)
        #expect(state.isLocalQuiet)
        #expect(state.isSoftPowerOff)
        #expect(state.isPanelSleepActive)
        #expect(state.uptimeSeconds == 3661)
    }

    @Test
    func `pet device state maps sentinels to unknown values`() throws {
        let data = Data([
            0x00, 0x80,
            UInt8.max,
            UInt8.max,
            0x00, 0x00,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            0,
            8, 0,
        ])

        let state = try #require(PetDeviceState.decode(data))

        #expect(state.tempCentiC == nil)
        #expect(state.temperatureCelsius == nil)
        #expect(state.humidityPct == nil)
        #expect(state.batteryPct == nil)
        #expect(state.batteryMv == nil)
        #expect(state.batteryVolts == nil)
        #expect(!state.isLocalQuiet)
        #expect(!state.isSoftPowerOff)
        #expect(!state.isPanelSleepActive)
        #expect(PetDeviceState.decode(Data([0x00])) == nil)
    }

    @Test
    func `pet ble ipc command and snapshot round trip through json`() throws {
        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 37,
            usageWeekPct: 62,
            mode: PetMode.working.rawValue,
            flags: PetStatus.flagBitAnyFetching,
            presentation: 0x21,
            reset5hMinutes: 42,
            resetWeekMinutes: 777,
            todayTokens: 1_100_000_000,
            epochSeconds: 1_800_000_123)
        let codexStatus = PetCodexStatus(
            usage5hPct: 22,
            usageWeekPct: 44,
            reset5hMinutes: 21,
            resetWeekMinutes: 700,
            todayTokens: 2_200_000_000,
            epochSeconds: 1_800_000_124)
        let command = PetBLEIPCCommand.pushProviderStatuses(status, codexStatus)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let commandData = try encoder.encode(command)
        let decodedCommand = try JSONDecoder().decode(PetBLEIPCCommand.self, from: commandData)

        #expect(decodedCommand == command)

        let deviceState = PetDeviceState(
            tempCentiC: 2590,
            humidityPct: 68,
            batteryPct: 89,
            batteryMv: 4065,
            petLevel: 3,
            hunger: 12,
            happiness: 77,
            energy: 54,
            mood: -2,
            bond: 44,
            stress: 8,
            sleepFlags: PetDeviceState.sleepFlagPanelSleepActive,
            uptimeSeconds: 3661)
        let snapshot = PetBLESnapshot(
            state: "ready",
            authorizationRawValue: 3,
            runtimeDetail: "BLE connected to ClawdPet",
            firmwareInfo: "ClawdPet/1.0 ESP32-S3-RLCD",
            peripheralName: "ClawdPet",
            rssi: -47,
            lastStatus: status,
            lastStatusSentAt: 1_800_000_124,
            lastTheme: .clawd,
            lastThemeSentAt: 1_800_000_125,
            deviceState: deviceState,
            deviceStateUpdatedAt: 1_800_000_126)
        let event = PetBLEIPCEvent.snapshot(
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            snapshot)

        let eventData = try encoder.encode(event)
        let decodedEvent = try JSONDecoder().decode(PetBLEIPCEvent.self, from: eventData)

        #expect(decodedEvent == event)
    }

    @Test
    func `pet ble helper proxy writes command into shared defaults`() throws {
        let suite = "PetIntegrationTests-helper-proxy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetIntegrationTests-helper-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let proxy = PetBLEHelperProxy(defaults: defaults, containerURL: container)

        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 12,
            usageWeekPct: 34,
            mode: PetMode.working.rawValue,
            flags: 0,
            presentation: 0x11,
            todayTokens: 1_100_000_000,
            epochSeconds: 1_800_000_000)
        let requestID = try #require(proxy.send(.pushStatus(status)))

        let data = try #require(defaults.data(forKey: PetBLEIPCBridge.commandDefaultsKey))
        let request = try JSONDecoder().decode(PetBLEIPCRequest.self, from: data)
        let fileData = try Data(contentsOf: container.appendingPathComponent(PetBLEIPCBridge.commandFilename))
        let fileRequest = try JSONDecoder().decode(PetBLEIPCRequest.self, from: fileData)

        #expect(request.requestID == requestID)
        #expect(fileRequest == request)
        #expect(defaults.string(forKey: PetBLEIPCBridge.commandIDDefaultsKey) == requestID.uuidString)
        #expect(request.command == .pushStatus(status))
    }

    @Test
    func `pet ble helper proxy writes combined provider statuses command`() throws {
        let suite = "PetIntegrationTests-helper-provider-statuses-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PetIntegrationTests-helper-provider-statuses-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let proxy = PetBLEHelperProxy(defaults: defaults, containerURL: container)

        let status = PetStatus(
            providerIdx: PetProvider.claude.rawValue,
            usage5hPct: 12,
            usageWeekPct: 34,
            mode: PetMode.working.rawValue,
            flags: 0,
            presentation: 0x11,
            todayTokens: 1_100_000_000,
            epochSeconds: 1_800_000_000)
        let codexStatus = PetCodexStatus(
            usage5hPct: 56,
            usageWeekPct: 78,
            todayTokens: 2_200_000_000,
            epochSeconds: 1_800_000_001)

        let requestID = try #require(proxy.send(.pushProviderStatuses(status, codexStatus)))

        let data = try #require(defaults.data(forKey: PetBLEIPCBridge.commandDefaultsKey))
        let request = try JSONDecoder().decode(PetBLEIPCRequest.self, from: data)
        #expect(request.requestID == requestID)
        #expect(request.command == .pushProviderStatuses(status, codexStatus))
    }

    @Test
    func `pet ble helper proxy writes display config command`() throws {
        let suite = "PetIntegrationTests-helper-display-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("PetIntegrationTests-helper-display-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let proxy = PetBLEHelperProxy(defaults: defaults, containerURL: container)
        let config = PetDisplayConfig(
            locale: .chinese,
            defaultLayout: .metrics,
            hideCodex: true,
            compactMode: true)

        let requestID = try #require(proxy.send(.setDisplayConfig(config)))

        let data = try #require(defaults.data(forKey: PetBLEIPCBridge.commandDefaultsKey))
        let request = try JSONDecoder().decode(PetBLEIPCRequest.self, from: data)
        #expect(request.requestID == requestID)
        #expect(request.command == .setDisplayConfig(config))
    }

    @Test
    func `pet settings persist sanitized defaults`() throws {
        let suite = "PetIntegrationTests-settings"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(90.0, forKey: "petPushIntervalSeconds")
        defaults.set(99, forKey: "petQuietHoursStart")
        defaults.set(-1, forKey: "petQuietHoursEnd")
        defaults.set("bad-display", forKey: "petUsageDisplay")
        defaults.set("bad-personality", forKey: "petPersonality")
        let settings = Self.makeSettingsStore(userDefaults: defaults, suite: suite)

        #expect(settings.petEnabled == false)
        #expect(settings.petPushIntervalSeconds == 60.0)
        #expect(settings.petQuietHoursStart == 23)
        #expect(settings.petQuietHoursEnd == 0)
        #expect(settings.petUsageDisplay == .remaining)
        #expect(settings.petPersonality == .playful)

        settings.petEnabled = true
        settings.petPushIntervalSeconds = 0
        settings.petUsageDisplay = .both
        settings.petPersonality = .focus

        #expect(defaults.bool(forKey: "petEnabled"))
        #expect(defaults.double(forKey: "petPushIntervalSeconds") == 1.0)
        #expect(defaults.string(forKey: "petUsageDisplay") == "both")
        #expect(defaults.string(forKey: "petPersonality") == "focus")
    }

    @Test
    func `quiet hours handles same day and midnight wrapped windows`() {
        #expect(PetUsageBridge.isHourInQuietWindow(hour: 23, start: 22, end: 7))
        #expect(PetUsageBridge.isHourInQuietWindow(hour: 3, start: 22, end: 7))
        #expect(!PetUsageBridge.isHourInQuietWindow(hour: 12, start: 22, end: 7))
        #expect(PetUsageBridge.isHourInQuietWindow(hour: 10, start: 9, end: 17))
        #expect(!PetUsageBridge.isHourInQuietWindow(hour: 18, start: 9, end: 17))
        #expect(!PetUsageBridge.isHourInQuietWindow(hour: 9, start: 9, end: 9))
    }

    @Test
    func `pet bridge matches token UI today semantics and presentation settings`() throws {
        let suite = "PetIntegrationTests-bridge"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = Self.makeSettingsStore(userDefaults: defaults, suite: suite)
        settings.petQuipsEnabled = false
        settings.petMicroActionsEnabled = false
        settings.petMilestoneCelebrationsEnabled = false
        settings.petUsageDisplay = .both
        settings.petPersonality = .focus
        let store = Self.makeUsageStore(settings: settings)
        let now = Self.date("2026-05-19T10:00:00+08:00")
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(15 * 60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 91,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: now.addingTimeInterval(120 * 60),
                    resetDescription: nil),
                updatedAt: now),
            provider: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 1_000_000_000,
                sessionCostUSD: 1.25,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-05-18",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 42,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                    CostUsageDailyReport.Entry(
                        date: "2026-05-19",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 123_456,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now),
            provider: .claude)

        let status = PetUsageBridge(store: store, settings: settings, now: { now }).snapshot()

        #expect(status.usage5hPct == 100)
        #expect(status.usageWeekPct == 91)
        #expect(status.todayTokens == 123_456)
        #expect(status.flags & PetStatus.flagBitFiveHourWarning != 0)
        #expect(status.flags & PetStatus.flagBitWeeklyWarning != 0)
        #expect(status.flags & PetStatus.flagBitRateLimited != 0)
        #expect(status.flags & PetStatus.flagBitQuipsDisabled != 0)
        #expect(status.flags & PetStatus.flagBitMicroActionsDisabled != 0)
        #expect(status.flags & PetStatus.flagBitMilestonesDisabled != 0)
        #expect(status.presentation == 0x22)
    }

    @Test
    func `pet bridge falls back to latest local snapshot when a new day bucket has not landed`() throws {
        let suite = "PetIntegrationTests-bridge-prior-day"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = Self.makeSettingsStore(userDefaults: defaults, suite: suite)
        let store = Self.makeUsageStore(settings: settings)
        let now = Self.date("2026-05-19T10:00:00+08:00")
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 118_363_055,
                sessionCostUSD: 1.25,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                daily: [
                    CostUsageDailyReport.Entry(
                        date: "2026-05-18",
                        inputTokens: nil,
                        outputTokens: nil,
                        totalTokens: 118_363_055,
                        costUSD: nil,
                        modelsUsed: nil,
                        modelBreakdowns: nil),
                ],
                updatedAt: now),
            provider: .claude)

        let status = PetUsageBridge(store: store, settings: settings, now: { now }).snapshot()

        #expect(status.todayTokens == 118_363_055)
    }

    private static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private static func makeSettingsStore(userDefaults: UserDefaults, suite: String) -> SettingsStore {
        SettingsStore(userDefaults: userDefaults, configStore: testConfigStore(suiteName: suite), codexCookieStore: InMemoryCookieHeaderStore(), claudeCookieStore: InMemoryCookieHeaderStore(), tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeUsageStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }
}

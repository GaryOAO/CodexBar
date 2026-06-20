import Foundation

/// Theme command shared by the main app and the future sandboxed BLE helper.
/// Values intentionally mirror the ESP32 `cbar_theme_t` wire enum.
public enum PetTheme: UInt8, Sendable, Codable, Equatable {
    case auto = 0
    case clawd = 1
    case calico = 2
    case cloudling = 3
    case tank = 4
}

/// Snapshot emitted by the BLE runtime/helper. It is deliberately plain data
/// so the main app can render the Pet pane without linking to CoreBluetooth in
/// the long-term helper architecture.
public struct PetBLESnapshot: Sendable, Codable, Equatable {
    public var state: String
    public var authorizationRawValue: Int
    public var runtimeDetail: String
    public var firmwareInfo: String?
    public var peripheralName: String?
    public var rssi: Int?
    public var lastStatus: PetStatus?
    public var lastStatusSentAt: TimeInterval?
    public var lastCodexStatus: PetCodexStatus?
    public var lastCodexStatusSentAt: TimeInterval?
    public var lastTheme: PetTheme?
    public var lastThemeSentAt: TimeInterval?
    public var deviceState: PetDeviceState?
    public var deviceStateUpdatedAt: TimeInterval?
    public var lastDisplayConfig: PetDisplayConfig?
    public var lastDisplayConfigSentAt: TimeInterval?

    public init(
        state: String,
        authorizationRawValue: Int,
        runtimeDetail: String,
        firmwareInfo: String? = nil,
        peripheralName: String? = nil,
        rssi: Int? = nil,
        lastStatus: PetStatus? = nil,
        lastStatusSentAt: TimeInterval? = nil,
        lastCodexStatus: PetCodexStatus? = nil,
        lastCodexStatusSentAt: TimeInterval? = nil,
        lastTheme: PetTheme? = nil,
        lastThemeSentAt: TimeInterval? = nil,
        deviceState: PetDeviceState? = nil,
        deviceStateUpdatedAt: TimeInterval? = nil,
        lastDisplayConfig: PetDisplayConfig? = nil,
        lastDisplayConfigSentAt: TimeInterval? = nil)
    {
        self.state = state
        self.authorizationRawValue = authorizationRawValue
        self.runtimeDetail = runtimeDetail
        self.firmwareInfo = firmwareInfo
        self.peripheralName = peripheralName
        self.rssi = rssi
        self.lastStatus = lastStatus
        self.lastStatusSentAt = lastStatusSentAt
        self.lastCodexStatus = lastCodexStatus
        self.lastCodexStatusSentAt = lastCodexStatusSentAt
        self.lastTheme = lastTheme
        self.lastThemeSentAt = lastThemeSentAt
        self.deviceState = deviceState
        self.deviceStateUpdatedAt = deviceStateUpdatedAt
        self.lastDisplayConfig = lastDisplayConfig
        self.lastDisplayConfigSentAt = lastDisplayConfigSentAt
    }
}

/// Commands sent by the main app to the BLE helper. The helper will own the
/// actual CoreBluetooth objects; the main app will keep UsageStore/hook logic
/// and push compact status/theme commands over IPC.
public enum PetBLEIPCCommand: Sendable, Codable, Equatable {
    case start
    case stop
    case restartForForegroundAuthorization
    case pushStatus(PetStatus)
    case setTheme(PetTheme)
    case snapshot
    case shutdown
    case pushCodexStatus(PetCodexStatus)
    case pushProviderStatuses(PetStatus, PetCodexStatus)
    case setDisplayConfig(PetDisplayConfig)
}

/// Frames sent back by the helper. Each command that expects a reply carries a
/// caller-provided request id; async snapshot updates can use `nil`.
public enum PetBLEIPCEvent: Sendable, Codable, Equatable {
    case ack(requestID: UUID?)
    case error(requestID: UUID?, message: String)
    case snapshot(requestID: UUID?, PetBLESnapshot)
}

public struct PetBLEIPCRequest: Sendable, Codable, Equatable {
    public var requestID: UUID
    public var createdAt: TimeInterval
    public var command: PetBLEIPCCommand

    public init(
        requestID: UUID = UUID(),
        createdAt: TimeInterval = Date().timeIntervalSince1970,
        command: PetBLEIPCCommand)
    {
        self.requestID = requestID
        self.createdAt = createdAt
        self.command = command
    }
}

public enum PetBLEIPCBridge {
    public static let commandDefaultsKey = "petBLEHelperCommandJSON"
    public static let commandIDDefaultsKey = "petBLEHelperCommandID"
    public static let eventDefaultsKey = "petBLEHelperEventJSON"
    public static let eventIDDefaultsKey = "petBLEHelperEventID"
    public static let snapshotDefaultsKey = "petBLEHelperSnapshotJSON"
    public static let commandFilename = "pet-ble-command.json"
    public static let eventFilename = "pet-ble-event.json"
    public static let snapshotFilename = "pet-ble-snapshot.json"
    public static let commandNotificationName = Notification.Name("com.steipete.codexbar.petble.command")
    public static let eventNotificationName = Notification.Name("com.steipete.codexbar.petble.event")

    public static func sharedDefaults(
        bundleID: String? = Bundle.main.bundleIdentifier)
        -> UserDefaults
    {
        AppGroupSupport.sharedDefaults(bundleID: bundleID) ?? .standard
    }

    public static func sharedContainerURL(
        bundleID: String? = Bundle.main.bundleIdentifier)
        -> URL?
    {
        AppGroupSupport.currentContainerURL(bundleID: bundleID)
    }
}

#if os(macOS)
public final class PetBLEHelperProxy: @unchecked Sendable {
    private let defaults: UserDefaults
    private let containerURL: URL?
    private let center: DistributedNotificationCenter
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = PetBLEIPCBridge.sharedDefaults(),
        containerURL: URL? = PetBLEIPCBridge.sharedContainerURL(),
        center: DistributedNotificationCenter = .default())
    {
        self.defaults = defaults
        self.containerURL = containerURL
        self.center = center
    }

    @discardableResult
    public func send(_ command: PetBLEIPCCommand) -> UUID? {
        let request = PetBLEIPCRequest(command: command)
        guard let data = try? self.encoder.encode(request) else { return nil }
        self.write(data, filename: PetBLEIPCBridge.commandFilename, defaultsKey: PetBLEIPCBridge.commandDefaultsKey)
        self.defaults.set(data, forKey: PetBLEIPCBridge.commandDefaultsKey)
        self.defaults.set(request.requestID.uuidString, forKey: PetBLEIPCBridge.commandIDDefaultsKey)
        self.defaults.synchronize()
        self.center.postNotificationName(
            PetBLEIPCBridge.commandNotificationName,
            object: nil,
            userInfo: ["requestID": request.requestID.uuidString],
            deliverImmediately: true)
        return request.requestID
    }

    public func start() {
        self.send(.start)
    }

    public func stop() {
        self.send(.stop)
    }

    public func restartForForegroundAuthorization() {
        self.send(.restartForForegroundAuthorization)
    }

    public func pushStatus(_ status: PetStatus) {
        self.send(.pushStatus(status))
    }

    public func pushCodexStatus(_ status: PetCodexStatus) {
        self.send(.pushCodexStatus(status))
    }

    public func pushProviderStatuses(_ status: PetStatus, codexStatus: PetCodexStatus) {
        self.send(.pushProviderStatuses(status, codexStatus))
    }

    public func setTheme(_ theme: PetTheme) {
        self.send(.setTheme(theme))
    }

    public func setDisplayConfig(_ config: PetDisplayConfig) {
        self.send(.setDisplayConfig(config))
    }

    public func requestSnapshot() {
        self.send(.snapshot)
    }

    public func lastEvent() -> PetBLEIPCEvent? {
        guard let data = self.read(
            filename: PetBLEIPCBridge.eventFilename,
            defaultsKey: PetBLEIPCBridge.eventDefaultsKey)
        else { return nil }
        return try? self.decoder.decode(PetBLEIPCEvent.self, from: data)
    }

    public func lastSnapshot() -> PetBLESnapshot? {
        guard let data = self.read(
            filename: PetBLEIPCBridge.snapshotFilename,
            defaultsKey: PetBLEIPCBridge.snapshotDefaultsKey)
        else { return nil }
        return try? self.decoder.decode(PetBLESnapshot.self, from: data)
    }

    private func url(for filename: String) -> URL? {
        self.containerURL?.appendingPathComponent(filename, isDirectory: false)
    }

    private func write(_ data: Data, filename: String, defaultsKey: String) {
        if let url = self.url(for: filename) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        self.defaults.set(data, forKey: defaultsKey)
    }

    private func read(filename: String, defaultsKey: String) -> Data? {
        if let url = self.url(for: filename),
           let data = try? Data(contentsOf: url)
        {
            return data
        }
        return self.defaults.data(forKey: defaultsKey)
    }
}
#endif

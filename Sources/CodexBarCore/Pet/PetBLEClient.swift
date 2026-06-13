#if os(macOS)
@preconcurrency import CoreBluetooth
import Foundation

/// CoreBluetooth central that pairs CodexBar (mac) with the ESP32-S3 pet.
///
/// Lifecycle:
///   let client = PetBLEClient()
///   client.start()
///   ...
///   client.pushStatus(PetStatus(...))
///   client.setTheme(.clawd)
///
/// State machine (driven entirely by CB callbacks; no manual reconnect loop):
///
///   .scanning  ── didDiscover ──▶ .connecting  ── didConnect ──▶ .servicesDiscovering
///   .servicesDiscovering ── chars ──▶ .ready
///   .ready ── didDisconnect ──▶ .scanning (re-scan automatically)
///   .authorizing = CoreBluetooth has not produced a TCC decision yet.
///   .permissionRequired = macOS denied/restricted Bluetooth access.
///
/// Reads firmware_info on connect so we can show "pet present + firmware
/// version" in the UI without polling.
public final class PetBLEClient: NSObject, @unchecked Sendable {
    public static let serviceUUID = CBUUID(string: "C0DEC0DE-0000-1000-8000-00805F9B34FB")
    public static let statusCharUUID = CBUUID(string: "C0DEC0DE-FFE1-1000-8000-00805F9B34FB")
    public static let themeCharUUID = CBUUID(string: "C0DEC0DE-FFE2-1000-8000-00805F9B34FB")
    public static let firmwareCharUUID = CBUUID(string: "C0DEC0DE-FFE3-1000-8000-00805F9B34FB")
    public static let deviceStateCharUUID = CBUUID(string: "C0DEC0DE-FFE4-1000-8000-00805F9B34FB")
    /// Added 2026-05-17 — carries Codex provider snapshot so OVERVIEW /
    /// METRICS / LIVING can show real CL and CX numbers side-by-side
    /// instead of duplicating Claude's value into both.
    public static let codexStatusCharUUID = CBUUID(string: "C0DEC0DE-FFE5-1000-8000-00805F9B34FB")
    /// Added 2026-05-17 — display_config block (locale + default layout +
    /// flags). Pet persists it to NVS, so the user's choice survives reboots
    /// even when CodexBar isn't running.
    public static let displayConfigCharUUID = CBUUID(string: "C0DEC0DE-FFE6-1000-8000-00805F9B34FB")

    public enum State: Sendable, Equatable {
        case off
        case authorizing
        case permissionRequired
        case scanning
        case connecting
        case ready
    }

    public enum Theme: UInt8, Sendable {
        case auto = 0
        case clawd = 1
        case calico = 2
        case cloudling = 3
        case tank = 4
    }

    /// Read-only state stream consumers can poll. Mutations happen on the
    /// internal queue; readers see the last published value.
    public private(set) var state: State = .off
    public private(set) var firmwareInfo: String?
    public private(set) var peripheralName: String?
    public private(set) var lastRSSI: Int?
    public private(set) var lastStatus: PetStatus?
    public private(set) var lastStatusSentAt: Date?
    public private(set) var lastTheme: Theme?
    public private(set) var lastThemeSentAt: Date?
    public private(set) var deviceState: PetDeviceState?
    public private(set) var deviceStateUpdatedAt: Date?
    public private(set) var lastCodexStatus: PetCodexStatus?
    public private(set) var lastCodexStatusSentAt: Date?
    public private(set) var lastDisplayConfig: PetDisplayConfig?
    public private(set) var lastDisplayConfigSentAt: Date?

    public var onStateChange: (@Sendable (State) -> Void)?
    public var onSnapshotChange: (@Sendable () -> Void)?

    private let log = CodexBarLog.logger("pet.ble")
    // Keep CoreBluetooth on the main queue. In an LSUIElement menu-bar app this
    // is more predictable than a private utility queue for the initial
    // CBCentralManager state callback, and all CBPeripheral calls stay on the
    // same delegate queue.
    private let queue = DispatchQueue.main
    private var central: CBCentralManager?
    private var permissionProbe: CBPeripheralManager?
    private var peripheral: CBPeripheral?
    private var statusChar: CBCharacteristic?
    private var themeChar: CBCharacteristic?
    private var firmwareChar: CBCharacteristic?
    private var deviceStateChar: CBCharacteristic?
    private var codexStatusChar: CBCharacteristic?
    private var displayConfigChar: CBCharacteristic?
    private var pendingStatus: Data?
    private var pendingTheme: UInt8?
    private var pendingCodexStatus: Data?
    private var pendingDisplayConfig: Data?
    private var recoveryConnectAttemptID: UUID?

    override public init() {
        super.init()
    }

    public func start() {
        self.queue.async {
            guard self.central == nil else { return }
            self.recordDiagnostic("start: creating CBCentralManager auth=\(CBManager.authorization.rawValue)")
            if Self.authorizationIsDeniedOrRestricted() {
                self.setState(.permissionRequired)
                return
            }
            if CBManager.authorization == .notDetermined {
                self.setState(.authorizing)
            }
            if CBManager.authorization == .notDetermined, self.permissionProbe == nil {
                self.recordDiagnostic("start: creating permission probe")
                self.permissionProbe = CBPeripheralManager(delegate: self, queue: self.queue)
            }
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: true])
            self
                .recordDiagnostic(
                    "start: manager created state=\(self.central?.state.rawValue ?? -1) "
                        + "auth=\(CBManager.authorization.rawValue)")
            self.queue.asyncAfter(deadline: .now() + 1.0) {
                guard let central = self.central else { return }
                self
                    .recordDiagnostic(
                        "central delayed state=\(central.state.rawValue) auth=\(CBManager.authorization.rawValue)")
                if central.state == .poweredOn, self.state != .scanning, self.state != .connecting,
                   self.state != .ready
                {
                    self.startScanIfReady()
                } else if central.state == .unknown, CBManager.authorization == .notDetermined {
                    self.recordDiagnostic("probe scan to request Bluetooth authorization")
                    self.setState(.authorizing)
                    central.scanForPeripherals(withServices: nil)
                }
            }
        }
    }

    public func stop() {
        self.queue.async {
            self.pendingStatus = nil
            self.pendingTheme = nil
            self.pendingCodexStatus = nil
            self.pendingDisplayConfig = nil
            self.recoveryConnectAttemptID = nil
            self.statusChar = nil
            self.themeChar = nil
            self.firmwareChar = nil
            self.deviceStateChar = nil
            self.codexStatusChar = nil
            self.displayConfigChar = nil
            self.firmwareInfo = nil
            self.peripheralName = nil
            self.lastRSSI = nil
            self.deviceState = nil
            self.deviceStateUpdatedAt = nil
            if let central = self.central {
                central.stopScan()
                if let peripheral = self.peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
            self.permissionProbe = nil
            self.peripheral = nil
            self.central = nil
            self.setState(.off)
            self.recordDiagnostic("stop: BLE runtime stopped")
        }
    }

    public func restartForForegroundAuthorization() {
        self.queue.async {
            self.recordDiagnostic(
                "foreground restart requested state=\(self.central?.state.rawValue ?? -1) "
                    + "auth=\(CBManager.authorization.rawValue)")
            self.pendingStatus = nil
            self.pendingTheme = nil
            self.pendingCodexStatus = nil
            self.pendingDisplayConfig = nil
            self.recoveryConnectAttemptID = nil
            self.statusChar = nil
            self.themeChar = nil
            self.firmwareChar = nil
            self.deviceStateChar = nil
            self.codexStatusChar = nil
            self.displayConfigChar = nil
            self.firmwareInfo = nil
            self.peripheralName = nil
            self.lastRSSI = nil
            self.deviceState = nil
            self.deviceStateUpdatedAt = nil
            if let central = self.central {
                central.stopScan()
                if let peripheral = self.peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
            self.permissionProbe = nil
            self.peripheral = nil
            self.central = nil
            self.setState(.off)
            self.queue.asyncAfter(deadline: .now() + 0.25) {
                self.start()
            }
        }
    }

    public func pushStatus(_ status: PetStatus) {
        let data = status.encoded()
        self.queue.async {
            self.lastStatus = status
            self.writeStatus(data)
            // Also serve to a BLE-central watch connecting directly to this Mac.
            PetBLEPeripheral.shared.update(claude: status)
        }
    }

    public func setTheme(_ theme: Theme) {
        let value = theme.rawValue
        self.queue.async {
            self.lastTheme = theme
            self.writeTheme(value)
        }
    }

    public func setTheme(_ theme: PetTheme) {
        self.setTheme(Theme(rawValue: theme.rawValue) ?? .clawd)
    }

    /// Push a Codex provider snapshot to the pet so OVERVIEW/METRICS/LIVING
    /// can show the CX column with real data. Pet treats `usage5hPct ==
    /// 0xFF` as "no data yet" — pass the real value or
    /// `PetCodexStatus.unknownPct` to surface a dash on the device.
    public func pushCodexStatus(_ status: PetCodexStatus) {
        let data = status.encoded()
        self.queue.async {
            self.lastCodexStatus = status
            self.writeCodexStatus(data)
            PetBLEPeripheral.shared.update(codex: status)
        }
    }

    /// Push a new display config to the pet. The pet persists it in NVS,
    /// so the choice survives reboots even when CodexBar is offline.
    public func setDisplayConfig(_ cfg: PetDisplayConfig) {
        let data = cfg.encoded()
        self.queue.async {
            self.lastDisplayConfig = cfg
            self.writeDisplayConfig(data)
        }
    }

    public func snapshot(runtimeDetail: String? = nil) -> PetBLESnapshot {
        PetBLESnapshot(
            state: String(describing: self.state),
            authorizationRawValue: CBManager.authorization.rawValue,
            runtimeDetail: runtimeDetail ?? (UserDefaults.standard.string(forKey: "petBleRuntimeDetail") ?? "—"),
            firmwareInfo: self.firmwareInfo,
            peripheralName: self.peripheralName,
            rssi: self.lastRSSI,
            lastStatus: self.lastStatus,
            lastStatusSentAt: self.lastStatusSentAt?.timeIntervalSince1970,
            lastCodexStatus: self.lastCodexStatus,
            lastCodexStatusSentAt: self.lastCodexStatusSentAt?.timeIntervalSince1970,
            lastTheme: self.lastTheme.map { PetTheme(rawValue: $0.rawValue) ?? .clawd },
            lastThemeSentAt: self.lastThemeSentAt?.timeIntervalSince1970,
            deviceState: self.deviceState,
            deviceStateUpdatedAt: self.deviceStateUpdatedAt?.timeIntervalSince1970,
            lastDisplayConfig: self.lastDisplayConfig,
            lastDisplayConfigSentAt: self.lastDisplayConfigSentAt?.timeIntervalSince1970)
    }

    public func refreshSnapshotInputs() {
        self.queue.async {
            guard self.state == .ready else { return }
            self.refreshReadableCharacteristics()
        }
    }

    // MARK: - Internal

    private func writeStatus(_ data: Data) {
        guard let p = self.peripheral, let c = self.statusChar else {
            self.pendingStatus = data
            return
        }
        p.writeValue(data, for: c, type: .withResponse)
    }

    private func writeTheme(_ value: UInt8) {
        guard let p = self.peripheral, let c = self.themeChar else {
            self.pendingTheme = value
            return
        }
        p.writeValue(Data([value]), for: c, type: .withResponse)
    }

    private func writeCodexStatus(_ data: Data) {
        guard let p = self.peripheral, let c = self.codexStatusChar else {
            self.pendingCodexStatus = data
            return
        }
        p.writeValue(data, for: c, type: .withResponse)
    }

    private func writeDisplayConfig(_ data: Data) {
        guard let p = self.peripheral, let c = self.displayConfigChar else {
            self.pendingDisplayConfig = data
            return
        }
        p.writeValue(data, for: c, type: .withResponse)
    }

    private func setState(_ new: State) {
        if self.state == new { return }
        self.state = new
        UserDefaults.standard.set(String(describing: new), forKey: "petBleState")
        UserDefaults.standard.set(CBManager.authorization.rawValue, forKey: "petBleAuthorization")
        self.recordDiagnostic("state=\(new)")
        let cb = self.onStateChange
        if let cb {
            DispatchQueue.main.async { cb(new) }
        }
    }

    private func flushPending() {
        if let s = self.pendingStatus {
            self.pendingStatus = nil
            self.writeStatus(s)
        }
        if let t = self.pendingTheme {
            self.pendingTheme = nil
            self.writeTheme(t)
        }
        if let cs = self.pendingCodexStatus {
            self.pendingCodexStatus = nil
            self.writeCodexStatus(cs)
        }
        if let dc = self.pendingDisplayConfig {
            self.pendingDisplayConfig = nil
            self.writeDisplayConfig(dc)
        }
    }

    private func refreshReadableCharacteristics() {
        guard let p = self.peripheral else { return }
        p.readRSSI()
        if let c = self.firmwareChar {
            p.readValue(for: c)
        }
        if let c = self.deviceStateChar {
            p.readValue(for: c)
        }
        if let c = self.displayConfigChar {
            p.readValue(for: c)
        }
    }

    private func connect(_ peripheral: CBPeripheral, recovered: Bool, reason: String) {
        guard let central = self.central else { return }
        self.peripheral = peripheral
        if let name = peripheral.name, !name.isEmpty {
            self.peripheralName = name
        }
        peripheral.delegate = self
        self.setState(.connecting)
        self.recordDiagnostic("connect: \(reason) \(peripheral.name ?? "unknown")")
        central.connect(peripheral)

        guard recovered else { return }
        let attemptID = UUID()
        self.recoveryConnectAttemptID = attemptID
        self.queue.asyncAfter(deadline: .now() + 6.0) {
            guard self.recoveryConnectAttemptID == attemptID,
                  self.state == .connecting,
                  self.peripheral?.identifier == peripheral.identifier,
                  let central = self.central
            else { return }
            self.recordDiagnostic("known peripheral connect timed out; falling back to scan")
            UserDefaults.standard.removeObject(forKey: "petBleLastPeripheralUUID")
            central.cancelPeripheralConnection(peripheral)
            if self.peripheral?.identifier == peripheral.identifier {
                self.peripheral = nil
            }
            self.startScanIfReady(skipRecovery: true)
        }
    }

    private func startScanIfReady(skipRecovery: Bool = false) {
        guard let c = self.central, c.state == .poweredOn else { return }

        if !skipRecovery {
            // 1. Try to recover a lingering connected peripheral.
            let connected = c.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
            if let p = connected.first {
                self.connect(p, recovered: true, reason: "recovering OS-connected peripheral")
                return
            }

            // 2. Try the last CoreBluetooth identifier, but do not let a stale
            // identifier suppress normal scanning forever.
            if let uuidString = UserDefaults.standard.string(forKey: "petBleLastPeripheralUUID"),
               let uuid = UUID(uuidString: uuidString)
            {
                let known = c.retrievePeripherals(withIdentifiers: [uuid])
                if let p = known.first {
                    self.connect(p, recovered: true, reason: "recovering known peripheral")
                    return
                }
            }
        }

        self.recoveryConnectAttemptID = nil
        self.setState(.scanning)
        // Some macOS builds are unreliable at matching 128-bit service filters
        // during early authorization / freshly-signed app launches. Scan broad,
        // then filter strictly in didDiscover by service UUID or advertised
        // local name before connecting.
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        self.recordDiagnostic("scan: broad filter=\(Self.serviceUUID.uuidString)")
        self.log.info("scanning for pet")
    }

    private static func authorizationIsDeniedOrRestricted() -> Bool {
        switch CBManager.authorization {
        case .denied, .restricted:
            true
        case .notDetermined, .allowedAlways:
            false
        @unknown default:
            true
        }
    }

    private func recordDiagnostic(_ message: String) {
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(message, forKey: "petBleRuntimeDetail")
        UserDefaults.standard.set(now, forKey: "petBleRuntimeUpdatedAt")
        UserDefaults.standard.set(CBManager.authorization.rawValue, forKey: "petBleAuthorization")
    }

    private func notifySnapshotChange() {
        guard let cb = self.onSnapshotChange else { return }
        DispatchQueue.main.async { cb() }
    }
}

extension PetBLEClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.recordDiagnostic("central state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            self.startScanIfReady()
        case .poweredOff:
            self.log.warning("bluetooth off")
            self.setState(.off)
        case .unauthorized:
            self.log.warning("bluetooth permission denied")
            self.setState(.permissionRequired)
        case .unsupported:
            self.log.warning("bluetooth unsupported")
            self.setState(.off)
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber)
    {
        let name = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "?"
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasPetService = advertisedServices.contains(Self.serviceUUID)
        let isPetName = name.caseInsensitiveCompare("ClawdPet") == .orderedSame
        guard hasPetService || isPetName else { return }
        self.peripheralName = name
        self.lastRSSI = RSSI.intValue
        self.recordDiagnostic("discover: \(name) rssi=\(RSSI) service=\(hasPetService)")
        self.log.info("discovered \(name) rssi=\(RSSI)")
        central.stopScan()

        // Save identifier for direct reconnection next time
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "petBleLastPeripheralUUID")

        self.connect(peripheral, recovered: false, reason: "discovered")
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.recordDiagnostic("connected: discovering services")
        if let name = peripheral.name, !name.isEmpty {
            self.peripheralName = name
        }
        self.recoveryConnectAttemptID = nil
        self.log.info("connected, discovering services")
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?)
    {
        self.recordDiagnostic("disconnect: \(error?.localizedDescription ?? "clean")")
        self.recoveryConnectAttemptID = nil
        self.log.info("disconnected: \(error?.localizedDescription ?? "clean")")
        self.peripheral = nil
        self.statusChar = nil
        self.themeChar = nil
        self.firmwareChar = nil
        self.deviceStateChar = nil
        self.codexStatusChar = nil
        self.displayConfigChar = nil
        self.firmwareInfo = nil
        self.peripheralName = nil
        self.lastRSSI = nil
        self.deviceState = nil
        self.deviceStateUpdatedAt = nil
        self.startScanIfReady()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?)
    {
        self.recordDiagnostic("connect failed: \(error?.localizedDescription ?? "?")")
        self.recoveryConnectAttemptID = nil
        self.log.warning("connect failed: \(error?.localizedDescription ?? "?")")
        self.peripheral = nil
        self.peripheralName = nil
        self.lastRSSI = nil
        self.startScanIfReady()
    }
}

extension PetBLEClient: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        self.recordDiagnostic(
            "permission probe state=\(peripheral.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        if peripheral.state == .unauthorized {
            self.setState(.permissionRequired)
        } else if peripheral.state == .poweredOn {
            self.startScanIfReady()
        }
    }
}

extension PetBLEClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            self.recordDiagnostic("discover services error: \(error.localizedDescription)")
        } else {
            self.recordDiagnostic("services: \(peripheral.services?.count ?? 0)")
        }
        for svc in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(
                [
                    Self.statusCharUUID,
                    Self.themeCharUUID,
                    Self.firmwareCharUUID,
                    Self.deviceStateCharUUID,
                    Self.codexStatusCharUUID,
                    Self.displayConfigCharUUID,
                ],
                for: svc)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?)
    {
        if let error {
            self.recordDiagnostic("discover chars error: \(error.localizedDescription)")
        } else {
            self.recordDiagnostic("chars: \(service.characteristics?.count ?? 0)")
        }
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.statusCharUUID:
                self.statusChar = ch
            case Self.themeCharUUID:
                self.themeChar = ch
            case Self.firmwareCharUUID:
                self.firmwareChar = ch
                peripheral.readValue(for: ch)
            case Self.deviceStateCharUUID:
                self.deviceStateChar = ch
                peripheral.readValue(for: ch)
                peripheral.setNotifyValue(true, for: ch)
            case Self.codexStatusCharUUID:
                self.codexStatusChar = ch
            case Self.displayConfigCharUUID:
                self.displayConfigChar = ch
                // Seed UI from current pet state on connect so the settings
                // sheet shows the value the user picked last time.
                peripheral.readValue(for: ch)
            default:
                break
            }
        }
        guard self.statusChar != nil, self.themeChar != nil else {
            self
                .recordDiagnostic(
                    "chars missing status=\(self.statusChar != nil) "
                        + "theme=\(self.themeChar != nil) device=\(self.deviceStateChar != nil)")
            self.log.warning("pet service missing required writable characteristics")
            self.central?.cancelPeripheralConnection(peripheral)
            return
        }
        self.setState(.ready)
        self.flushPending()
        peripheral.readRSSI()
        self.queue.asyncAfter(deadline: .now() + 0.75) {
            guard self.state == .ready, self.peripheral?.identifier == peripheral.identifier else { return }
            self.refreshReadableCharacteristics()
        }
        self.log.info("pet ready")
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?)
    {
        if let error {
            self.recordDiagnostic("read failed: \(characteristic.uuid) \(error.localizedDescription)")
            self.log.debug("read failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == Self.firmwareCharUUID, let data = characteristic.value {
            let s = String(data: data, encoding: .utf8) ?? "?"
            self.firmwareInfo = s
            self.recordDiagnostic("firmware: \(s)")
            self.log.info("pet firmware: \(s)")
            self.notifySnapshotChange()
        } else if characteristic.uuid == Self.deviceStateCharUUID, let data = characteristic.value {
            guard let state = PetDeviceState.decode(data) else {
                self.log.debug("invalid pet device_state length=\(data.count)")
                self.recordDiagnostic("device_state invalid length=\(data.count)")
                return
            }
            self.deviceState = state
            self.deviceStateUpdatedAt = Date()
            self
                .recordDiagnostic(
                    "device_state: battery=\(state.batteryPct.map(String.init) ?? "?") "
                        + "temp=\(state.tempCentiC.map(String.init) ?? "?")")
            self.notifySnapshotChange()
        } else if characteristic.uuid == Self.displayConfigCharUUID, let data = characteristic.value {
            // Pet pushed us the persisted config on connect (NVS-backed).
            // Cache it so the UI seeds correctly the first time the user
            // opens the settings sheet.
            if let cfg = PetDisplayConfig.decode(data) {
                self.lastDisplayConfig = cfg
                self.recordDiagnostic("display_config seed: locale=\(cfg.locale) layout=\(cfg.defaultLayout)")
                self.notifySnapshotChange()
            } else {
                self.log.debug("invalid display_config len=\(data.count)")
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if let error {
            self.recordDiagnostic("rssi read failed: \(error.localizedDescription)")
            self.log.debug("rssi read failed: \(error.localizedDescription)")
            return
        }
        self.lastRSSI = RSSI.intValue
        self.recordDiagnostic("rssi: \(RSSI.intValue) dBm")
        self.notifySnapshotChange()
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?)
    {
        if let error {
            self.log.debug("write failed for \(characteristic.uuid): \(error.localizedDescription)")
            self.recordDiagnostic("write failed: \(characteristic.uuid) \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == Self.statusCharUUID {
            self.lastStatusSentAt = Date()
            self.recordDiagnostic("status write ok")
        } else if characteristic.uuid == Self.themeCharUUID {
            self.lastThemeSentAt = Date()
            self.recordDiagnostic("theme write ok")
        } else if characteristic.uuid == Self.codexStatusCharUUID {
            self.lastCodexStatusSentAt = Date()
            self.recordDiagnostic("codex_status write ok")
        } else if characteristic.uuid == Self.displayConfigCharUUID {
            self.lastDisplayConfigSentAt = Date()
            self.recordDiagnostic("display_config write ok")
        }
        self.notifySnapshotChange()
    }
}
#endif

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
///
/// Reads firmware_info on connect so we can show "pet present + firmware
/// version" in the UI without polling.
public final class PetBLEClient: NSObject, @unchecked Sendable {
    public static let serviceUUID = CBUUID(string: "C0DEC0DE-0000-1000-8000-00805F9B34FB")
    public static let statusCharUUID = CBUUID(string: "C0DEC0DE-FFE1-1000-8000-00805F9B34FB")
    public static let themeCharUUID = CBUUID(string: "C0DEC0DE-FFE2-1000-8000-00805F9B34FB")
    public static let firmwareCharUUID = CBUUID(string: "C0DEC0DE-FFE3-1000-8000-00805F9B34FB")

    public enum State: Sendable, Equatable {
        case off
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

    public var onStateChange: (@Sendable (State) -> Void)?

    private let log = CodexBarLog.logger("pet.ble")
    private let queue = DispatchQueue(label: "com.steipete.codexbar.petble", qos: .utility)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var statusChar: CBCharacteristic?
    private var themeChar: CBCharacteristic?
    private var pendingStatus: Data?
    private var pendingTheme: UInt8?

    override public init() {
        super.init()
    }

    public func start() {
        self.queue.async {
            guard self.central == nil else { return }
            // showPowerAlert=false to avoid a popup if Bluetooth is off; the
            // user opts into the pet linkage explicitly via the UI button.
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    public func stop() {
        self.queue.async {
            self.pendingStatus = nil
            self.pendingTheme = nil
            self.statusChar = nil
            self.themeChar = nil
            self.firmwareInfo = nil
            self.peripheralName = nil
            self.lastRSSI = nil
            if let central = self.central {
                central.stopScan()
                if let peripheral = self.peripheral {
                    central.cancelPeripheralConnection(peripheral)
                }
            }
            self.peripheral = nil
            self.central = nil
            self.setState(.off)
        }
    }

    public func pushStatus(_ status: PetStatus) {
        let data = status.encoded()
        self.queue.async {
            self.lastStatus = status
            self.lastStatusSentAt = Date()
            self.writeStatus(data)
        }
    }

    public func setTheme(_ theme: Theme) {
        let value = theme.rawValue
        self.queue.async {
            self.lastTheme = theme
            self.lastThemeSentAt = Date()
            self.writeTheme(value)
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

    private func setState(_ new: State) {
        if self.state == new { return }
        self.state = new
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
    }

    private func startScanIfReady() {
        guard let c = self.central, c.state == .poweredOn else { return }
        self.setState(.scanning)
        c.scanForPeripherals(withServices: [Self.serviceUUID])
        self.log.info("scanning for pet")
    }
}

extension PetBLEClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            self.startScanIfReady()
        case .poweredOff:
            self.log.warning("bluetooth off")
            self.setState(.off)
        case .unauthorized:
            self.log.warning("bluetooth permission denied")
            self.setState(.off)
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
        self.peripheralName = name
        self.lastRSSI = RSSI.intValue
        self.log.info("discovered \(name) rssi=\(RSSI)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        self.setState(.connecting)
        central.connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        self.log.info("connected, discovering services")
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?)
    {
        self.log.info("disconnected: \(error?.localizedDescription ?? "clean")")
        self.peripheral = nil
        self.statusChar = nil
        self.themeChar = nil
        self.firmwareInfo = nil
        self.peripheralName = nil
        self.lastRSSI = nil
        self.startScanIfReady()
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?)
    {
        self.log.warning("connect failed: \(error?.localizedDescription ?? "?")")
        self.peripheral = nil
        self.peripheralName = nil
        self.lastRSSI = nil
        self.startScanIfReady()
    }
}

extension PetBLEClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for svc in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(
                [Self.statusCharUUID, Self.themeCharUUID, Self.firmwareCharUUID],
                for: svc)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?)
    {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.statusCharUUID:
                self.statusChar = ch
            case Self.themeCharUUID:
                self.themeChar = ch
            case Self.firmwareCharUUID:
                peripheral.readValue(for: ch)
            default:
                break
            }
        }
        self.setState(.ready)
        self.flushPending()
        self.log.info("pet ready")
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?)
    {
        if characteristic.uuid == Self.firmwareCharUUID, let data = characteristic.value {
            let s = String(data: data, encoding: .utf8) ?? "?"
            self.firmwareInfo = s
            self.log.info("pet firmware: \(s)")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?)
    {
        if let error {
            self.log.debug("write failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
}
#endif

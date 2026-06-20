#if os(macOS)
@preconcurrency import CoreBluetooth
import Foundation

/// BLE **peripheral** (GATT server) that advertises CodexBar's Claude / Codex
/// usage so a Zepp OS watch (which can only be a BLE central) can connect to
/// THIS Mac and read it directly — no phone, no ESP32 required.
///
/// It deliberately reuses the same service + FFE1/FFE5 characteristic UUIDs
/// and the identical 18-byte `PetStatus` wire format as the ESP32 pet, so the
/// watch parser is trivial. It advertises a **distinct local name**
/// ("CodexBarMac") so the watch targets the Mac, not the pet ("ClawdPet").
///
/// Fed by `PetBLEClient.pushStatus` / `pushCodexStatus` (see the one-line hooks
/// there), so the watch always sees exactly what the pet sees. Reads serve the
/// last cached value; subscribers get notified on each update.
public final class PetBLEPeripheral: NSObject, @unchecked Sendable {
    public static let shared = PetBLEPeripheral()

    public static let localName = "CodexBarMac"
    public static let serviceUUID = CBUUID(string: "C0DEC0DE-0000-1000-8000-00805F9B34FB")
    public static let claudeCharUUID = CBUUID(string: "C0DEC0DE-FFE1-1000-8000-00805F9B34FB")
    public static let codexCharUUID = CBUUID(string: "C0DEC0DE-FFE5-1000-8000-00805F9B34FB")

    private let log = CodexBarLog.logger("pet.ble.peripheral")
    private let queue = DispatchQueue.main
    private var manager: CBPeripheralManager?
    private var claudeChar: CBMutableCharacteristic?
    private var codexChar: CBMutableCharacteristic?
    private var serviceAdded = false
    private var advertising = false
    private var claudeValue = PetStatus().encoded()
    private var codexValue = PetCodexStatus().encoded()

    override private init() {
        super.init()
    }

    /// Idempotent. Safe to call at app launch; also auto-invoked on first update.
    public func start() {
        self.queue.async { self.ensureStarted() }
    }

    public func update(claude status: PetStatus) {
        let data = status.encoded()
        self.queue.async {
            self.claudeValue = data
            self.ensureStarted()
            if let c = self.claudeChar, let m = self.manager {
                m.updateValue(data, for: c, onSubscribedCentrals: nil)
            }
        }
    }

    public func update(codex status: PetCodexStatus) {
        let data = status.encoded()
        self.queue.async {
            self.codexValue = data
            self.ensureStarted()
            if let c = self.codexChar, let m = self.manager {
                m.updateValue(data, for: c, onSubscribedCentrals: nil)
            }
        }
    }

    // MARK: - Internal

    private func ensureStarted() {
        guard self.manager == nil else { return }
        self.manager = CBPeripheralManager(delegate: self, queue: self.queue)
        self.log.info("peripheral manager created")
    }

    private func buildServiceIfNeeded(_ m: CBPeripheralManager) {
        guard !self.serviceAdded else {
            self.startAdvertising(m)
            return
        }
        let claude = CBMutableCharacteristic(
            type: Self.claudeCharUUID, properties: [.read, .notify], value: nil, permissions: [.readable])
        let codex = CBMutableCharacteristic(
            type: Self.codexCharUUID, properties: [.read, .notify], value: nil, permissions: [.readable])
        self.claudeChar = claude
        self.codexChar = codex
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [claude, codex]
        m.add(service)
        self.serviceAdded = true
        // Advertising begins in peripheralManager(_:didAdd:error:).
    }

    private func startAdvertising(_ m: CBPeripheralManager) {
        guard !self.advertising else { return }
        m.startAdvertising([
            CBAdvertisementDataLocalNameKey: Self.localName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
        self.advertising = true
        self.log.info("advertising as \(Self.localName)")
    }

    private func value(for uuid: CBUUID) -> Data? {
        if uuid == Self.claudeCharUUID { return self.claudeValue }
        if uuid == Self.codexCharUUID { return self.codexValue }
        return nil
    }
}

extension PetBLEPeripheral: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            self.buildServiceIfNeeded(peripheral)
        case .unauthorized:
            self.log.warning("peripheral unauthorized (bluetooth permission)")
        case .poweredOff:
            self.advertising = false
        default:
            break
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?)
    {
        if let error {
            self.log.warning("add service failed: \(error.localizedDescription)")
            return
        }
        self.startAdvertising(peripheral)
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest)
    {
        guard let value = self.value(for: request.characteristic.uuid) else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }
        guard request.offset <= value.count else {
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }
        request.value = value.subdata(in: request.offset..<value.count)
        peripheral.respond(to: request, withResult: .success)
    }
}
#endif

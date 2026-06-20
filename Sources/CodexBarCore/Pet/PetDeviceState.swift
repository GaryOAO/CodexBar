import Foundation

/// 16-byte device-state payload sent from the ESP32 pet to CodexBar.
///
/// Wire layout, little-endian:
///   [0:2]  int16   tempCentiC       Int16.min = unknown
///   [2]    uint8   humidityPct      UInt8.max = unknown
///   [3]    uint8   batteryPct       UInt8.max = unknown
///   [4:6]  uint16  batteryMv        0 = unknown
///   [6]    uint8   petLevel
///   [7]    uint8   hunger
///   [8]    uint8   happiness
///   [9]    uint8   energy
///   [10]   int8    mood
///   [11]   uint8   bond
///   [12]   uint8   stress
///   [13]   uint8   sleepFlags       bit0: localQuiet, bit1: softPowerOff,
///                                      bit2: panelSleepActive
///   [14:16] uint16 uptimeSeconds
public struct PetDeviceState: Sendable, Equatable, Codable {
    public static let wireSize = 16
    public static let unknownTempCentiC = Int16.min
    public static let unknownPercent = UInt8.max
    public static let unknownBatteryMv: UInt16 = 0

    public static let sleepFlagLocalQuiet: UInt8 = 0x01
    public static let sleepFlagSoftPowerOff: UInt8 = 0x02
    public static let sleepFlagPanelSleepActive: UInt8 = 0x04

    public var tempCentiC: Int16?
    public var humidityPct: UInt8?
    public var batteryPct: UInt8?
    public var batteryMv: UInt16?
    public var petLevel: UInt8
    public var hunger: UInt8
    public var happiness: UInt8
    public var energy: UInt8
    public var mood: Int8
    public var bond: UInt8
    public var stress: UInt8
    public var sleepFlags: UInt8
    public var uptimeSeconds: UInt16

    public init(
        tempCentiC: Int16? = nil,
        humidityPct: UInt8? = nil,
        batteryPct: UInt8? = nil,
        batteryMv: UInt16? = nil,
        petLevel: UInt8 = 0,
        hunger: UInt8 = 0,
        happiness: UInt8 = 0,
        energy: UInt8 = 0,
        mood: Int8 = 0,
        bond: UInt8 = 0,
        stress: UInt8 = 0,
        sleepFlags: UInt8 = 0,
        uptimeSeconds: UInt16 = 0)
    {
        self.tempCentiC = tempCentiC
        self.humidityPct = humidityPct
        self.batteryPct = batteryPct
        self.batteryMv = batteryMv
        self.petLevel = petLevel
        self.hunger = hunger
        self.happiness = happiness
        self.energy = energy
        self.mood = mood
        self.bond = bond
        self.stress = stress
        self.sleepFlags = sleepFlags
        self.uptimeSeconds = uptimeSeconds
    }

    public static func decode(_ data: Data) -> PetDeviceState? {
        guard data.count == self.wireSize else { return nil }
        let bytes = [UInt8](data)

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        let tempRaw = Int16(bitPattern: u16(0))
        let humidityRaw = bytes[2]
        let batteryPctRaw = bytes[3]
        let batteryMvRaw = u16(4)

        return PetDeviceState(
            tempCentiC: tempRaw == Self.unknownTempCentiC ? nil : tempRaw,
            humidityPct: humidityRaw == Self.unknownPercent ? nil : humidityRaw,
            batteryPct: batteryPctRaw == Self.unknownPercent ? nil : batteryPctRaw,
            batteryMv: batteryMvRaw == Self.unknownBatteryMv ? nil : batteryMvRaw,
            petLevel: bytes[6],
            hunger: bytes[7],
            happiness: bytes[8],
            energy: bytes[9],
            mood: Int8(bitPattern: bytes[10]),
            bond: bytes[11],
            stress: bytes[12],
            sleepFlags: bytes[13],
            uptimeSeconds: u16(14))
    }

    public var temperatureCelsius: Double? {
        self.tempCentiC.map { Double($0) / 100.0 }
    }

    public var batteryVolts: Double? {
        self.batteryMv.map { Double($0) / 1000.0 }
    }

    public var isLocalQuiet: Bool {
        self.sleepFlags & Self.sleepFlagLocalQuiet != 0
    }

    public var isSoftPowerOff: Bool {
        self.sleepFlags & Self.sleepFlagSoftPowerOff != 0
    }

    public var isPanelSleepActive: Bool {
        self.sleepFlags & Self.sleepFlagPanelSleepActive != 0
    }
}

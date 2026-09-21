import Foundation

enum PowerStats {
    static let maxPlausibleWatts = 20_000.0
    static let minInterval: TimeInterval = 0.05

    static func watts(
        energyUj: UInt64,
        previousEnergyUj: UInt64,
        maxEnergyUj: UInt64,
        interval: TimeInterval
    ) -> Double? {
        guard energyUj > 0 || previousEnergyUj > 0 else { return nil }
        guard interval >= minInterval else { return nil }
        let delta: UInt64
        if energyUj >= previousEnergyUj {
            delta = energyUj - previousEnergyUj
        } else if maxEnergyUj > previousEnergyUj {
            delta = (maxEnergyUj - previousEnergyUj) + energyUj
        } else {
            return nil
        }
        let watts = Double(delta) / (interval * 1_000_000)
        guard watts.isFinite, watts >= 0, watts <= maxPlausibleWatts else { return nil }
        return watts
    }

    static func watts(microwatts: UInt64) -> Double? {
        guard microwatts > 0 else { return nil }
        let watts = Double(microwatts) / 1_000_000
        guard watts <= maxPlausibleWatts else { return nil }
        return watts
    }

    /// InstantAmperage is milliamps; Voltage is millivolts.
    static func watts(milliamps: Int, millivolts: Int) -> Double? {
        guard millivolts > 0, milliamps != 0 else { return nil }
        let watts = abs(Double(milliamps) * Double(millivolts)) / 1_000_000
        guard watts.isFinite, watts <= maxPlausibleWatts else { return nil }
        return watts
    }
}

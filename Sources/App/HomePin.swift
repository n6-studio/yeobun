import Foundation

enum PinMetric: String, Codable, CaseIterable, Identifiable {
    case cpu
    case memory
    case storage
    case network
    case down
    case up
    case power
    case battery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .storage: "Storage"
        case .network: "Net"
        case .down: "Down"
        case .up: "Up"
        case .power: "Power"
        case .battery: "Battery"
        }
    }
}

enum PinSource: Hashable {
    case mac
    case remote(UUID)
}

struct MacRowStat: Identifiable {
    var label: String
    var value: String
    var level: UsageLevel
    var id: String { label }
}

struct PinDisplay: Identifiable {
    var pin: HomePin
    var caption: String
    var value: String
    var level: UsageLevel
    var glyph: GlyphID
    var route: PanelRoute
    var accessibility: String
    var id: String { pin.id }
}

struct HomePin: Hashable, Identifiable {
    var source: PinSource
    var metric: PinMetric

    var id: String { token }

    var token: String {
        switch source {
        case .mac:
            "mac:\(metric.rawValue)"
        case .remote(let id):
            "remote:\(id.uuidString):\(metric.rawValue)"
        }
    }

    init(source: PinSource, metric: PinMetric) {
        self.source = source
        self.metric = metric
    }

    init?(token: String) {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "mac", let metric = PinMetric(rawValue: parts[1]) {
            self.init(source: .mac, metric: metric)
            return
        }
        if parts.count == 3, parts[0] == "remote", let id = UUID(uuidString: parts[1]), let metric = PinMetric(rawValue: parts[2]) {
            self.init(source: .remote(id), metric: metric)
            return
        }
        return nil
    }

    static let defaults: [HomePin] = [
        HomePin(source: .mac, metric: .storage),
        HomePin(source: .mac, metric: .cpu),
        HomePin(source: .mac, metric: .memory),
        HomePin(source: .mac, metric: .network)
    ]

    static let maxCount = 8
}

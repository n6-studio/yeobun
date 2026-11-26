import AppKit
import CoreLocation

/// macOS hides the Wi-Fi name from apps without Location Services. Yeobun only
/// asks so it can read that name; it never requests a position.
enum WiFiNameAccess: Equatable {
    case granted
    case notAsked
    case denied
}

final class WiFiNameAuthorization: NSObject, CLLocationManagerDelegate {
    var onChange: ((WiFiNameAccess) -> Void)?
    private var manager: CLLocationManager?

    /// Creates the manager on the main thread so its callbacks land there.
    func start() {
        guard manager == nil else { return }
        let manager = CLLocationManager()
        manager.delegate = self
        self.manager = manager
    }

    var access: WiFiNameAccess {
        guard let manager else { return .notAsked }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notAsked
        @unknown default:
            return .notAsked
        }
    }

    /// Shows the system prompt the first time, then opens Privacy settings.
    func request() {
        start()
        if access == .notAsked, CLLocationManager.locationServicesEnabled() {
            NSApp.activate(ignoringOtherApps: true)
            manager?.requestWhenInUseAuthorization()
            return
        }
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange?(access)
    }
}

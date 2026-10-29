import AppKit

/// Control Center's "Allow in the Menu Bar" list. Turning Yeobun off there
/// hides the wrench and the chevron together.
///
/// An app turned off there stops being drawn. macOS 27 can leave its last
/// frame on the bar. macOS 27.2 drops `AXExtrasMenuBar` for that app entirely,
/// so the strip lists it from this record and opens the app when clicked.
///
/// macOS 27.2 also blocks other apps from reading the live file. A saved copy
/// in Application Support is the fallback until Full Disk Access is on.
enum MenuBarAllowance {
    private static let bundleID = "studio.n6.yeobun"

    /// The last read used the saved copy. The live file was not readable.
    static private(set) var usingSnapshot = false

    /// Apps whose Allow in the Menu Bar switch is off.
    struct Disallowed {
        var bundleIDs: Set<String> = []
        /// Executables of ad-hoc signed builds, which Control Center tracks by path.
        var executables: Set<String> = []

        func contains(_ app: NSRunningApplication) -> Bool {
            if let id = app.bundleIdentifier, bundleIDs.contains(id) { return true }
            if let path = app.executableURL?.standardizedFileURL.path, executables.contains(path) { return true }
            return false
        }
    }

    static func isYeobunAllowed() -> Bool {
        for entry in entries() {
            guard let allowed = entry["isAllowed"] as? Bool, mentionsYeobun(entry) else { continue }
            return allowed
        }
        return true
    }

    static func disallowed() -> Disallowed {
        var result = Disallowed()
        for entry in entries() where (entry["isAllowed"] as? Bool) == false {
            collect(entry, under: nil, into: &result)
        }
        return result
    }

    private static var liveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    private static var snapshotURL: URL {
        YeobunPaths.applicationSupport.appendingPathComponent("menu-bar-allowance.plist")
    }

    private static func entries() -> [[String: Any]] {
        if let entries = decode(liveURL) {
            usingSnapshot = false
            if let data = try? Data(contentsOf: liveURL) {
                try? FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: snapshotURL, options: .atomic)
            }
            return entries
        }
        usingSnapshot = true
        return decode(snapshotURL) ?? []
    }

    private static func decode(_ url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let tracked = root["trackedApplications"] as? Data,
              let entries = try? PropertyListSerialization.propertyList(from: tracked, format: nil) as? [[String: Any]]
        else { return nil }
        return entries
    }

    /// Bundle ids sit under a `bundle` key; ad-hoc builds under `adhocBinary` as a file URL.
    private static func collect(_ value: Any, under key: String?, into result: inout Disallowed) {
        switch value {
        case let text as String:
            if key == "bundle" {
                result.bundleIDs.insert(text)
            } else if key == "adhocBinary", let url = URL(string: text), url.isFileURL {
                result.executables.insert(url.standardizedFileURL.path)
            }
        case let list as [Any]:
            list.forEach { collect($0, under: key, into: &result) }
        case let record as [String: Any]:
            for (childKey, child) in record {
                let inherited = childKey == "bundle" || childKey == "adhocBinary" ? childKey : key
                collect(child, under: inherited, into: &result)
            }
        default:
            break
        }
    }

    private static func mentionsYeobun(_ value: Any) -> Bool {
        switch value {
        case let text as String:
            return text == bundleID
        case let list as [Any]:
            return list.contains { mentionsYeobun($0) }
        case let record as [String: Any]:
            return record.values.contains { mentionsYeobun($0) }
        default:
            return false
        }
    }
}

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
    static var usingSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return cachedUsingSnapshot
    }

    private static let lock = NSLock()
    private static var cachedSignature = ""
    private static var cachedEntries: [[String: Any]] = []
    private static var cachedUsingSnapshot = false
    private static var cachedAllowed = true
    private static var cachedDisallowed = Disallowed()
    private static var lastSnapshotHash: Int?

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
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return cachedAllowed
    }

    static func disallowed() -> Disallowed {
        lock.lock()
        defer { lock.unlock() }
        refreshLocked()
        return cachedDisallowed
    }

    private static var liveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
    }

    private static var snapshotURL: URL {
        YeobunPaths.applicationSupport.appendingPathComponent("menu-bar-allowance.plist")
    }

    /// Re-decode only when the live file or the saved copy changes. The copy
    /// is rewritten only when the live bytes change. Caller holds `lock`.
    private static func refreshLocked() {
        let signature = "\(stamp(liveURL))|\(stamp(snapshotURL))"
        if signature == cachedSignature { return }

        if let data = try? Data(contentsOf: liveURL), let entries = decode(data) {
            cachedUsingSnapshot = false
            cachedEntries = entries
            storeDerivedLocked()
            let hash = data.hashValue
            if hash != lastSnapshotHash {
                do {
                    try FileManager.default.createDirectory(
                        at: snapshotURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: snapshotURL, options: .atomic)
                    lastSnapshotHash = hash
                } catch {
                    lastSnapshotHash = nil
                }
            }
            cachedSignature = "\(stamp(liveURL))|\(stamp(snapshotURL))"
            return
        }

        cachedUsingSnapshot = true
        if let data = try? Data(contentsOf: snapshotURL), let entries = decode(data) {
            cachedEntries = entries
        } else {
            cachedEntries = []
        }
        storeDerivedLocked()
        cachedSignature = "\(stamp(liveURL))|\(stamp(snapshotURL))"
    }

    private static func storeDerivedLocked() {
        var allowed = true
        var seenYeobun = false
        var denied = Disallowed()
        for entry in cachedEntries {
            if !seenYeobun, mentionsYeobun(entry), let flag = entry["isAllowed"] as? Bool {
                allowed = flag
                seenYeobun = true
            }
            if (entry["isAllowed"] as? Bool) == false {
                collect(entry, under: nil, into: &denied)
            }
        }
        cachedAllowed = allowed
        cachedDisallowed = denied
    }

    private static func stamp(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(size)@\(modified)"
    }

    private static func decode(_ data: Data) -> [[String: Any]]? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
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

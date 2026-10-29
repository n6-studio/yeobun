import Darwin
import Foundation

final class ScrollHelperController {
    static let shared = ScrollHelperController()

    private let watch = ProcessWatch()

    var isRunning: Bool {
        let pid = pid_t(ToolStateStore.shared.current.scrollHelperPID)
        if watch.isAlive(pid) { return true }
        guard DetachedProcess.isRunning(pid: pid, commandContains: YeobunPaths.scrollHelperName) else {
            watch.cancel()
            return false
        }
        watch.watch(pid)
        return true
    }

    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        let url = YeobunPaths.scrollHelperURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return false
        }
        do {
            let pid = try DetachedProcess.spawn(executable: url.path, arguments: [])
            ToolStateStore.shared.update { $0.scrollHelperPID = Int(pid) }
            guard DetachedProcess.stayedAlive(pid: pid, for: 0.2),
                  DetachedProcess.isRunning(pid: pid, commandContains: YeobunPaths.scrollHelperName)
            else {
                watch.cancel()
                return false
            }
            watch.watch(pid)
            return true
        } catch {
            return false
        }
    }

    func stop() {
        let pid = pid_t(ToolStateStore.shared.current.scrollHelperPID)
        if DetachedProcess.isRunning(pid: pid, commandContains: YeobunPaths.scrollHelperName) {
            kill(pid, SIGTERM)
            DetachedProcess.waitForExit(pid: pid, timeout: 1.5)
        }
        watch.cancel()
        ToolStateStore.shared.update { $0.scrollHelperPID = 0 }
    }
}

enum ScrollPolicy {
    static func enabledIDs(mice: [MouseDevice], map: [String: Bool], enabled: Bool) -> Set<String> {
        guard enabled else { return [] }
        return Set(mice.filter { map[$0.id] ?? true }.map(\.id))
    }
}

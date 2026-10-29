import Darwin
import Foundation

/// Idle/display sleep hold, wrapping `/usr/bin/caffeinate`.
///
/// KeepingYouAwake and Caffeine do the same thing with IOPM assertions.
/// `caffeinate -di` creates `PreventUserIdleDisplaySleep` plus
/// `PreventUserIdleSystemSleep`. `-t` drops them after N seconds.
/// `-s` is intentionally unused: that assertion blocks lid-close sleep on AC,
/// which is Lid awake's job.
///
/// The process is spawned in its own group so it survives CLI (and GUI) exit.
/// PID and deadline live in `ToolStateStore` so both controllers see the same hold.
struct CaffeinateError: LocalizedError {
    let errorDescription: String?
}

final class CaffeinateService {
    struct Snapshot {
        var active: Bool
        var remainingSeconds: Int?
    }

    private let watch = ProcessWatch()

    func snapshot() -> Snapshot {
        guard livePID() != nil else {
            return Snapshot(active: false, remainingSeconds: nil)
        }
        if let deadline = ToolStateStore.shared.current.awakeDeadline, deadline > 0 {
            return Snapshot(
                active: true,
                remainingSeconds: max(0, Int((deadline - Date().timeIntervalSince1970).rounded(.down)))
            )
        }
        return Snapshot(active: true, remainingSeconds: nil)
    }

    func start(timeoutSeconds: Int?) throws {
        stop()
        var arguments = ["-d", "-i"]
        var deadline: TimeInterval?
        if let timeoutSeconds, timeoutSeconds > 0 {
            arguments += ["-t", "\(timeoutSeconds)"]
            deadline = Date().timeIntervalSince1970 + Double(timeoutSeconds)
        }
        do {
            let pid = try DetachedProcess.spawn(executable: "/usr/bin/caffeinate", arguments: arguments)
            watch.watch(pid)
            ToolStateStore.shared.update {
                $0.caffeinatePID = Int(pid)
                $0.awakeDeadline = deadline
            }
        } catch {
            throw CaffeinateError(errorDescription: "Unable to prevent sleep.")
        }
    }

    func stop() {
        if let pid = livePID() {
            kill(pid, SIGTERM)
        }
        watch.cancel()
        ToolStateStore.shared.update {
            $0.caffeinatePID = 0
            $0.awakeDeadline = nil
        }
    }

    /// Name is checked once per pid. Later calls trust the exit watch, so the
    /// 1s remaining-time tick is arithmetic.
    private func livePID() -> pid_t? {
        let pid = pid_t(ToolStateStore.shared.current.caffeinatePID)
        if watch.isAlive(pid) { return pid }
        guard DetachedProcess.isRunning(pid: pid, commandContains: "caffeinate") else {
            watch.cancel()
            return nil
        }
        watch.watch(pid)
        return pid
    }
}

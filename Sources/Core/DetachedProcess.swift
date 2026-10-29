import Darwin
import Foundation

struct DetachedProcessError: LocalizedError {
    let errorDescription: String?
}

enum DetachedProcess {
    static func spawn(executable: String, arguments: [String]) throws -> pid_t {
        var pid: pid_t = 0
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        "/dev/null".withCString { path in
            _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0)
            _ = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, path, O_WRONLY, 0)
            _ = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, path, O_WRONLY, 0)
        }

        let cArgs = ([executable] + arguments).map { strdup($0) } + [nil]
        defer {
            for pointer in cArgs {
                free(pointer)
            }
        }

        let status = cArgs.withUnsafeBufferPointer { argv in
            executable.withCString { path in
                posix_spawn(&pid, path, &actions, &attr, argv.baseAddress, environ)
            }
        }
        guard status == 0 else {
            throw DetachedProcessError(errorDescription: "Could not start \(executable) (\(status)).")
        }
        return pid
    }

    static func isRunning(pid: pid_t, commandContains needle: String) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        guard let name = commandName(of: pid) else { return false }
        return name.contains(needle)
    }

    /// Executable path, or the short process name when the path is unavailable.
    /// `proc_pidpath` / `proc_name` stay in this process. No `/bin/ps`.
    static func commandName(of pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let value = String(cString: path)
            if !value.isEmpty { return value }
        }
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        let value = String(cString: name)
        return value.isEmpty ? nil : value
    }

    /// `true` when `pid` is still alive after `seconds`. Waits on process exit
    /// instead of sleeping and probing.
    static func stayedAlive(pid: pid_t, for seconds: TimeInterval) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        return !waitForExit(pid: pid, timeout: seconds)
    }

    /// `true` once the process is gone, or the timeout elapses after it has gone.
    @discardableResult
    static func waitForExit(pid: pid_t, timeout: TimeInterval) -> Bool {
        guard pid > 1 else { return true }
        if kill(pid, 0) != 0 { return true }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        let semaphore = DispatchSemaphore(value: 0)
        source.setEventHandler { semaphore.signal() }
        source.resume()
        let exited = semaphore.wait(timeout: .now() + timeout) == .success
        source.cancel()
        return exited || kill(pid, 0) != 0
    }
}

/// Remembers one pid and flips when that process exits, so callers can skip
/// a name lookup on every poll.
final class ProcessWatch {
    private let lock = NSLock()
    private var source: DispatchSourceProcess?
    private var pid: pid_t = 0
    private var exited = true

    func isAlive(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.pid == pid && !exited && source != nil
    }

    func watch(_ pid: pid_t) {
        lock.lock()
        if self.pid == pid, source != nil, !exited {
            lock.unlock()
            return
        }
        let previous = source
        source = nil
        lock.unlock()
        previous?.cancel()

        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pid == pid { self.exited = true }
            self.lock.unlock()
        }
        lock.lock()
        self.pid = pid
        self.exited = false
        self.source = source
        lock.unlock()
        source.resume()
    }

    func cancel() {
        lock.lock()
        let previous = source
        source = nil
        pid = 0
        exited = true
        lock.unlock()
        previous?.cancel()
    }
}

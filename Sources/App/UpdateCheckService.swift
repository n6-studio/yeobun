import Darwin
import Foundation

struct BrewCaskInfo {
    let version: String
    /// Set when Homebrew installed this cask. Nil for a disk-image or dev build.
    let installed: String?
    /// True when this result follows `brew update`.
    var refreshed: Bool
    /// False while a refresh is still running after an early cask read.
    var finished: Bool
}

enum UpdateCheckError: LocalizedError {
    case brewMissing
    case noCask
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .brewMissing:
            return "Homebrew is not installed"
        case .noCask:
            return "Unable to read the Yeobun cask from Homebrew"
        case .failed(let message):
            return message
        }
    }
}

/// Homebrew is the update source. The cask lives on `n6-studio/tap`, which is
/// not in the public formulae API, so a fresh answer needs `brew update`.
enum UpdateCheckService {
    static let cask = "n6-studio/tap/yeobun"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static func brewExecutable() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func check(refresh: Bool, completion: @escaping (Result<BrewCaskInfo, Error>) -> Void) -> UpdateCheckHandle {
        let handle = UpdateCheckHandle()
        DispatchQueue.global(qos: .utility).async {
            performCheck(refresh: refresh, handle: handle, completion: completion)
        }
        return handle
    }

    /// Quits have to happen before `brew` runs. Homebrew will not quit an app
    /// that is an ancestor of the `brew` process, so this script waits until
    /// Yeobun has exited, then upgrades and opens it again.
    static func scheduleInstall(upgrade: Bool) throws {
        guard let brew = brewExecutable() else { throw UpdateCheckError.brewMissing }
        let support = YeobunPaths.applicationSupport
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let scriptURL = support.appendingPathComponent("update.sh")
        let resultURL = support.appendingPathComponent("update-result.txt")
        let verb = upgrade ? "upgrade" : "install"
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        trap '' HUP
        target=\(pid)
        result=\(shellQuote(resultURL.path))
        log=$(mktemp)
        for _ in {1..50}; do
          kill -0 "$target" 2>/dev/null || break
          sleep 0.2
        done
        if kill -0 "$target" 2>/dev/null; then
          printf '%s\\n' 'error Yeobun was still running, so the update did not start.' > "$result"
          exit 1
        fi
        if \(shellQuote(brew)) \(verb) --cask \(shellQuote(cask)) >"$log" 2>&1; then
          printf '%s\\n' 'ok' > "$result"
        else
          message=$(tail -n 1 "$log" | tr -d $'\\r' | sed 's/^Error: //')
          if [ -z "$message" ]; then
            message='The Homebrew update failed.'
          fi
          printf 'error %s\\n' "$message" > "$result"
        fi
        rm -f "$log"
        open -b studio.n6.yeobun || open -a Yeobun || open /Applications/Yeobun.app || open "$HOME/Applications/Yeobun.app" || true
        rm -f \(shellQuote(scriptURL.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        do {
            _ = try DetachedProcess.spawn(executable: "/bin/bash", arguments: [scriptURL.path])
        } catch {
            throw UpdateCheckError.failed("Unable to start the Homebrew update")
        }
    }

    static func compare(latest: String, current: String) -> ComparisonResult {
        let left = components(latest)
        let right = components(current)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a < b ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    static func parseInfo(_ data: Data) throws -> BrewCaskInfo {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let brace = raw.firstIndex(of: "{") else { throw UpdateCheckError.noCask }
        let json = Data(raw[brace...].utf8)
        let decoded: BrewInfoFile
        do {
            decoded = try JSONDecoder().decode(BrewInfoFile.self, from: json)
        } catch {
            throw UpdateCheckError.noCask
        }
        guard let cask = decoded.casks.first(where: { $0.token == "yeobun" || $0.fullToken == Self.cask }) ?? decoded.casks.first else {
            throw UpdateCheckError.noCask
        }
        let version = normalized(cask.version)
        guard !version.isEmpty else { throw UpdateCheckError.noCask }
        let installed = cask.installed.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
        return BrewCaskInfo(version: version, installed: installed, refreshed: false, finished: true)
    }

    static func normalized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    /// Reads the cask immediately, then refreshes the tap when asked. The early
    /// result lets the dot appear before `brew update` finishes.
    private static func performCheck(
        refresh: Bool,
        handle: UpdateCheckHandle,
        completion: @escaping (Result<BrewCaskInfo, Error>) -> Void
    ) {
        guard let brew = brewExecutable() else {
            if !handle.isCancelled { completion(.failure(UpdateCheckError.brewMissing)) }
            return
        }
        let first = readCask(brew: brew, handle: handle)
        if handle.isCancelled { return }
        if case .success(var info) = first {
            info.finished = !refresh
            completion(.success(info))
            if !refresh { return }
        } else if !refresh {
            completion(first)
            return
        }

        _ = run(brew: brew, arguments: ["update", "--quiet"], timeout: 90, handle: handle)
        if handle.isCancelled { return }
        let second = readCask(brew: brew, handle: handle)
        if handle.isCancelled { return }
        switch second {
        case .success(var info):
            info.refreshed = true
            info.finished = true
            completion(.success(info))
        case .failure:
            if case .success(var info) = first {
                info.refreshed = true
                info.finished = true
                completion(.success(info))
            } else {
                completion(second)
            }
        }
    }

    private static func readCask(brew: String, handle: UpdateCheckHandle) -> Result<BrewCaskInfo, Error> {
        guard let info = run(
            brew: brew,
            arguments: ["info", "--cask", "--json=v2", cask],
            timeout: 30,
            handle: handle
        ) else {
            return .failure(UpdateCheckError.failed("Cancelled"))
        }
        if info.status != 0 {
            return .failure(UpdateCheckError.failed(stderrMessage(info.stderr) ?? "Unable to check Homebrew"))
        }
        do {
            return .success(try parseInfo(info.stdout))
        } catch {
            return .failure(error)
        }
    }

    private static func run(
        brew: String,
        arguments: [String],
        timeout: TimeInterval,
        handle: UpdateCheckHandle
    ) -> CommandOutput? {
        if handle.isCancelled { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_COLOR"] = "0"
        process.environment = env
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        guard handle.track(process) else { return nil }
        defer { handle.clearProcess() }
        do {
            try process.run()
        } catch {
            return CommandOutput(status: 1, stdout: Data(), stderr: Data("Could not start Homebrew".utf8))
        }

        let output = ReadBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            output.stdout = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            output.stderr = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if handle.isCancelled {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()
        if handle.isCancelled { return nil }
        return CommandOutput(status: process.terminationStatus, stdout: output.stdout, stderr: output.stderr)
    }

    private static func stderrMessage(_ data: Data) -> String? {
        let lines = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var line = lines?.last else { return nil }
        for prefix in ["Error: ", "Warning: "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
        }
        return line.isEmpty ? nil : line
    }

    private static func components(_ version: String) -> [Int] {
        normalized(version)
            .split(separator: ".")
            .prefix(3)
            .map { Int($0) ?? 0 }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class UpdateCheckHandle {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        process?.terminate()
    }

    fileprivate func track(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.process = process
        return true
    }

    fileprivate func clearProcess() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

private struct CommandOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private final class ReadBox {
    var stdout = Data()
    var stderr = Data()
}

private struct BrewInfoFile: Decodable {
    let casks: [BrewCaskJSON]
}

private struct BrewCaskJSON: Decodable {
    let token: String?
    let fullToken: String?
    let version: String
    let installed: String?

    enum CodingKeys: String, CodingKey {
        case token, version, installed
        case fullToken = "full_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token)
        fullToken = try container.decodeIfPresent(String.self, forKey: .fullToken)
        version = try container.decode(String.self, forKey: .version)
        installed = try container.decodeIfPresent(String.self, forKey: .installed)
    }
}

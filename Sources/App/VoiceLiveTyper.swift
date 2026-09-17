import AppKit
import CoreGraphics
import Foundation

/// Types words into the frontmost app while they are still being spoken.
///
/// The recognizer keeps revising a phrase until it settles. Instead of
/// waiting for that, this types each revision right away: it keeps what
/// already matches, backspaces over the part that changed, and types the
/// rest. Text goes in as Unicode key events, so the clipboard is untouched.
/// Needs Accessibility to post events.
final class VoiceLiveTyper {
    private struct Job {
        var text: String
        var commit: Bool
        var pid: pid_t
        var frontIsYeobun: Bool
    }

    private let queue = DispatchQueue(label: "studio.n6.yeobun.voice.typer", qos: .userInteractive)
    private let lock = NSLock()
    private var jobs: [Job] = []
    private var draining = false

    // Queue-confined.
    private var typed = ""
    private var typedPID: pid_t = 0
    private var hasCommitted = false

    /// Pause after a revision so a burst of them collapses into the newest one.
    private static let revisionPause: useconds_t = 50_000
    private static let eventPause: useconds_t = 1_200
    private static let backspaceKey: CGKeyCode = 51
    /// `keyboardSetUnicodeString` carries about this many UTF-16 units per event.
    private static let chunkLength = 20

    static var canType: Bool {
        AccessibilityAuth.hasPermission
    }

    /// Call on the main thread at the start of a session.
    func reset() {
        lock.withLock { jobs.removeAll() }
        queue.async { [self] in
            typed = ""
            typedPID = 0
            hasCommitted = false
        }
    }

    /// Main thread. `commit` marks the phrase as final; later text starts a new one.
    func update(_ text: String, commit: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        let job = Job(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            commit: commit,
            pid: front?.processIdentifier ?? 0,
            frontIsYeobun: front?.bundleIdentifier == Bundle.main.bundleIdentifier
        )
        let shouldStart: Bool = lock.withLock {
            // A newer revision replaces one that has not been typed yet.
            // Commits are never dropped.
            if let last = jobs.last, !last.commit {
                jobs[jobs.count - 1] = job
            } else {
                jobs.append(job)
            }
            if draining { return false }
            draining = true
            return true
        }
        if shouldStart {
            queue.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            let next: Job? = lock.withLock {
                if jobs.isEmpty {
                    draining = false
                    return nil
                }
                return jobs.removeFirst()
            }
            guard let next else { return }
            apply(next)
            if !next.commit {
                usleep(Self.revisionPause)
            }
        }
    }

    private func apply(_ job: Job) {
        guard Self.canType, !job.frontIsYeobun, job.pid != 0 else {
            // Nowhere to type. Forget the phrase once it is final.
            if job.commit { typed = "" }
            return
        }
        if job.pid != typedPID {
            // Never backspace in an app this phrase was not typed into.
            typed = ""
            typedPID = job.pid
        }
        guard !job.text.isEmpty else {
            if job.commit { typed = "" }
            return
        }
        let target = (hasCommitted ? " " : "") + job.text
        let shared = Self.commonPrefixCount(typed, target)
        backspace(typed.count - shared)
        type(String(target.dropFirst(shared)))
        if job.commit {
            typed = ""
            hasCommitted = true
        } else {
            typed = target
        }
    }

    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var left = a.makeIterator()
        var right = b.makeIterator()
        while let x = left.next(), let y = right.next(), x == y {
            count += 1
        }
        return count
    }

    private func backspace(_ count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: Self.backspaceKey, keyDown: false) else {
                return
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(Self.eventPause)
        }
    }

    private func type(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + Self.chunkLength, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            let chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return
            }
            // Clear modifiers so a held shortcut key cannot turn text into commands.
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(Self.eventPause)
            index = end
        }
    }
}

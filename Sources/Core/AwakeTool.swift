import Foundation

/// What the duration row shows after a keep-awake session ends.
enum AwakeResume: String, Codable, CaseIterable, Identifiable {
    case keepLast
    case preferred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepLast: "Keep last setting"
        case .preferred: "Always set back to"
        }
    }

    static let durationChoices = [0, 5, 10, 15, 30, 60, 120, 300]

    static func sanitizedMinutes(_ minutes: Int) -> Int {
        durationChoices.contains(minutes) ? minutes : 0
    }
}

final class AwakeTool: ToggleTool {
    let id: ToolID = .awake
    private let service = CaffeinateService()

    func snapshot() throws -> ToggleSnapshot {
        let hardware = service.snapshot()
        return ToggleSnapshot(
            isOn: hardware.active,
            remainingSeconds: hardware.remainingSeconds,
            remainingMinutes: nil
        )
    }

    func hardwareSnapshot() -> CaffeinateService.Snapshot {
        service.snapshot()
    }

    func setEnabled(_ enabled: Bool, options: ToolOptions) throws {
        if enabled {
            try start(minutes: options.minutes)
        } else {
            stop(persist: true)
        }
        ToolStateStore.shared.notifyChange()
    }

    func restore() {
        let state = ToolStateStore.shared.current
        guard state.awakeEnabled else { return }
        if service.snapshot().active {
            return
        }
        let minutes = state.awakeMinutes
        if minutes == 0 {
            try? start(minutes: 0)
            return
        }
        let deadline = state.awakeDeadline ?? 0
        let remaining = Int((deadline - Date().timeIntervalSince1970).rounded(.down))
        if remaining > 1 {
            try? start(timeoutSeconds: remaining, persistMinutes: nil)
        } else {
            stop(persist: true)
        }
    }

    func noteExpired() {
        stop(persist: true)
    }

    private func start(minutes: Int?) throws {
        let chosen = minutes ?? ToolStateStore.shared.current.awakeMinutes
        try start(
            timeoutSeconds: chosen > 0 ? chosen * 60 : nil,
            persistMinutes: minutes
        )
    }

    private func start(timeoutSeconds: Int?, persistMinutes: Int?) throws {
        do {
            try service.start(timeoutSeconds: timeoutSeconds)
        } catch {
            ToolStateStore.shared.update {
                $0.awakeEnabled = false
                $0.awakeDeadline = nil
            }
            throw ToolError.failed(error)
        }
        ToolStateStore.shared.update {
            $0.awakeEnabled = true
            if let persistMinutes {
                $0.awakeMinutes = persistMinutes
            }
        }
    }

    private func stop(persist: Bool) {
        service.stop()
        if persist {
            ToolStateStore.shared.update {
                $0.awakeEnabled = false
                $0.awakeDeadline = nil
                if $0.awakeResume == .preferred {
                    $0.awakeMinutes = AwakeResume.sanitizedMinutes($0.awakePreferredMinutes)
                }
            }
        }
    }
}

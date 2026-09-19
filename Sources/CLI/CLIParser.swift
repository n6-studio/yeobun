import Foundation

enum CLIParser {
    static let keyboardMinutes = [5, 10, 15, 30, 60]
    static let awakeMinutes = [5, 10, 15, 30, 60, 120, 300]

    static let helpText = """
    yeobun — control Yeobun from the terminal

    Usage:
      yeobun status [--json]
      yeobun keyboard on [--minutes N] [--dim|--no-dim] [--json]
      yeobun keyboard off [--json]
      yeobun keyboard status [--json]
      yeobun scroll on [--json]
      yeobun scroll off [--json]
      yeobun scroll status [--json]
      yeobun lid on [--json]
      yeobun lid off [--json]
      yeobun lid status [--json]
      yeobun awake on [--minutes N] [--json]
      yeobun awake off [--json]
      yeobun awake status [--json]
      yeobun menubar on [--json]
      yeobun menubar off [--json]
      yeobun menubar status [--json]
      yeobun voice on [--json]
      yeobun voice off [--json]
      yeobun voice start [--json]
      yeobun voice stop [--json]
      yeobun voice status [--json]
      yeobun voice vocab [--json]
      yeobun voice vocab add <term> [--sounds-like <text>]... [--json]
      yeobun voice vocab remove <term> [--json]
      yeobun voice vocab clear [--json]
      yeobun mac [--json]

    keyboard  Built-in keyboard
    scroll    Scroll reverse
    lid       Lid awake
    awake     Keep awake
    menubar   Hidden icons
    voice     Voice typing. on/off arms or disables the tool and its shortcut;
              start/stop controls listening (needs on, and the app running);
              vocab lists the words it should get right. --sounds-like is what
              it writes instead today, e.g. add kubectl --sounds-like "cube control"
    mac       This Mac

    Keyboard --minutes: \(keyboardMinutes.map(String.init).joined(separator: ", "))
    Keep awake --minutes: \(awakeMinutes.map(String.init).joined(separator: ", ")) (omit for indefinitely)

    Exit codes: 0 ok, 1 failed, 2 usage, 3 permission

    """

    static func parse(_ args: [String]) throws -> CLIRequest {
        if args.isEmpty {
            return CLIRequest(command: .status, json: false)
        }
        var tokens = args
        var json = false
        tokens.removeAll { token in
            if token == "--json" {
                json = true
                return true
            }
            return false
        }
        guard let first = tokens.first else {
            return CLIRequest(command: .status, json: json)
        }
        if first == "--help" || first == "-h" || first == "help" {
            return CLIRequest(command: .help, json: json)
        }
        switch first {
        case "status":
            guard tokens.count == 1 else { throw CLIError.usage("Unexpected arguments for status.") }
            return CLIRequest(command: .status, json: json)
        case "mac":
            guard tokens.count == 1 else { throw CLIError.usage("Unexpected arguments for mac.") }
            return CLIRequest(command: .mac, json: json)
        case "keyboard":
            return CLIRequest(command: .keyboard(try parseSwitch(Array(tokens.dropFirst()), tool: .keyboard)), json: json)
        case "scroll":
            return CLIRequest(command: .scroll(try parseSwitch(Array(tokens.dropFirst()), tool: .scroll)), json: json)
        case "lid":
            return CLIRequest(command: .lid(try parseSwitch(Array(tokens.dropFirst()), tool: .lid)), json: json)
        case "awake":
            return CLIRequest(command: .awake(try parseSwitch(Array(tokens.dropFirst()), tool: .awake)), json: json)
        case "menubar":
            return CLIRequest(command: .menuBar(try parseSwitch(Array(tokens.dropFirst()), tool: .menuBar)), json: json)
        case "voice":
            return CLIRequest(command: .voice(try parseVoice(Array(tokens.dropFirst()))), json: json)
        default:
            throw CLIError.usage("Unknown command: \(first)")
        }
    }

    private static func parseSwitch(_ tokens: [String], tool: ToolID) throws -> CLISwitch {
        guard let action = tokens.first else {
            return .status
        }
        switch action {
        case "status":
            guard tokens.count == 1 else { throw CLIError.usage("Unexpected arguments for status.") }
            return .status
        case "off":
            guard tokens.count == 1 else { throw CLIError.usage("Unexpected arguments for off.") }
            return .off
        case "on":
            return try parseOn(Array(tokens.dropFirst()), tool: tool)
        default:
            throw CLIError.usage("Unknown action: \(action) (expected on, off, or status)")
        }
    }

    private static func parseVoice(_ tokens: [String]) throws -> CLIVoiceAction {
        guard let action = tokens.first else { return .status }
        if action == "vocab" {
            return .vocab(try parseVocab(Array(tokens.dropFirst())))
        }
        guard tokens.count == 1 else { throw CLIError.usage("Unexpected arguments for voice \(action).") }
        switch action {
        case "status": return .status
        case "on": return .on
        case "off": return .off
        case "start": return .start
        case "stop": return .stop
        default:
            throw CLIError.usage("Unknown action: \(action) (expected on, off, start, stop, status, or vocab)")
        }
    }

    private static func parseVocab(_ tokens: [String]) throws -> CLIVocabAction {
        guard let action = tokens.first else { return .list }
        let rest = Array(tokens.dropFirst())
        switch action {
        case "list":
            guard rest.isEmpty else { throw CLIError.usage("Unexpected arguments for vocab list.") }
            return .list
        case "clear":
            guard rest.isEmpty else { throw CLIError.usage("Unexpected arguments for vocab clear.") }
            return .clear
        case "remove":
            guard rest.count == 1, !VoiceVocabulary.tidy(rest[0]).isEmpty else {
                throw CLIError.usage("vocab remove needs one term. Quote it if it has spaces.")
            }
            return .remove(rest[0])
        case "add":
            var words: [String] = []
            var soundsLike: [String] = []
            var i = 0
            while i < rest.count {
                if rest[i] == "--sounds-like" {
                    i += 1
                    guard i < rest.count else { throw CLIError.usage("--sounds-like needs text.") }
                    soundsLike += VoiceVocabulary.aliases(from: rest[i])
                } else if rest[i].hasPrefix("--") {
                    throw CLIError.usage("Unknown option: \(rest[i])")
                } else {
                    words.append(rest[i])
                }
                i += 1
            }
            guard words.count == 1, !VoiceVocabulary.tidy(words[0]).isEmpty else {
                throw CLIError.usage("vocab add needs one term. Quote it if it has spaces.")
            }
            return .add(VoiceTerm(text: VoiceVocabulary.tidy(words[0]), soundsLike: soundsLike))
        default:
            throw CLIError.usage("Unknown action: \(action) (expected list, add, remove, or clear)")
        }
    }

    private static func parseOn(_ tokens: [String], tool: ToolID) throws -> CLISwitch {
        var minutes: Int?
        var dim: Bool?
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            switch token {
            case "--minutes":
                guard tool == .keyboard || tool == .awake else {
                    throw CLIError.usage("\(toolName(tool)) does not take --minutes.")
                }
                i += 1
                guard i < tokens.count, let value = Int(tokens[i]) else {
                    throw CLIError.usage("--minutes needs a number.")
                }
                minutes = try validateMinutes(value, tool: tool)
            case "--dim":
                guard tool == .keyboard else { throw CLIError.usage("Only keyboard takes --dim.") }
                dim = true
            case "--no-dim":
                guard tool == .keyboard else { throw CLIError.usage("Only keyboard takes --no-dim.") }
                dim = false
            default:
                throw CLIError.usage("Unexpected argument: \(token)")
            }
            i += 1
        }
        return .on(minutes: minutes, dim: dim)
    }

    private static func validateMinutes(_ value: Int, tool: ToolID) throws -> Int {
        let allowed = tool == .keyboard ? keyboardMinutes : awakeMinutes
        guard allowed.contains(value) else {
            throw CLIError.usage(
                "--minutes must be one of \(allowed.map(String.init).joined(separator: ", "))."
            )
        }
        return value
    }

    private static func toolName(_ tool: ToolID) -> String {
        tool.rawValue
    }
}

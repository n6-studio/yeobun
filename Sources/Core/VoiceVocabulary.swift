import Foundation

/// One word or term Voice typing should get right.
///
/// `text` is the exact spelling to write. It is handed to the recognizer as
/// a hint, which is enough for words the model half knows. `soundsLike`
/// lists what the recognizer writes instead when the hint is not enough,
/// such as "cube control" for "kubectl"; those are rewritten afterwards.
struct VoiceTerm: Codable, Equatable, Identifiable {
    var text: String
    var soundsLike: [String] = []

    var id: String { VoiceVocabulary.key(text) }

    init(text: String, soundsLike: [String] = []) {
        self.text = text
        self.soundsLike = soundsLike
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        soundsLike = try container.decodeIfPresent([String].self, forKey: .soundsLike) ?? []
    }
}

enum VoiceVocabulary {
    /// The recognizers stop paying attention to long hint lists.
    static let maxTerms = 100
    static let maxLength = 60

    /// Case and spacing do not tell two terms apart.
    static func key(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func tidy(_ text: String) -> String {
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(joined.prefix(maxLength))
    }

    /// Trims, drops blanks and duplicates, and caps the list.
    static func clean(_ terms: [VoiceTerm]) -> [VoiceTerm] {
        var seen = Set<String>()
        var result: [VoiceTerm] = []
        for term in terms {
            let text = tidy(term.text)
            guard !text.isEmpty, seen.insert(key(text)).inserted else { continue }
            var aliasKeys: Set<String> = [key(text)]
            let aliases = term.soundsLike.map(tidy).filter { alias in
                !alias.isEmpty && aliasKeys.insert(key(alias)).inserted
            }
            result.append(VoiceTerm(text: text, soundsLike: aliases))
            if result.count == maxTerms { break }
        }
        return result
    }

    /// Adds a term, or merges new aliases into the one already there.
    static func adding(_ term: VoiceTerm, to terms: [VoiceTerm]) -> [VoiceTerm] {
        var terms = terms
        if let index = terms.firstIndex(where: { $0.id == term.id }) {
            terms[index].text = term.text
            terms[index].soundsLike += term.soundsLike
        } else {
            terms.append(term)
        }
        return clean(terms)
    }

    static func removing(_ text: String, from terms: [VoiceTerm]) -> [VoiceTerm] {
        terms.filter { $0.id != key(text) }
    }

    /// Splits "cube control, cube cuddle" into aliases.
    static func aliases(from list: String) -> [String] {
        list.split(separator: ",").map { tidy(String($0)) }.filter { !$0.isEmpty }
    }
}

/// Rewrites recognized text so vocabulary terms come out as spelled.
///
/// Whole words only, any case: "posthog" and "Post hog" (as an alias) both
/// become "PostHog". One pass over the text, longest match first, so a
/// rewrite is never rewritten again.
struct VoiceCorrector {
    private let regex: NSRegularExpression?
    private let replacements: [String: String]

    init(terms: [VoiceTerm]) {
        var replacements: [String: String] = [:]
        for term in terms {
            for spoken in [term.text] + term.soundsLike {
                let key = VoiceVocabulary.key(spoken)
                if !key.isEmpty, replacements[key] == nil {
                    replacements[key] = term.text
                }
            }
        }
        self.replacements = replacements
        let alternatives = replacements.keys
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .map { key in
                key.split(separator: " ")
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
        if alternatives.isEmpty {
            regex = nil
        } else {
            let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
            regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    func apply(_ text: String) -> String {
        guard let regex, !text.isEmpty else { return text }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let heard = source.substring(with: match.range)
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += replacements[VoiceVocabulary.key(heard)] ?? heard
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}

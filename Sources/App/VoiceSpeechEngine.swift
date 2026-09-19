import AVFoundation
import Foundation
import Speech

struct VoiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum VoiceEngineEvent {
    /// Text for the phrase still being spoken. Replaces the previous partial.
    case partial(String)
    /// A finished phrase. Safe to type.
    case phrase(String)
    /// Progress while preparing, such as a model download.
    case progress(String)
    case failed(String)
}

enum VoiceLocaleSupport {
    case ready
    case needsDownload
    case unsupported
}

/// One on-device recognizer. Events arrive on the main thread.
protocol VoiceSpeechEngine: AnyObject {
    var onEvent: ((VoiceEngineEvent) -> Void)? { get set }
    /// Words to favour while recognizing. Can change during a session.
    var vocabulary: [String] { get set }
    func supportedLocales() async -> [Locale]
    func support(for locale: Locale) async -> VoiceLocaleSupport
    /// Loads or downloads what the language needs. Throws a user-facing message.
    func prepare(locale: Locale) async throws
    func start() async throws
    /// Called from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Finalizes pending speech; the last phrase can still arrive after this.
    func stop() async
}

enum VoiceEngineFactory {
    static var usesAnalyzer: Bool {
        if #available(macOS 26, *) {
            return ProcessInfo.processInfo.environment["YEOBUN_VOICE_ENGINE"] != "legacy"
        }
        return false
    }

    static func make() -> VoiceSpeechEngine {
        if #available(macOS 26, *), usesAnalyzer {
            return AnalyzerSpeechEngine()
        }
        return LegacySpeechEngine()
    }

    static func localeName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

/// `SFSpeechRecognizer` in on-device mode, for macOS 14 and 15.
///
/// The recognizer reports one growing transcription per request, so a
/// pause in speech ends the request and starts a fresh one. Each finished
/// request becomes one phrase.
final class LegacySpeechEngine: VoiceSpeechEngine {
    var onEvent: ((VoiceEngineEvent) -> Void)?
    /// Read at the start of each request, so a change lands after the next pause.
    var vocabulary: [String] = []

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var currentText = ""
    private var lastChange = Date()
    private var pauseTimer: Timer?
    private let lock = NSLock()

    private static let pauseSeconds: TimeInterval = 1.4

    func supportedLocales() async -> [Locale] {
        Array(SFSpeechRecognizer.supportedLocales()).sorted { $0.identifier < $1.identifier }
    }

    func support(for locale: Locale) async -> VoiceLocaleSupport {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return .unsupported }
        return recognizer.supportsOnDeviceRecognition ? .ready : .unsupported
    }

    func prepare(locale: Locale) async throws {
        let name = VoiceEngineFactory.localeName(locale)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw VoiceError("\(name) is not available for speech recognition.")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError("Download \(name) under System Settings › Keyboard › Dictation so it can run on this Mac.")
        }
        try await Self.authorize()
        self.recognizer = recognizer
    }

    private static func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw VoiceError("Allow Speech Recognition for Yeobun in System Settings › Privacy & Security.")
        }
    }

    func start() async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceError("Speech recognition is not available right now.")
        }
        running = true
        rotate()
        startPauseTimer()
    }

    private func startPauseTimer() {
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkForPause()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let request = lock.withLock { self.request }
        request?.append(buffer)
    }

    func stop() async {
        running = false
        pauseTimer?.invalidate()
        pauseTimer = nil
        let request = lock.withLock {
            let current = self.request
            self.request = nil
            return current
        }
        // Let the current request finish so its words still become a phrase.
        request?.endAudio()
    }

    /// Ends the current request and opens the next one so no audio is lost.
    private func rotate() {
        guard let recognizer, running else { return }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        next.requiresOnDeviceRecognition = true
        next.addsPunctuation = true
        next.contextualStrings = vocabulary
        let previous = lock.withLock {
            let current = request
            request = next
            return current
        }
        currentText = ""
        lastChange = Date()
        previous?.endAudio()

        var finished = false
        var taskRef: SFSpeechRecognitionTask?
        taskRef = recognizer.recognitionTask(with: next) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if finished { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        finished = true
                        self.emitPhrase(text, from: taskRef)
                    } else {
                        self.notePartial(text, from: taskRef)
                    }
                }
                if let error {
                    finished = true
                    self.handle(error, from: taskRef, lastText: self.currentText)
                }
            }
        }
        task = taskRef
    }

    private func notePartial(_ text: String, from task: SFSpeechRecognitionTask?) {
        guard task === self.task else { return }
        if text != currentText {
            currentText = text
            lastChange = Date()
        }
        onEvent?(.partial(text))
    }

    private func emitPhrase(_ text: String, from task: SFSpeechRecognitionTask?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if task === self.task {
            currentText = ""
            onEvent?(.partial(""))
        }
        if !trimmed.isEmpty {
            onEvent?(.phrase(trimmed))
        }
    }

    private func handle(_ error: Error, from task: SFSpeechRecognitionTask?, lastText: String) {
        let nsError = error as NSError
        // 1110: no speech detected. 216 / 301: request ended or cancelled.
        let benign = [1110, 216, 301].contains(nsError.code)
            || nsError.localizedDescription.localizedCaseInsensitiveContains("no speech")
        if task === self.task {
            currentText = ""
            onEvent?(.partial(""))
            if running {
                if benign {
                    rotate()
                } else {
                    running = false
                    onEvent?(.failed(nsError.localizedDescription))
                }
            }
        }
        if benign, !lastText.isEmpty {
            onEvent?(.phrase(lastText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private func checkForPause() {
        guard running, !currentText.isEmpty else { return }
        if Date().timeIntervalSince(lastChange) >= Self.pauseSeconds {
            rotate()
        }
    }
}

import Foundation

/// One live voice-typing session. Main thread only.
///
/// Owns the microphone and the recognizer, keeps the persisted session flag
/// in step for the CLI, and streams words to the live typer as they are heard.
final class VoiceSession: VoiceDriver {
    enum Phase: Equatable {
        case idle
        case requestingMicrophone
        case preparing(String)
        case listening
        case failed(String)
    }

    var onPhase: ((Phase) -> Void)?
    var onPartial: ((String) -> Void)?
    var onPhrase: ((String) -> Void)?

    /// Empty means the system language.
    var localeIdentifier = ""
    var silenceSeconds = VoiceTool.defaultSilenceSeconds
    var typesText = true

    private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { onPhase?(phase) }
        }
    }

    private var engine: VoiceSpeechEngine?
    private let microphone = VoiceMicrophone()
    private var silenceTimer: Timer?
    private var lastSpeech = Date()
    private var startTask: Task<Void, Never>?
    private let typer = VoiceLiveTyper()

    var isListening: Bool { phase == .listening }

    var isBusy: Bool {
        switch phase {
        case .requestingMicrophone, .preparing: true
        default: false
        }
    }

    var locale: Locale {
        localeIdentifier.isEmpty ? .current : Locale(identifier: localeIdentifier)
    }

    func setListening(_ listening: Bool) throws {
        if listening {
            start()
        } else {
            stop()
        }
    }

    func toggle() {
        if isListening || isBusy {
            stop()
        } else {
            start()
        }
    }

    func start() {
        if isListening || isBusy { return }
        ToolStateStore.shared.update { $0.voiceNotice = "" }
        typer.reset()
        onPartial?("")
        phase = .requestingMicrophone
        startTask = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func stop(notice: String? = nil) {
        startTask?.cancel()
        startTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        microphone.onBuffer = nil
        microphone.stop()
        let finishing = engine
        engine = nil
        if let finishing {
            Task { @MainActor in
                await finishing.stop()
            }
        }
        onPartial?("")
        if let notice {
            phase = .failed(notice)
        } else {
            phase = .idle
        }
        persistListening(false, notice: notice ?? "")
    }

    @MainActor
    private func run() async {
        var granted = VoiceMicrophone.permission == .granted
        if VoiceMicrophone.permission == .undetermined {
            granted = await VoiceMicrophone.requestPermission()
        }
        if Task.isCancelled { return }
        ToolStateStore.shared.update { $0.voiceMicrophone = granted ? "granted" : "denied" }
        guard granted else {
            fail("Allow Microphone for Yeobun in System Settings › Privacy & Security.")
            return
        }

        let engine = VoiceEngineFactory.make()
        engine.onEvent = { [weak self, weak engine] event in
            guard let self, let engine else { return }
            self.handle(event, from: engine)
        }
        let name = VoiceEngineFactory.localeName(locale)
        phase = .preparing("Preparing \(name)…")
        do {
            try await engine.prepare(locale: locale)
            if Task.isCancelled { return }
            try await engine.start()
        } catch {
            if Task.isCancelled { return }
            await engine.stop()
            fail(error.localizedDescription)
            return
        }
        if Task.isCancelled {
            await engine.stop()
            return
        }

        microphone.onBuffer = { [weak engine] buffer in
            engine?.append(buffer)
        }
        microphone.onConfigurationChange = { [weak self] in
            self?.restartMicrophone()
        }
        do {
            try microphone.start()
        } catch {
            await engine.stop()
            fail(error.localizedDescription)
            return
        }

        self.engine = engine
        lastSpeech = Date()
        startSilenceTimer()
        phase = .listening
        persistListening(true, notice: "")
    }

    private func fail(_ message: String) {
        stop(notice: message)
    }

    private func handle(_ event: VoiceEngineEvent, from source: VoiceSpeechEngine) {
        switch event {
        case .partial(let text):
            guard source === engine else { return }
            onPartial?(text)
            // An empty revision only clears the panel; the phrase that follows fixes the app.
            guard !text.isEmpty else { return }
            lastSpeech = Date()
            if typesText { typer.update(text, commit: false) }
        case .phrase(let text):
            lastSpeech = Date()
            deliver(text)
        case .progress(let message):
            guard source === engine || isBusy else { return }
            if case .preparing = phase {
                phase = .preparing(message)
            }
        case .failed(let message):
            guard source === engine else { return }
            fail(message)
        }
    }

    private func deliver(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onPhrase?(text)
        if typesText { typer.update(text, commit: true) }
    }

    private func restartMicrophone() {
        guard engine != nil else { return }
        do {
            try microphone.start()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSilence()
        }
    }

    private func checkSilence() {
        guard isListening, silenceSeconds > 0 else { return }
        if Date().timeIntervalSince(lastSpeech) >= TimeInterval(silenceSeconds) {
            stop()
        }
    }

    private func persistListening(_ listening: Bool, notice: String) {
        ToolStateStore.shared.update {
            $0.voiceListening = listening
            $0.voiceNotice = notice
        }
        ToolStateStore.shared.notifyChange()
    }
}

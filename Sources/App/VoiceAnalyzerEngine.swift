import AVFoundation
import Foundation
import Speech

/// `SpeechAnalyzer` with `SpeechTranscriber`, macOS 26 and later.
///
/// On device, and it finalizes phrases as you pause. Language models
/// download on demand. Vocabulary is applied after recognition, not as
/// contextual strings on the transcriber.
@available(macOS 26, *)
final class AnalyzerSpeechEngine: VoiceSpeechEngine {
    var onEvent: ((VoiceEngineEvent) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let converter = VoiceBufferConverter()
    private let lock = NSLock()

    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    func support(for locale: Locale) async -> VoiceLocaleSupport {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }
        let installed = await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == match.identifier(.bcp47)
        }
        return installed ? .ready : .needsDownload
    }

    func prepare(locale: Locale) async throws {
        let name = VoiceEngineFactory.localeName(locale)
        guard SpeechTranscriber.isAvailable else {
            throw VoiceError("Speech transcription is not available on this Mac.")
        }
        guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceError("\(name) is not supported for Voice typing on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: match, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            emit(.progress("Downloading \(name)…"))
            do {
                try await request.downloadAndInstall()
            } catch {
                throw VoiceError("\(name) could not be downloaded. \(error.localizedDescription)")
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError("No audio format works with the \(name) model.")
        }
        self.transcriber = transcriber
        self.analyzerFormat = format
    }

    func start() async throws {
        guard let transcriber else {
            throw VoiceError("The speech model is not ready.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock { input = continuation }
        let deliver: (VoiceEngineEvent) -> Void = { [weak self] event in
            self?.emit(event)
        }
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let event: VoiceEngineEvent = result.isFinal ? .phrase(text) : .partial(text)
                    await MainActor.run { deliver(event) }
                }
            } catch {
                if Task.isCancelled { return }
                let message = error.localizedDescription
                await MainActor.run { deliver(.failed(message)) }
            }
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (input, format) = lock.withLock { (self.input, analyzerFormat) }
        guard let input, let format,
              let converted = converter.convert(buffer, to: format) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        let input = lock.withLock {
            let current = self.input
            self.input = nil
            return current
        }
        input?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        // Results finish once the analyzer does; give the last phrase time to land.
        _ = await resultsTask?.result
        resultsTask = nil
    }

    private func emit(_ event: VoiceEngineEvent) {
        if Thread.isMainThread {
            onEvent?(event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        }
    }
}

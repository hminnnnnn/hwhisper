import Foundation
import AVFoundation
import Speech

/// B1 engine (Decision b): on-device transcription via the macOS 26
/// `SpeechAnalyzer`/`SpeechTranscriber` API. Locale-scoped by design (Apple),
/// so intra-utterance KO/EN code-switching is a structural risk (§2, R1) —
/// the M0 bake-off decides whether this is the runtime default vs
/// `WhisperKitRecognizer` (B2).
///
/// Callers MUST supply `PCMBuffer`s already at the sample rate this engine's
/// negotiated `AVAudioFormat` expects (queried internally via
/// `SpeechAnalyzer.bestAvailableAudioFormat`); this type does not resample.
@available(macOS 26.0, iOS 26.0, *)
public final class AppleSpeechRecognizer: SpeechRecognizer {
    public init() {}

    public var isAvailable: Bool {
        get async {
            SpeechTranscriber.isAvailable
        }
    }

    public func transcribe(
        _ buffers: [PCMBuffer],
        languageMode: RecognitionLanguageMode,
        contextualStrings: [String]
    ) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognizerError.engineUnavailable
        }

        let requestedLocale = Self.locale(for: languageMode)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SpeechRecognizerError.assetsNotProvisioned
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

        try await Self.ensureAssetsInstalled(for: transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            try await analyzer.setContext(context)
        }

        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechRecognizerError.recognitionFailed("no audio format compatible with SpeechTranscriber")
        }
        try await analyzer.prepareToAnalyze(in: audioFormat)

        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Consume results concurrently with feeding input (per Apple's
        // documented SpeechAnalyzer usage pattern) rather than after — the
        // results sequence is not guaranteed to buffer indefinitely.
        async let collectedText: String = {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }()

        async let analysisRun: Void = {
            try await analyzer.start(inputSequence: inputSequence)
        }()

        do {
            // Always finish the stream, even on failure, so `analyzer.start`
            // (running concurrently in `analysisRun`) doesn't hang waiting
            // for more input that will never arrive.
            defer { continuation.finish() }
            for buffer in buffers {
                let pcmBuffer = try Self.makePCMBuffer(from: buffer, format: audioFormat)
                continuation.yield(AnalyzerInput(buffer: pcmBuffer))
            }
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = try await analysisRun

        let text = try await collectedText
        return TranscriptionResult(text: text, languageMode: languageMode)
    }

    /// `AssetInventory` locale allocation is scoped to *this process*,
    /// independent of whether the model bits are already installed on disk
    /// (`SpeechTranscriber.installedLocales`) — confirmed via direct
    /// `AssetInventory` inspection: `status(forModules:)` reports
    /// `.supported` (not `.installed`) for an on-disk-installed locale
    /// until the process calls `reserve(locale:)`. Without this call,
    /// `SpeechAnalyzer(modules:)` fails at runtime with "Cannot use
    /// modules with unallocated locales" even when `installedLocales`
    /// already contains the locale (e.g. downloaded previously by
    /// `HwhisperEval` or System Settings > Dictation — a different
    /// process, so its allocation doesn't carry over to this one).
    private static func ensureAssetsInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        // reserve() returns false when this app already holds a reservation
        // for the locale (reservations persist per bundle ID across
        // launches) — a benign no-op, NOT a failure. Only a thrown error is
        // fatal. Verified empirically: first call → true, second → false,
        // reservedLocales contains the locale either way.
        _ = try await AssetInventory.reserve(locale: locale)

        let installed = await SpeechTranscriber.installedLocales
        let alreadyInstalled = installed.contains {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }
        guard !alreadyInstalled else { return }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            throw SpeechRecognizerError.assetsNotProvisioned
        }
        try await request.downloadAndInstall()
    }

    /// KO/EN mode selection. `.auto` (mixed) has no true code-switch locale
    /// on this engine (structural limit, §2 R1); defaults to Korean since
    /// KO-base with EN loanwords is the more common code-switch direction.
    /// Revisit once the M0 bake-off data is in.
    private static func locale(for mode: RecognitionLanguageMode) -> Locale {
        switch mode {
        case .korean: Locale(identifier: "ko-KR")
        case .english: Locale(identifier: "en-US")
        case .auto: Locale(identifier: "ko-KR")
        }
    }

    /// Converts a plain-PCM `PCMBuffer` into an `AVAudioPCMBuffer` matching
    /// `format` exactly. `SpeechAnalyzer.bestAvailableAudioFormat` is NOT
    /// guaranteed to negotiate Float32 — on this host it negotiates
    /// `.pcmFormatInt16` (16kHz mono) — so both common formats are handled
    /// explicitly. Silently dropping unconvertible buffers previously caused
    /// every buffer to be skipped (via `guard ... else { continue }`),
    /// yielding empty transcripts with no error; this now throws instead.
    ///
    /// Note on `isInterleaved`: `AVAudioPCMBuffer.floatChannelData` /
    /// `.int16ChannelData` always expose one contiguous pointer per channel
    /// regardless of the format's `isInterleaved` flag — AVFoundation
    /// manages the underlying (de)interleaving internally — so no special
    /// casing is needed here. Confirmed moot in practice too: the negotiated
    /// format on this host is mono (channelCount == 1).
    private static func makePCMBuffer(from buffer: PCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let channels = max(buffer.channelCount, 1)
        let frameCount = AVAudioFrameCount(buffer.samples.count / channels)
        guard frameCount > 0 else {
            throw Self.conversionError("empty PCM buffer (0 usable frames, \(buffer.samples.count) samples / \(channels) channels)")
        }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw Self.conversionError("failed to allocate AVAudioPCMBuffer for negotiated format \(format)")
        }
        pcmBuffer.frameLength = frameCount

        let outputChannels = Int(format.channelCount)

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = pcmBuffer.floatChannelData else {
                throw Self.conversionError("floatChannelData unavailable for negotiated Float32 format \(format)")
            }
            for frame in 0..<Int(frameCount) {
                for channel in 0..<outputChannels {
                    let sourceChannel = min(channel, channels - 1)
                    let sampleIndex = frame * channels + sourceChannel
                    channelData[channel][frame] = sampleIndex < buffer.samples.count ? buffer.samples[sampleIndex] : 0
                }
            }
        case .pcmFormatInt16:
            guard let channelData = pcmBuffer.int16ChannelData else {
                throw Self.conversionError("int16ChannelData unavailable for negotiated Int16 format \(format)")
            }
            for frame in 0..<Int(frameCount) {
                for channel in 0..<outputChannels {
                    let sourceChannel = min(channel, channels - 1)
                    let sampleIndex = frame * channels + sourceChannel
                    let floatSample = sampleIndex < buffer.samples.count ? buffer.samples[sampleIndex] : 0
                    channelData[channel][frame] = Self.scaledInt16(from: floatSample)
                }
            }
        default:
            throw Self.conversionError("unsupported AVAudioCommonFormat \(format.commonFormat.rawValue) negotiated by SpeechAnalyzer")
        }

        return pcmBuffer
    }

    /// Scales a [-1, 1] Float sample to Int16 PCM, clamping out-of-range
    /// input defensively (callers should already be supplying normalized
    /// samples).
    private static func scaledInt16(from sample: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, sample))
        return Int16((clamped * Float(Int16.max)).rounded())
    }

    private static func conversionError(_ message: String) -> SpeechRecognizerError {
        FileHandle.standardError.write(Data("AppleSpeechRecognizer: \(message)\n".utf8))
        return .recognitionFailed(message)
    }
}

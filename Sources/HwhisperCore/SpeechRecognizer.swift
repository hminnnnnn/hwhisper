import Foundation

/// Language handling mode requested for a transcription pass.
public enum RecognitionLanguageMode: Sendable, Equatable {
    case korean
    case english
    /// Mixed / code-switched KO+EN in a single utterance.
    case auto
}

public struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let languageMode: RecognitionLanguageMode
    /// Optional per-segment confidence, when the engine exposes one.
    public let confidence: Double?

    public init(text: String, languageMode: RecognitionLanguageMode, confidence: Double? = nil) {
        self.text = text
        self.languageMode = languageMode
        self.confidence = confidence
    }
}

public enum SpeechRecognizerError: Error, Sendable {
    case engineUnavailable
    case assetsNotProvisioned
    case recognitionFailed(String)
}

/// STT engine abstraction (Decision b). Concrete engines:
/// `AppleSpeechRecognizer` (B1, macOS 26+ SpeechAnalyzer/SpeechTranscriber)
/// and `WhisperKitRecognizer` (B2, WhisperKit large-v3-turbo).
/// Runtime selects by host availability; M0 bake-off decides the default.
public protocol SpeechRecognizer: Sendable {
    /// Whether this engine's runtime prerequisites (OS version, downloaded
    /// assets) are currently satisfied on this host.
    var isAvailable: Bool { get async }

    /// Transcribes a complete utterance's PCM buffers.
    /// Streaming partials are consumed internally for latency (no V1 UI);
    /// this entry point returns only the final result.
    func transcribe(
        _ buffers: [PCMBuffer],
        languageMode: RecognitionLanguageMode,
        contextualStrings: [String]
    ) async throws -> TranscriptionResult
}

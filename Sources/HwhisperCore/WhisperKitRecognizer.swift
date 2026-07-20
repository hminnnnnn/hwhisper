import Foundation
@preconcurrency import WhisperKit

/// B2 engine (Decision b): WhisperKit large-v3-turbo (quantized,
/// `large-v3-v20240930_turbo_632MB` — see `init` doc for the real repo-name
/// evidence), a single multilingual CoreML model. Architecturally better
/// positioned than the locale-scoped `AppleSpeechRecognizer` (B1) for
/// intra-utterance KO/EN code-switching, at the cost of resident model
/// memory (§2, R1/D2). The M0 bake-off decides whether B1 or B2 becomes the
/// runtime default.
///
/// Callers MUST supply `PCMBuffer`s already mono at `WhisperKit.sampleRate`
/// (16kHz); this type does not resample (same contract as
/// `AppleSpeechRecognizer`, §3 — resampling belongs to the platform-specific
/// audio capture layer, not Core).
///
/// The underlying `WhisperKit` instance is loaded lazily on first use (model
/// download + CoreML specialization can take seconds to minutes) and cached
/// for the lifetime of this recognizer to avoid repeated ~1.5GB reloads.
///
/// `@preconcurrency import WhisperKit` above: WhisperKit's `WhisperKit`
/// class (v1.0.0) predates Swift 6 concurrency auditing and is not
/// `Sendable`. Under strict concurrency, even calling an async method on an
/// actor-isolated, non-`Sendable` `kit` (e.g. `kit.transcribe(...)`) is
/// flagged as "sending" it across an isolation boundary. This is safe here:
/// `kit` is only ever touched from this actor's own isolated methods, which
/// the actor already serializes (no concurrent mutation of `kit` itself is
/// possible), and `WhisperKit.transcribe` is explicitly designed to be
/// called concurrently (its own multi-file/array batch APIs fan out via
/// `withTaskGroup` internally). `@preconcurrency` downgrades the
/// not-actually-unsafe-here diagnostic rather than papering over a real
/// race with `nonisolated(unsafe)`.
public actor WhisperKitRecognizer: SpeechRecognizer {
    private let modelVariant: String
    private var kit: WhisperKit?
    private var isLoading = false

    /// Default model variant fix (team-fix 2회차, root-caused via
    /// `HwhisperEval --probe`): the plain name `"large-v3-turbo"` does not
    /// exist as a folder in the `argmaxinc/whisperkit-coreml` HF repo — its
    /// real naming uses underscores/version tags, confirmed via the repo's
    /// actual file listing (`huggingface.co/api/models/argmaxinc/whisperkit-coreml`):
    /// `openai_whisper-large-v3-v20240930_turbo` /
    /// `openai_whisper-large-v3-v20240930_turbo_632MB` (no plain
    /// `large-v3-turbo` folder exists at all). `WhisperKit.download`'s glob
    /// search (`*\(variant)/*`, falling back to `*openai*\(variant)/*`)
    /// silently found zero matches for the old string and threw
    /// `WhisperError.modelsUnavailable` on every single fixture — previously
    /// hidden behind an opaque `.engineUnavailable` (see the error-mapping
    /// fix above). `_632MB` (quantized) is chosen over the uncompressed
    /// `_turbo` variant to minimize resident memory on the 8GB host (P2/D2),
    /// consistent with why "turbo" was picked at all (plan §2 Decision b);
    /// `-v20240930` is Argmax's current/recommended generation per the
    /// WhisperKit README, superseding the older un-versioned `large-v3_turbo`.
    public init(modelVariant: String = "large-v3-v20240930_turbo_632MB") {
        self.modelVariant = modelVariant
    }

    /// WhisperKit has no first-party "is this host supported" check that
    /// doesn't also risk triggering a model download (`WhisperKitConfig`
    /// downloads by default). To keep `isAvailable` cheap and side-effect
    /// free (matching `AppleSpeechRecognizer.isAvailable`'s contract), this
    /// reports platform support only; actual model load/download failures
    /// surface from `transcribe(_:languageMode:contextualStrings:)` as
    /// `.engineUnavailable` / `.assetsNotProvisioned`.
    public var isAvailable: Bool {
        get async { true }
    }

    public func transcribe(
        _ buffers: [PCMBuffer],
        languageMode: RecognitionLanguageMode,
        contextualStrings: [String]
    ) async throws -> TranscriptionResult {
        // NOTE: WhisperKit's DecodingOptions (v1.0.0) exposes only
        // token-level prompt/prefix biasing, not a string-based contextual
        // API like Apple's `contextualStrings`. Dictionary biasing for this
        // engine is deferred to the M2 PersonalDictionary work (§3); this
        // M0 recognizer accepts `contextualStrings` for protocol
        // conformance but does not yet apply it.
        _ = contextualStrings

        // NOTE (diagnosis fix, team-fix 2회차): this used to swallow the
        // real underlying error and rethrow the opaque `.engineUnavailable`,
        // which made a 60/60 "engineUnavailable" bake-off failure
        // undiagnosable (network error? repo/model name wrong? disk full?
        // decoding exception?). Preserve the real error text instead.
        let kit: WhisperKit
        do {
            kit = try await loadedWhisperKit()
        } catch {
            throw SpeechRecognizerError.recognitionFailed(
                "WhisperKit model load (\"\(modelVariant)\") failed: \(String(describing: error))"
            )
        }

        let audioArray = try Self.flattenToMono(buffers)
        guard !audioArray.isEmpty else {
            throw SpeechRecognizerError.recognitionFailed("no audio samples supplied")
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: Self.whisperLanguageCode(for: languageMode),
            usePrefillPrompt: true,
            detectLanguage: languageMode == .auto,
            wordTimestamps: false
        )

        // NOTE: deliberately no explicit result-type annotation anywhere in
        // this block — the module name and the `WhisperKit` class share a
        // name, so writing `WhisperKit.TranscriptionResult` resolves
        // (wrongly) to "nested type in class WhisperKit" rather than the
        // module-qualified re-exported type. Letting the type be inferred
        // purely from `kit.transcribe`'s own declared return type (and never
        // spelling it ourselves) avoids the collision entirely.
        let joinedText: String
        do {
            let rawResults = try await kit.transcribe(audioArray: audioArray, decodeOptions: options)
            joinedText = rawResults.map { $0.text }.joined(separator: " ")
        } catch {
            throw SpeechRecognizerError.recognitionFailed(String(describing: error))
        }

        let text = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(text: text, languageMode: languageMode)
    }

    /// Lazily loads (and caches) the underlying `WhisperKit` instance.
    ///
    /// `WhisperKit` (v1.0.0) is NOT `Sendable`, so it must never cross an
    /// isolation boundary via a `Task<WhisperKit, Error>`/`.value` handoff
    /// (that pattern requires `Success: Sendable` and fails Swift 6 strict
    /// concurrency checking). Instead, concurrent callers that arrive while
    /// a load is already in flight simply yield in a loop until the single
    /// in-progress load (still fully actor-isolated) publishes `kit` — the
    /// `WhisperKit` value itself never leaves this actor's isolation domain
    /// except as an ordinary return value from this actor-isolated method
    /// to another actor-isolated method (`transcribe`) on the same actor.
    private func loadedWhisperKit() async throws -> WhisperKit {
        while isLoading {
            await Task.yield()
        }
        if let kit {
            return kit
        }

        isLoading = true
        defer { isLoading = false }

        // Diagnostic logging (team-fix 2회차, M0-T6 item d): WhisperKitConfig's
        // one-shot init doesn't expose a download-progress callback (only the
        // low-level `WhisperKit.download(...)` static does), so this at least
        // surfaces *when* the load started/ended and the real failure reason,
        // instead of a silent hang followed by an opaque `.engineUnavailable`.
        let start = Date()
        print("[WhisperKitRecognizer] loading model \"\(modelVariant)\" (this downloads ~1.5GB on first run)...")
        do {
            let loaded = try await WhisperKit(WhisperKitConfig(model: modelVariant))
            print("[WhisperKitRecognizer] loaded model \"\(modelVariant)\" in \(Date().timeIntervalSince(start))s")
            kit = loaded
            return loaded
        } catch {
            print("[WhisperKitRecognizer] FAILED to load model \"\(modelVariant)\" after \(Date().timeIntervalSince(start))s: \(String(describing: error))")
            throw error
        }
    }

    /// KO/EN mode selection. `.auto` intentionally passes no forced
    /// language so WhisperKit's multilingual decoding (its structural
    /// advantage over B1 for code-switching, §2 R1) is not overridden.
    private static func whisperLanguageCode(for mode: RecognitionLanguageMode) -> String? {
        switch mode {
        case .korean: "ko"
        case .english: "en"
        case .auto: nil
        }
    }

    /// Concatenates and downmixes `PCMBuffer`s into a single mono `[Float]`
    /// array at the caller-supplied sample rate, which MUST already be
    /// `WhisperKit.sampleRate` (16kHz) — see the type-level doc comment.
    private static func flattenToMono(_ buffers: [PCMBuffer]) throws -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(buffers.reduce(0) { $0 + $1.samples.count })

        for buffer in buffers {
            guard buffer.sampleRate == Double(WhisperKit.sampleRate) else {
                throw SpeechRecognizerError.recognitionFailed(
                    "WhisperKitRecognizer requires \(WhisperKit.sampleRate)Hz PCM input, got \(buffer.sampleRate)Hz"
                )
            }

            let channels = max(buffer.channelCount, 1)
            if channels == 1 {
                samples.append(contentsOf: buffer.samples)
                continue
            }

            var frame = 0
            while frame * channels < buffer.samples.count {
                var sum: Float = 0
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    if index < buffer.samples.count {
                        sum += buffer.samples[index]
                    }
                }
                samples.append(sum / Float(channels))
                frame += 1
            }
        }

        return samples
    }
}

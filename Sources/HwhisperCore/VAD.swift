import Foundation

/// Dictation trigger mode. VAD behavior differs per mode (§3):
/// push-to-talk trims silence, toggle detects end-of-utterance.
public enum DictationMode: Sendable, Equatable {
    case pushToTalk
    case toggle
}

public enum VADEvent: Sendable, Equatable {
    case silenceTrimmed
    case utteranceEnd
}

/// Mode-aware voice activity detector (streaming shape — reserved for a
/// future partial-results consumer; V1's toggle-mode dictation captures a
/// complete utterance before STT runs, so `EnergyVAD.trim(_:)` below is the
/// concrete VAD implementation actually wired into the pipeline for now).
public protocol VoiceActivityDetector: Sendable {
    func process(_ buffer: PCMBuffer, mode: DictationMode) -> VADEvent?
}

/// Result of a batch leading/trailing silence trim.
public struct SilenceTrimResult: Sendable, Equatable {
    public let buffer: PCMBuffer
    public let leadingTrimmedSeconds: Double
    public let trailingTrimmedSeconds: Double
    /// True when no window in the buffer cleared the RMS threshold — the
    /// entire recording is silence. Callers should skip STT entirely and
    /// short-circuit with "음성이 감지되지 않았습니다" rather than pay for a
    /// transcription call that can only return empty/garbage text.
    public let isEntirelySilent: Bool
}

/// Energy (RMS)-based leading/trailing silence trimmer (§3 backlog item
/// "VAD 무음 트리밍"). Runs a fixed-size sliding window over the buffer,
/// finds the first/last window whose RMS clears `rmsThreshold`, and trims to
/// that range plus a `marginSeconds` pad on each side (clamped to the
/// buffer's bounds) so trimming can't clip the start/end of actual speech.
///
/// Operates on a complete, already-captured utterance buffer rather than a
/// streaming per-tap-callback buffer — toggle-mode dictation (the only mode
/// this app currently ships) records the whole utterance before handing it
/// to STT, so a single batch pass is sufficient and simpler than wiring up
/// `VoiceActivityDetector`'s streaming shape.
public struct EnergyVAD: Sendable {
    /// Upper bound on the speech/silence threshold. The threshold actually
    /// applied adapts to the recording's own peak level (see `trim`) — a
    /// fixed absolute threshold misclassified quiet-but-real speech (e.g.
    /// a soft speaker or low mic gain) as silence and trimmed the entire
    /// utterance, observed live: a clearly audible utterance transcribed
    /// as "." because every window fell below the fixed 0.015 RMS.
    public let rmsThreshold: Float
    public let marginSeconds: Double
    private let windowSeconds: Double = 0.02
    /// Below this peak RMS the whole buffer is considered genuinely silent
    /// (no plausible speech at any gain).
    private let absoluteFloor: Float = 0.003

    public init(rmsThreshold: Float = 0.015, marginSeconds: Double = 0.2) {
        self.rmsThreshold = rmsThreshold
        self.marginSeconds = marginSeconds
    }

    public func trim(_ buffer: PCMBuffer) -> SilenceTrimResult {
        let samples = buffer.samples
        let sampleRate = buffer.sampleRate
        guard !samples.isEmpty, sampleRate > 0 else {
            return SilenceTrimResult(
                buffer: buffer,
                leadingTrimmedSeconds: 0,
                trailingTrimmedSeconds: 0,
                isEntirelySilent: samples.isEmpty
            )
        }

        let windowSize = max(1, Int(windowSeconds * sampleRate))

        // Pass 1: per-window RMS + peak, so the speech threshold can adapt
        // to this recording's actual level instead of assuming a fixed gain.
        var windowRMS: [(start: Int, end: Int, rms: Float)] = []
        var peakRMS: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + windowSize, samples.count)
            let value = Self.rms(samples[index..<end])
            windowRMS.append((index, end, value))
            peakRMS = max(peakRMS, value)
            index += windowSize
        }

        // No window shows plausible speech at any gain → genuinely silent.
        guard peakRMS >= absoluteFloor else {
            return SilenceTrimResult(
                buffer: buffer,
                leadingTrimmedSeconds: Double(samples.count) / sampleRate,
                trailingTrimmedSeconds: 0,
                isEntirelySilent: true
            )
        }

        // Adaptive threshold: 10% of this recording's peak, clamped between
        // the absolute floor and the configured upper bound.
        let effectiveThreshold = min(rmsThreshold, max(absoluteFloor, peakRMS * 0.1))

        var firstActiveWindowStart: Int?
        var lastActiveWindowEnd: Int?
        for window in windowRMS where window.rms >= effectiveThreshold {
            if firstActiveWindowStart == nil { firstActiveWindowStart = window.start }
            lastActiveWindowEnd = window.end
        }

        guard let start = firstActiveWindowStart, let end = lastActiveWindowEnd else {
            return SilenceTrimResult(
                buffer: buffer,
                leadingTrimmedSeconds: Double(samples.count) / sampleRate,
                trailingTrimmedSeconds: 0,
                isEntirelySilent: true
            )
        }

        let marginSamples = Int(marginSeconds * sampleRate)
        let trimmedStart = max(0, start - marginSamples)
        let trimmedEnd = min(samples.count, end + marginSamples)

        let leadingTrimmed = Double(trimmedStart) / sampleRate
        let trailingTrimmed = Double(samples.count - trimmedEnd) / sampleRate
        let trimmedSamples = Array(samples[trimmedStart..<trimmedEnd])

        return SilenceTrimResult(
            buffer: PCMBuffer(samples: trimmedSamples, sampleRate: sampleRate, channelCount: buffer.channelCount),
            leadingTrimmedSeconds: leadingTrimmed,
            trailingTrimmedSeconds: trailingTrimmed,
            isEntirelySilent: false
        )
    }

    private static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in slice { sumSquares += sample * sample }
        return sqrt(sumSquares / Float(slice.count))
    }
}

import Foundation

/// Plain PCM buffer handed from platform-specific audio capture (HwhisperMac)
/// into HwhisperCore. Core never manages the audio session itself (§3).
///
/// (An `AudioSource` streaming protocol used to live here too; it never
/// gained a conformer — capture hands Core one finished buffer per
/// recording — so it was deleted in the 2026-08 audit rather than kept as an
/// unreachable abstraction.)
public struct PCMBuffer: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int

    public init(samples: [Float], sampleRate: Double, channelCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

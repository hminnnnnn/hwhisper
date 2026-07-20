import Foundation

/// Plain PCM buffer handed from platform-specific audio capture (HwhisperMac)
/// into HwhisperCore. Core never manages the audio session itself (§3).
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

/// Source of PCM buffers. Implemented by platform-specific audio capture
/// (e.g. HwhisperMac's `AVAudioEngine`-backed capture); consumed by Core.
public protocol AudioSource: Sendable {
    func stream() -> AsyncStream<PCMBuffer>
}

import AVFoundation
import HwhisperCore

enum AudioCaptureError: Error {
    case permissionDenied
    case engineStartFailed(String)
}

/// Owns the audio session and `AVAudioEngine` mic tap (§3: HwhisperMac-only,
/// Core never manages the audio session). Accumulates the recording as a
/// single 16kHz mono Float sample buffer, returned by `stop()` as a
/// `HwhisperCore.PCMBuffer`. Every downstream engine consumes this converted
/// path — `AppleSpeechRecognizer` re-derives its own negotiated analyzer
/// format from it in `makePCMBuffer`, so no raw-format copy of the audio is
/// kept. (An earlier revision also retained every unconverted tap buffer
/// "for engines that negotiate their own format"; nothing ever read them,
/// and at the 300s cap that dead path held ~58MB on the realtime audio
/// thread. 2026-08 audit.)
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isTapInstalled = false

    /// Guards `samples16k`/`latestLevel`: the tap callback appends from
    /// whatever realtime thread `AVAudioEngine` uses, while `start()`/
    /// `stop()`/`currentLevel()` touch the same state from the main actor.
    /// `engine.stop()` + `removeTap` do NOT document that in-flight tap
    /// callbacks have drained before returning, so an unsynchronized
    /// `Array.append` racing the drain would be heap corruption, not just a
    /// lost sample. Held only for the append/drain itself, never across
    /// conversion work.
    private let stateLock = NSLock()
    /// 16kHz mono Float samples, appended per tap buffer after conversion.
    private var samples16k: [Float] = []
    /// Most recent coarse RMS level in [0, 1] — polled by the main actor's
    /// level-meter timer (see `AppDelegate`). Written on the tap thread.
    /// Replaces the old per-buffer `onLevelUpdate` callback, which spawned a
    /// `Task { @MainActor }` from the realtime audio thread for every buffer
    /// (~12/s) — the same "create a Task from an event callback" shape as
    /// 함정 21, plus an allocation on a thread where allocation is a
    /// priority-inversion hazard.
    private var latestLevel: Float = 0

    static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// Starts capturing. Samples accumulate in `samples16k` until `stop()`
    /// is called (push-to-talk hold semantics, §4 M0/M1).
    func start() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioCaptureError.permissionDenied
        }

        stateLock.lock()
        samples16k.removeAll(keepingCapacity: false)
        // Pre-size for a typical dictation so the first several appends
        // don't each realloc; long recordings still grow amortized-O(1).
        samples16k.reserveCapacity(16_000 * 30)
        latestLevel = 0
        stateLock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.engineStartFailed("could not construct 16kHz mono target format")
        }
        self.targetFormat = targetFormat
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        isTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            isTapInstalled = false
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Stops capturing and returns the accumulated 16kHz mono samples as a
    /// single `HwhisperCore.PCMBuffer`. Also RELEASES the accumulator:
    /// before this, the last dictation's full PCM (~19MB at the 300s cap)
    /// stayed resident until the next recording started (2026-08 audit).
    @discardableResult
    func stop() -> PCMBuffer {
        engine.stop()
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        converter = nil
        targetFormat = nil

        stateLock.lock()
        let samples = samples16k
        samples16k = []
        latestLevel = 0
        stateLock.unlock()
        return PCMBuffer(samples: samples, sampleRate: 16_000, channelCount: 1)
    }

    /// Latest RMS level in [0, 1] — safe to call from the main actor while
    /// the tap thread is producing.
    func currentLevel() -> Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestLevel
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        let level = Self.computeLevel(for: buffer)

        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        let provider = SingleBufferProvider(buffer: buffer)
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if let next = provider.takeBuffer() {
                outStatus.pointee = .haveData
                return next
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard error == nil, outBuffer.frameLength > 0, let channelData = outBuffer.floatChannelData else { return }

        let frameCount = Int(outBuffer.frameLength)
        stateLock.lock()
        samples16k.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameCount))
        if let level { latestLevel = level }
        stateLock.unlock()
    }

    /// Coarse RMS level from the raw (unconverted) tap buffer — uses the raw
    /// buffer rather than the resampled one so the meter still animates even
    /// if conversion ever fails, and to avoid doing this work twice.
    private static func computeLevel(for buffer: AVAudioPCMBuffer) -> Float? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let samples = channelData[0]
        var sumSquares: Float = 0
        for i in 0..<frameCount {
            let sample = samples[i]
            sumSquares += sample * sample
        }
        let rms = Float(sqrt(Double(sumSquares / Float(frameCount))))
        // Normal speech RMS sits quite low (~0.01-0.1); apply a fixed gain
        // so the meter uses more of its visual range for typical mic input
        // instead of sitting near zero.
        return min(1, rms * 12)
    }
}

/// Feeds a single `AVAudioPCMBuffer` to `AVAudioConverter`'s block-based
/// `convert(to:error:withInputFrom:)` API exactly once, then reports
/// "no more data". `@unchecked Sendable`: the converter invokes the block
/// synchronously within the (also synchronous) `convert` call on the
/// capture-thread tap callback, so there is no actual concurrent access —
/// this box exists only to satisfy the compiler's Sendable-closure-capture
/// check without smuggling a mutable var/non-Sendable buffer directly into
/// the closure.
private final class SingleBufferProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var hasBeenTaken = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func takeBuffer() -> AVAudioPCMBuffer? {
        guard !hasBeenTaken else { return nil }
        hasBeenTaken = true
        return buffer
    }
}

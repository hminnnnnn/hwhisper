import AVFoundation
import HwhisperCore

enum AudioCaptureError: Error {
    case permissionDenied
    case engineStartFailed(String)
}

/// Owns the audio session and `AVAudioEngine` mic tap (§3: HwhisperMac-only,
/// Core never manages the audio session). Publishes two things per
/// recording:
///   - `PCMBuffer`s resampled to 16kHz mono Float, for engines that want a
///     fixed format `AudioSource` (matches `HwhisperCore.AudioSource`).
///   - the original-format `AVAudioPCMBuffer`s, unconverted, because
///     `AppleSpeechRecognizer` negotiates its own preferred format via
///     `SpeechAnalyzer.bestAvailableAudioFormat` and must not be fed a
///     buffer this class already resampled to some other rate (see that
///     type's header comment).
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var isTapInstalled = false

    /// Raw (unconverted) buffers captured from the input node's native
    /// format, forwarded as-is for engines that negotiate their own format.
    private(set) var rawBuffers: [AVAudioPCMBuffer] = []
    private(set) var rawFormat: AVAudioFormat?

    /// 16kHz mono Float buffers, resampled from the input node's native
    /// format — the fixed-format path (`HwhisperCore.PCMBuffer`).
    private(set) var convertedBuffers: [PCMBuffer] = []

    /// Fires on every captured tap buffer with an approximate RMS level in
    /// [0, 1] — feeds the floating recording indicator's live level meter
    /// (§4 M1 UX fix: "am I actually being heard" feedback). Invoked on
    /// whichever thread `AVAudioEngine`'s tap callback runs on (not
    /// necessarily main); callers must hop to the main actor before
    /// touching UI with it.
    var onLevelUpdate: ((Float) -> Void)?

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

    /// Starts capturing. Buffers accumulate in `rawBuffers`/`convertedBuffers`
    /// until `stop()` is called (push-to-talk hold semantics, §4 M0/M1).
    func start() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioCaptureError.permissionDenied
        }

        rawBuffers.removeAll()
        convertedBuffers.removeAll()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        rawFormat = inputFormat

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

    /// Stops capturing and returns the accumulated 16kHz mono buffers as a
    /// single `HwhisperCore.PCMBuffer` (samples concatenated).
    @discardableResult
    func stop() -> PCMBuffer {
        engine.stop()
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        let samples = convertedBuffers.flatMap(\.samples)
        return PCMBuffer(samples: samples, sampleRate: 16_000, channelCount: 1)
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        rawBuffers.append(buffer)
        reportLevel(for: buffer)

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
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        convertedBuffers.append(PCMBuffer(samples: samples, sampleRate: targetFormat.sampleRate, channelCount: 1))
    }

    /// Computes a coarse RMS level from the raw (unconverted) tap buffer and
    /// reports it via `onLevelUpdate`. Uses the raw buffer rather than the
    /// resampled one so the meter still animates even if conversion ever
    /// fails, and to avoid doing this work twice.
    private func reportLevel(for buffer: AVAudioPCMBuffer) {
        guard let onLevelUpdate,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

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
        let level = min(1, rms * 12)
        onLevelUpdate(level)
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

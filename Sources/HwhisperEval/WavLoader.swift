import Foundation

/// Minimal PCM WAV reader for the fixtures `fixtures/generate_fixtures.py`
/// produces (`afconvert -f WAVE -d LEI16@16000 -c 1`, i.e. mono 16-bit
/// little-endian PCM at 16kHz). Only what that pipeline emits is supported;
/// this is not a general-purpose WAV/AIFF decoder.
///
/// Foundation-only — no HwhisperCore/WhisperKit dependency, so it
/// typechecks standalone.
public enum WavLoader {
    public struct DecodedAudio: Sendable, Equatable {
        public let samples: [Float]
        public let sampleRate: Double
        public let channelCount: Int
    }

    public enum LoadError: Error, Equatable {
        case notRIFF
        case notWAVE
        case missingFormatChunk
        case missingDataChunk
        case unsupportedFormat(String)
    }

    public static func load(path: String) throws -> DecodedAudio {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> DecodedAudio {
        guard data.count >= 12 else { throw LoadError.notRIFF }

        let bytes = [UInt8](data)
        guard bytes[0...3].elementsEqual(Array("RIFF".utf8)) else { throw LoadError.notRIFF }
        guard bytes[8...11].elementsEqual(Array("WAVE".utf8)) else { throw LoadError.notWAVE }

        var offset = 12
        var channelCount: Int?
        var sampleRate: Double?
        var bitsPerSample: Int?
        var audioFormat: Int?
        var dataRange: Range<Int>?

        while offset + 8 <= bytes.count {
            let chunkID = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(readUInt32LE(bytes, at: offset + 4))
            let chunkBodyStart = offset + 8
            let chunkBodyEnd = min(chunkBodyStart + chunkSize, bytes.count)

            if chunkID == "fmt " {
                guard chunkBodyEnd - chunkBodyStart >= 16 else { throw LoadError.missingFormatChunk }
                audioFormat = Int(readUInt16LE(bytes, at: chunkBodyStart))
                channelCount = Int(readUInt16LE(bytes, at: chunkBodyStart + 2))
                sampleRate = Double(readUInt32LE(bytes, at: chunkBodyStart + 4))
                bitsPerSample = Int(readUInt16LE(bytes, at: chunkBodyStart + 14))
            } else if chunkID == "data" {
                dataRange = chunkBodyStart..<chunkBodyEnd
            }

            // Chunks are word-aligned (padded to even size).
            offset = chunkBodyStart + chunkSize + (chunkSize % 2)
        }

        guard let channelCount, let sampleRate, let bitsPerSample, let audioFormat else {
            throw LoadError.missingFormatChunk
        }
        guard let dataRange else { throw LoadError.missingDataChunk }
        // 1 = PCM integer. This loader only supports what afconvert's
        // `-d LEI16@...` produces.
        guard audioFormat == 1, bitsPerSample == 16 else {
            throw LoadError.unsupportedFormat("format=\(audioFormat) bitsPerSample=\(bitsPerSample)")
        }

        let dataBytes = bytes[dataRange]
        var samples: [Float] = []
        samples.reserveCapacity(dataBytes.count / 2)

        var i = dataRange.lowerBound
        while i + 1 < dataRange.upperBound {
            let raw = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            samples.append(Float(raw) / Float(Int16.max))
            i += 2
        }

        return DecodedAudio(samples: samples, sampleRate: sampleRate, channelCount: channelCount)
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

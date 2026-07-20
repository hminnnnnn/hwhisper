import Foundation

/// Decodes `fixtures/sentences.json` (M0 bake-off, n=60: 20 KO / 20 EN /
/// 20 mixed KO/EN). Foundation-only — no HwhisperCore/WhisperKit
/// dependency, so it typechecks standalone.
public enum FixtureLanguage: String, Codable, Sendable {
    case ko
    case en
    case mixed
}

public struct SentenceFixture: Codable, Sendable {
    public let id: String
    public let language: FixtureLanguage
    public let voice: String
    public let text: String
}

private struct FixtureFile: Codable {
    let normalization: String
    let note: String
    let sentences: [SentenceFixture]
}

public enum FixtureLoader {
    public enum LoadError: Error {
        case audioMissing(id: String, path: String)
    }

    /// Loads `sentences.json` and resolves each entry's expected
    /// `fixtures/audio/<id>.wav` path, verifying it exists on disk.
    /// - Parameters:
    ///   - sentencesPath: path to `fixtures/sentences.json`.
    ///   - audioDirectory: path to `fixtures/audio/`.
    public static func load(
        sentencesPath: String,
        audioDirectory: String
    ) throws -> [(fixture: SentenceFixture, audioPath: String)] {
        let data = try Data(contentsOf: URL(fileURLWithPath: sentencesPath))
        let file = try JSONDecoder().decode(FixtureFile.self, from: data)

        return try file.sentences.map { fixture in
            let audioPath = (audioDirectory as NSString).appendingPathComponent("\(fixture.id).wav")
            guard FileManager.default.fileExists(atPath: audioPath) else {
                throw LoadError.audioMissing(id: fixture.id, path: audioPath)
            }
            return (fixture, audioPath)
        }
    }
}

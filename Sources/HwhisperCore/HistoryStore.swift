import Foundation

/// One completed dictation, as it left the pipeline (§3 backlog "히스토리").
/// Both the raw transcript and the refined text are kept: the raw text is
/// the recovery source when refinement mangled something, and the pair
/// doubles as prompt-tuning data (실사용 수집 §BACKLOG).
public struct HistoryItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The transcript exactly as STT produced it (post-VAD).
    public let rawText: String
    /// The refiner's output, or nil when refinement was disabled, skipped,
    /// or fell back to raw (so `nil` always means "rawText is what was
    /// inserted").
    public let refinedText: String?
    /// Bundle ID of the app the text was inserted into (nil when unknown).
    public let targetBundleID: String?
    /// How the dictation ended: "inserted", "clipboard", "secureField",
    /// "failed" — mirrors `TextInserter`'s outcome cases as stable strings
    /// so Core stays decoupled from the Mac insertion layer.
    public let outcome: String
    /// Trimmed speech length in seconds (0 for rows recorded before this
    /// field existed) — the basis for the home tab's 받아쓰기 시간/절약
    /// 시간 stats.
    public let durationSeconds: Double
    public let createdAt: Date

    /// The text the user most likely wants back: what was actually
    /// inserted (refined when refinement ran, raw otherwise).
    public var insertedText: String { refinedText ?? rawText }

    public init(
        id: UUID = UUID(),
        rawText: String,
        refinedText: String? = nil,
        targetBundleID: String? = nil,
        outcome: String,
        durationSeconds: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rawText = rawText
        self.refinedText = refinedText
        self.targetBundleID = targetBundleID
        self.outcome = outcome
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
    }
}

/// Local dictation history with substring search. Lives in Core so V2 iOS
/// can reuse it (§3); the concrete implementation is `SQLiteHistoryStore`.
public protocol HistoryStore: Sendable {
    func save(_ item: HistoryItem) async throws
    /// Newest-first. Pass an empty query for "recent items".
    func search(query: String, limit: Int) async throws -> [HistoryItem]
    /// Newest-first rows recorded at or after `date` — the home tab's
    /// weekly-stats source (word/saved-time math happens in the caller).
    func items(since date: Date) async throws -> [HistoryItem]
    func delete(id: UUID) async throws
    func deleteAll() async throws
}

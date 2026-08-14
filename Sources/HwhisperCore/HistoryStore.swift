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
    /// Totals over `[since, ∞)` — `nil` means "everything ever recorded".
    /// Computed in SQL rather than by loading rows: the home tab's default
    /// view is all-time, and pulling every transcript's full text into memory
    /// just to count words would grow without bound.
    func aggregate(since date: Date?) async throws -> HistoryAggregate
    /// Per-app dictation counts over `[since, ∞)`, descending by count.
    func appCounts(since date: Date?) async throws -> [HistoryAppCount]
    /// Lightweight (timestamp, duration, words) triples for charting. Carries
    /// no transcript text, so a multi-month series stays cheap.
    func metrics(since date: Date?) async throws -> [HistoryMetricPoint]
    func delete(id: UUID) async throws
    func deleteAll() async throws
}

/// Totals for a period. Word counts come from the stored `word_count`
/// column so the number can never drift from what the UI would compute.
public struct HistoryAggregate: Sendable, Equatable {
    public var dictations: Int
    public var speechSeconds: Double
    public var words: Int

    public init(dictations: Int = 0, speechSeconds: Double = 0, words: Int = 0) {
        self.dictations = dictations
        self.speechSeconds = speechSeconds
        self.words = words
    }

    /// How long these words would have taken to type, per `typingWordsPerMinute`.
    public func typedSecondsEquivalent(wordsPerMinute: Double) -> Double {
        wordsPerMinute > 0 ? Double(words) / wordsPerMinute * 60 : 0
    }

    /// Time saved versus typing. Clamped at zero — a slow, heavily-paused
    /// dictation can legitimately take longer than typing it would have, and
    /// a negative "saving" is not a claim worth making.
    public func savedSeconds(typingWordsPerMinute: Double) -> Double {
        max(0, typedSecondsEquivalent(wordsPerMinute: typingWordsPerMinute) - speechSeconds)
    }

    /// Dictation words per minute of speech. Needs a few seconds of audio
    /// before the figure means anything.
    public var wordsPerMinute: Int {
        speechSeconds >= 5 ? Int((Double(words) / speechSeconds * 60).rounded()) : 0
    }
}

public struct HistoryAppCount: Sendable, Equatable, Identifiable {
    public let bundleID: String
    public let count: Int
    public var id: String { bundleID }

    public init(bundleID: String, count: Int) {
        self.bundleID = bundleID
        self.count = count
    }
}

public struct HistoryMetricPoint: Sendable, Equatable {
    public let createdAt: Date
    public let durationSeconds: Double
    public let words: Int

    public init(createdAt: Date, durationSeconds: Double, words: Int) {
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.words = words
    }
}

/// The single definition of "a word" in this app. Kept in Core so the value
/// written to `history.word_count` at save time, the value backfilled into
/// old rows, and anything the UI recomputes are all the same function.
///
/// Whitespace separation means this counts 어절 for Korean rather than
/// dictionary words — see the caveat on `typingWordsPerMinute`.
public enum TranscriptMetrics {
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

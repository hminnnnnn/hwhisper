import Foundation

/// One personal-dictionary entry (§3 N-3): `term` is the canonical spelling
/// the user wants to always see; `variants` are the misrecognitions STT (or
/// the refiner) tends to produce for it, replaced by `term` in the last-mile
/// pass.
public struct DictionaryEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public var term: String
    public var variants: [String]

    public init(id: UUID = UUID(), term: String, variants: [String] = []) {
        self.id = id
        self.term = term
        self.variants = variants
    }
}

/// Triple-defense personal dictionary (§3 N-3):
/// (a) recognition biasing — `biasingPhrases()` feeds the STT engine's
///     `contextualStrings` so the term is recognized correctly upfront;
/// (b) refinement protection — the same terms go to
///     `RefinementContext.protectedTerms` so the LLM won't "correct" them;
/// (c) last-mile substitution — AFTER refinement, known variants are
///     rewritten to the canonical term (final backstop, plan N-3: 치환은
///     정제 후).
public protocol PersonalDictionary: Sendable {
    func entries() async -> [DictionaryEntry]
    func biasingPhrases() async -> [String]
    /// Canonical terms whose spelling — the term itself OR any of its known
    /// variants — actually appears in `text`. This is what should be handed
    /// to the refiner as `protectedTerms`: passing a term that ISN'T in the
    /// input makes the LLM treat it as a salient entity and inject it into
    /// the output where the user never said it (observed live: "오웬" spliced
    /// onto an imperative sentence that only had a generic addressee).
    func protectedTerms(presentIn text: String) async -> [String]
    func applyLastMileSubstitution(to text: String) async -> String
}

/// JSON-file-backed `PersonalDictionary` with CRUD for the settings UI.
/// Platform-agnostic (storage URL injected) so V2 iOS reuses it; the Mac app
/// points it at the same owner-only App Support directory as
/// `CredentialStore`/`SQLiteHistoryStore`.
public actor FilePersonalDictionary: PersonalDictionary {
    private let fileURL: URL
    private var cached: [DictionaryEntry]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: PersonalDictionary

    public func entries() async -> [DictionaryEntry] {
        load()
    }

    public func biasingPhrases() async -> [String] {
        load().map(\.term).filter { !$0.isEmpty }
    }

    public func protectedTerms(presentIn text: String) async -> [String] {
        load().compactMap { entry in
            guard !entry.term.isEmpty else { return nil }
            let candidates = [entry.term] + entry.variants
            let appears = candidates.contains { needle in
                !needle.isEmpty && text.range(of: needle, options: [.caseInsensitive]) != nil
            }
            return appears ? entry.term : nil
        }
    }

    /// Replaces every known variant with its canonical term. Longest
    /// variants win first so "옴씨 코드" can't be half-rewritten by a
    /// shorter "옴씨" rule; matching is case-insensitive for Latin text
    /// (Korean has no case) via `.caseInsensitive` regex-free
    /// range(of:options:) scanning.
    public func applyLastMileSubstitution(to text: String) async -> String {
        var result = text
        let rules = load()
            .flatMap { entry in entry.variants.map { (variant: $0, term: entry.term) } }
            .filter { !$0.variant.isEmpty && !$0.term.isEmpty && $0.variant != $0.term }
            .sorted { $0.variant.count > $1.variant.count }

        for rule in rules {
            // A variant made only of ASCII letters/digits (e.g. "ON") must
            // match as a whole word, never inside a larger run — otherwise
            // "ON" rewrites the "on" in "conference"→"c<term>ference". Korean
            // (and other non-ASCII) variants keep plain substring matching:
            // Hangul has no case and words aren't space-delimited the same
            // way, so a boundary rule would mostly break legitimate matches.
            let asciiWord = rule.variant.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            var searchRange = result.startIndex..<result.endIndex
            while let found = result.range(of: rule.variant, options: [.caseInsensitive], range: searchRange) {
                if asciiWord && !Self.isWholeWord(found, in: result) {
                    // Skip this hit (it's inside a larger word) but keep scanning.
                    guard found.upperBound < result.endIndex else { break }
                    searchRange = found.upperBound..<result.endIndex
                    continue
                }
                result.replaceSubrange(found, with: rule.term)
                let resumeAt = result.index(found.lowerBound, offsetBy: rule.term.count)
                guard resumeAt < result.endIndex else { break }
                searchRange = resumeAt..<result.endIndex
            }
        }
        return result
    }

    /// True when the match at `range` is flanked by non-(ASCII-alphanumeric)
    /// characters on both sides — i.e. it's a standalone word, not a
    /// fragment of a larger Latin token.
    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        func isWordChar(_ character: Character) -> Bool {
            character.isASCII && (character.isLetter || character.isNumber)
        }
        if range.lowerBound > text.startIndex {
            let before = text[text.index(before: range.lowerBound)]
            if isWordChar(before) { return false }
        }
        if range.upperBound < text.endIndex {
            if isWordChar(text[range.upperBound]) { return false }
        }
        return true
    }

    // MARK: CRUD (settings UI)

    @discardableResult
    public func add(term: String, variants: [String]) async -> DictionaryEntry {
        let entry = DictionaryEntry(term: term, variants: variants)
        var all = load()
        all.append(entry)
        save(all)
        return entry
    }

    public func update(_ entry: DictionaryEntry) async {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == entry.id }) else { return }
        all[index] = entry
        save(all)
    }

    public func delete(id: UUID) async {
        save(load().filter { $0.id != id })
    }

    // MARK: Persistence

    private func load() -> [DictionaryEntry] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data) else {
            cached = []
            return []
        }
        cached = entries
        return entries
    }

    private func save(_ entries: [DictionaryEntry]) {
        cached = entries
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            // Atomic temp+rename (CredentialStore pattern) so a crash can't
            // truncate the dictionary.
            let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp")
            try data.write(to: tempURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Callers are UI actions; the next `load()` will show the truth.
            // No silent failure: this is the one Core file without a logger,
            // so surface via stderr for the log tail.
            FileHandle.standardError.write(Data("hwhisper: dictionary save failed: \(error)\n".utf8))
        }
    }
}

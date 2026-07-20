import Foundation

/// Text normalization + CER / spacing-normalized-WER for the M0 engine
/// bake-off (plan §2 Decision b): "primary accuracy metric for Korean/mixed
/// = CER OR spacing-normalized WER. Normalization rules fixed before M0:
/// strip/normalize punctuation, normalize whitespace/띄어쓰기, case-fold
/// Latin. Same normalizer applied to both engines."
///
/// Deliberately dependency-free (Foundation only) so it can be typechecked
/// and unit-verified with a bare `swiftc` invocation, independent of
/// HwhisperCore/WhisperKit SPM resolution.
public enum TextMetrics {
    /// Strips punctuation/symbols, collapses+trims whitespace, and
    /// lowercases Latin letters (Hangul has no case, so lowercasing is a
    /// no-op there). Applied identically to both reference and hypothesis
    /// text before scoring, and identically across engines (plan mandate).
    public static func normalize(_ text: String) -> String {
        let keptScalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        let stripped = String(String.UnicodeScalarView(keptScalars)).lowercased()
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// Levenshtein edit distance between two sequences (single-row DP,
    /// O(min(a.count, b.count)) memory).
    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previousRow = Array(0...b.count)
        var currentRow = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            currentRow[0] = i
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    currentRow[j] = previousRow[j - 1]
                } else {
                    currentRow[j] = 1 + min(previousRow[j - 1], previousRow[j], currentRow[j - 1])
                }
            }
            previousRow = currentRow
        }

        return previousRow[b.count]
    }

    /// Character error rate: edit distance over normalized text, divided by
    /// normalized reference length (in Unicode grapheme clusters, so
    /// precomposed Hangul syllables count as one character each).
    /// Returns 1.0 if the reference is empty and the hypothesis is not; 0.0
    /// if both are empty.
    public static func cer(reference: String, hypothesis: String) -> Double {
        let refChars = Array(normalize(reference))
        let hypChars = Array(normalize(hypothesis))
        guard !refChars.isEmpty else { return hypChars.isEmpty ? 0 : 1 }
        return Double(editDistance(refChars, hypChars)) / Double(refChars.count)
    }

    /// Spacing-normalized word error rate: edit distance over normalized,
    /// whitespace-split words, divided by normalized reference word count.
    public static func wer(reference: String, hypothesis: String) -> Double {
        let refWords = normalize(reference).split(separator: " ").map(String.init)
        let hypWords = normalize(hypothesis).split(separator: " ").map(String.init)
        guard !refWords.isEmpty else { return hypWords.isEmpty ? 0 : 1 }
        return Double(editDistance(refWords, hypWords)) / Double(refWords.count)
    }
}

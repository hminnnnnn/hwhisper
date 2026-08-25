import Foundation

/// Context passed to a refiner to protect personal-dictionary terms from being
/// re-mangled or translated (§3, N-3/N-4).
///
/// Intentionally carries NO app/frontmost-bundle identifier: refinement must
/// never adapt the transcript to whichever app is focused, and feeding the app
/// name in only ever risked leaking it into the output (removed for good).
public struct RefinementContext: Sendable, Equatable {
    /// Personal-dictionary terms passed as protected spans (N-3).
    public let protectedTerms: [String]

    public init(protectedTerms: [String] = []) {
        self.protectedTerms = protectedTerms
    }
}

public enum TextRefinerError: Error, Sendable {
    case timedOut
    case unavailable
    case requestFailed(String)
}

/// Refinement engine abstraction (Decision d). Concrete engines:
/// `PassthroughRefiner` (guaranteed floor) and `OpenAICompatibleRefiner`
/// (one client for Gemini/Groq/Ollama/custom — the planned separate
/// `LocalLLMRefiner`/`CloudRefiner` split never became necessary).
public protocol TextRefiner: Sendable {
    func refine(_ text: String, context: RefinementContext) async throws -> String
}

/// Guaranteed-floor refiner: returns the raw transcript unmodified.
/// Used offline, on timeout, on quota-exhaustion, or when refinement is off.
public struct PassthroughRefiner: TextRefiner {
    public init() {}

    public func refine(_ text: String, context: RefinementContext) async throws -> String {
        text
    }
}

import Foundation

/// Context passed to a refiner so it can adapt tone/formatting and protect
/// personal-dictionary terms from being re-mangled or translated (§3, N-3/N-4).
public struct RefinementContext: Sendable, Equatable {
    public let frontmostBundleID: String?
    /// Personal-dictionary terms passed as protected spans (N-3).
    public let protectedTerms: [String]

    public init(frontmostBundleID: String? = nil, protectedTerms: [String] = []) {
        self.frontmostBundleID = frontmostBundleID
        self.protectedTerms = protectedTerms
    }
}

public enum TextRefinerError: Error, Sendable {
    case timedOut
    case unavailable
    case requestFailed(String)
}

/// Refinement engine abstraction (Decision d). Concrete engines:
/// `PassthroughRefiner` (guaranteed floor), `LocalLLMRefiner` (qwen2.5:3b via
/// Ollama, MemoryGate-gated), `CloudRefiner` (BYOK free-tier, primary).
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

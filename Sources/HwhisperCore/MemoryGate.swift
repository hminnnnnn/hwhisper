import Foundation

/// Decision returned by the memory gate for the refining→inserting transition.
public enum RefinementGateDecision: Sendable, Equatable {
    /// Local LLM refinement permitted (explicit user override on an 8GB host,
    /// or host has sufficient headroom).
    case allowLocalLLM
    /// Local LLM refinement withheld; cloud (BYOK) refinement still allowed.
    case allowCloudOnly
    /// Refinement withheld entirely; raw passthrough only.
    case passthroughOnly
}

/// Static 8GB-host policy floor + live memory-pressure downgrade trigger
/// (§3, N-1). macOS has no `os_proc_available_memory` equivalent, so this
/// gate does not trust isolated RSS snapshots as a real-time signal; it uses
/// a static policy seeded from M0-measured peak RSS, with
/// `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` as a downgrade-only trigger.
public protocol MemoryGate: Sendable {
    func decide() -> RefinementGateDecision
}

import Foundation

/// Dictation pipeline state machine (§3.1), frozen before M1:
/// idle → listening → transcribing → refining → inserting → restoring → idle
public enum PipelineState: Sendable, Equatable {
    case idle
    case listening
    case transcribing
    case refining
    case inserting
    case restoring
}

/// A single queued utterance's end-to-end processing job (transcribe →
/// refine → insert). `run` is supplied by the platform layer (HwhisperMac)
/// and reports its own progress back through the owning `PipelineActor`'s
/// `transition(to:)` as it advances — the actor only sequences and
/// depth-bounds these opaque jobs, it never has to know what STT, refinement
/// or insertion actually are. That keeps this file (and all of
/// `HwhisperCore`) platform-agnostic (AC9): no AppKit/UIKit, no Mac-only
/// types like `TargetContextSnapshot` leak in here.
public struct PipelineJob {
    public let id: UUID
    public let run: () async -> Void
    /// Invoked if this job is dropped by backpressure (N-2) before it ever
    /// starts running. The platform layer uses this to notify the user —
    /// see `HwhisperMac/AppDelegate.handleJobDropped`.
    public let onDropped: () -> Void

    public init(id: UUID = UUID(), run: @escaping () async -> Void, onDropped: @escaping () -> Void = {}) {
        self.id = id
        self.run = run
        self.onDropped = onDropped
    }
}

/// Owns dictation pipeline state transitions and single-flight job
/// sequencing (§3.1).
///
/// This is a `@MainActor`-isolated class rather than a Swift `actor` — an
/// explicit alternative the design sanctions ("PipelineActor(또는
/// `@MainActor` 조정자)"). Every caller (hotkey handling, AX/clipboard/
/// CGEvent insertion in HwhisperMac) already runs on the main actor, so a
/// true cross-actor boundary here would only add `Sendable`-boxing overhead
/// for job closures without any real concurrency benefit — `@MainActor`
/// keeps the whole call chain isolation-free while still centralizing state
/// ownership exactly as §3.1 specifies.
///
/// Known simplification: `state` is a single, best-effort observability
/// signal, not a concurrency-control mechanism — that role belongs to the
/// `pending` queue + single-flight `drain()` loop below, which is what
/// actually guarantees jobs never interleave (no two jobs run
/// transcribe/refine/insert concurrently). A *new* recording can start
/// (idle→listening) via `transition(to:)` while a previously queued job is
/// still mid-flight through transcribing/refining/inserting; in that case
/// `state` reflects whichever transition fired most recently rather than
/// perfectly modeling two independent lanes (recording vs. processing).
/// `HwhisperLog`'s "state: A→B" trail still records every transition in the
/// order it actually happened, which is what matters for diagnosing overlap
/// scenarios.
@MainActor
public final class PipelineActor {
    /// N-2 backpressure policy: serial-queue depth cap. On overflow, the
    /// oldest *pending* (not-yet-started) job is dropped with notification
    /// rather than force-processed or merged — see `PipelineJob.onDropped`.
    public static let maxQueueDepth = 3

    public private(set) var state: PipelineState = .idle
    private var pending: [PipelineJob] = []
    private var isDraining = false

    /// Fired on every state change as `(old, new)` — HwhisperMac logs these
    /// as "state: A→B".
    public var onTransition: ((PipelineState, PipelineState) -> Void)?

    public init() {}

    public func transition(to newState: PipelineState) {
        let old = state
        guard old != newState else { return }
        state = newState
        onTransition?(old, newState)
    }

    /// Queues `job` for serial (single-flight) processing. Only one job's
    /// `run()` executes at a time, so insertion (and every stage before it)
    /// never interleaves across jobs — the overlap path's core guarantee.
    public func enqueue(_ job: PipelineJob) {
        if pending.count >= Self.maxQueueDepth {
            let dropped = pending.removeFirst()
            dropped.onDropped()
        }
        pending.append(job)
        drainIfNeeded()
    }

    private func drainIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let job = pending.removeFirst()
            await job.run()
        }
        isDraining = false
    }
}

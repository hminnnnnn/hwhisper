import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Peak resident-memory (RSS) sampling for the M0 bake-off's memory-vs-8GB
/// gating measurement (plan §2 Decision b, §4 M0 exit gate). Reads the
/// current process's resident size via `task_info`/`MACH_TASK_BASIC_INFO`
/// and tracks the observed maximum across periodic samples, rather than
/// relying solely on the kernel's `resident_size_max` (which is not
/// consistently updated pre-process-exit on all macOS versions).
///
/// Foundation/Darwin only — no HwhisperCore/WhisperKit dependency, so it
/// typechecks standalone.
public enum RSSSampler {
    /// Snapshot of the current process's resident memory, in bytes.
    /// Returns nil if `task_info` fails (should not happen for `self`).
    public static func currentResidentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
}

/// Periodically samples `RSSSampler.currentResidentBytes()` on a background
/// task and tracks the running maximum, for the duration of an arbitrary
/// scoped operation (e.g. "STT-only" vs "STT+LLM-concurrent" per the M0
/// exit-gate requirement).
public actor PeakRSSTracker {
    private var peakBytes: UInt64 = 0
    private var samplingTask: Task<Void, Never>?

    public init() {}

    /// Begins periodic sampling. Call `stop()` to end sampling and read the
    /// peak observed since `start()`.
    public func start(intervalNanoseconds: UInt64 = 50_000_000) {
        stopSamplingTaskOnly()
        peakBytes = RSSSampler.currentResidentBytes() ?? 0
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                if let bytes = RSSSampler.currentResidentBytes() {
                    await self?.record(bytes)
                }
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
    }

    /// Stops sampling and returns the peak resident-memory observed since
    /// the matching `start()` call, in bytes.
    @discardableResult
    public func stop() async -> UInt64 {
        stopSamplingTaskOnly()
        if let latest = RSSSampler.currentResidentBytes() {
            record(latest)
        }
        return peakBytes
    }

    private func record(_ bytes: UInt64) {
        peakBytes = max(peakBytes, bytes)
    }

    private func stopSamplingTaskOnly() {
        samplingTask?.cancel()
        samplingTask = nil
    }
}

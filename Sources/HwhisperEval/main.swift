import AVFoundation
import Foundation
import HwhisperCore
import Speech

// M0 engine bake-off harness (M0-T6, plan §4 M0 / §7): runs the n=60
// KO/EN/mixed fixture set through both SpeechRecognizer engines
// (AppleSpeechRecognizer=B1, WhisperKitRecognizer=B2), scores CER +
// spacing-normalized WER (TextMetrics), measures per-utterance latency and
// per-engine peak RSS (RSSSampler/PeakRSSTracker), and writes the M0
// exit-gate comparison table to `.omc/research/m0-bakeoff.md`.
//
// NOTE (plan-mandated caveat, §2 Decision b): fixtures/sentences.json audio
// is TTS-synthesized (macOS `say`), not real human speech — this is a
// *relative* engine comparison on this fixture set, not a real-world
// accuracy certification.
//
// KNOWN LIMITATION (this run): only STT-only peak RSS is measured here.
// The plan's "STT+LLM-concurrent" RSS scenario requires a TextRefiner
// (CloudRefiner/LocalLLMRefiner), which is M2 scope and not yet
// implemented — deferred, and called out explicitly in the report.
//
// DIAGNOSTIC MODE (team-fix 2회차): `HwhisperEval --probe <fixtureID>` runs
// a single fixture through both engines with verbose diagnostics (raw
// hypothesis text, full underlying errors, B1 asset-provisioning state,
// negotiated audio format) for fast iteration instead of a full 60x2 run.

// MARK: - Paths (repo-root-relative, resolved from this source file's
// compile-time location so the binary works regardless of CWD).

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // HwhisperEval/
    .deletingLastPathComponent() // Sources/
    .deletingLastPathComponent() // repo root
let sentencesPath = repoRoot.appendingPathComponent("fixtures/sentences.json").path
let audioDirectory = repoRoot.appendingPathComponent("fixtures/audio").path
let reportPath = repoRoot.appendingPathComponent(".omc/research/m0-bakeoff.md").path

// MARK: - Result types

struct FixtureRunResult {
    let fixture: SentenceFixture
    let hypothesis: String?
    let cer: Double?
    let wer: Double?
    let latencySeconds: Double?
    let errorDescription: String?

    /// True when the engine returned *successfully* (no thrown error) but
    /// with a blank/whitespace-only transcript. This is a silent failure —
    /// distinguishing it from both "real success" and "threw an error" is
    /// the whole point (team-fix 2회차 item 4): a report showing "0
    /// failures" alongside 100% CER previously hid exactly this.
    var isEmptyTranscript: Bool {
        guard let hypothesis else { return false }
        return hypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct EngineRunSummary {
    let engineName: String
    let results: [FixtureRunResult]
    let peakResidentBytes: UInt64?
    let loadError: String?
}

// MARK: - Language mapping

func recognitionLanguageMode(for language: FixtureLanguage) -> RecognitionLanguageMode {
    switch language {
    case .ko: .korean
    case .en: .english
    case .mixed: .auto
    }
}

func appleLocale(for languageMode: RecognitionLanguageMode) -> Locale {
    switch languageMode {
    case .korean: Locale(identifier: "ko-KR")
    case .english: Locale(identifier: "en-US")
    case .auto: Locale(identifier: "ko-KR")
    }
}

// MARK: - B1 (AppleSpeechRecognizer) asset-provisioning / format diagnostics
//
// AppleSpeechRecognizer.swift is worker-1's file — this does NOT modify or
// duplicate its production logic, it independently re-probes the same
// Speech-framework call sequence (SpeechTranscriber.isAvailable →
// installedLocales → supportedLocale → assetInstallationRequest →
// bestAvailableAudioFormat) purely for read-only diagnostic visibility that
// isn't otherwise observable from outside that file.

@available(macOS 26.0, *)
func diagnoseAppleSpeech(languageMode: RecognitionLanguageMode) async {
    let requestedLocale = appleLocale(for: languageMode)
    print("  SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")

    let installed = await SpeechTranscriber.installedLocales
    print("  installedLocales = \(installed.map { $0.identifier(.bcp47) })")

    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
        print("  supportedLocale(equivalentTo: \(requestedLocale.identifier(.bcp47))) = nil -> locale not supported at all on this host")
        return
    }
    print("  supportedLocale(equivalentTo: \(requestedLocale.identifier(.bcp47))) = \(supported.identifier(.bcp47))")

    let alreadyInstalled = installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
    print("  locale asset already installed = \(alreadyInstalled)")

    let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)

    if !alreadyInstalled {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                print("  assetInstallationRequest(supporting:) = non-nil; calling downloadAndInstall()...")
                let start = Date()
                try await request.downloadAndInstall()
                print("  downloadAndInstall() completed in \(Date().timeIntervalSince(start))s")
            } else {
                print("  assetInstallationRequest(supporting:) = nil -> no install needed OR unsupported")
            }
        } catch {
            print("  assetInstallationRequest/downloadAndInstall FAILED: \(String(describing: error))")
        }
    }

    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("  SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:) = nil")
        return
    }
    let commonFormatName: String = {
        switch format.commonFormat {
        case .pcmFormatFloat32: "pcmFormatFloat32"
        case .pcmFormatFloat64: "pcmFormatFloat64"
        case .pcmFormatInt16: "pcmFormatInt16"
        case .pcmFormatInt32: "pcmFormatInt32"
        case .otherFormat: "otherFormat"
        @unknown default: "unknown(\(format.commonFormat.rawValue))"
        }
    }()
    print("  bestAvailableAudioFormat: sampleRate=\(format.sampleRate) channels=\(format.channelCount) commonFormat=\(commonFormatName) isInterleaved=\(format.isInterleaved)")
    if format.commonFormat != .pcmFormatFloat32 {
        print("  ⚠️ commonFormat is NOT pcmFormatFloat32 — AppleSpeechRecognizer.makePCMBuffer() reads")
        print("     `pcmBuffer.floatChannelData`, which is nil for non-Float32 AVAudioPCMBuffers.")
        print("     If that guard fails, makePCMBuffer returns nil, the caller `continue`s past every")
        print("     buffer, ZERO audio is ever fed to the analyzer, and transcribe() returns an EMPTY")
        print("     string with NO thrown error. This matches the observed 60/60 empty-transcript")
        print("     100%-CER/0-failures bake-off result exactly.")
    }
}

// MARK: - Per-engine run

func run(
    engineName: String,
    engine: any SpeechRecognizer,
    fixtures: [(fixture: SentenceFixture, audioPath: String)]
) async -> EngineRunSummary {
    guard await engine.isAvailable else {
        return EngineRunSummary(
            engineName: engineName,
            results: [],
            peakResidentBytes: nil,
            loadError: "engine reported isAvailable == false"
        )
    }

    let tracker = PeakRSSTracker()
    await tracker.start()

    var results: [FixtureRunResult] = []
    results.reserveCapacity(fixtures.count)

    for (fixture, audioPath) in fixtures {
        let result: FixtureRunResult
        do {
            let decoded = try WavLoader.load(path: audioPath)
            let buffer = PCMBuffer(
                samples: decoded.samples,
                sampleRate: decoded.sampleRate,
                channelCount: decoded.channelCount
            )

            let start = Date()
            let transcription = try await engine.transcribe(
                [buffer],
                languageMode: recognitionLanguageMode(for: fixture.language),
                contextualStrings: []
            )
            let elapsed = Date().timeIntervalSince(start)

            let cer = TextMetrics.cer(reference: fixture.text, hypothesis: transcription.text)
            let wer = TextMetrics.wer(reference: fixture.text, hypothesis: transcription.text)

            result = FixtureRunResult(
                fixture: fixture,
                hypothesis: transcription.text,
                cer: cer,
                wer: wer,
                latencySeconds: elapsed,
                errorDescription: nil
            )
        } catch {
            result = FixtureRunResult(
                fixture: fixture,
                hypothesis: nil,
                cer: nil,
                wer: nil,
                latencySeconds: nil,
                errorDescription: String(describing: error)
            )
        }
        results.append(result)

        // Diagnostic requirement (a): print raw hypothesis text for at least
        // the first 3 fixtures per engine, explicitly flagging empty strings
        // rather than letting them look like ordinary short output.
        if results.count <= 3 {
            let hypDesc: String
            if let hypothesis = result.hypothesis {
                hypDesc = hypothesis.isEmpty ? "EMPTY STRING" : "\"\(hypothesis.prefix(120))\""
            } else {
                hypDesc = "nil (error: \(result.errorDescription ?? "?"))"
            }
            print("    [\(fixture.id)] hypothesis = \(hypDesc)")
        }
    }

    let peak = await tracker.stop()
    return EngineRunSummary(engineName: engineName, results: results, peakResidentBytes: peak, loadError: nil)
}

// MARK: - Aggregation

struct LanguageAggregate {
    let language: String
    let meanCER: Double?
    let meanWER: Double?
    let count: Int
    let emptyCount: Int
    let failureCount: Int
}

func aggregate(_ results: [FixtureRunResult], language: FixtureLanguage?) -> LanguageAggregate {
    let subset = language.map { lang in results.filter { $0.fixture.language == lang } } ?? results
    let succeeded = subset.filter { $0.errorDescription == nil }
    let cers = succeeded.compactMap { $0.cer }
    let wers = succeeded.compactMap { $0.wer }
    let meanCER = cers.isEmpty ? nil : cers.reduce(0, +) / Double(cers.count)
    let meanWER = wers.isEmpty ? nil : wers.reduce(0, +) / Double(wers.count)
    let emptyCount = succeeded.filter { $0.isEmptyTranscript }.count
    return LanguageAggregate(
        language: language?.rawValue ?? "overall",
        meanCER: meanCER,
        meanWER: meanWER,
        count: subset.count,
        emptyCount: emptyCount,
        failureCount: subset.count - succeeded.count
    )
}

func medianLatency(_ results: [FixtureRunResult]) -> Double? {
    let latencies = results.compactMap { $0.latencySeconds }.sorted()
    guard !latencies.isEmpty else { return nil }
    let mid = latencies.count / 2
    if latencies.count % 2 == 0 {
        return (latencies[mid - 1] + latencies[mid]) / 2
    }
    return latencies[mid]
}

// MARK: - Report rendering

func formatPercent(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.1f%%", value * 100)
}

func formatSeconds(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.2fs", value)
}

func formatMB(_ bytes: UInt64?) -> String {
    guard let bytes else { return "n/a" }
    return String(format: "%.0fMB", Double(bytes) / 1_048_576.0)
}

func renderReport(summaries: [EngineRunSummary]) -> String {
    var lines: [String] = []
    lines.append("# M0 Engine Bake-off — hwhisper")
    lines.append("")
    lines.append("Generated by `Sources/HwhisperEval/main.swift` (worker-2, M0-T6).")
    lines.append("")
    lines.append("**Caveat (plan §2 Decision b):** fixture audio is TTS-synthesized via macOS")
    lines.append("`say` (Yuna=ko-KR, Samantha=en-US), not real human speech. This is a")
    lines.append("**relative bake-off between engines on this fixture set**, not a certification")
    lines.append("of real-world accuracy.")
    lines.append("")
    lines.append("**Known limitation (this run):** only STT-only peak RSS is measured.")
    lines.append("The plan's STT+LLM-concurrent RSS scenario needs a `TextRefiner`")
    lines.append("(M2 scope, not yet implemented) and is deferred.")
    lines.append("")
    lines.append("Metric definition: CER / spacing-normalized WER per")
    lines.append("`Sources/HwhisperEval/TextMetrics.swift` (strip punctuation/symbols,")
    lines.append("collapse+trim whitespace, lowercase Latin — same normalizer both engines).")
    lines.append("")
    lines.append("**\"Empty\" column:** the engine returned *successfully* (no thrown error) with a")
    lines.append("blank/whitespace-only transcript. These are NOT counted as clean successes and are")
    lines.append("NOT folded into \"Failures\" either — they're a distinct silent-failure category.")
    lines.append("A row with `Failures=0` and a high `Empty` count means every call returned without")
    lines.append("an exception but produced no usable text; treat the CER/WER on that row as reflecting")
    lines.append("that silent failure, not real transcription accuracy.")
    lines.append("")

    for summary in summaries {
        lines.append("## \(summary.engineName)")
        lines.append("")

        if let loadError = summary.loadError {
            lines.append("**Not run:** \(loadError)")
            lines.append("")
            continue
        }

        lines.append("Peak RSS (STT-only, n=\(summary.results.count) fixtures): **\(formatMB(summary.peakResidentBytes))**")
        lines.append("")
        lines.append("| Subset | n | Mean CER | Mean WER | Empty | Failures |")
        lines.append("|---|---|---|---|---|---|")
        for language in [FixtureLanguage.ko, .en, .mixed] {
            let agg = aggregate(summary.results, language: language)
            lines.append("| \(agg.language) | \(agg.count) | \(formatPercent(agg.meanCER)) | \(formatPercent(agg.meanWER)) | \(agg.emptyCount) | \(agg.failureCount) |")
        }
        let overall = aggregate(summary.results, language: nil)
        lines.append("| **overall** | \(overall.count) | \(formatPercent(overall.meanCER)) | \(formatPercent(overall.meanWER)) | \(overall.emptyCount) | \(overall.failureCount) |")
        lines.append("")

        if overall.emptyCount > 0 {
            lines.append("> ⚠️ **\(overall.emptyCount)/\(overall.count) fixtures returned an EMPTY transcript with no thrown error.** This is a silent failure, not a real transcription attempt. Do not read the CER/WER above as an accuracy result until this is root-caused (see `--probe` diagnostics).")
            lines.append("")
        }

        lines.append("Median latency (utterance audio duration → transcript returned): \(formatSeconds(medianLatency(summary.results)))")
        lines.append("")

        lines.append("Sample transcripts (first 3 fixtures, raw hypothesis text):")
        lines.append("")
        for result in summary.results.prefix(3) {
            let hypDesc: String
            if let hypothesis = result.hypothesis {
                hypDesc = hypothesis.isEmpty ? "**(EMPTY STRING)**" : "\"\(hypothesis)\""
            } else {
                hypDesc = "*(no hypothesis — error: \(result.errorDescription ?? "?"))*"
            }
            lines.append("- `\(result.fixture.id)` ref=\"\(result.fixture.text)\" hyp=\(hypDesc)")
        }
        lines.append("")

        let failures = summary.results.filter { $0.errorDescription != nil }
        if !failures.isEmpty {
            lines.append("<details><summary>Failures (\(failures.count))</summary>")
            lines.append("")
            for failure in failures {
                lines.append("- `\(failure.fixture.id)`: \(failure.errorDescription ?? "unknown error")")
            }
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }
    }

    lines.append("## M0 Exit Gate")
    lines.append("")
    lines.append("Per plan §2 Decision (b): if B1 and B2 are comparable on code-switch (mixed)")
    lines.append("accuracy, default to B1 (lighter, lower peak RSS). If B1 is materially worse")
    lines.append("on mixed KO/EN, default to B2 despite memory cost. See the `mixed` row above")
    lines.append("per engine for the deciding comparison.")
    lines.append("")

    return lines.joined(separator: "\n") + "\n"
}

// MARK: - Probe mode (team-fix 2회차): fast single-fixture diagnosis instead
// of a full 60x2 run.

func runProbe(
    fixtureID: String,
    fixtures: [(fixture: SentenceFixture, audioPath: String)],
    engines: [(name: String, engine: any SpeechRecognizer)]
) async {
    guard let target = fixtures.first(where: { $0.fixture.id == fixtureID }) else {
        print("PROBE: fixture '\(fixtureID)' not found in \(sentencesPath)")
        return
    }

    print("PROBE fixture=\(target.fixture.id) language=\(target.fixture.language.rawValue)")
    print("PROBE reference text: \"\(target.fixture.text)\"")
    print("PROBE audio path: \(target.audioPath)")

    let decoded: WavLoader.DecodedAudio
    do {
        decoded = try WavLoader.load(path: target.audioPath)
        print("PROBE decoded audio: \(decoded.samples.count) samples, sampleRate=\(decoded.sampleRate)Hz, channels=\(decoded.channelCount)")
    } catch {
        print("PROBE WAV decode FAILED: \(String(describing: error))")
        return
    }

    let buffer = PCMBuffer(samples: decoded.samples, sampleRate: decoded.sampleRate, channelCount: decoded.channelCount)
    let languageMode = recognitionLanguageMode(for: target.fixture.language)

    if #available(macOS 26.0, *) {
        print("")
        print("PROBE [B1 AppleSpeechRecognizer] asset-provisioning / format diagnostics:")
        await diagnoseAppleSpeech(languageMode: languageMode)
    } else {
        print("")
        print("PROBE [B1 AppleSpeechRecognizer] skipped: requires macOS 26.0+")
    }

    for (name, engine) in engines {
        print("")
        print("PROBE running \(name)...")
        let available = await engine.isAvailable
        print("  isAvailable = \(available)")
        guard available else { continue }

        let start = Date()
        do {
            let result = try await engine.transcribe([buffer], languageMode: languageMode, contextualStrings: [])
            let elapsed = Date().timeIntervalSince(start)
            let hypDesc = result.text.isEmpty ? "EMPTY STRING" : "\"\(result.text)\""
            print("  SUCCESS in \(elapsed)s: hypothesis = \(hypDesc)")
            let cer = TextMetrics.cer(reference: target.fixture.text, hypothesis: result.text)
            let wer = TextMetrics.wer(reference: target.fixture.text, hypothesis: result.text)
            print("  CER = \(String(format: "%.1f%%", cer * 100)), WER = \(String(format: "%.1f%%", wer * 100))")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("  FAILED after \(elapsed)s: \(String(describing: error))")
        }
    }
}

// MARK: - Entry point

var engines: [(name: String, engine: any SpeechRecognizer)] = []
if #available(macOS 26.0, *) {
    engines.append(("AppleSpeechRecognizer (B1)", AppleSpeechRecognizer()))
} else {
    print("AppleSpeechRecognizer (B1) skipped: requires macOS 26.0+")
}
engines.append(("WhisperKitRecognizer (B2, large-v3-turbo)", WhisperKitRecognizer()))

let arguments = CommandLine.arguments
if let probeFlagIndex = arguments.firstIndex(of: "--probe") {
    guard probeFlagIndex + 1 < arguments.count else {
        print("usage: HwhisperEval --probe <fixtureID>  (e.g. --probe ko-01)")
        exit(1)
    }
    let fixtureID = arguments[probeFlagIndex + 1]
    do {
        let fixtures = try FixtureLoader.load(sentencesPath: sentencesPath, audioDirectory: audioDirectory)
        await runProbe(fixtureID: fixtureID, fixtures: fixtures, engines: engines)
        exit(0)
    } catch {
        print("PROBE failed to load fixtures: \(error)")
        exit(1)
    }
}

do {
    let fixtures = try FixtureLoader.load(sentencesPath: sentencesPath, audioDirectory: audioDirectory)
    print("Loaded \(fixtures.count) fixtures from \(sentencesPath)")

    var summaries: [EngineRunSummary] = []
    for (name, engine) in engines {
        print("Running \(name)...")
        let summary = await run(engineName: name, engine: engine, fixtures: fixtures)
        summaries.append(summary)
        print("  done: \(summary.results.count) results, peak RSS \(formatMB(summary.peakResidentBytes))")
    }

    let report = renderReport(summaries: summaries)
    let reportURL = URL(fileURLWithPath: reportPath)
    try FileManager.default.createDirectory(
        at: reportURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try report.write(to: reportURL, atomically: true, encoding: .utf8)
    print("Wrote report to \(reportPath)")
} catch {
    print("hwhisper-eval failed: \(error)")
    exit(1)
}

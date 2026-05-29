// PipelineSim.swift
//
// Deterministic simulator for the AutoImproveRecorder
// record-stop -> final-output pipeline. The simulator mirrors the orchestration
// shape of `AppState.processRecording()` with controllable stage latencies so
// scheduling changes can be benchmarked without a live microphone.
//
// The pipeline stages we model (in the order they happen on stop):
//
//   T0: stop button pressed
//   - audioFinalize:  AudioRecorder.stop() + clear sink + UI flip to .transcribing
//   - transcribe:     either streaming finalize or saved-file transcribe
//   - firstResult:    UI flip showing raw transcript / .ready (this is
//                     "first useful visible result" when auto-improve is off,
//                     OR auto-improve threshold not crossed)
//   - persist:        cache/diagnostics writes (modeled as a tiny serial cost
//                     today, target for deferral)
//   - improve:        POST to OpenAI Responses API, waits for full body
//   - finalReady:     UI flip + paste + clipboard write (this is final output)
//
// Time measurements:
//   tFirstResult: T0 -> first visible result
//   tFinal:       T0 -> final output complete
//
// The orchestrator under test lives in PipelineOrchestrator.swift -- the
// only file that the autoresearch loop is allowed to edit.

import Foundation

// MARK: - Stage clock

@MainActor
final class SimClock {
    private var nowSeconds: Double = 0
    private var pendingTasks: [(at: Double, work: () -> Void)] = []

    func now() -> Double { nowSeconds }

    /// Schedule work to run after `delay` seconds of simulated time.
    func after(_ delay: Double, _ work: @escaping () -> Void) {
        let at = nowSeconds + max(delay, 0)
        pendingTasks.append((at: at, work: work))
        pendingTasks.sort { $0.at < $1.at }
    }

    /// Run until the queue is empty.
    func runUntilQuiescent() {
        while let next = pendingTasks.first {
            pendingTasks.removeFirst()
            nowSeconds = next.at
            next.work()
        }
    }
}

// MARK: - Stage latency profile

struct StageProfile {
    /// Local time spent in AudioRecorder.stop + sink clear + UI flip to transcribing.
    var audioFinalize: Double
    /// Time to finalize streaming transcript (commit + wait for completion event)
    /// OR time to upload + transcribe saved file. Whichever path is active.
    var transcribe: Double
    /// Synchronous local persistence cost on the main actor right after the
    /// transcript arrives (writing diagnostics, updating defaults, refreshing
    /// the menu, copying the buffer to clipboard).
    var persist: Double
    /// Time for the improve provider to return improved text.
    var improve: Double
    /// Time to flip phase = .ready, paste, copy to clipboard.
    var finalize: Double

    /// Realistic profile inferred from logs (Parakeet path with OpenAI improve)
    /// -- numbers chosen as a representative scenario, not the exact production
    /// distribution. They are stable across trials so trial deltas are signal.
    static let realistic = StageProfile(
        audioFinalize: 0.05,
        transcribe: 1.40,
        persist: 0.10,
        improve: 1.90,
        finalize: 0.05
    )

    /// Faster scenario: streaming "fastest" mode where streamed transcript is
    /// nearly ready at stop -- finalize is short.
    static let streaming = StageProfile(
        audioFinalize: 0.05,
        transcribe: 0.45,
        persist: 0.10,
        improve: 1.90,
        finalize: 0.05
    )
}

// MARK: - Trial result

struct TrialMeasurement: Codable {
    var label: String
    var profile: String
    var firstResultMs: Double
    var finalMs: Double
    /// Critical-path serial sum (lower bound) used as a sanity check. If
    /// finalMs < this, the orchestrator broke a dependency.
    var serialSumMs: Double
    /// Did first-result happen on or before final?
    var orderingValid: Bool
    /// Was the improved text delivered?
    var improvedDelivered: Bool
    /// Was the raw transcript delivered (correctness guardrail)?
    var rawDelivered: Bool
}

// MARK: - Orchestrator API the simulator exposes

/// What the simulator hands to the orchestrator. Only this surface is edited
/// for trials.
@MainActor
final class SimContext {
    let clock: SimClock
    let profile: StageProfile
    private(set) var firstResultAt: Double?
    private(set) var finalAt: Double?
    private(set) var rawDelivered = false
    private(set) var improvedDelivered = false

    init(clock: SimClock, profile: StageProfile) {
        self.clock = clock
        self.profile = profile
    }

    /// Stage 1: AudioRecorder finalization + sink clear + transcribe-phase flip.
    /// Returns when the audio file is ready to hand off.
    func audioFinalize(_ done: @escaping () -> Void) {
        clock.after(profile.audioFinalize, done)
    }

    /// Stage 2: Transcribe -- streaming finalize or file transcribe.
    func transcribe(_ done: @escaping (_ rawTranscript: String) -> Void) {
        clock.after(profile.transcribe) {
            done("hello world this is a representative dictation transcript with enough words to cross the threshold")
        }
    }

    /// Stage 3 (today's serial behavior): non-critical persistence happening on the main thread before improve starts.
    func persist(_ done: @escaping () -> Void) {
        clock.after(profile.persist, done)
    }

    /// Stage 4: Improve provider. Cancellable, returns improved text.
    func improve(rawTranscript: String, _ done: @escaping (_ improvedText: String) -> Void) {
        clock.after(profile.improve) {
            done(rawTranscript.uppercased())
        }
    }

    /// Stage 5: paste + clipboard + UI ready flash.
    func finalize(_ done: @escaping () -> Void) {
        clock.after(profile.finalize, done)
    }

    /// Mark first useful visible result -- raw transcript shown OR improved
    /// text streaming starts. Whichever fires first wins.
    func markFirstVisibleResult() {
        if firstResultAt == nil {
            firstResultAt = clock.now()
        }
    }

    /// Mark the raw transcript handed to the user (clipboard / paste / ready).
    func markRawDelivered() {
        rawDelivered = true
    }

    /// Mark the improved text handed to the user (clipboard / paste / ready).
    func markImprovedDelivered() {
        improvedDelivered = true
    }

    /// Mark the pipeline complete.
    func markFinal() {
        if finalAt == nil {
            finalAt = clock.now()
        }
    }
}

// MARK: - Bench runner

@MainActor
enum PipelineBench {
    static func run(label: String, profile: StageProfile, profileName: String, orchestrate: @escaping (SimContext, @escaping () -> Void) -> Void) -> TrialMeasurement {
        let clock = SimClock()
        let ctx = SimContext(clock: clock, profile: profile)
        var didFinish = false
        orchestrate(ctx) {
            didFinish = true
        }
        clock.runUntilQuiescent()
        precondition(didFinish, "orchestrator never invoked completion in trial \(label)")

        let firstResult = ctx.firstResultAt ?? Double.infinity
        let final = ctx.finalAt ?? clock.now()
        let serialSum = profile.audioFinalize + profile.transcribe + profile.persist + profile.improve + profile.finalize

        return TrialMeasurement(
            label: label,
            profile: profileName,
            firstResultMs: firstResult * 1000,
            finalMs: final * 1000,
            serialSumMs: serialSum * 1000,
            orderingValid: firstResult <= final,
            improvedDelivered: ctx.improvedDelivered,
            rawDelivered: ctx.rawDelivered
        )
    }
}

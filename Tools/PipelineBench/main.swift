// main.swift
//
// Entry point for the pipeline scheduling bench.
//
// Usage:
//   swift Tools/PipelineBench/main.swift Tools/PipelineBench/PipelineSim.swift Tools/PipelineBench/PipelineOrchestrator.swift
//
// Or via run.sh which fixes argv ordering.
//
// Output: prints a JSON array of TrialMeasurement objects to stdout. The
// orchestrator-under-test is selected by the AIR_BENCH_VARIANT env var:
//
//   baseline                 -- baseline serial pipeline
//   defer_persist            -- improve and persist run in parallel
//   defer_persist_fnf        -- persist fired-and-forgotten after improve
//   prewarm_improve          -- improve URLSession prewarms during transcribe
//   partial_prewarm_defer    -- partial first-result + prewarm + deferred persist
//   speculative              -- speculative improve on partial transcript

import Foundation

@MainActor
func benchAll() -> [TrialMeasurement] {
    let variant = ProcessInfo.processInfo.environment["AIR_BENCH_VARIANT"] ?? "baseline"
    let orchestrate: (SimContext, @escaping () -> Void) -> Void
    switch variant {
    case "baseline": orchestrate = PipelineOrchestrator.baseline
    case "defer_persist": orchestrate = PipelineOrchestrator.deferPersist
    case "defer_persist_fnf": orchestrate = PipelineOrchestrator.deferPersistFireAndForget
    case "prewarm_improve": orchestrate = PipelineOrchestrator.prewarmImprove
    case "partial_prewarm_defer": orchestrate = PipelineOrchestrator.partialPlusPrewarmPlusDeferPersist
    case "speculative": orchestrate = PipelineOrchestrator.speculativeImprove
    default:
        FileHandle.standardError.write(Data("Unknown variant: \(variant)\n".utf8))
        exit(2)
    }

    var results: [TrialMeasurement] = []
    let profiles: [(String, StageProfile)] = [
        ("realistic", .realistic),
        ("streaming", .streaming),
    ]
    for (name, profile) in profiles {
        let label = "\(variant)/\(name)"
        let result = PipelineBench.run(label: label, profile: profile, profileName: name, orchestrate: orchestrate)
        results.append(result)
    }
    return results
}

MainActor.assumeIsolated {
    let results = benchAll()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    if let data = try? encoder.encode(results), let json = String(data: data, encoding: .utf8) {
        print(json)
    } else {
        FileHandle.standardError.write(Data("Failed to encode results\n".utf8))
        exit(3)
    }
}

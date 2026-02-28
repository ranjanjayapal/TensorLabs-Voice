#!/usr/bin/env swift

import Foundation

struct BenchmarkResult {
    let profile: String
    let firstPartialMs: Int
    let finalizeMs: Int
    let memoryMB: Int
}

func runSyntheticBenchmark(profile: String) -> BenchmarkResult {
    let baseline = profile == "fast" ? 180 : 260
    return BenchmarkResult(
        profile: profile,
        firstPartialMs: baseline,
        finalizeMs: baseline + 420,
        memoryMB: profile == "fast" ? 640 : 980
    )
}

let profile = CommandLine.arguments.dropFirst().first ?? "balanced"
let result = runSyntheticBenchmark(profile: profile)

print("ASR Benchmark (synthetic scaffold)")
print("profile=\(result.profile)")
print("first_partial_ms=\(result.firstPartialMs)")
print("finalize_ms=\(result.finalizeMs)")
print("memory_mb=\(result.memoryMB)")

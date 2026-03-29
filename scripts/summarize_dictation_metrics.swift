#!/usr/bin/env swift

import Foundation

struct CaptureRow {
    let engine: String
    let transcriptionMs: Int
    let elapsedMs: Int
    let inserted: Bool
}

let fileManager = FileManager.default
let defaultMetricsPath = fileManager
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("TensorLabsVoice/logs/metrics.jsonl")
    .path

let metricsPath = CommandLine.arguments.dropFirst().first ?? defaultMetricsPath
let limit = Int(ProcessInfo.processInfo.environment["LIMIT"] ?? "") ?? 50

guard let contents = try? String(contentsOfFile: metricsPath, encoding: .utf8) else {
    fputs("Could not read metrics file at \(metricsPath)\n", stderr)
    exit(1)
}

let rows: [CaptureRow] = contents
    .split(separator: "\n")
    .compactMap { line in
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (raw["event"] as? String) == "capture_complete",
              let engine = raw["engine_used"] as? String,
              let transcriptionMs = Int((raw["transcription_ms"] as? String) ?? ""),
              let elapsedMs = Int((raw["elapsed_ms"] as? String) ?? "")
        else {
            return nil
        }

        return CaptureRow(
            engine: engine,
            transcriptionMs: transcriptionMs,
            elapsedMs: elapsedMs,
            inserted: (raw["inserted"] as? String) == "true"
        )
    }

guard !rows.isEmpty else {
    print("No dictation capture metrics found in \(metricsPath)")
    exit(0)
}

let trimmedRows = Array(rows.suffix(limit))
let grouped = Dictionary(grouping: trimmedRows, by: \.engine)

func percentile(_ values: [Int], _ percentile: Double) -> Int {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let index = Int((Double(sorted.count - 1) * percentile).rounded())
    return sorted[max(0, min(index, sorted.count - 1))]
}

print("Dictation metrics summary")
print("file=\(metricsPath)")
print("sessions=\(trimmedRows.count)")
print("limit=\(limit)")

for engine in grouped.keys.sorted() {
    let engineRows = grouped[engine] ?? []
    let transcription = engineRows.map(\.transcriptionMs)
    let elapsed = engineRows.map(\.elapsedMs)
    let insertedCount = engineRows.filter(\.inserted).count

    print("")
    print("[\(engine)]")
    print("sessions=\(engineRows.count)")
    print("insert_success=\(insertedCount)/\(engineRows.count)")
    print("transcription_ms_p50=\(percentile(transcription, 0.50))")
    print("transcription_ms_p95=\(percentile(transcription, 0.95))")
    print("elapsed_ms_p50=\(percentile(elapsed, 0.50))")
    print("elapsed_ms_p95=\(percentile(elapsed, 0.95))")
}

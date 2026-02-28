import Foundation

final class LocalMetricsLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tensorlabs.voice.metrics")
    private let fileManager = FileManager.default

    private var logFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("TensorLabsVoice/logs", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("metrics.jsonl", isDirectory: false)
    }

    func log(event: String, metadata: [String: String]) {
        queue.async {
            var payload = metadata
            payload["event"] = event
            payload["ts"] = ISO8601DateFormatter().string(from: Date())

            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                var line = String(data: data, encoding: .utf8)
            else {
                return
            }

            line.append("\n")
            self.append(line)
        }
    }

    private func append(_ line: String) {
        let url = logFileURL
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        guard
            let handle = try? FileHandle(forWritingTo: url),
            let data = line.data(using: .utf8)
        else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }
}

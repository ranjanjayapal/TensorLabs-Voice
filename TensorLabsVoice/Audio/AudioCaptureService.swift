import AVFoundation
import Foundation

enum AudioCaptureError: Error {
    case inputUnavailable
}

final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    var onLevelUpdate: ((Float) -> Void)?
    private let targetSampleRate: Double = 16_000
    private let maxPrebufferSamples = 5_600
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var isMonitoring = false
    private var recentSamples: [Float] = []

    func startCaptureStream() -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation

            do {
                try primeCapture()
                if !recentSamples.isEmpty {
                    continuation.yield(recentSamples)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func stopCapture() {
        continuation?.finish()
        continuation = nil
    }

    func primeCapture() throws {
        if isMonitoring {
            return
        }
        try configureTap()
        isMonitoring = true
    }

    func shutdown() {
        continuation?.finish()
        continuation = nil
        recentSamples.removeAll(keepingCapacity: true)
        isMonitoring = false
        engine.inputNode.removeTap(onBus: 0)

        if engine.isRunning {
            engine.stop()
        }
    }

    private func configureTap() throws {
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        if converterInputFormat?.sampleRate != format.sampleRate || converterInputFormat?.channelCount != format.channelCount {
            converter = AVAudioConverter(from: format, to: targetFormat)
            converterInputFormat = format
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let values = self.toMono16kFloat(buffer: buffer)
            let level = self.calculateRMS(values)
            self.appendToPrebuffer(values)
            self.onLevelUpdate?(level)
            self.continuation?.yield(values)
        }

        if !engine.isRunning {
            try engine.start()
        }
    }

    private func toMono16kFloat(buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        guard buffer.frameLength > 0 else { return [] }

        if
            abs(format.sampleRate - targetSampleRate) < 0.1,
            format.channelCount == 1,
            format.commonFormat == .pcmFormatFloat32,
            let channelData = buffer.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        }

        guard let converter else {
            return extractFallbackMono(buffer: buffer)
        }

        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetSampleRate / format.sampleRate)
        ) + 32

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return extractFallbackMono(buffer: buffer)
        }

        var consumedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil, let channelData = outputBuffer.floatChannelData else {
            return extractFallbackMono(buffer: buffer)
        }

        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    private func extractFallbackMono(buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return [] }

        if let floatData = buffer.floatChannelData {
            var output = [Float](repeating: 0, count: frameLength)
            for frameIndex in 0..<frameLength {
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += floatData[channelIndex][frameIndex]
                }
                output[frameIndex] = sum / Float(channelCount)
            }
            return output
        }

        return []
    }

    private func appendToPrebuffer(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        recentSamples.append(contentsOf: samples)
        if recentSamples.count > maxPrebufferSamples {
            recentSamples.removeFirst(recentSamples.count - maxPrebufferSamples)
        }
    }

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { partial, value in
            partial + (value * value)
        }
        let mean = sum / Float(samples.count)
        let rms = sqrt(mean)
        return min(max(rms * 8, 0), 1)
    }
}

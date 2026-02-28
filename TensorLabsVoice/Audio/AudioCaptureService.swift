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

    func startCaptureStream() -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation

            do {
                try configureTap()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)

        if engine.isRunning {
            engine.stop()
        }

        continuation?.finish()
        continuation = nil
    }

    private func configureTap() throws {
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw AudioCaptureError.inputUnavailable
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let values = self.toMono16kFloat(buffer: buffer)
            let level = self.calculateRMS(values)
            self.onLevelUpdate?(level)
            self.continuation?.yield(values)
        }

        if !engine.isRunning {
            try engine.start()
        }
    }

    private func toMono16kFloat(buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return [] }

        let mono: [Float]
        if let floatData = buffer.floatChannelData {
            var result = [Float](repeating: 0.0, count: frameLength)
            for frameIndex in 0..<frameLength {
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += floatData[channelIndex][frameIndex]
                }
                result[frameIndex] = sum / Float(channelCount)
            }
            mono = result
        } else if let int16Data = buffer.int16ChannelData {
            var result = [Float](repeating: 0.0, count: frameLength)
            let scale: Float = 1.0 / Float(Int16.max)
            for frameIndex in 0..<frameLength {
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += Float(int16Data[channelIndex][frameIndex]) * scale
                }
                result[frameIndex] = sum / Float(channelCount)
            }
            mono = result
        } else if let int32Data = buffer.int32ChannelData {
            var result = [Float](repeating: 0.0, count: frameLength)
            let scale: Float = 1.0 / Float(Int32.max)
            for frameIndex in 0..<frameLength {
                var sum: Float = 0
                for channelIndex in 0..<channelCount {
                    sum += Float(int32Data[channelIndex][frameIndex]) * scale
                }
                result[frameIndex] = sum / Float(channelCount)
            }
            mono = result
        } else {
            return []
        }

        let sampleRate = buffer.format.sampleRate
        if abs(sampleRate - targetSampleRate) < 0.1 {
            return mono
        }

        return resampleLinear(mono, from: sampleRate, to: targetSampleRate)
    }

    private func resampleLinear(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return samples }

        let ratio = sourceRate / targetRate
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        var output = [Float](repeating: 0, count: outputCount)

        for index in 0..<outputCount {
            let sourceIndex = Double(index) * ratio
            let lower = Int(sourceIndex)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourceIndex - Double(lower))
            let lowerValue = samples[lower]
            let upperValue = samples[upper]
            output[index] = lowerValue + ((upperValue - lowerValue) * fraction)
        }

        return output
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

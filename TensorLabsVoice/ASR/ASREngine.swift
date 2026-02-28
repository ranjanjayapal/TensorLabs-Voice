import Foundation

enum ASREvent: Equatable {
    case partial(String)
    case final(String)
}

@MainActor
protocol ASREngine {
    var id: String { get }
    func prepare() async throws
    func transcribe(audioStream: AsyncThrowingStream<[Float], Error>) -> AsyncThrowingStream<ASREvent, Error>
    func stop() async
}

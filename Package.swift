// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TensorLabsVoice",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "TensorLabsVoice", targets: ["TensorLabsVoice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/soniqo/speech-swift", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "TensorLabsVoice",
            dependencies: [
                "WhisperKit",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "ParakeetASR", package: "speech-swift"),
            ],
            path: "TensorLabsVoice"
        ),
        .testTarget(
            name: "TensorLabsVoiceTests",
            dependencies: ["TensorLabsVoice"],
            path: "TensorLabsVoiceTests"
        ),
    ]
)

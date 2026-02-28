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
    ],
    targets: [
        .executableTarget(
            name: "TensorLabsVoice",
            dependencies: ["WhisperKit"],
            path: "TensorLabsVoice"
        ),
    ]
)

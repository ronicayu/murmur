// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .executable(name: "MurmurEngine", targets: ["MurmurEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.1"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        .binaryTarget(
            name: "SherpaOnnxC",
            path: "vendor/sherpa-onnx.xcframework"
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "HotKey",
                // No Swift code imports this. The vendored sherpa-onnx static
                // library needs the ONNX Runtime symbols at link time.
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "SherpaOnnxC",
            ],
            path: ".",
            exclude: ["Package.swift", "Scripts", "Tests", "EngineHelper"],
            resources: [.copy("Resources")],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        // The speech engine as a process of its own, so that the gigabytes it
        // holds go back to the system when the app ends that process. Its
        // sources are symbolic links to the app's own engine files: one copy
        // of the code, compiled into both.
        .executableTarget(
            name: "MurmurEngine",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "SherpaOnnxC",
            ],
            path: "EngineHelper",
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests"
        ),
    ]
)

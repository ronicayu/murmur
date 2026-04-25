// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
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
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                "SherpaOnnxC",
            ],
            path: ".",
            exclude: ["Package.swift", "Scripts", "Tests"],
            resources: [.copy("Resources")],
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

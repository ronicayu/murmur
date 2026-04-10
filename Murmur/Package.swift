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
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: ["HotKey"],
            path: ".",
            exclude: ["Package.swift", "Scripts", "Tests"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests"
        ),
    ]
)

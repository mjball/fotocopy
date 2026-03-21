// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Fotocopy",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Fotocopy",
            resources: [
                .process("../../Resources")
            ]
        ),
        .testTarget(
            name: "FotocopyTests",
            dependencies: ["Fotocopy"]
        )
    ]
)

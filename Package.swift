// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Foto",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Foto",
            resources: [
                .process("../../Resources")
            ]
        )
    ]
)

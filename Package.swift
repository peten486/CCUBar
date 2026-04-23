// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCUBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CCUBar",
            path: "Sources/CCUBar"
        ),
        .testTarget(
            name: "CCUBarTests",
            dependencies: ["CCUBar"],
            path: "Tests/CCUBarTests",
            resources: [.copy("Fixtures")]
        )
    ]
)

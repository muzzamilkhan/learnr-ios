// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LearnrEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LearnrEngine", targets: ["LearnrEngine"]),
    ],
    targets: [
        .target(name: "LearnrEngine"),
        .testTarget(
            name: "LearnrEngineTests",
            dependencies: ["LearnrEngine"],
            resources: [.copy("Vectors")]
        ),
    ]
)

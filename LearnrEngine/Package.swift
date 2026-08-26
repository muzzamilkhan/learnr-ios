// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LearnrEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LearnrEngine", targets: ["LearnrEngine"]),
    ],
    targets: [
        // `speed-modes.json` is the twenty-six modes' question specs, written by
        // `tools/generate-speedrun-vectors.ts` from the real `specsFor`. It
        // ships with the engine rather than being transcribed into Swift, so a
        // bound cannot drift from the TypeScript's.
        .target(name: "LearnrEngine", resources: [.process("Resources")]),
        .testTarget(
            name: "LearnrEngineTests",
            dependencies: ["LearnrEngine"],
            resources: [.copy("Vectors")]
        ),
    ]
)

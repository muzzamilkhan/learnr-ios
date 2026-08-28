// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LearnrEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LearnrEngine", targets: ["LearnrEngine"]),
    ],
    dependencies: [
        // The wire types are generated from the vendored contract rather than
        // transcribed - ledger `L1`. Both are Apple's, and the runtime is a
        // dependency of the generated code, not a client library this app calls.
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.12.0"),
    ],
    targets: [
        // `speed-modes.json` is the twenty-six modes' question specs, written by
        // `tools/generate-speedrun-vectors.ts` from the real `specsFor`. It
        // ships with the engine rather than being transcribed into Swift, so a
        // bound cannot drift from the TypeScript's.
        .target(
            name: "LearnrEngine",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            // The code directories, named explicitly. `Contract` and
            // `Resources` are deliberately absent: both are carried by the
            // resource rules below, and a directory named in both lists is a
            // duplicate-rule error. A new directory of Swift files has to be
            // added here or it is not built.
            sources: [
                "Api", "Expr", "Figures", "Rng",
                "Session", "SpeedRun", "Templates",
            ],
            // The contract and its config are inputs to the PLUGIN, not to the
            // compiler and not files to copy into the bundle. Listing them as
            // resources is what keeps them in the target's file list - which is
            // where the plugin looks - while keeping swiftc from being handed a
            // `.yaml` and refusing it as an unexpected input.
            //
            // `.copy` rather than `.process`: nothing needs transforming, and
            // `.process` on a `.yaml` is a no-op that only reads as intent.
            resources: [
                .process("Resources/speed-modes.json"),
                // `.copy` keeps the `Packs/` directory in the bundle, which
                // `.process` would flatten - and `BundledPacks` looks the packs
                // up by `subdirectory: "Packs"`. These are the content packs the
                // app ships with so a first launch with no network still has
                // questions; they move only in a re-vendoring commit.
                .copy("Resources/Packs"),
                .copy("Contract/openapi.yaml"),
                .copy("Contract/openapi-generator-config.yaml"),
            ],
            plugins: [
                // Runs at build time: nothing generated is committed, so the
                // types cannot drift from `Contract/openapi.yaml` the way a
                // checked-in copy would.
                .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator"),
            ]
        ),
        .testTarget(
            name: "LearnrEngineTests",
            dependencies: ["LearnrEngine"],
            resources: [.copy("Vectors"), .copy("Digests"), .copy("Packs")]
        ),
    ]
)

// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TeslaLinkCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "TeslaLinkCore", targets: ["TeslaLinkCore"]),
    ],
    targets: [
        // Apple platforms ship the `SQLite3` module; Linux (CI / tests) needs a shim.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "TeslaLinkCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "TeslaLinkCoreTests", dependencies: ["TeslaLinkCore"]),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blackout",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Blackout", targets: ["Blackout"])],
    targets: [
        .target(name: "BlackoutCore", path: "Sources/BlackoutCore"),
        .executableTarget(name: "Blackout", dependencies: ["BlackoutCore"], path: "Sources/Blackout"),
        // Maintainer-only: creates the release signing key and signs release ZIPs (see release.sh).
        .executableTarget(name: "ReleaseTool", dependencies: ["BlackoutCore"], path: "Sources/ReleaseTool"),
        // Plain executables rather than test targets: XCTest and Swift Testing are not part of the
        // Command Line Tools, and these checks must run with only those installed. Run via test.sh.
        .executableTarget(name: "CoreChecks", dependencies: ["BlackoutCore"], path: "Tests/CoreChecks"),
        .executableTarget(name: "BackendChecks", dependencies: ["BlackoutCore"], path: "Tests/BackendChecks"),
    ]
)

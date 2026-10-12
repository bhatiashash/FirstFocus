// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "DailyOS",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Confirmed working on this machine (Apple M3, Command Line Tools
        // only, no Xcode.app): ships a precompiled XCFramework, so unlike
        // MLX Swift it needs no local Metal shader compilation at all.
        .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.10549.0")),
        // Updates (ADR 0044): a binary XCFramework, like llama.swift, so it
        // needs no Xcode to build.
        .package(url: "https://github.com/sparkle-project/Sparkle", .upToNextMajor(from: "2.6.0"))
    ],
    targets: [
        .target(
            name: "DailyOSCore",
            dependencies: [
                .product(name: "LlamaSwift", package: "llama.swift")
            ]
        ),
        // Everything above AppKit that a test can still reach: the app
        // model and its preferences. The executable below keeps only
        // `main.swift`, the views, and the AppKit/Carbon glue, none of
        // which is testable without a running application (ADR 0020).
        // Imports no AppKit: the foreground trigger and the System
        // Settings opener are seams, so this inherits DailyOSCore's
        // framework-free posture.
        .target(
            name: "DailyOSApp",
            dependencies: ["DailyOSCore"]
        ),
        .executableTarget(
            name: "DailyOS",
            dependencies: ["DailyOSCore", "DailyOSApp", .product(name: "Sparkle", package: "Sparkle")]
        ),
        // Not a `.testTarget`: `swift test`'s runtime helper cannot load its
        // own test bundle on this machine (see TestHarness.swift for why).
        // Run with `swift run DailyOSTestRunner`. Covers DailyOSApp as
        // well as DailyOSCore, which is why it is no longer named for
        // Core alone.
        .executableTarget(
            name: "DailyOSTestRunner",
            dependencies: ["DailyOSCore", "DailyOSApp"],
            resources: [.copy("Fixtures")]
        ),
        // One-off model comparison study (not part of the shipped app):
        // loads each of the three catalog models in turn and runs a fixed
        // corpus through `LlamaCppIntentExtractor`, writing
        // model_evaluation_report.md. `DailyOSCore` only — no AppKit, no
        // EventKit, nothing beyond what reading the History DB and running
        // extraction actually needs.
        .executableTarget(
            name: "ModelEvaluator",
            dependencies: ["DailyOSCore"]
        ),
    ]
)

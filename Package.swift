// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hwhisper",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "HwhisperCore",
            targets: ["HwhisperCore"]
        ),
        .executable(
            name: "HwhisperMac",
            targets: ["HwhisperMac"]
        ),
        .executable(
            name: "HwhisperEval",
            targets: ["HwhisperEval"]
        )
    ],
    dependencies: [
        // GlobalHotkey (HwhisperMac only — AppKit-backed, never linked into HwhisperCore, AC9).
        // Pinned <1.16.0: 1.16.0+ (through 3.x) ships #Preview blocks that fail to compile on
        // CLT-only hosts (no PreviewsMacros plugin without full Xcode). 1.15.0 is the last clean
        // release and has the same onKeyDown/onKeyUp/setShortcut API surface we use.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", "1.9.0"..<"1.16.0"),
        // WhisperKit (B2 engine) — linked into HwhisperCore behind the SpeechRecognizer protocol (§3).
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0")
    ],
    targets: [
        // Platform-agnostic core (§3, P4). MUST NOT import AppKit/UIKit (AC9).
        .target(
            name: "HwhisperCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ]
        ),
        .testTarget(
            name: "HwhisperCoreTests",
            dependencies: ["HwhisperCore"],
            // CLT-only hosts (no Xcode.app) don't put Testing.framework on the
            // default search path the way Xcode does; point at it explicitly.
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
        // macOS app shell — hotkey, audio session, AX insertion, menubar UI (platform-specific).
        .executableTarget(
            name: "HwhisperMac",
            dependencies: [
                "HwhisperCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ]
        ),
        // M0 engine bake-off harness (CER / spacing-normalized-WER, peak-RSS).
        .executableTarget(
            name: "HwhisperEval",
            dependencies: ["HwhisperCore"]
        )
    ]
)

// swift-tools-version:5.9
import PackageDescription

// GameDock — macOS-only, Apple Silicon, controller-first gaming frontend.
// Architecture: SwiftUI shell + AppKit interop + Metal rendering + GameController input,
// with libretro cores embedded via dlopen (CLibretro C shim provides ABI-safe trampolines).
//
// Language mode is Swift 5 intentionally: GameController/Metal/libretro callbacks are
// not Swift 6 strict-concurrency friendly, and v1 correctness matters more than
// language-mode purity. Revisit for a future v2.

let package = Package(
    name: "Leblanc",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Leblanc", targets: ["GameDock"])
    ],
    targets: [
        // ABI-critical C shim: trimmed libretro.h + callback trampolines.
        // NEVER change struct layouts / enum values in here.
        .target(name: "CLibretro"),

        // RetroAchievements runtime (rcheevos, MIT) — vendored C library.
        .target(
            name: "CRcheevos",
            path: "Sources/CRcheevos",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .headerSearchPath("src/rcheevos"),
                .headerSearchPath("src/rhash"),
                .headerSearchPath("src/rapi"),
                .unsafeFlags(["-fno-modules", "-fno-objc-arc"]),
            ]
        ),

        .executableTarget(
            name: "GameDock",
            dependencies: ["CLibretro", "CRcheevos"],
            path: "Sources/GameDock",
            resources: [
                .process("Resources/Fonts")
            ],
            swiftSettings: [
                // GL bridge intentionally uses the deprecated-but-functional
                // OpenGL API (required by libretro GL cores).
                .unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"]),
                // Strip unused code/data at link time (smaller binary).
                .unsafeFlags(["-Xlinker", "-dead_strip"]),
            ]
        ),
    ]
)

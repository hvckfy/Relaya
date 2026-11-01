// swift-tools-version: 6.0
import Foundation
import PackageDescription

// FreeRDP 3 (встроенный RDP ядра): scripts/build-core-macos.sh с FREERDP_DIR_* кладёт universal dylib в core/build/freerdp.
// Без них ядро собирается без rdp-freerdp, и линковать нечего.
let freerdpDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../core/build/freerdp").standardized.path
let freerdpLinker: [LinkerSetting] = FileManager.default.fileExists(atPath: freerdpDir + "/libfreerdp3.dylib") ? [
    .linkedLibrary("freerdp3"), .linkedLibrary("freerdp-client3"), .linkedLibrary("winpr3"),
    // flate2 в ядре с rdp-freerdp собирается против zlib — системная из macOS SDK.
    .linkedLibrary("z"),
    // VNC ядра (vnc-royal): librelaya_core.a ссылается на rvnc_* из RoyalVNCKit — dylib лежит там же, где FreeRDP.
    .linkedLibrary("RoyalVNCKit"),
    // Сборка и тесты берут dylib отсюда; в .app они лежат в Contents/Frameworks (bundle-macos.sh).
    .unsafeFlags(["-L", freerdpDir, "-Xlinker", "-rpath", "-Xlinker", freerdpDir,
                  "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
] : []

let package = Package(
    name: "Relaya",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Relaya", targets: ["Relaya"]),
        .library(name: "RelayaCore", targets: ["RelayaCore"]),
    ],
    dependencies: [
        // 1.99+ требует Swift 6.2; держим 1.20.x, пока CI на Xcode 16.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        // Rust-ядро (core/ в корне репозитория): scripts/build-core-macos.sh кладёт xcframework в Frameworks/.
        .binaryTarget(name: "RelayaCoreFFI", path: "Frameworks/RelayaCoreFFI.xcframework"),
        // Сгенерированный UniFFI Swift API этого ядра.
        .target(
            name: "RelayaRust",
            dependencies: ["RelayaCoreFFI"],
            exclude: ["README.md"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: freerdpLinker
        ),
        // UI-независимая логика: ~/.ssh/config, ключи, хосты. Логика — в Rust-ядре, здесь — Swift-фасад и платформа.
        .target(name: "RelayaCore", dependencies: ["RelayaRust"]),
        .executableTarget(
            name: "Relaya",
            dependencies: [
                "RelayaCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(name: "RelayaCoreTests", dependencies: ["RelayaCore"]),
    ]
)

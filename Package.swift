// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relaya",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Relaya", targets: ["Relaya"]),
        .library(name: "RelayaCore", targets: ["RelayaCore"]),
    ],
    dependencies: [
        // 1.99+ требует Swift 6.2; держим 1.20.x, пока CI на Xcode 16.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        // UI-независимая логика: ~/.ssh/config, ключи, хосты.
        .target(name: "RelayaCore"),
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

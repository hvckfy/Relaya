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
        // Встроенный VNC-клиент (MIT, Royal Applications).
        // Закреплён на коммите тега 1.1.0: royalvnc зависит от CryptoSwift по ветке, и SwiftPM не разрешает версионную зависимость.
        // Встроенный RDP-клиент на чистом Swift (MIT). Закреплён на теге 0.5.0: проект молодой, API меняется.
        .package(url: "https://github.com/steelbrain/RDPKit.git", exact: "0.5.0"),
        .package(url: "https://github.com/royalapplications/royalvnc", revision: "8e9d3bb9cd041266df0659651f646fef251b4c71"),
    ],
    targets: [
        // UI-независимая логика: ~/.ssh/config, ключи, хосты.
        .target(name: "RelayaCore"),
        .executableTarget(
            name: "Relaya",
            dependencies: [
                "RelayaCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "RoyalVNCKit", package: "royalvnc"),
                .product(name: "RDPKit", package: "RDPKit"),
            ]
        ),
        .testTarget(name: "RelayaCoreTests", dependencies: ["RelayaCore"]),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ostra",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Ostra", targets: ["Ostra"]),
        .library(name: "OstraCore", targets: ["OstraCore"]),
        .library(name: "T3Bridge", targets: ["T3Bridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Domain models, the backend contract, and UI-independent state.
        .target(name: "OstraCore"),
        // The T3 Code engine: runtime install, server supervision, and RPC.
        .target(name: "T3Bridge", dependencies: ["OstraCore"]),
        // The macOS app.
        .executableTarget(
            name: "Ostra",
            dependencies: [
                "OstraCore",
                "T3Bridge",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            resources: [.copy("Resources/Fonts")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "OstraCoreTests", dependencies: ["OstraCore"]),
        .testTarget(name: "T3BridgeTests", dependencies: ["T3Bridge", "OstraCore"]),
    ]
)

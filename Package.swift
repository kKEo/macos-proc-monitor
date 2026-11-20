// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pmon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pmond", targets: ["pmond"]),
        .executable(name: "pmon", targets: ["pmon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "CPmonSys"),
        .target(name: "PmonCore", dependencies: ["CPmonSys"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "pmond", dependencies: ["PmonCore"]),
        .executableTarget(
            name: "pmon",
            dependencies: ["PmonCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .executableTarget(
            name: "pmon-stress",
            dependencies: ["PmonCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "PmonCoreTests", dependencies: ["PmonCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v5]
)

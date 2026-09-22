// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [
        .macOS(.v14),
        .iOS("26.0"),
    ],
    products: [
        .library(name: "QuotaModel", targets: ["QuotaModel"]),
        .library(name: "QuotaCloud", targets: ["QuotaCloud"]),
        .library(name: "QuotaRelay", targets: ["QuotaRelay"]),
    ],
    targets: [
        // What a reading is, and nothing that reads one: shared with the iOS
        // app, so Foundation only.
        .target(
            name: "QuotaModel",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // The readings' trip through the owner's private iCloud database,
        // written by the Mac and read by the iOS app and its widgets.
        .target(
            name: "QuotaCloud",
            dependencies: ["QuotaModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // The readings' trip through a Quota Run account when the phone is on
        // another iCloud account: request signing, the relay endpoints, and
        // the end-to-end encryption the server cannot see through.
        .target(
            name: "QuotaRelay",
            dependencies: ["QuotaModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "QuotaCore",
            dependencies: ["QuotaModel", "QuotaRelay"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "QuotaBar",
            dependencies: ["QuotaCore", "QuotaCloud"],
            resources: [.copy("Resources/logos"), .copy("Resources/brands"), .copy("Resources/fonts")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore", "QuotaModel", "QuotaCloud", "QuotaRelay"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

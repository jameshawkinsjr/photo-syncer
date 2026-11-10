// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoSyncer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhotoSyncer", targets: ["PhotoSyncer"]),
        .library(name: "PhotoSyncerCore", targets: ["PhotoSyncerCore"]),
    ],
    targets: [
        // Everything that doesn't need a window: config, the sync ledger,
        // sources (folders, Photos albums), service clients and the sync engine.
        .target(name: "PhotoSyncerCore"),
        // The SwiftUI app: windows, sign-in web views, Google OAuth.
        .executableTarget(name: "PhotoSyncer", dependencies: ["PhotoSyncerCore"]),
        .testTarget(name: "PhotoSyncerCoreTests", dependencies: ["PhotoSyncerCore"]),
    ]
)

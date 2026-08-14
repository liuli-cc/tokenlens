// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenLens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenLens", targets: ["TokenLens"]),
        .executable(name: "TokenLensBridge", targets: ["TokenLensBridge"])
    ],
    targets: [
        .executableTarget(
            name: "TokenLens",
            path: "Sources",
            exclude: ["Assets.xcassets"]
        ),
        .executableTarget(
            name: "TokenLensBridge",
            path: "BridgeSources"
        )
    ]
)

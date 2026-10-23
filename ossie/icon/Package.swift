// swift-tools-version: 6.0
import PackageDescription

// Renders the iPhone app's 1024 px App Store icon from the koala the apps
// already draw (CuaBotsCore's KoalaRenderer), so the icon never drifts from
// the avatar. Run from ossie/icon: swift run MakeIcon <output.png>
let package = Package(
    name: "MakeIcon",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../examples/cua-bots-macos")],
    targets: [
        .executableTarget(
            name: "MakeIcon",
            dependencies: [.product(name: "CuaBotsCore", package: "cua-bots-macos")],
            path: "Sources/MakeIcon"),
    ]
)

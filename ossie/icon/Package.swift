// swift-tools-version: 6.0
// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Ossie Irondi

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

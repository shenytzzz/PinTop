// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PinTop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PinTop", targets: ["PinTop"])
    ],
    targets: [
        .executableTarget(
            name: "PinTop",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)

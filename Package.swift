// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "edgepulse",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "edgepulse",
            targets: ["edgepulse"]
        ),
    ],
    dependencies:[
        .package(path: "localPackages/Tor"),
        .package(path: "localPackages/BitLogger"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.21.1")
    ],
    targets: [
        .executableTarget(
            name: "edgepulse",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "BitLogger", package: "BitLogger"),
                .product(name: "Tor", package: "Tor")
            ],
            path: "edgepulse",
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "edgepulse.entitlements",
                "edgepulse-macOS.entitlements",
                "LaunchScreen.storyboard"
            ],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "edgepulseTests",
            dependencies: ["edgepulse"],
            path: "edgepulseTests",
            exclude: [
                "Info.plist",
                "README.md"
            ],
            resources: [
                .process("Localization")
            ]
        )
    ]
)

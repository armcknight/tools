// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "tools",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
        .package(url: "https://github.com/armcknight/git-kit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]),
        .executableTarget(
            name: "migrate-changelog",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GitKit", package: "git-kit"),
            ]),
        .executableTarget(
            name: "changetag",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GitKit", package: "git-kit"),
            ]),
        .executableTarget(
            name: "prepare-release",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "prepare-github-release",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "read-changelog",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "vrsn",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "xcbs",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "psst",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "inject-git-info",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GitKit", package: "git-kit"),
            ]),
        .executableTarget(
            name: "upload-symbols",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "tag-icons",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GitKit", package: "git-kit"),
            ]),
        .executableTarget(
            name: "spm-acknowledgements",
            dependencies: [
                "Shared",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "Shared",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]),
    ]
)

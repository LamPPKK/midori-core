// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "XanhBrowserApple",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "XanhBrowserCore", targets: ["XanhBrowserCore"]),
    ],
    targets: [
        .target(
            name: "XanhBrowserCore",
            path: "Sources/XanhBrowserCore"
        ),
        .testTarget(
            name: "XanhBrowserCoreTests",
            dependencies: ["XanhBrowserCore"],
            path: "Tests/XanhBrowserCoreTests"
        ),
    ]
)

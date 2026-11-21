// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HiDpiSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HiDpiSwitcher", targets: ["HiDpiSwitcher"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "HiDpiSwitcher",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "HiDpiSwitcherTests",
            dependencies: ["HiDpiSwitcher"],
            path: "Tests/HiDpiSwitcherTests"
        )
    ],
    swiftLanguageModes: [.v6]
)

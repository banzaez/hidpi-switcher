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
    targets: [
        .executableTarget(
            name: "HiDpiSwitcher",
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

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapInk",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SnapInk", targets: ["SnapInk"])
    ],
    targets: [
        .executableTarget(
            name: "SnapInk",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Translation"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "SnapInkTests",
            dependencies: ["SnapInk"]
        )
    ]
)

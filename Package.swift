// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brushot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Brushot", targets: ["Brushot"])
    ],
    targets: [
        .executableTarget(
            name: "Brushot",
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
            name: "BrushotTests",
            dependencies: ["Brushot"]
        )
    ]
)

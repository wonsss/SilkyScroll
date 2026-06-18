// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SilkyScroll",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "SilkyScroll",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)

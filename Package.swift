// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Quicker",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CShims",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "Quicker",
            dependencies: ["CShims"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)

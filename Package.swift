// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Dimac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Dimac", targets: ["Dimac"])
    ],
    targets: [
        .target(
            name: "DimacCore",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "Dimac",
            dependencies: ["DimacCore"],
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "DimacCoreTests",
            dependencies: ["DimacCore"]
        ),
        .testTarget(
            name: "DimacTests",
            dependencies: ["Dimac"]
        )
    ]
)

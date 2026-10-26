// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZMarkDowner",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ZMarkDowner", targets: ["ZMarkDowner"]),
        .executable(name: "ZMarkDownerQuickLook", targets: ["ZMarkDownerQuickLook"]),
        .library(name: "MarkDownerCore", targets: ["MarkDownerCore"]),
    ],
    targets: [
        .target(name: "MarkDownerCore"),
        .executableTarget(name: "ZMarkDowner", dependencies: ["MarkDownerCore"]),
        // Quick Look preview extension (packaged as an .appex by build.sh)
        .executableTarget(
            name: "ZMarkDownerQuickLook",
            dependencies: ["MarkDownerCore"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
                .linkedFramework("QuickLookUI"),
            ]
        ),
        .testTarget(name: "MarkDownerCoreTests", dependencies: ["MarkDownerCore"]),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZMarkDowner",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ZMarkDowner", targets: ["ZMarkDowner"]),
        .library(name: "MarkDownerCore", targets: ["MarkDownerCore"]),
    ],
    targets: [
        .target(name: "MarkDownerCore"),
        .executableTarget(name: "ZMarkDowner", dependencies: ["MarkDownerCore"]),
        .testTarget(name: "MarkDownerCoreTests", dependencies: ["MarkDownerCore"]),
    ]
)

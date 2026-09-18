// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Beygla",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoshCore", targets: ["MoshCore"]),
        .executable(name: "Beygla", targets: ["Beygla"]),
        .executable(name: "beyglactl", targets: ["beyglactl"]),
    ],
    targets: [
        .target(name: "MoshCore"),
        .executableTarget(name: "Beygla", dependencies: ["MoshCore"]),
        .executableTarget(name: "beyglactl", dependencies: ["MoshCore"]),
    ]
)

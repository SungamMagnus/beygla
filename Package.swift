// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Moshbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MoshCore", targets: ["MoshCore"]),
        .executable(name: "Moshbox", targets: ["Moshbox"]),
        .executable(name: "moshctl", targets: ["moshctl"]),
    ],
    targets: [
        .target(name: "MoshCore"),
        .executableTarget(name: "Moshbox", dependencies: ["MoshCore"]),
        .executableTarget(name: "moshctl", dependencies: ["MoshCore"]),
    ]
)

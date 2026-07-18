// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Seanboy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeanboyCore", targets: ["SeanboyCore"]),
        .executable(name: "Seanboy", targets: ["Seanboy"]),
    ],
    targets: [
        .target(name: "SeanboyCore"),
        .executableTarget(
            name: "Seanboy",
            dependencies: ["SeanboyCore"]
        ),
        .testTarget(
            name: "SeanboyCoreTests",
            dependencies: ["SeanboyCore"]
        ),
    ]
)

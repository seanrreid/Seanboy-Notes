// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TomboyMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TomboyCore", targets: ["TomboyCore"]),
        .executable(name: "TomboyMac", targets: ["TomboyMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "TomboyCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .executableTarget(
            name: "TomboyMac",
            dependencies: ["TomboyCore"]
        ),
        .testTarget(
            name: "TomboyCoreTests",
            dependencies: ["TomboyCore"]
        ),
    ]
)

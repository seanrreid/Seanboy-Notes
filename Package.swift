// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Seanboy",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SeanboyCore", targets: ["SeanboyCore"]),
        .executable(name: "Seanboy", targets: ["Seanboy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "SeanboyCore",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
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

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Apparent",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Apparent", targets: ["Apparent"]),
    ],
    targets: [
        .target(
            name: "Apparent",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "ApparentTests",
            dependencies: ["Apparent"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

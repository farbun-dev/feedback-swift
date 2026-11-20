// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Feedback",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FeedbackKit", targets: ["FeedbackKit"])
    ],
    targets: [
        .target(name: "FeedbackKit"),
        .testTarget(name: "FeedbackKitTests", dependencies: ["FeedbackKit"]),
    ]
)

// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AIVVideoView",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AIVVideoView", targets: ["AIVVideoView"])
    ],
    targets: [
        .target(
            name: "AIVVideoView",
            path: "AIVVideoView/Classes"
        )
    ]
)

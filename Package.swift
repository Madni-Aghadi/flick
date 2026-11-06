// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flick",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FlickKit", targets: ["FlickKit"]),
        .library(name: "FlickMacCore", targets: ["FlickMacCore"]),
    ],
    targets: [
        .target(name: "FlickKit", path: "FlickKit/Sources/FlickKit"),
        .target(name: "FlickMacCore", dependencies: ["FlickKit"], path: "Mac/Core"),
        .executableTarget(name: "FlickMac", dependencies: ["FlickKit", "FlickMacCore"], path: "Mac/App"),
        .executableTarget(name: "flickctl", dependencies: ["FlickKit"], path: "Tools/flickctl"),
        .testTarget(name: "FlickKitTests", dependencies: ["FlickKit"], path: "FlickKit/Tests/FlickKitTests"),
    ]
)

// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LlamaLocal",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "llama", targets: ["llama"]),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            path: "llama.xcframework"
        ),
    ]
)

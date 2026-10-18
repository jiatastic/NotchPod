// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietCast",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuietCast", targets: ["QuietCast"])],
    targets: [
        .executableTarget(name: "QuietCast"),
        .testTarget(name: "QuietCastTests", dependencies: ["QuietCast"])
    ],
    swiftLanguageModes: [.v5]
)

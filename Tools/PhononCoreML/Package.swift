// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhononCoreML",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: [])
    ],
    targets: [
        .executableTarget(name: "phonon-coreml", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio")
        ])
    ]
)

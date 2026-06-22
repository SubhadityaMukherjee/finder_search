// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderSearch",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "FinderSearch", targets: ["FinderSearchApp"])
    ],
    targets: [
        .executableTarget(
            name: "FinderSearchApp",
            path: "Sources/FinderSearchApp",
            exclude: ["Resources/Info.plist"]
        )
    ]
)

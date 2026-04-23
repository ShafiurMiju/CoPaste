// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Copaste",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Copaste",
            path: "Sources/Copaste",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        )
    ]
)

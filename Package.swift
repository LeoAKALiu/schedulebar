// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ScheduleBar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "ScheduleBar", targets: ["ScheduleBar"]),
        .executable(name: "ScheduleBarApp", targets: ["ScheduleBarApp"]),
    ],
    targets: [
        .target(
            name: "ScheduleBar",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "ScheduleBarApp",
            dependencies: ["ScheduleBar"]
        ),
        .testTarget(
            name: "ScheduleBarTests",
            dependencies: ["ScheduleBar"]
        ),
    ]
)

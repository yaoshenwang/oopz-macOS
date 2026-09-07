// swift-tools-version:5.9
import PackageDescription

let vendor = "Vendor"

func local(_ name: String) -> Target {
    .binaryTarget(name: name, path: "\(vendor)/\(name).xcframework")
}

let package = Package(
    name: "Oopz",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Oopz", targets: ["Oopz"])],
    dependencies: [
        .package(url: "https://github.com/AgoraIO/AgoraInfra_macOS.git", exact: "1.3.7")
    ],
    targets: [
        .executableTarget(
            name: "Oopz",
            dependencies: [
                .byName(name: "AgoraRtcKit"),
                .byName(name: "Agorafdkaac"),
                .byName(name: "Agoraffmpeg"),
                .byName(name: "AgoraSoundTouch"),
                .byName(name: "video_dec"),
                .byName(name: "AgoraScreenCaptureExtension"),
                .byName(name: "AgoraInfra_macOS")
            ],
            path: "Sources/Oopz"
        ),
        local("AgoraRtcKit"),
        local("Agorafdkaac"),
        local("Agoraffmpeg"),
        local("AgoraSoundTouch"),
        local("video_dec"),
        local("AgoraScreenCaptureExtension"),
    ]
)

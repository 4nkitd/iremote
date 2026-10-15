// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "iRemote",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "RemoteCore", path: "Sources/RemoteCore", swiftSettings: v5),
        .executableTarget(name: "iRemote", dependencies: ["RemoteCore"], path: "Sources/iRemote", swiftSettings: v5),
        .target(name: "FakeTVKit", dependencies: ["RemoteCore"], path: "Sources/FakeTVKit", swiftSettings: v5),
        .executableTarget(name: "FakeTV", dependencies: ["FakeTVKit", "RemoteCore"], path: "Sources/FakeTV", swiftSettings: v5),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore", "FakeTVKit"], path: "Tests/RemoteCoreTests", swiftSettings: v5),
    ]
)

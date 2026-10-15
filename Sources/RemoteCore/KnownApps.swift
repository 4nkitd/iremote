import Foundation

public struct KnownApp: Identifiable, Equatable {
    public let name: String
    public let package: String
    public let link: String
    public var id: String { package }
}

/// App links verified against a real Chromecast with Google TV by the Couch project.
public enum KnownLinks {
    public static let apps: [KnownApp] = [
        KnownApp(name: "YouTube", package: "com.google.android.youtube.tv", link: "https://www.youtube.com"),
        KnownApp(name: "Netflix", package: "com.netflix.ninja", link: "https://www.netflix.com/title"),
        KnownApp(name: "Prime Video", package: "com.amazon.amazonvideo.livingroom", link: "https://app.primevideo.com"),
        KnownApp(name: "Disney+", package: "com.disney.disneyplus", link: "https://www.disneyplus.com"),
        KnownApp(name: "Apple TV", package: "com.apple.atve.androidtv.appletv", link: "https://tv.apple.com"),
        KnownApp(name: "Spotify", package: "com.spotify.tv.android", link: "https://open.spotify.com"),
        KnownApp(name: "Max", package: "com.wbd.stream", link: "https://play.max.com"),
        KnownApp(name: "YouTube Kids", package: "com.google.android.youtube.tvkids", link: "https://www.youtubekids.com"),
    ]

    static let screens: [String: String] = [
        "com.google.android.apps.tv.launcherx": "Home",
        "com.google.android.tvlauncher": "Home",
        "com.android.tv.settings": "Settings",
        "com.google.android.katniss": "Voice search",
    ]

    public static func package(for link: String) -> String? {
        apps.first { $0.link == link }?.package
    }

    public static func displayName(for package: String) -> String {
        if let app = apps.first(where: { $0.package == package }) { return app.name }
        if let screen = screens[package] { return screen }
        let last = package.split(separator: ".").last.map(String.init) ?? package
        return last.prefix(1).uppercased() + last.dropFirst()
    }
}

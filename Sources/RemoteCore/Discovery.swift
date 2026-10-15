import Foundation
import Network

public struct DiscoveredTV: Identifiable, Hashable {
    public let name: String
    public let endpoint: NWEndpoint
    public var id: String { name }
}

/// Browses for Android TV Remote services. Callbacks run on the main queue.
public final class Discovery {
    public static let serviceType = "_androidtvremote2._tcp"
    public var onChange: (([DiscoveredTV]) -> Void)?

    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let tvs = results.compactMap { result -> DiscoveredTV? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredTV(name: name, endpoint: result.endpoint)
            }
            let sorted = Array(Set(tvs)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.onChange?(sorted) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Resolves a Bonjour service to an IP address by opening (and dropping) a TCP connection.
    public static func resolveHost(_ endpoint: NWEndpoint, completion: @escaping (String?) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        var done = false
        let finish: (String?) -> Void = { host in
            guard !done else { return }
            done = true
            connection.cancel()
            completion(host)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                    finish(Self.string(for: host))
                } else {
                    finish(nil)
                }
            case .failed, .waiting:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
    }

    static func string(for host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let a):
            return "\(a)".components(separatedBy: "%").first
        case .ipv6(let a):
            return "\(a)"
        case .name(let n, _):
            return n
        @unknown default:
            return nil
        }
    }
}

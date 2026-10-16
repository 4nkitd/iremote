import Foundation

public struct AppDiscoveryScan {
    public enum Action: Equatable {
        case home
        case launch(String)
        case completed([String])
        case unavailable
    }

    private enum Phase { case idle, home, app }
    private var phase = Phase.idle
    private var index = 0
    private var deadline: TimeInterval = 0
    private var matchedSince: TimeInterval?
    private var confirmed: [String] = []
    private var receivedAppReport = false
    private var latest: String?
    private var baseline: String?
    private var reportsAfterLaunch = false
    private let candidates: [KnownApp]

    public var isRunning: Bool { phase != .idle }
    public var current: KnownApp? { isRunning ? candidates[index] : nil }
    public var position: Int { index + 1 }
    public var total: Int { candidates.count }

    public init(candidates: [KnownApp] = KnownLinks.apps) {
        self.candidates = candidates
    }

    public mutating func start(at now: TimeInterval, current: String? = nil) -> Action {
        index = 0
        confirmed = []
        receivedAppReport = false
        latest = current
        baseline = nil
        reportsAfterLaunch = false
        guard !candidates.isEmpty else { phase = .idle; return .completed([]) }
        return prepare(at: now)
    }

    public mutating func receive(_ package: String, at now: TimeInterval) -> Action? {
        guard isRunning else { return nil }
        if !package.isEmpty {
            latest = package
            if phase == .app {
                receivedAppReport = true
                reportsAfterLaunch = true
            }
        }
        // Reports arriving after a phase deadline cannot validate that phase.
        if now >= deadline {
            if phase == .app, package != candidates[index].package { matchedSince = nil }
            return tick(at: now)
        }
        guard phase == .app, !package.isEmpty else { return nil }
        if package == candidates[index].package {
            if matchedSince == nil { matchedSince = now }
        } else {
            matchedSince = nil
        }
        return nil
    }

    public mutating func tick(at now: TimeInterval) -> Action? {
        guard isRunning else { return nil }
        if phase == .app, let matchedSince, now - matchedSince >= 1, matchedSince + 1 <= deadline {
            confirmed.append(candidates[index].package)
            return advance(at: now)
        }
        guard now >= deadline else { return nil }
        if phase == .home {
            phase = .app
            deadline = now + 8
            matchedSince = nil
            baseline = latest
            reportsAfterLaunch = false
            return .launch(candidates[index].link)
        }
        // No fresh report, but the TV still reports the candidate as the foreground app.
        if !reportsAfterLaunch, baseline == candidates[index].package {
            confirmed.append(candidates[index].package)
        }
        return advance(at: now)
    }

    public mutating func cancel() {
        phase = .idle
        matchedSince = nil
    }

    private mutating func prepare(at now: TimeInterval) -> Action {
        phase = .home
        // Home may keep a custom launcher open without producing any app report.
        deadline = now + 1
        matchedSince = nil
        return .home
    }

    private mutating func advance(at now: TimeInterval) -> Action {
        index += 1
        if index == candidates.count {
            cancel()
            return receivedAppReport || !confirmed.isEmpty ? .completed(confirmed) : .unavailable
        }
        return prepare(at: now)
    }
}

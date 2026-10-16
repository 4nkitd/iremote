import XCTest
import AppKit
import SwiftUI
import RemoteCore
@testable import iRemote

final class AppModelTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    @MainActor
    private func makeModel() throws -> (AppModel, UserDefaults) {
        let suite = "iremote-tests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let tvs = [
            PairedTV(name: "Test A", host: "127.0.0.1", certificateSHA256: "test-a"),
            PairedTV(name: "Test B", host: "127.0.0.1", certificateSHA256: "test-b"),
        ]
        defaults.set(try JSONEncoder().encode(tvs), forKey: "pairedTVs")
        defaults.set("Test A", forKey: "selectedTV")
        return (AppModel(defaults: defaults), defaults)
    }

    @MainActor
    private func ready(_ model: AppModel) {
        model.handle(.connected, from: "Test A")
        model.handle(.power(true), from: "Test A")
        model.tab = .apps
    }

    @MainActor
    func testEmptyScanReplacesCatalogAndSurvivesReload() throws {
        let (model, defaults) = try makeModel()
        XCTAssertEqual(model.apps.count, 8)
        XCTAssertFalse(model.appListVerified)
        model.saveDiscoveredApps([])
        let reloaded = AppModel(defaults: defaults)
        XCTAssertTrue(reloaded.apps.isEmpty)
        XCTAssertTrue(reloaded.appListVerified)
    }

    @MainActor
    func testResultsStayWithTheTVAndForgetClearsItsCache() throws {
        let (model, defaults) = try makeModel()
        model.saveDiscoveredApps([KnownLinks.apps[0].package, "unknown.package"])
        XCTAssertEqual(model.apps, [KnownLinks.apps[0]])
        model.select(model.tvs[1])
        XCTAssertFalse(model.appListVerified)
        XCTAssertEqual(model.apps.count, 8)
        model.saveDiscoveredApps([])
        model.select(model.tvs[0])
        XCTAssertEqual(model.apps, [KnownLinks.apps[0]])
        model.forgetSelected()
        let data = try XCTUnwrap(defaults.data(forKey: "discoveredAppsByTV"))
        let cache = try JSONDecoder().decode([String: [String]].self, from: data)
        XCTAssertNil(cache["test-a"])
        XCTAssertEqual(cache["test-b"], [])
    }

    @MainActor
    func testScanNeedsVisibleConfirmationAndNeverStartsOnPowerEvent() throws {
        let (model, _) = try makeModel()
        ready(model)
        XCTAssertFalse(model.isDiscoveringApps)
        model.discoverApps()
        XCTAssertFalse(model.isDiscoveringApps)
        model.requestAppDiscovery()
        XCTAssertTrue(model.showsDiscoveryConfirmation)
        model.discoverApps()
        XCTAssertTrue(model.isDiscoveringApps)
        model.cancelAppDiscovery()
    }

    @MainActor
    func testPowerOffAndUntrustedEventsCancelWithoutChangingSavedApps() throws {
        for event in [RemoteSession.Event.power(false), .untrustedTV, .disconnected("test")] {
            let (model, _) = try makeModel()
            model.saveDiscoveredApps([KnownLinks.apps[1].package])
            ready(model)
            model.requestAppDiscovery()
            model.discoverApps()
            model.handle(event, from: "Test A")
            XCTAssertFalse(model.isDiscoveringApps)
            XCTAssertEqual(model.apps, [KnownLinks.apps[1]])
        }
    }

    @MainActor
    func testNavigationAndPairingCancelAndDiscardPendingMatches() throws {
        let (model, _) = try makeModel()
        ready(model)
        model.requestAppDiscovery()
        model.discoverApps()
        model.handle(.currentApp("com.google.android.apps.tv.launcherx"), from: "Test A")
        model.handle(.currentApp(KnownLinks.apps[0].package), from: "Test A")
        model.tab = .keyboard
        XCTAssertFalse(model.isDiscoveringApps)
        XCTAssertFalse(model.appListVerified)
        model.tab = .apps
        model.requestAppDiscovery()
        model.discoverApps()
        model.beginPairing()
        XCTAssertFalse(model.isDiscoveringApps)
        XCTAssertFalse(model.showsDiscoveryConfirmation)
    }

    @MainActor
    func testNormalTileLaunchDoesNotChangeSavedList() async throws {
        let (model, _) = try makeModel()
        model.saveDiscoveredApps([KnownLinks.apps[0].package, KnownLinks.apps[1].package])
        ready(model)
        model.launch(KnownLinks.apps[1])
        try await Task.sleep(nanoseconds: 8_000_000_000)
        XCTAssertEqual(model.apps, Array(KnownLinks.apps.prefix(2)))
    }

    @MainActor
    func testNoFeedbackDoesNotShowTheUnverifiedCatalogAsResults() throws {
        let (model, defaults) = try makeModel()
        ready(model)
        model.requestAppDiscovery()
        model.discoverApps()
        let now = ProcessInfo.processInfo.systemUptime
        for index in 0..<KnownLinks.apps.count {
            model.advanceAppDiscovery(at: now + Double(index) * 10 + 1.1)
            model.advanceAppDiscovery(at: now + Double(index) * 10 + 9.2)
        }
        XCTAssertEqual(model.appDiscovery, .unavailable)
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertFalse(model.appListVerified)
        XCTAssertNil(defaults.data(forKey: "discoveredAppsByTV"))
    }

    @MainActor
    func testStoppedScanCannotFinishANewScan() async throws {
        let (model, _) = try makeModel()
        ready(model)
        model.requestAppDiscovery()
        model.discoverApps()
        model.handle(.currentApp("com.google.android.apps.tv.launcherx"), from: "Test A")
        model.handle(.currentApp(KnownLinks.apps[0].package), from: "Test A")
        model.cancelAppDiscovery()
        model.requestAppDiscovery()
        model.discoverApps()
        model.handle(.currentApp(KnownLinks.apps[0].package), from: "Test A")
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(model.appDiscovery, .running(app: "YouTube", index: 1, total: 8))
        XCTAssertFalse(model.appListVerified)
        model.cancelAppDiscovery()
    }

    @MainActor
    func testAppsPanelRendersSuggestedConfirmationAndEmptyStates() throws {
        let (model, _) = try makeModel()
        ready(model)
        func render(_ name: String) throws {
            let host = NSHostingView(rootView: PanelView(model: model))
            host.frame = NSRect(origin: .zero, size: Theme.panelSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(host.fittingSize.height, Theme.panelSize.height, accuracy: 1)
            if let directory = ProcessInfo.processInfo.environment["IREMOTE_SNAPSHOT_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
            }
        }
        try render("suggested")
        model.requestAppDiscovery()
        try render("confirmation")
        model.cancelAppDiscovery()
        model.saveDiscoveredApps([])
        try render("empty")
    }
}

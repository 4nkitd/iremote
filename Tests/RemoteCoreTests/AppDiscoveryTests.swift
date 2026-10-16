import XCTest
@testable import RemoteCore

final class AppDiscoveryTests: XCTestCase {
    let home = "com.google.android.apps.tv.launcherx"
    let youtube = KnownLinks.apps[0]
    let netflix = KnownLinks.apps[1]

    func testCustomLauncherWithoutHomeReportStillLaunchesYouTube() {
        var scan = AppDiscoveryScan(candidates: [youtube])
        XCTAssertEqual(scan.start(at: 0), .home)
        XCTAssertNil(scan.receive("com.overdevs.at4k", at: 0.1))
        XCTAssertNil(scan.tick(at: 0.9))
        XCTAssertEqual(scan.tick(at: 1), .launch(youtube.link))
        XCTAssertNil(scan.receive(youtube.package, at: 1.822))
        XCTAssertEqual(scan.tick(at: 2.9), .completed([youtube.package]))
        XCTAssertFalse(scan.isRunning)
    }

    func testAlreadyForegroundAppWithNoFurtherFeedbackConfirms() {
        var scan = AppDiscoveryScan(candidates: [youtube])
        XCTAssertEqual(scan.start(at: 0, current: youtube.package), .home)
        XCTAssertEqual(scan.tick(at: 1), .launch(youtube.link))
        XCTAssertEqual(scan.tick(at: 9.1), .completed([youtube.package]))
    }

    func testAlreadyCurrentAppIsNotConfirmedIfAnotherAppReportsAfterLaunch() {
        var scan = AppDiscoveryScan(candidates: [youtube])
        XCTAssertEqual(scan.start(at: 0, current: youtube.package), .home)
        XCTAssertEqual(scan.tick(at: 1), .launch(youtube.link))
        XCTAssertNil(scan.receive("com.overdevs.at4k", at: 2))
        XCTAssertEqual(scan.tick(at: 9.1), .completed([]))
    }

    func testNoMatchesProducesAnEmptyCompletedResult() {
        var scan = AppDiscoveryScan(candidates: [youtube, netflix])
        XCTAssertEqual(scan.start(at: 0), .home)
        XCTAssertEqual(scan.tick(at: 1), .launch(youtube.link))
        XCTAssertNil(scan.receive("com.android.vending", at: 2))
        XCTAssertEqual(scan.tick(at: 9.1), .home)
        XCTAssertEqual(scan.tick(at: 10.2), .launch(netflix.link))
        XCTAssertNil(scan.receive("com.browser.tv", at: 11))
        XCTAssertEqual(scan.tick(at: 18.3), .completed([]))
    }

    func testTransientMatchFollowedByLauncherIsNotConfirmed() {
        var scan = AppDiscoveryScan(candidates: [netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        XCTAssertNil(scan.receive(netflix.package, at: 2))
        XCTAssertNil(scan.receive(home, at: 2.3))
        XCTAssertNil(scan.tick(at: 3.5))
        XCTAssertEqual(scan.tick(at: 9.1), .completed([]))
    }

    func testSlowLaunchAndRepeatedReportsGetOneConfirmation() {
        var scan = AppDiscoveryScan(candidates: [netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        XCTAssertNil(scan.tick(at: 3))
        XCTAssertNil(scan.receive(netflix.package, at: 6))
        XCTAssertNil(scan.receive(netflix.package, at: 6.5))
        XCTAssertEqual(scan.tick(at: 7.1), .completed([netflix.package]))
        XCTAssertNil(scan.receive(netflix.package, at: 7.2))
    }

    func testLatePreviousAppCannotConfirmNextApp() {
        var scan = AppDiscoveryScan(candidates: [youtube, netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        XCTAssertEqual(scan.tick(at: 9.1), .home)
        XCTAssertNil(scan.receive(youtube.package, at: 9.2))
        XCTAssertEqual(scan.tick(at: 10.2), .launch(netflix.link))
        XCTAssertNil(scan.receive(youtube.package, at: 11))
        XCTAssertEqual(scan.tick(at: 18.3), .completed([]))
    }

    func testLateReportIsFeedbackButCannotConfirmAnApp() {
        var scan = AppDiscoveryScan(candidates: [netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        XCTAssertEqual(scan.receive(netflix.package, at: 9.1), .completed([]))
    }

    func testCancelDiscardsPendingEventsAndRestartRequiresAnotherLaunch() {
        var scan = AppDiscoveryScan(candidates: [netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        _ = scan.receive(netflix.package, at: 2)
        scan.cancel()
        XCTAssertNil(scan.tick(at: 3))
        XCTAssertNil(scan.receive(netflix.package, at: 4))
        XCTAssertEqual(scan.start(at: 5), .home)
        XCTAssertNil(scan.receive(netflix.package, at: 5.1))
        XCTAssertEqual(scan.tick(at: 6), .launch(netflix.link))
        XCTAssertEqual(scan.tick(at: 14.1), .completed([netflix.package]))
    }

    func testMissingLaterFeedbackDoesNotDiscardConfirmedResults() {
        var scan = AppDiscoveryScan(candidates: [youtube, netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        _ = scan.receive(youtube.package, at: 1.2)
        XCTAssertEqual(scan.tick(at: 2.3), .home)
        XCTAssertEqual(scan.tick(at: 3.4), .launch(netflix.link))
        XCTAssertEqual(scan.tick(at: 11.5), .completed([youtube.package]))
    }

    func testLastMomentMatchMustBeStableBeforeDeadline() {
        var scan = AppDiscoveryScan(candidates: [netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        _ = scan.receive(netflix.package, at: 8.9)
        XCTAssertEqual(scan.tick(at: 10.1), .completed([]))
    }

    func testLateMismatchCannotConfirmThePreviousReport() {
        var scan = AppDiscoveryScan(candidates: [netflix])
        _ = scan.start(at: 0)
        _ = scan.tick(at: 1)
        _ = scan.receive(netflix.package, at: 2)
        XCTAssertEqual(scan.receive(home, at: 9.1), .completed([]))
    }
}

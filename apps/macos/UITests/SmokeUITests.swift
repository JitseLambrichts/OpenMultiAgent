import XCTest

/// Real-tmux acceptance run. Skipped unless the environment provides a compiled
/// sidecar and an OMA home whose sessions are backed by live tmux sessions:
///
///   TEST_RUNNER_OMA_SMOKE_SIDECAR=/tmp/oma-smoke/oma-desktop-api \
///   TEST_RUNNER_OMA_SMOKE_HOME=/tmp/oma-smoke \
///   xcodebuild test -scheme OpenMultiAgentUITests -only-testing:OpenMultiAgentUITests/SmokeUITests
///
/// The test drives the UI only; the sandboxed runner cannot reach the tmux
/// socket, so tmux client counts, pane content, and session survival are
/// verified by the shell around it (see scripts/macos-smoke.sh).
@MainActor
final class SmokeUITests: XCTestCase {
    private var sidecar = ""
    private var home = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let sidecar = environment["OMA_SMOKE_SIDECAR"], let home = environment["OMA_SMOKE_HOME"] else {
            throw XCTSkip("Set OMA_SMOKE_SIDECAR and OMA_SMOKE_HOME to run the tmux smoke test")
        }
        self.sidecar = sidecar
        self.home = home
    }

    func testSixTerminalsAttachTypeCloseAndSurviveQuit() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OMA_HOME"] = home
        app.launchEnvironment["OMA_DESKTOP_DEBUG"] = "1"
        app.launchEnvironment["OMA_DESKTOP_DEBUG_LOG"] = home + "/trace.log"
        app.launchEnvironment["OMA_DESKTOP_SIDECAR"] = sidecar
        app.launchEnvironment["OMA_DESKTOP_SIDECAR_ARGS"] = ""
        app.launch()

        let openProject = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open oma-smoke-repo'")).firstMatch
        XCTAssertTrue(openProject.waitForExistence(timeout: 15), app.debugDescription)
        openProject.click()

        let openSession = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open sessie Smoke 2'")).firstMatch
        XCTAssertTrue(openSession.waitForExistence(timeout: 10), app.debugDescription)
        openSession.click()

        let terminals = app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Terminal voor sessie'"))
        XCTAssertTrue(terminals.firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        // Diagnostics: header controls must be reachable next to the hosted NSView.
        let focus = app.buttons["Focus"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 5))
        focus.click()
        let unfocus = app.buttons["Verlaat focus"].firstMatch
        let focusWorked = unfocus.waitForExistence(timeout: 3)
        if focusWorked { unfocus.click() }
        XCTAssertTrue(focusWorked, "Focus button should present the focused cell")

        // Fill the grid through Open in Grid → picker, up to six cells.
        for title in ["Smoke 3", "Smoke 4", "Smoke 5", "Smoke 6", "Smoke A"] {
            let openInGrid = app.buttons["Open in raster"]
            XCTAssertTrue(openInGrid.waitForExistence(timeout: 5), app.debugDescription)
            openInGrid.click()
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open sessie \(title)'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "picker should list \(title)\n\(app.debugDescription)")
            row.click()
            sleep(1)
        }
        sleep(3)
        XCTAssertEqual(terminals.count, 6, "six terminal cells should be attached")
        XCTAssertFalse(app.buttons["Open in raster"].isEnabled, "grid is full at six cells")

        // Type into the first terminal while five others are live.
        terminals.firstMatch.click()
        sleep(1)
        terminals.firstMatch.typeText("echo smoke-typing-ok\n")
        // Hold here so the shell can sample six attached tmux clients.
        sleep(8)

        // Closing one cell ends only that attachment. The last close button is
        // used so a system dialog parked over the first cell cannot block it.
        let closeButtons = app.buttons.matching(identifier: "Sluit terminal").allElementsBoundByIndex
        let close = try XCTUnwrap(closeButtons.last(where: \.isHittable) ?? closeButtons.last)
        close.click()
        sleep(6)
        XCTAssertTrue(app.buttons["Open een sessie in deze lege terminal"].exists, "closing a cell should leave an empty cell")
        XCTAssertEqual(terminals.count, 5, "closing a cell removes exactly one attachment")

        app.terminate()
    }
}

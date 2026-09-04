import XCTest

/// Drives the dashboard → cockpit → session → promotion preview flow against
/// the fixture sidecar. No tmux, Git, or agent CLI is involved.
@MainActor
final class CriticalFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testDashboardCockpitSessionAndPromotionPreview() throws {
        let app = launchWithFixtureSidecar()

        let openProject = app.buttons["Open OpenMultiAgent"]
        XCTAssertTrue(openProject.waitForExistence(timeout: 10), "dashboard card should appear\n\(app.debugDescription)")
        openProject.click()

        XCTAssertTrue(element(app, labelPrefix: "Actief werk").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(element(app, labelPrefix: "Recente beslissingen").exists, app.debugDescription)

        let openSession = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open sessie M4'")).firstMatch
        XCTAssertTrue(openSession.waitForExistence(timeout: 5), app.debugDescription)
        openSession.click()

        XCTAssertTrue(element(app, labelPrefix: "Terminal").waitForExistence(timeout: 5), app.debugDescription)

        let extract = app.buttons["Extract Knowledge"]
        XCTAssertTrue(extract.waitForExistence(timeout: 5), app.debugDescription)
        extract.click()

        XCTAssertTrue(element(app, labelPrefix: "Review Knowledge").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Pas toe"].exists, app.debugDescription)
        app.buttons["Sluit"].click()
    }

    /// Combined accessibility elements expose their text as a label on a group,
    /// so lookups match on label prefix across every element type.
    private func element(_ app: XCUIApplication, labelPrefix: String) -> XCUIElement {
        // Scoped to the main window: a whole-app query also walks the menu bar
        // and times out.
        app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix))
            .firstMatch
    }

    func testRecoveryViewOffersReconnectWhenSidecarIsMissing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OMA_DESKTOP_SIDECAR"] = "/nonexistent/oma-desktop-api"
        app.launch()

        XCTAssertTrue(app.buttons["Verbind opnieuw"].waitForExistence(timeout: 10), app.debugDescription)
    }

    /// The fixture ships inside the test bundle (under ~/Library/Developer):
    /// processes launched by the test runner have no access to user folders
    /// such as Desktop, and reading the checkout would block on a TCC prompt.
    private func launchWithFixtureSidecar() -> XCUIApplication {
        let app = XCUIApplication()
        let fixture = Bundle(for: CriticalFlowUITests.self)
            .url(forResource: "fixture-sidecar", withExtension: "ts")?
            .path ?? "/nonexistent/fixture-sidecar.ts"
        let bun = ["/opt/homebrew/bin/bun", "\(NSHomeDirectory())/.bun/bin/bun", "/usr/local/bin/bun"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
        // Start from the dashboard regardless of what a previous run restored.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OMA_DESKTOP_DEBUG"] = "1"
        app.launchEnvironment["OMA_DESKTOP_DEBUG_LOG"] = "/tmp/oma-ui-fixture-trace.log"
        app.launchEnvironment["FIXTURE_LOG"] = "/tmp/oma-ui-fixture.log"
        app.launchEnvironment["OMA_DESKTOP_SIDECAR"] = bun
        app.launchEnvironment["OMA_DESKTOP_SIDECAR_ARGS"] = ["run", fixture].joined(separator: "\u{1F}")
        app.launch()
        return app
    }
}

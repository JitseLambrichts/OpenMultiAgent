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

    /// Regressietest: een actieve sessie met dode tmux toont de
    /// "Terminalkoppeling gestopt"-kaart, maar de sessie-navigatie (Terug-knop
    /// en tabs) moet zichtbaar én aanklikbaar blijven. Voorheen duwde de
    /// Grid-cel met ongelimiteerde hoogte de header buiten beeld, waardoor de
    /// gebruiker vastzat op een fullscreen exited-kaart.
    func testDeadTmuxKeepsSessionNavigationVisible() throws {
        let app = launchWithFixtureSidecar(extraEnvironment: ["FIXTURE_DEAD_TMUX": "1"])

        let openProject = app.buttons["Open OpenMultiAgent"]
        XCTAssertTrue(openProject.waitForExistence(timeout: 10), "dashboard card should appear\n\(app.debugDescription)")
        openProject.click()

        let openSession = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open sessie M4'")).firstMatch
        XCTAssertTrue(openSession.waitForExistence(timeout: 5), app.debugDescription)
        openSession.click()

        // De attach faalt direct (/bin/false): de exited-kaart verschijnt…
        let reconnect = app.buttons["Verbind opnieuw"]
        XCTAssertTrue(
            reconnect.waitForExistence(timeout: 10),
            "exited-kaart zou moeten verschijnen\n\(app.debugDescription)"
        )

        let back = app.buttons["Terug naar project"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Terug-knop ontbreekt; header buiten beeld?\n\(app.debugDescription)")
        XCTAssertTrue(back.isHittable, "Terug-knop is niet aanklikbaar; header buiten beeld?\n\(app.debugDescription)")

        let transcriptTab = app.buttons["Transcript"]
        XCTAssertTrue(transcriptTab.waitForExistence(timeout: 5), "Tabbladen ontbreken; header buiten beeld?\n\(app.debugDescription)")
        XCTAssertTrue(transcriptTab.isHittable, "Tabblad is niet aanklikbaar; header buiten beeld?\n\(app.debugDescription)")
    }

    func testChangedFileOpensDiffAndEditor() throws {
        let app = launchWithFixtureSidecar()

        let openProject = app.buttons["Open OpenMultiAgent"]
        XCTAssertTrue(openProject.waitForExistence(timeout: 10), app.debugDescription)
        openProject.click()

        let changed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'README.md'")).firstMatch
        XCTAssertTrue(changed.waitForExistence(timeout: 5), "Gewijzigd bestand zou klikbaar moeten zijn\n\(app.debugDescription)")
        changed.click()

        let openEditor = app.buttons["Open in editor"]
        XCTAssertTrue(openEditor.waitForExistence(timeout: 5), "Diff-sheet ontbreekt\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'changed'")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        openEditor.click()

        let codeTab = app.buttons["Code"]
        XCTAssertTrue(codeTab.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(codeTab.isHittable)
        let readme = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'README.md' OR value CONTAINS 'README.md'")).firstMatch
        XCTAssertTrue(readme.waitForExistence(timeout: 5), "Editor zou README.md moeten tonen\n\(app.debugDescription)")
        let content = app.textViews.matching(NSPredicate(format: "value CONTAINS '# OpenMultiAgent'")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5), "Editor zou de bestandsinhoud moeten tonen\n\(app.debugDescription)")
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
    private func launchWithFixtureSidecar(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
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
        for (key, value) in extraEnvironment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }
}

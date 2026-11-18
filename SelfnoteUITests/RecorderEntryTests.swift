import XCTest

final class RecorderEntryTests: XCTestCase {
    @MainActor
    func testLaunchAndFindBothButtonSetups() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["startRecording"].waitForExistence(timeout: 15))
        let setup = app.buttons["recordingSetup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 8))
        setup.tap()

        XCTAssertTrue(app.navigationBars["Recording setup"].waitForExistence(timeout: 8))
        for identifier in ["setupBackTap", "setupActionButton"] {
            let instructions = app.staticTexts[identifier]
            for _ in 0..<3 where !instructions.exists { app.swipeUp() }
            XCTAssertTrue(instructions.exists)
        }
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["startRecording"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testDeniedMicrophoneKeepsRecorderIdle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        defer { app.resetAuthorizationStatus(for: .microphone) }
        app.launch()
        let record = app.buttons["startRecording"]
        XCTAssertTrue(record.waitForExistence(timeout: 15))
        record.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow"])).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 10))
        deny.tap()
        let alert = app.alerts["Recording needs attention"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["OK"].tap()
        XCTAssertTrue(record.isEnabled)
        XCTAssertFalse(app.buttons["stopRecording"].exists)
    }
}

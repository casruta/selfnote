import XCTest

final class CaptureFlowTests: XCTestCase {
    @MainActor
    func testStartStopPlayAndReopenOneRecording() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        defer { app.resetAuthorizationStatus(for: .microphone) }
        app.launch()

        let start = app.buttons["startRecording"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "noteRow-"))
        let existingIDs = Set(rows.allElementsBoundByIndex.map(\.identifier))
        start.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = system.alerts.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 12))
        allow.tap()

        let stop = app.buttons["stopRecording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15), app.debugDescription)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Recording in progress"
        image.lifetime = .keepAlways
        add(image)
        // Use real elapsed audio, long enough to observe playback in the UI.
        try await Task.sleep(for: .seconds(3))
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(12)
        var addedIDs = Set<String>()
        repeat {
            addedIDs = Set(rows.allElementsBoundByIndex.map(\.identifier)).subtracting(existingIDs)
            if !addedIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(200))
        } while clock.now < deadline
        XCTAssertEqual(addedIDs.count, 1, app.debugDescription)
        let id = try XCTUnwrap(addedIDs.first)

        app.terminate()
        app.launch()
        let saved = rows.matching(identifier: id).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)), existingIDs.union([id]))
        saved.tap()
        let play = app.buttons["Play recording"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        play.tap()
        XCTAssertTrue(app.buttons["Stop playback"].waitForExistence(timeout: 5), app.debugDescription)

        // Remove only the note created in this test.
        app.buttons["Note actions"].tap()
        app.buttons["Delete note"].tap()
        app.buttons["Delete note and recording"].tap()
        XCTAssertTrue(app.navigationBars["Notebook"].waitForExistence(timeout: 8))
        XCTAssertTrue(saved.waitForNonExistence(timeout: 8))
    }
}

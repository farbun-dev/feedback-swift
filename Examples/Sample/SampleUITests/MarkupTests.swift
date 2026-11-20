import XCTest

/// Marks the screenshot the way a person would, and keeps a picture of the
/// result in the test's output folder (`FEEDBACK_SCREENSHOTS`).
final class MarkupTests: XCTestCase {
    func testTapAndDragAddMarksWithComments() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-showFeedback"]
        app.launch()

        let shot = app.otherElements["feedback-screenshot"]
        XCTAssertTrue(shot.waitForExistence(timeout: 10))

        shot.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)).tap()
        let first = app.textFields["What about this?"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.typeText("This total should be 16.50")

        let start = shot.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2))
        let end = shot.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.32))
        start.press(forDuration: 0.1, thenDragTo: end)
        // Its comment field scrolls into view above the keyboard, focused.
        XCTAssertTrue(app.buttons["Remove mark 2"].waitForExistence(timeout: 5))
        sleep(1)
        app.typeText("Title is too big")
        let typed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", "Title is too big"))
        XCTAssertTrue(typed.firstMatch.waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["Remove mark 2"].exists)
        save("markup.png")
    }

    func testATwoFingerTripleTapOpensTheSheet() {
        let app = XCUIApplication()
        app.launch()
        let window = app.collectionViews.firstMatch
        XCTAssertTrue(app.buttons["Send feedback"].waitForExistence(timeout: 10))

        // One finger is the app's: nothing opens.
        window.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertFalse(app.otherElements["feedback-screenshot"].waitForExistence(timeout: 2))

        window.tap(withNumberOfTaps: 3, numberOfTouches: 2)
        XCTAssertTrue(app.otherElements["feedback-screenshot"].waitForExistence(timeout: 5))
        save("gesture.png")
    }

    private func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["FEEDBACK_SCREENSHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appending(path: name))
    }
}

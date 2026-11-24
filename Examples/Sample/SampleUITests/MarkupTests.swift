import XCTest

/// Pins comments the way a person would, and keeps pictures of the orb, a
/// pin with its bubble, and the review sheet in the test's output folder
/// (`FEEDBACK_SCREENSHOTS`).
final class MarkupTests: XCTestCase {
    func testPinsOnTwoScreensAreReviewedTogether() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-showFeedback"]
        app.launch()

        let orb = app.buttons["feedback-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 10))
        save("orb.png")

        // A double tap on the total pins a comment there.
        app.staticTexts["Total, €0.00"].doubleTap()
        let bubble = app.textViews["feedback-pin-comment"].firstMatch
        XCTAssertTrue(waitForComment(app), "the bubble opens")
        XCTAssertTrue(app.buttons["feedback-pin-1"].exists)
        app.typeText("Total should be €16.50")
        save("pin.png")
        app.buttons["Done"].tap()
        XCTAssertFalse(bubble.exists)
        XCTAssertEqual(orb.value as? String, "1 pin")

        // The app still works: on to Payment, where pin 1 is not shown.
        app.buttons["Payment"].tap()
        XCTAssertTrue(app.navigationBars["Payment"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feedback-pin-1"].waitForExistence(timeout: 1))
        app.staticTexts["Expiry, 04/29"].doubleTap()
        XCTAssertTrue(waitForComment(app))
        app.typeText("Pay button shows €0.00")
        app.buttons["Done"].tap()

        // An empty pin goes when its bubble closes.
        app.buttons["Pay €0.00"].doubleTap()
        XCTAssertTrue(waitForComment(app))
        XCTAssertTrue(app.buttons["feedback-pin-3"].exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["feedback-pin-3"].waitForExistence(timeout: 1))
        XCTAssertEqual(orb.value as? String, "2 pins")

        // Back on Checkout, its pin is there again and Payment's is not.
        // The back button, which iOS 27 does not label "Checkout".
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["feedback-pin-1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feedback-pin-2"].exists)

        // Dragged across, the orb snaps to the left side.
        let width = app.windows.firstMatch.frame.width
        orb.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        sleep(1)
        XCTAssertLessThan(orb.frame.midX, width / 4)
        save("orb-left.png")

        // The orb opens the review: one screenshot per screen.
        orb.tap()
        XCTAssertTrue(app.buttons["feedback-comment-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.otherElements.matching(identifier: "feedback-screenshot").count, 2)
        XCTAssertTrue(app.staticTexts["Anything else"].exists || app.staticTexts["ANYTHING ELSE"].exists)
        sleep(1)
        save("review.png")

        // A comment takes you back to it.
        app.buttons["feedback-comment-1"].tap()
        XCTAssertTrue(waitForComment(app))
        XCTAssertEqual(bubbleText(app), "Total should be €16.50")
        app.buttons["Done"].tap()

        // Discarding puts the orb away, with every pin.
        orb.tap()
        XCTAssertTrue(app.buttons["feedback-comment-1"].waitForExistence(timeout: 5))
        // The form builds its rows as they scroll into view.
        let discard = app.buttons["Discard"].firstMatch
        for _ in 0..<5 where !(discard.exists && discard.isHittable) { app.swipeUp() }
        discard.tap()
        let confirm = app.sheets.buttons["Discard"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(orb.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["feedback-pin-1"].exists)
    }

    func testAPinMovesWithTheListItIsOn() {
        let app = XCUIApplication()
        app.launchArguments = ["-showFeedback"]
        app.launch()
        let orb = app.buttons["feedback-orb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 10))

        let total = app.staticTexts["Total, €0.00"]
        total.doubleTap()
        XCTAssertTrue(waitForComment(app))
        app.typeText("Total should be €16.50")
        app.buttons["Done"].tap()
        let pin = app.buttons["feedback-pin-1"]
        XCTAssertEqual(pin.frame.midY, total.frame.midY, accuracy: 2)

        // Scrolled a little, the pin stays on the total.
        let start = total.frame.midY
        drag(app, from: 0.7, to: 0.6)
        XCTAssertLessThan(total.frame.midY, start - 60, "the list scrolled")
        XCTAssertEqual(pin.frame.midY, total.frame.midY, accuracy: 2)
        save("pin-scrolled.png")

        // Scrolled under the bar, the pin is hidden.
        drag(app, from: 0.8, to: 0.3)
        XCTAssertTrue(pin.waitForNonExistence(timeout: 2))

        // Opened again from the review, the list scrolls back to it.
        orb.tap()
        XCTAssertTrue(app.buttons["feedback-comment-1"].waitForExistence(timeout: 5))
        app.buttons["feedback-comment-1"].tap()
        XCTAssertTrue(waitForComment(app))
        sleep(1)
        XCTAssertGreaterThan(total.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertEqual(pin.frame.midY, total.frame.midY, accuracy: 2)
        save("pin-revealed.png")
    }

    func testADoubleTapOnSomethingTappablePinsItWithoutPressingIt() {
        let app = XCUIApplication()
        app.launchArguments = ["-showFeedback"]
        app.launch()
        XCTAssertTrue(app.buttons["feedback-orb"].waitForExistence(timeout: 10))

        app.buttons["Payment"].doubleTap()
        XCTAssertTrue(waitForComment(app), "the bubble opens")
        XCTAssertFalse(app.navigationBars["Payment"].exists, "the link is not followed")
        app.buttons["Done"].tap()

        // A single tap is still the app's, once the double tap gives up.
        app.buttons["Payment"].tap()
        XCTAssertTrue(app.navigationBars["Payment"].waitForExistence(timeout: 5))
    }

    func testATwoFingerTripleTapShowsTheOrb() {
        let app = XCUIApplication()
        app.launch()
        let window = app.collectionViews.firstMatch
        XCTAssertTrue(app.buttons["Send feedback"].waitForExistence(timeout: 10))

        // One finger is the app's: nothing shows.
        window.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        XCTAssertFalse(app.buttons["feedback-orb"].waitForExistence(timeout: 2))

        window.tap(withNumberOfTaps: 3, numberOfTouches: 2)
        XCTAssertTrue(app.buttons["feedback-orb"].waitForExistence(timeout: 5))
        save("gesture.png")
    }

    /// Whether a pin's comment bubble is open.
    private func waitForComment(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["feedback-pin-comment"].waitForExistence(timeout: 5)
    }

    /// Scrolls slowly enough that the list stops where the finger lifts,
    /// away from the orb on the right. `from` and `to` are fractions of the
    /// window's height.
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: from)).press(
            forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: to)),
            withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
    }

    private func bubbleText(_ app: XCUIApplication) -> String? {
        app.descendants(matching: .any)["feedback-pin-comment"].firstMatch.value as? String
    }

    private func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo.environment["FEEDBACK_SCREENSHOTS"] else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appending(path: name))
    }
}

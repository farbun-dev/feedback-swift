import Foundation
import Testing

@testable import FeedbackKit

/// Sends one item to a running Feedback server, when one is given:
/// FEEDBACK_E2E_URL, FEEDBACK_E2E_KEY and FEEDBACK_E2E_TOKEN (a macOS or iOS
/// sign-in's token for that app). Skipped otherwise.
struct MemoryTokens: TokenStore {
    let token: String
    func read(_ account: String) -> String? { token }
    func write(_ token: String, _ account: String) {}
    func delete(_ account: String) {}
}

let e2e = ProcessInfo.processInfo.environment

@MainActor
@Test(.enabled(if: e2e["FEEDBACK_E2E_URL"] != nil))
func anItemReachesTheServer() async throws {
    let session = Session(
        api: API(baseURL: URL(string: e2e["FEEDBACK_E2E_URL"]!)!, appKey: e2e["FEEDBACK_E2E_KEY"]!),
        redirectURI: "x:/y", commit: "abc1234",
        build: BuildInfo(appVersion: "1.0", buildNumber: "7", bundleID: "dev.farbun.feedback.sample"),
        tokens: MemoryTokens(token: e2e["FEEDBACK_E2E_TOKEN"]!), defaults: .standard,
        outboxDirectory: temporaryDirectory())

    await session.refreshAccount()
    guard case .signedIn(let person) = session.account else {
        Issue.record("not signed in: \(session.account)")
        return
    }
    #expect(person.githubLogin == "octo-example")

    var draft = Draft(environment: ["os": "macOS test"])
    draft.pin(
        CGPoint(x: 50, y: 25), on: picture(CGSize(width: 100, height: 50)),
        key: ScreenKey(owner: nil, name: "Checkout"), screen: "Checkout", source: nil)
    draft.pin(
        CGPoint(x: 10, y: 10), on: picture(CGSize(width: 100, height: 50), red: 0),
        key: ScreenKey(owner: nil, name: "Payment"), screen: "Payment", source: nil)
    draft.pins[0].comment = "On checkout"
    draft.pins[1].comment = "On payment"
    draft.overall = "Whole thing"

    let outcome = await session.send(draft)

    guard case .sent(let saved) = outcome else {
        Issue.record("not sent: \(outcome)")
        return
    }
    #expect(saved.url?.absoluteString.hasSuffix("/feedback/\(saved.id)/") == true)
    print("E2E_ITEM \(saved.id)")
}

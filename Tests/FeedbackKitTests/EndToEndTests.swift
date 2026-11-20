import CoreGraphics
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

    let context = CGContext(
        data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    var draft = Draft(
        screenshot: Screenshot(image: context.makeImage()!, pointSize: CGSize(width: 100, height: 50)),
        screen: "Checkout", environment: ["os": "macOS test"])
    draft.marks = [
        .init(region: .init(x: 0.5, y: 0.5, width: 0, height: 0), comment: "Point"),
        .init(region: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.2), comment: "Area"),
    ]
    draft.overall = "Whole screen"

    let outcome = await session.send(draft)

    guard case .sent(let saved) = outcome else {
        Issue.record("not sent: \(outcome)")
        return
    }
    #expect(saved.url?.absoluteString.hasSuffix("/feedback/\(saved.id)/") == true)
    print("E2E_ITEM \(saved.id)")
}

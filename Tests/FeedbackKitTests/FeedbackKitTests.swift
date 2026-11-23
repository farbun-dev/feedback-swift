import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import FeedbackKit

/// Answers requests with what a test queues, and records them.
final class Stub: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var answers: [Answer] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var offline = false
    static let lock = NSLock()

    static func reset() {
        lock.withLock {
            answers = []
            requests = []
            offline = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            recorded.httpBody = data
        }
        let (answer, offline) = Self.lock.withLock { () -> (Answer?, Bool) in
            Self.requests.append(recorded)
            return (Self.answers.isEmpty ? nil : Self.answers.removeFirst(), Self.offline)
        }
        if offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let reply = answer ?? Answer(status: 500, body: "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: reply.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func stubbedAPI() -> API {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [Stub.self]
    return API(
        baseURL: URL(string: "https://feedback.example.com")!, appKey: "pk_test",
        session: URLSession(configuration: configuration))
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "feedback-tests-\(UUID().uuidString)")
}

let payload = FeedbackPayload(
    screen: "Cart", appVersion: "2.1", buildNumber: "45", commit: nil,
    environment: ["os": "iOS 27.0"],
    annotations: [
        .init(
            comment: "Cut off", screenshot: "screen.png",
            region: .init(x: 0.1, y: 0.2, width: 0, height: 0))
    ])
let screenFile = API.File(name: "screen.png", contentType: "image/png", data: Data([1, 2, 3]))

// The request format, version 1

@Test func thePayloadUsesTheServersFieldNames() throws {
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]

    #expect(json["app_version"] as? String == "2.1")
    #expect(json["build_number"] as? String == "45")
    #expect(json["screen"] as? String == "Cart")
    // Left out when unknown, never sent as null.
    #expect(json["commit"] == nil)
    // The platform comes from the sign-in, so it is never sent.
    #expect(json["platform"] == nil)
    let annotation = (json["annotations"] as! [[String: Any]])[0]
    #expect(annotation["screenshot"] as? String == "screen.png")
    let region = annotation["region"] as! [String: Double]
    #expect(region == ["x": 0.1, "y": 0.2, "width": 0, "height": 0])
}

/// A picture of `size` points at a scale of 2, filled with one colour.
func picture(_ size: CGSize = CGSize(width: 100, height: 200), red: CGFloat = 1) -> Screenshot {
    let context = CGContext(
        data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: red, green: 0.5, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
    return Screenshot(image: context.makeImage()!, pointSize: size)
}

final class Owner {}

@Test func pinsOnAnUnchangedScreenShareItsScreenshot() {
    let checkout = ScreenKey(owner: nil, name: "Checkout")
    var draft = Draft(environment: [:])

    draft.pin(CGPoint(x: 10, y: 20), on: picture(), key: checkout, screen: "Checkout", source: nil)
    draft.pin(CGPoint(x: 50, y: 50), on: picture(), key: checkout, screen: "Checkout", source: nil)
    // The same screen, changed since: a screenshot of its own.
    draft.pin(CGPoint(x: 5, y: 5), on: picture(red: 0), key: checkout, screen: "Checkout", source: nil)
    // Another screen that happens to look the same: never shared.
    draft.pin(
        CGPoint(x: 5, y: 5), on: picture(), key: ScreenKey(owner: nil, name: "Payment"),
        screen: "Payment", source: nil)

    #expect(draft.shots.count == 3)
    #expect(draft.pins[0].shot == draft.pins[1].shot)
    #expect(draft.pins[1].shot != draft.pins[2].shot)
    #expect(draft.pins[0].point == .init(x: 0.1, y: 0.1, width: 0, height: 0))
}

@Test func eachCommentNamesItsScreensFileAndOnlyUsedFilesAreSent() throws {
    var draft = Draft(environment: [:])
    let checkout = ScreenKey(owner: nil, name: "Checkout")
    let payment = ScreenKey(owner: nil, name: "Payment")
    draft.pin(CGPoint(x: 10, y: 20), on: picture(), key: checkout, screen: "Checkout", source: "A.swift:3")
    // Pinned, but without a comment: its screenshot is not sent.
    draft.pin(CGPoint(x: 10, y: 20), on: picture(red: 0.2), key: checkout, screen: "Checkout", source: nil)
    draft.pin(CGPoint(x: 50, y: 100), on: picture(), key: payment, screen: "Payment", source: nil)
    draft.pins[0].comment = "  Total is wrong "
    draft.pins[1].comment = "   "
    draft.pins[2].comment = "Card cut off"
    draft.overall = "Slow overall"

    let (payload, files) = draft.request(build: BuildInfo(), commit: nil)

    #expect(files.map(\.name) == ["screen-1.png", "screen-2.png"])
    #expect(payload.annotations.map(\.comment) == ["Total is wrong", "Card cut off", "Slow overall"])
    #expect(payload.annotations.map(\.screenshot) == ["screen-1.png", "screen-2.png", nil])
    #expect(payload.annotations[1].region == .init(x: 0.5, y: 0.5, width: 0, height: 0))
    #expect(payload.annotations[0].target?["screen_source"] == "A.swift:3")
    #expect(payload.annotations[1].target?["screen"] == "Payment")
    #expect(payload.annotations[2].region == nil)
    #expect(payload.screen == "Checkout")
}

@Test func manyScreenshotsAreScaledToFitTheServersPixelLimit() throws {
    var draft = Draft(environment: [:])
    for index in 0..<3 {
        draft.pin(
            CGPoint(x: 1, y: 1), on: picture(), key: ScreenKey(owner: nil, name: "\(index)"),
            screen: nil, source: nil)
        draft.pins[index].comment = "Comment \(index)"
    }
    // 3 × 200 × 400 = 240,000 pixels, against a limit of 60,000: half as wide.
    let (_, files) = draft.request(build: BuildInfo(), commit: nil, maxPixels: 60_000)

    for file in files {
        let source = try #require(CGImageSourceCreateWithData(file.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 100 && image.height == 200)
    }
    #expect(files.count == 3)
}

@Test func aScreenMatchesItsOwnerAndByNameOnceTheOwnerIsGone() {
    var owner: Owner? = Owner()
    let other = Owner()
    let key = ScreenKey(owner: owner, name: "Checkout")

    #expect(key.matches(ScreenKey(owner: owner, name: "Checkout")))
    #expect(!key.matches(ScreenKey(owner: other, name: "Payment")))
    // Pushed over by an unnamed screen: not this one.
    #expect(!key.matches(ScreenKey(owner: other, name: nil)))
    owner = nil
    // Went back and came again: a new view controller, the same name.
    #expect(key.matches(ScreenKey(owner: other, name: "Checkout")))
    #expect(!ScreenKey(owner: nil, name: nil).matches(ScreenKey(owner: other, name: "Checkout")))
}

@MainActor
@Test func anEmptyPinGoesWhenItsBubbleClosesAndCannotBeSent() {
    let review = Review(draft: Draft(environment: [:]))
    let key = ScreenKey(owner: nil, name: "Checkout")
    review.pin(at: CGPoint(x: 10, y: 10), on: picture(), key: key, screen: nil, source: nil)
    #expect(!review.draft.canSend)
    review.closeBubble()
    #expect(review.draft.pins.isEmpty && review.draft.shots.isEmpty)

    review.pin(at: CGPoint(x: 10, y: 10), on: picture(), key: key, screen: nil, source: nil)
    review.comment(of: review.open!).wrappedValue = "Kept"
    review.closeBubble()
    #expect(review.draft.pins.map(\.comment) == ["Kept"])
    #expect(review.open == nil)
}

@Test func atMostNineteenPinsLeaveRoomForTheOverallComment() {
    var draft = Draft(environment: [:])
    for _ in 0..<25 {
        draft.pin(CGPoint(x: 1, y: 1), on: picture(), key: ScreenKey(owner: nil, name: nil), screen: nil, source: nil)
    }
    #expect(draft.pins.count == 19)
}

@Test func aRegionIsAFractionOfThePictureClampedToIt() {
    let size = CGSize(width: 400, height: 200)

    let region = Region(CGRect(x: 300, y: 150, width: 200, height: -100), in: size)

    // A drag up and to the right: standardised, then cut at the edge.
    #expect(region == .init(x: 0.75, y: 0.25, width: 0.25, height: 0.5))
    #expect(Region(CGRect(x: 100, y: 50, width: 0, height: 0), in: size).isPoint)
    #expect(region.rect(in: CGSize(width: 800, height: 400)) == CGRect(x: 600, y: 100, width: 200, height: 200))
}

@Test func theMultipartBodyHasThePayloadAndEachFile() {
    let body = String(
        decoding: API.multipart(payload: Data("{}".utf8), files: [screenFile], boundary: "B"),
        as: UTF8.self)

    #expect(body.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"payload\"\r\n"))
    #expect(body.contains("name=\"files\"; filename=\"screen.png\"\r\nContent-Type: image/png\r\n"))
    #expect(body.hasSuffix("--B--\r\n"))
}

// Signing in

@Test func theChallengeIsTheVerifiersSHA256() {
    let attempt = PKCE()
    let digest = Data(SHA256.hash(data: Data(attempt.verifier.utf8)))

    #expect(attempt.challenge == PKCE.base64URL(digest))
    #expect(!attempt.challenge.contains("="))
    #expect(attempt.verifier.count >= 43)
    #expect(PKCE().state != attempt.state)
}

@Test func theCodeIsTakenOnlyFromAnAnswerToThisAttempt() throws {
    let good = URL(string: "com.example.shop:/feedback?code=abc&state=s1")!
    #expect(try code(from: good, state: "s1") == "abc")

    #expect(throws: SignInError.self) {
        try code(from: URL(string: "com.example.shop:/feedback?code=abc&state=other")!, state: "s1")
    }
    #expect(throws: SignInError.refused("Not on the list")) {
        try code(
            from: URL(
                string: "com.example.shop:/feedback?error=access_denied&error_description=Not%20on%20the%20list&state=s1")!,
            state: "s1")
    }
}

@Test func theAuthorizeAddressCarriesTheNativeClient() {
    let url = stubbedAPI().authorizeURL(
        clientID: "pk_test.ios", redirectURI: "com.example.shop:/feedback", challenge: "c", state: "s")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })

    #expect(url.path() == "/auth/github/authorize")
    #expect(query["client_id"] == "pk_test.ios")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["redirect_uri"] == "com.example.shop:/feedback")
}

@Suite(.serialized) struct Network {
    init() { Stub.reset() }

    @Test func theTokenExchangeIsAFormThatKeepsPlusSigns() async throws {
        Stub.answers = [.init(status: 200, body: #"{"access_token":"tok","expires_in":2592000}"#)]

        let token = try await stubbedAPI().exchange(
            code: "a+b", verifier: "v", clientID: "pk_test.ios", redirectURI: "x:/y")

        #expect(token.accessToken == "tok")
        let sent = String(decoding: Stub.requests[0].httpBody!, as: UTF8.self)
        #expect(sent.contains("code=a%2Bb"))
        #expect(sent.contains("grant_type=authorization_code"))
    }

    @Test func signingOutNeverEndsEverySession() async throws {
        Stub.answers = [.init(status: 204, body: "")]

        await stubbedAPI().logout(token: "tok")

        let request = Stub.requests[0]
        #expect(request.url?.path() == "/auth/logout")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        // No body at all: a scope of "all" would end dashboard sessions too.
        #expect(request.httpBody == nil || request.httpBody!.isEmpty)
    }

    // The outbox

    @Test func anItemIsSentWithItsTokenAndKeyAndThenRemoved() async throws {
        Stub.answers = [
            .init(status: 201, body: #"{"id":"i1","url":"https://feedback.example.com/feedback/i1/"}"#)
        ]
        let outbox = Outbox(directory: temporaryDirectory(), api: stubbedAPI())
        let id = try await outbox.add(payload, files: [screenFile])
        let key = await outbox.items()[0].idempotencyKey

        let outcome = await outbox.send(id, token: "tok")

        #expect(
            outcome
                == .sent(.init(id: "i1", url: URL(string: "https://feedback.example.com/feedback/i1/"))))
        let request = Stub.requests[0]
        #expect(request.url?.path() == "/sdk/v1/apps/pk_test/feedback")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(await outbox.items().isEmpty)
    }

    @Test func offlineItemIsKeptAndResentWithTheSameKey() async throws {
        Stub.offline = true
        let outbox = Outbox(directory: temporaryDirectory(), api: stubbedAPI())
        let id = try await outbox.add(payload, files: [screenFile])
        let start = Date(timeIntervalSince1970: 1_000_000)

        guard case .waiting = await outbox.send(id, token: "tok", now: start) else {
            Issue.record("expected the item to wait")
            return
        }
        let kept = await outbox.items()
        #expect(kept.count == 1)
        #expect(kept[0].nextAttempt == start.addingTimeInterval(30))
        // Not due yet: nothing is sent.
        #expect(await outbox.flush(token: "tok", now: start.addingTimeInterval(10)).isEmpty)

        Stub.offline = false
        Stub.answers = [.init(status: 200, body: #"{"id":"i1","url":null}"#)]
        let outcomes = await outbox.flush(token: "tok", now: start.addingTimeInterval(31))

        #expect(outcomes[id] == .sent(.init(id: "i1", url: nil)))
        let keys = Stub.requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    @Test func aRateLimitWaitsAsLongAsTheServerSays() async throws {
        Stub.answers = [.init(status: 429, body: #"{"detail":"slow"}"#, headers: ["Retry-After": "900"])]
        let outbox = Outbox(directory: temporaryDirectory(), api: stubbedAPI())
        let id = try await outbox.add(payload, files: [])
        let now = Date(timeIntervalSince1970: 1_000_000)

        _ = await outbox.send(id, token: "tok", now: now)

        #expect(await outbox.items()[0].nextAttempt == now.addingTimeInterval(900))
    }

    @Test func aRefusalIsDroppedAndASignedOutItemIsKept() async throws {
        Stub.answers = [
            .init(status: 422, body: #"{"detail":"Bad region"}"#),
            .init(status: 401, body: #"{"detail":"signed_out"}"#),
        ]
        let outbox = Outbox(directory: temporaryDirectory(), api: stubbedAPI())
        let refused = try await outbox.add(payload, files: [])
        let kept = try await outbox.add(payload, files: [])

        #expect(await outbox.send(refused, token: "tok") == .refused("Bad region"))
        #expect(await outbox.send(kept, token: "tok") == .signedOut)
        #expect(await outbox.items().map(\.id) == [kept])
    }
}

// Screenshots

@Test func maskedAreasArePaintedOver() throws {
    let context = CGContext(
        data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
    let red = context.makeImage()!

    // At a scale of 2: the top-left 5 × 2.5 points, 10 × 5 pixels.
    let masked = try #require(
        Capture.blank(
            [CGRect(x: 0, y: 0, width: 5, height: 2.5)], in: red,
            pointSize: CGSize(width: 10, height: 5)))

    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let data = masked.dataProvider!.data! as Data
        let offset = y * masked.bytesPerRow + x * 4
        return Array(data[offset..<offset + 3])
    }
    // Rows count from the top in the image's memory.
    #expect(pixel(2, 2) == [128, 128, 128])
    #expect(pixel(15, 2) == [255, 0, 0])
    #expect(pixel(2, 8) == [255, 0, 0])
}

@Test func onlyAnAppsOwnFeedbackLinkShowsTheOrb() {
    #expect(Feedback.isFeedbackLink(URL(string: "duck://feedback")!))
    #expect(Feedback.isFeedbackLink(URL(string: "com.example.shop://feedback/")!))
    #expect(!Feedback.isFeedbackLink(URL(string: "https://example.com/feedback")!))
    #expect(!Feedback.isFeedbackLink(URL(string: "https://feedback/")!))
    #expect(!Feedback.isFeedbackLink(URL(string: "duck://pair/feedback")!))
    #expect(!Feedback.isFeedbackLink(URL(string: "duck://feedback/settings")!))
}

#if os(macOS)
    import AppKit

    @MainActor
    @Test func aMaskGreysOutOnlyItsOwnWindow() {
        let first = NSWindow()
        let second = NSWindow()
        let id = UUID()
        Masks.registered[id] = (ObjectIdentifier(first), CGRect(x: 1, y: 2, width: 3, height: 4))
        defer { Masks.registered[id] = nil }

        #expect(Masks.frames(in: first) == [CGRect(x: 1, y: 2, width: 3, height: 4)])
        #expect(Masks.frames(in: second).isEmpty)
    }
#endif

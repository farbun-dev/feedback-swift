import CoreGraphics
import CryptoKit
import Foundation
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

@Test func aDraftSendsEachMarkWithTextThenTheOverallComment() {
    var draft = Draft(screenshot: nil, screen: "Cart", environment: [:])
    draft.marks = [
        .init(region: .init(x: 0, y: 0, width: 0.5, height: 0.5), comment: "  First  "),
        .init(region: .init(x: 0.5, y: 0.5, width: 0, height: 0), comment: "   "),
    ]
    draft.overall = "Slow overall"

    let comments = draft.annotations

    #expect(comments.map(\.comment) == ["First", "Slow overall"])
    #expect(comments[0].region == .init(x: 0, y: 0, width: 0.5, height: 0.5))
    #expect(comments[1].region == nil)
    // Without a screenshot, nothing names one.
    #expect(comments.allSatisfy { $0.screenshot == nil })
}

@Test func anEmptyDraftCannotBeSent() {
    var draft = Draft(screenshot: nil, screen: nil, environment: [:])
    draft.marks = [.init(region: .init(x: 0, y: 0, width: 0, height: 0))]
    #expect(!draft.canSend)
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

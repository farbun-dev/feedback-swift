import Foundation

/// The service's SDK endpoints, as described in the service's README.
///
/// Every call carries the bearer token only; the SDK never uses cookies.
struct API: Sendable {
    let baseURL: URL
    let appKey: String
    var session: URLSession = .shared

    struct Person: Codable, Equatable, Sendable {
        var name: String
        var githubLogin: String
        var avatarURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case githubLogin = "github_login"
            case avatarURL = "avatar_url"
        }
    }

    struct State: Codable, Equatable, Sendable {
        /// `signed_out`, `signed_in` or `no_access`.
        var state: String
        var user: Person?
        var appName: String?

        enum CodingKeys: String, CodingKey {
            case state, user
            case appName = "app_name"
        }
    }

    struct Token: Codable, Sendable {
        var accessToken: String
        var expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    struct Saved: Codable, Equatable, Sendable {
        var id: String
        /// The item's page in the inbox.
        var url: URL?
    }

    enum Failure: Error, Equatable, Sendable {
        /// Not signed in, or the sign-in ended: sign in, then try again.
        case signedOut
        /// Refused for good, such as an invalid request or an archived app.
        case refused(status: Int, detail: String)
        /// Worth sending again later: no network, a server error, or a rate limit.
        case retry(after: TimeInterval?, reason: String)
    }

    func url(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    // Signing in

    func authorizeURL(clientID: String, redirectURI: String, challenge: String, state: String)
        -> URL
    {
        var components = URLComponents(
            url: url("auth/github/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return components.url!
    }

    func exchange(code: String, verifier: String, clientID: String, redirectURI: String)
        async throws -> Token
    {
        var request = URLRequest(url: url("auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_verifier", value: verifier),
        ]
        // URLComponents leaves "+" alone, which a form would read as a space.
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw Failure.refused(status: response.statusCode, detail: detail(of: data))
        }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    func state(token: String?) async throws -> State {
        var request = URLRequest(url: url("sdk/v1/apps/\(appKey)/state"))
        authorize(&request, token)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw failure(response, data)
        }
        return try JSONDecoder().decode(State.self, from: data)
    }

    /// Ends this sign-in and nothing else.
    ///
    /// Never sends `{"scope": "all"}`: that would also end the person's
    /// dashboard sessions.
    func logout(token: String) async {
        var request = URLRequest(url: url("auth/logout"))
        request.httpMethod = "POST"
        authorize(&request, token)
        _ = try? await send(request)
    }

    // Sending feedback

    struct File: Sendable {
        var name: String
        var contentType: String
        var data: Data
    }

    func upload(payload: Data, files: [File], idempotencyKey: String, token: String)
        async throws -> Saved
    {
        let boundary = "feedback-\(UUID().uuidString)"
        var request = URLRequest(url: url("sdk/v1/apps/\(appKey)/feedback"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        authorize(&request, token)
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipart(payload: payload, files: files, boundary: boundary)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 || response.statusCode == 201 else {
            throw failure(response, data)
        }
        return try JSONDecoder().decode(Saved.self, from: data)
    }

    static func multipart(payload: Data, files: [File], boundary: String) -> Data {
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }
        line("--\(boundary)")
        line("Content-Disposition: form-data; name=\"payload\"")
        line("Content-Type: application/json")
        line("")
        body.append(payload)
        line("")
        for file in files {
            line("--\(boundary)")
            line("Content-Disposition: form-data; name=\"files\"; filename=\"\(file.name)\"")
            line("Content-Type: \(file.contentType)")
            line("")
            body.append(file.data)
            line("")
        }
        line("--\(boundary)--")
        return body
    }

    // Requests

    private func authorize(_ request: inout URLRequest, _ token: String?) {
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.retry(after: nil, reason: "No answer from the server.")
            }
            return (data, http)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.retry(after: nil, reason: error.localizedDescription)
        }
    }

    private func failure(_ response: HTTPURLResponse, _ data: Data) -> Failure {
        let status = response.statusCode
        switch status {
        case 401:
            return .signedOut
        case 429:
            let after = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            return .retry(after: after, reason: "Too many items sent. Waiting to send again.")
        case 500...:
            return .retry(after: nil, reason: "The server answered \(status).")
        default:
            return .refused(status: status, detail: detail(of: data))
        }
    }

    private func detail(of data: Data) -> String {
        struct Body: Decodable {
            var detail: JSONValue?
            var error: String?
            var error_description: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return "" }
        if case .string(let text)? = body.detail { return text }
        if let detail = body.detail, let text = try? JSONEncoder().encode(detail) {
            return String(decoding: text, as: UTF8.self)
        }
        return body.error_description ?? body.error ?? ""
    }
}

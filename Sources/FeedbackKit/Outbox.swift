import Foundation

/// Feedback waiting to be sent, kept on disk so nothing is lost to a bad
/// network or the app being closed.
///
/// Each item is a folder: `item.json` (its idempotency key and attempts),
/// `payload.json`, and its files. The idempotency key is chosen once, when
/// the item is saved, so sending it again never makes a second item on the
/// server.
actor Outbox {
    struct Item: Codable, Equatable, Sendable {
        var id: UUID
        var idempotencyKey: String
        var created: Date
        var attempts: Int = 0
        var nextAttempt: Date
        var lastError: String?
        var files: [FileInfo]

        struct FileInfo: Codable, Equatable, Sendable {
            var name: String
            var contentType: String
        }
    }

    enum Outcome: Equatable, Sendable {
        case sent(API.Saved)
        /// Kept, to be sent again later.
        case waiting(reason: String)
        /// The sign-in ended. Kept until the person signs in again.
        case signedOut
        /// The server refused it for good. It is removed.
        case refused(String)
    }

    /// After the first, second, third… failed attempt. The last repeats.
    static let delays: [TimeInterval] = [30, 120, 600, 3600]
    /// Items older than this are given up on.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    let directory: URL
    let api: API
    private var sending = false

    init(directory: URL, api: API) {
        self.directory = directory
        self.api = api
    }

    static func defaultDirectory(appKey: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Feedback/\(appKey)/outbox")
    }

    func add(_ payload: FeedbackPayload, files: [API.File], now: Date = .now) throws -> UUID {
        let id = UUID()
        let folder = directory.appending(path: id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: folder.appending(path: file.name), options: .atomic)
        }
        try JSONEncoder().encode(payload).write(to: folder.appending(path: "payload.json"))
        let item = Item(
            id: id, idempotencyKey: UUID().uuidString.lowercased(), created: now, nextAttempt: now,
            files: files.map { .init(name: $0.name, contentType: $0.contentType) })
        try save(item)
        return id
    }

    func items() -> [Item] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            (try? Data(contentsOf: folder.appending(path: "item.json")))
                .flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
        }
        .sorted { $0.created < $1.created }
    }

    /// Tries to send one item now, whatever its schedule.
    func send(_ id: UUID, token: String, now: Date = .now) async -> Outcome {
        guard var item = items().first(where: { $0.id == id }) else {
            return .refused("This feedback is no longer waiting to be sent.")
        }
        let folder = directory.appending(path: id.uuidString)
        let payload: Data
        var files: [API.File] = []
        do {
            payload = try Data(contentsOf: folder.appending(path: "payload.json"))
            for file in item.files {
                files.append(
                    .init(
                        name: file.name, contentType: file.contentType,
                        data: try Data(contentsOf: folder.appending(path: file.name))))
            }
        } catch {
            remove(id)
            return .refused("The saved feedback could not be read.")
        }

        item.attempts += 1
        do {
            let saved = try await api.upload(
                payload: payload, files: files, idempotencyKey: item.idempotencyKey, token: token)
            remove(id)
            return .sent(saved)
        } catch API.Failure.signedOut {
            item.lastError = "Signed out"
            try? save(item)
            return .signedOut
        } catch API.Failure.refused(_, let detail) {
            remove(id)
            return .refused(detail.isEmpty ? "The server refused this feedback." : detail)
        } catch {
            let reason: String
            var wait = Self.delays[min(item.attempts, Self.delays.count) - 1]
            if case API.Failure.retry(let after, let why) = error {
                reason = why
                if let after { wait = max(wait, after) }
            } else {
                reason = error.localizedDescription
            }
            if now.timeIntervalSince(item.created) > Self.maxAge {
                remove(id)
                return .refused("Given up after a week of trying: \(reason)")
            }
            item.lastError = reason
            item.nextAttempt = now.addingTimeInterval(wait)
            try? save(item)
            return .waiting(reason: reason)
        }
    }

    /// Sends every item that is due. Stops at the first sign that the
    /// person is signed out, as the others would fail the same way.
    @discardableResult
    func flush(token: String, now: Date = .now) async -> [UUID: Outcome] {
        guard !sending else { return [:] }
        sending = true
        defer { sending = false }
        var outcomes: [UUID: Outcome] = [:]
        for item in items() where item.nextAttempt <= now {
            let outcome = await send(item.id, token: token, now: now)
            outcomes[item.id] = outcome
            if outcome == .signedOut { break }
        }
        return outcomes
    }

    private func save(_ item: Item) throws {
        let folder = directory.appending(path: item.id.uuidString)
        try JSONEncoder().encode(item).write(to: folder.appending(path: "item.json"), options: .atomic)
    }

    private func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString))
    }
}

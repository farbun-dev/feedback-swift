import CoreGraphics
import Foundation

/// Which screen of the app a screenshot shows, so that its pins are drawn
/// only while that screen is in view.
///
/// A screen is the view controller on top (on macOS, the window) together
/// with the name given by `.feedbackScreen(_:)`. Once that view controller is
/// gone, such as after going back, a screen with the same name counts as the
/// same one again, so its pins come back when the person returns to it.
struct ScreenKey {
    weak var owner: AnyObject?
    let hadOwner: Bool
    var name: String?

    init(owner: AnyObject?, name: String?) {
        self.owner = owner
        hadOwner = owner != nil
        self.name = name
    }

    /// Whether `current`, the screen in view now, is this one.
    func matches(_ current: ScreenKey) -> Bool {
        if let owner { return owner === current.owner && name == current.name }
        if hadOwner { return name != nil && name == current.name }
        return name == current.name
    }

    func isSame(as other: ScreenKey) -> Bool {
        owner === other.owner && hadOwner == other.hadOwner && name == other.name
    }
}

/// Feedback being written: pins on screenshots of one or more screens, each
/// with a comment, and a comment about the whole thing.
struct Draft {
    /// A screenshot, taken when a pin was dropped on a screen.
    struct Shot: Identifiable {
        let id = UUID()
        var screenshot: Screenshot
        var key: ScreenKey
        var screen: String?
        /// Where the screen is in the source, as `file:line`.
        var source: String?
    }

    struct Pin: Identifiable, Equatable {
        let id = UUID()
        var shot: Shot.ID
        /// Where it is on its screenshot: a point.
        var point: Region
        var comment = ""
    }

    /// With the comment about the whole thing, the 20 annotations the
    /// service takes in one item.
    static let maxPins = 19
    /// All the screenshots of one item together. The service takes 60
    /// million pixels; past this many they are scaled down, which also keeps
    /// the upload well under its size limit.
    static let maxPixels = 30_000_000

    var shots: [Shot] = []
    var pins: [Pin] = []
    var overall = ""
    var environment: [String: JSONValue]

    init(environment: [String: JSONValue]) {
        self.environment = environment
    }

    func shot(_ id: Shot.ID) -> Shot? { shots.first { $0.id == id } }

    func number(of id: Pin.ID) -> Int { (pins.firstIndex { $0.id == id } ?? 0) + 1 }

    /// Drops a pin at `point`, in points from the top left of `screenshot`.
    /// The screenshot is shared with the last one of the same screen when
    /// nothing on it has changed. Answers nil once there are as many pins as
    /// can be sent.
    @discardableResult
    mutating func pin(
        _ point: CGPoint, on screenshot: Screenshot, key: ScreenKey, screen: String?,
        source: String?
    ) -> Pin.ID? {
        guard pins.count < Self.maxPins else { return nil }
        let shot: Shot.ID
        if let last = shots.last(where: { $0.key.matches(key) }),
            last.screenshot.hasSamePixels(as: screenshot)
        {
            shot = last.id
        } else {
            let new = Shot(screenshot: screenshot, key: key, screen: screen, source: source)
            shots.append(new)
            shot = new.id
        }
        let pin = Pin(
            shot: shot,
            point: Region(CGRect(origin: point, size: .zero), in: screenshot.pointSize))
        pins.append(pin)
        return pin.id
    }

    /// Removes a pin, and its screenshot when no other pin is on it.
    mutating func remove(_ id: Pin.ID) {
        pins.removeAll { $0.id == id }
        shots.removeAll { shot in !pins.contains { $0.shot == shot.id } }
    }

    private static func text(_ comment: String) -> String {
        comment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The screenshots that will be sent, each with its file name: only
    /// those with a pin that has a comment, as the service refuses a file
    /// that no comment names.
    var files: [(name: String, shot: Shot)] {
        let used = Set(pins.filter { !Self.text($0.comment).isEmpty }.map(\.shot))
        return shots.filter { used.contains($0.id) }.enumerated().map {
            ("screen-\($0.offset + 1).png", $0.element)
        }
    }

    /// The comments that will be sent: each pin with text, in their order,
    /// then the overall one.
    var annotations: [AnnotationPayload] {
        let files = files
        var found = pins.compactMap { pin -> AnnotationPayload? in
            let text = Self.text(pin.comment)
            guard !text.isEmpty, let file = files.first(where: { $0.shot.id == pin.shot })
            else { return nil }
            var target: [String: JSONValue] = [:]
            if let screen = file.shot.screen { target["screen"] = .string(screen) }
            if let source = file.shot.source { target["screen_source"] = .string(source) }
            return AnnotationPayload(
                comment: text, screenshot: file.name, region: pin.point,
                target: target.isEmpty ? nil : target)
        }
        let overall = Self.text(overall)
        if !overall.isEmpty { found.append(AnnotationPayload(comment: overall)) }
        return found
    }

    var canSend: Bool { !annotations.isEmpty }

    /// The `payload` part and the files of the upload.
    func request(build: BuildInfo, commit: String?, maxPixels: Int = Self.maxPixels)
        -> (FeedbackPayload, [API.File])
    {
        let files = files
        let pixels = files.reduce(0) { $0 + $1.shot.screenshot.image.width * $1.shot.screenshot.image.height }
        let factor = pixels > maxPixels ? (Double(maxPixels) / Double(pixels)).squareRoot() : 1
        let payload = FeedbackPayload(
            screen: files.first?.shot.screen, appVersion: build.appVersion,
            buildNumber: build.buildNumber, commit: commit, environment: environment,
            annotations: annotations)
        let uploads = files.compactMap { file -> API.File? in
            let picture = factor < 1 ? file.shot.screenshot.scaled(by: factor) : file.shot.screenshot
            return picture?.png().map { API.File(name: file.name, contentType: "image/png", data: $0) }
        }
        return (payload, uploads)
    }
}

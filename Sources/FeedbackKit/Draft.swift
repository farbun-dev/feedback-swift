import Foundation

/// Feedback being written: one screenshot, with marks on it that each carry
/// a comment, and a comment about the screen as a whole.
struct Draft {
    struct Mark: Identifiable, Equatable {
        let id = UUID()
        var region: Region
        var comment = ""
    }

    static let screenshotName = "screen.png"

    var screenshot: Screenshot?
    var screen: String?
    var environment: [String: JSONValue]
    var marks: [Mark] = []
    var overall = ""

    init(screenshot: Screenshot?, screen: String?, environment: [String: JSONValue]) {
        self.screenshot = screenshot
        self.screen = screen
        self.environment = environment
    }

    /// The comments that will be sent: each mark with text, then the overall one.
    var annotations: [AnnotationPayload] {
        let file = screenshot == nil ? nil : Self.screenshotName
        var found = marks.compactMap { mark -> AnnotationPayload? in
            let text = mark.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AnnotationPayload(comment: text, screenshot: file, region: mark.region)
        }
        let overall = overall.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overall.isEmpty {
            found.append(AnnotationPayload(comment: overall, screenshot: file))
        }
        return found
    }

    var canSend: Bool { !annotations.isEmpty }

    /// The `payload` part and the files of the upload.
    func request(build: BuildInfo, commit: String?) -> (FeedbackPayload, [API.File]) {
        let payload = FeedbackPayload(
            screen: screen, appVersion: build.appVersion, buildNumber: build.buildNumber,
            commit: commit, environment: environment, annotations: annotations)
        let files = (screenshot?.png()).map {
            [API.File(name: Self.screenshotName, contentType: "image/png", data: $0)]
        }
        return (payload, files ?? [])
    }
}

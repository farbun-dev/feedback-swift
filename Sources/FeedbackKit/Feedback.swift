import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#else
    import AppKit
#endif

/// Collects feedback on the app and sends it to the Feedback service.
///
/// It does nothing for ordinary users of the app. It shows itself when the
/// app calls `show()`, such as from a debug menu, or opens a `…://feedback`
/// link through `handle(_:)`. Once someone has signed in on a device,
/// `isAvailable` stays true there until they hide it.
///
/// ```swift
/// Feedback.configure(appKey: "pk_…", baseURL: URL(string: "https://feedback.farbun.dev")!)
/// ```
@MainActor
public enum Feedback {
    public static let sdkVersion = "0.1.0"
    /// The hosted Feedback service.
    public static let defaultBaseURL = URL(string: "https://feedback.farbun.dev")!

    static var session: Session?

    /// Sets the SDK up. Call once, early, such as in the app's `init`.
    ///
    /// - Parameters:
    ///   - redirectURI: where the sign-in returns to. It must be registered
    ///     for this app and platform in the Feedback dashboard. The default
    ///     is the bundle identifier as a scheme: `com.example.app:/feedback`.
    ///   - commit: the commit the build was made from. By default it is read
    ///     from the `FeedbackCommit` key of the app's Info.plist, when set.
    ///   - showOnGesture: shows the orb on a two-finger triple tap on iOS,
    ///     or Control-Option-Command-F on macOS, with no button in the app.
    public static func configure(
        appKey: String, baseURL: URL = defaultBaseURL, redirectURI: String? = nil,
        commit: String? = nil,
        showOnGesture: Bool = false, bundle: Bundle = .main
    ) {
        let build = BuildInfo.of(bundle)
        let redirect = redirectURI ?? "\(build.bundleID ?? "app"):/feedback"
        let commit = commit ?? (bundle.object(forInfoDictionaryKey: "FeedbackCommit") as? String)
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        session = Session(
            api: API(baseURL: baseURL, appKey: appKey), redirectURI: redirect, commit: commit,
            build: build, tokens: KeychainTokenStore(), defaults: .standard)
        session?.start()
        if showOnGesture { Gesture.shared.start() }
    }

    /// Whether someone has signed in on this device and not hidden it.
    /// Use it to decide whether to show a Feedback button.
    public static var isAvailable: Bool { session?.isAvailable ?? false }

    /// Shows the feedback orb over the key window. While it is out, a double
    /// tap (Option-click on macOS) pins a comment to that spot and takes a
    /// screenshot of the screen; tapping the orb reviews and sends them.
    public static func show() {
        guard let session else {
            assertionFailure("Call Feedback.configure(appKey:baseURL:) first.")
            return
        }
        session.present()
    }

    /// Shows the orb for an app link such as `myapp://feedback`, and answers
    /// true. Any other link, including every http and https one, is left for
    /// the app: it answers false.
    ///
    /// ```swift
    /// .onOpenURL { url in
    ///     if Feedback.handle(url) { return }
    ///     handleOwnLink(url)
    /// }
    /// ```
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard isFeedbackLink(url) else { return false }
        show()
        return true
    }

    nonisolated static func isFeedbackLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme != "http", scheme != "https"
        else { return false }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return url.host()?.lowercased() == "feedback" && path.isEmpty
    }

    /// Stops offering feedback on this device, until `show()` is called again.
    /// The sign-in is kept.
    public static func hide() { session?.isAvailable = false }

    /// Ends this device's sign-in. Only this one: the person's other
    /// sign-ins and their dashboard sessions are left alone.
    public static func signOut() async { await session?.signOut() }
}

/// The SDK's state: the sign-in, the outbox, and the orb with its pins.
@MainActor
@Observable
final class Session {
    enum Account: Equatable {
        case unknown
        case signedOut
        case signedIn(API.Person)
        case noAccess(String?)
    }

    let api: API
    let redirectURI: String
    let commit: String?
    let build: BuildInfo
    @ObservationIgnored let tokens: TokenStore
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let outbox: Outbox
    @ObservationIgnored private let sheet = SignInSheet()
    /// Closes the open sheet, then runs what it is given.
    @ObservationIgnored private var dismissSheet: ((@escaping @MainActor () -> Void) -> Void)?

    var account: Account = .unknown
    var appName: String?
    var waiting = 0

    init(
        api: API, redirectURI: String, commit: String?, build: BuildInfo, tokens: TokenStore,
        defaults: UserDefaults, outboxDirectory: URL? = nil
    ) {
        self.api = api
        self.redirectURI = redirectURI
        self.commit = commit
        self.build = build
        self.tokens = tokens
        self.defaults = defaults
        outbox = Outbox(
            directory: outboxDirectory ?? Outbox.defaultDirectory(appKey: api.appKey), api: api)
    }

    var platform: String {
        #if os(macOS)
            "macos"
        #else
            "ios"
        #endif
    }

    var clientID: String { "\(api.appKey).\(platform)" }
    private var tokenAccount: String { "\(api.baseURL.host() ?? "")/\(api.appKey)" }
    private var availableKey: String { "dev.farbun.feedback.available.\(api.appKey)" }

    var token: String? { tokens.read(tokenAccount) }

    var isAvailable: Bool {
        get { access(keyPath: \.isAvailable); return defaults.bool(forKey: availableKey) }
        set { withMutation(keyPath: \.isAvailable) { defaults.set(newValue, forKey: availableKey) } }
    }

    func start() {
        Task { await flush() }
        #if canImport(UIKit)
            let name = UIApplication.didBecomeActiveNotification
        #else
            let name = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.flush() } }
        }
    }

    // Signing in

    func refreshAccount() async {
        guard let token else {
            account = .signedOut
            return
        }
        do {
            let state = try await api.state(token: token)
            appName = state.appName
            switch state.state {
            case "signed_in":
                account = state.user.map(Account.signedIn) ?? .signedOut
            case "no_access":
                account = .noAccess(state.user?.githubLogin)
            default:
                tokens.delete(tokenAccount)
                account = .signedOut
            }
        } catch API.Failure.signedOut {
            tokens.delete(tokenAccount)
            account = .signedOut
        } catch {
            // Offline: keep the token, and assume it still works.
            if account == .unknown { account = .signedOut }
        }
    }

    func signIn() async throws {
        let attempt = PKCE()
        let url = api.authorizeURL(
            clientID: clientID, redirectURI: redirectURI, challenge: attempt.challenge,
            state: attempt.state)
        let scheme = String(redirectURI.prefix { $0 != ":" })
        let callback = try await sheet.run(url, callbackScheme: scheme)
        let code = try code(from: callback, state: attempt.state)
        let issued = try await api.exchange(
            code: code, verifier: attempt.verifier, clientID: clientID, redirectURI: redirectURI)
        tokens.write(issued.accessToken, tokenAccount)
        isAvailable = true
        await refreshAccount()
        await flush()
    }

    func signOut() async {
        if let token { await api.logout(token: token) }
        tokens.delete(tokenAccount)
        account = .signedOut
    }

    // Sending

    func flush() async {
        if let token {
            let outcomes = await outbox.flush(token: token)
            if outcomes.values.contains(.signedOut) {
                tokens.delete(tokenAccount)
                account = .signedOut
            }
        }
        waiting = await outbox.items().count
    }

    func send(_ draft: Draft) async -> Outbox.Outcome {
        guard let token else { return .signedOut }
        let (payload, files) = draft.request(build: build, commit: commit)
        let id: UUID
        do {
            id = try await outbox.add(payload, files: files)
        } catch {
            return .refused("The feedback could not be saved: \(error.localizedDescription)")
        }
        let outcome = await outbox.send(id, token: token)
        if outcome == .signedOut {
            tokens.delete(tokenAccount)
            account = .signedOut
        }
        waiting = await outbox.items().count
        return outcome
    }

    // The orb and the review sheet

    @ObservationIgnored private(set) var overlay: Overlay?

    /// Shows the orb over the key window. Pins are dropped on it until the
    /// person sends or discards them from the review sheet.
    func present() {
        isAvailable = true
        guard overlay == nil, let window = Capture.keyWindow() else { return }
        let review = Review(
            draft: Draft(environment: Context.environment(window: window, bundleID: build.bundleID)))
        overlay = Overlay(review: review, window: window) { [weak self] in self?.openReview() }
        Task { await refreshAccount() }
    }

    /// Opens the review sheet, from the orb.
    func openReview() {
        guard dismissSheet == nil, let overlay, let window = overlay.window else { return }
        let review = overlay.review
        review.closeBubble()
        review.reviewing = true
        let view = ReviewView(
            session: self, review: review,
            close: { [weak self] in self?.closeReview() },
            goTo: { [weak self] id in
                // Once the sheet is gone: the bubble makes the overlay the
                // key window, which a sheet still on its way out must not see.
                self?.closeReview { review.open = id }
            },
            finish: { [weak self] in self?.finish() })
        #if canImport(UIKit)
            guard var top = window.rootViewController else { return }
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            let host = UIHostingController(rootView: view)
            host.modalPresentationStyle = .pageSheet
            host.isModalInPresentation = true
            top.present(host, animated: true)
            dismissSheet = { [weak host] then in
                guard let host else { return then() }
                host.dismiss(animated: true) { MainActor.assumeIsolated { then() } }
            }
        #else
            let host = NSHostingController(rootView: view)
            let panel = NSWindow(contentViewController: host)
            panel.title = "Send feedback"
            panel.setContentSize(NSSize(width: 560, height: 640))
            window.beginSheet(panel)
            dismissSheet = { [weak window, weak panel] then in
                if let panel { window?.endSheet(panel) }
                then()
            }
        #endif
        Task { await refreshAccount() }
    }

    /// Closes the review sheet and leaves the orb out.
    func closeReview(then: @escaping @MainActor () -> Void = {}) {
        let review = overlay?.review
        let dismiss = dismissSheet
        dismissSheet = nil
        review?.reviewing = false
        if let dismiss { dismiss(then) } else { then() }
    }

    /// Puts the orb away, with every pin: after sending, or to discard them.
    func finish() {
        dismissSheet?({})
        dismissSheet = nil
        overlay?.remove()
        overlay = nil
    }
}

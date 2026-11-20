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

    static var session: Session?

    /// Sets the SDK up. Call once, early, such as in the app's `init`.
    ///
    /// - Parameters:
    ///   - redirectURI: where the sign-in returns to. It must be registered
    ///     for this app and platform in the Feedback dashboard. The default
    ///     is the bundle identifier as a scheme: `com.example.app:/feedback`.
    ///   - commit: the commit the build was made from, when the build knows it.
    public static func configure(
        appKey: String, baseURL: URL, redirectURI: String? = nil, commit: String? = nil,
        bundle: Bundle = .main
    ) {
        let build = BuildInfo.of(bundle)
        let redirect = redirectURI ?? "\(build.bundleID ?? "app"):/feedback"
        session = Session(
            api: API(baseURL: baseURL, appKey: appKey), redirectURI: redirect, commit: commit,
            build: build, tokens: KeychainTokenStore(), defaults: .standard)
        session?.start()
    }

    /// Whether someone has signed in on this device and not hidden it.
    /// Use it to decide whether to show a Feedback button.
    public static var isAvailable: Bool { session?.isAvailable ?? false }

    /// Takes a screenshot of the key window and opens the feedback sheet,
    /// signing in first when needed.
    public static func show() {
        guard let session else {
            assertionFailure("Call Feedback.configure(appKey:baseURL:) first.")
            return
        }
        session.present()
    }

    /// Opens the sheet for a `…://feedback` link and answers true, or answers
    /// false for any other link. Call it from `onOpenURL`.
    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard url.host() == "feedback" || url.path() == "/feedback" || url.path() == "feedback"
        else { return false }
        show()
        return true
    }

    /// Stops offering feedback on this device, until `show()` is called again.
    /// The sign-in is kept.
    public static func hide() { session?.isAvailable = false }

    /// Ends this device's sign-in. Only this one: the person's other
    /// sign-ins and their dashboard sessions are left alone.
    public static func signOut() async { await session?.signOut() }
}

/// The SDK's state: the sign-in, the outbox, and what the sheet shows.
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
    @ObservationIgnored private var dismissSheet: (() -> Void)?

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

    // The sheet

    func present() {
        guard dismissSheet == nil else { return }
        let window = Capture.keyWindow()
        let draft = Draft(
            screenshot: Capture.screenshot(), screen: Screens.current?.name,
            environment: Context.environment(window: window, bundleID: build.bundleID))
        let view = ComposeView(session: self, draft: draft) { [weak self] in self?.dismiss() }
        isAvailable = true
        #if canImport(UIKit)
            guard var top = window?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            let host = UIHostingController(rootView: view)
            host.modalPresentationStyle = .pageSheet
            host.isModalInPresentation = true
            top.present(host, animated: true)
            dismissSheet = { [weak host] in host?.dismiss(animated: true) }
        #else
            let host = NSHostingController(rootView: view)
            let panel = NSWindow(contentViewController: host)
            panel.title = "Send feedback"
            panel.setContentSize(NSSize(width: 720, height: 640))
            if let window {
                window.beginSheet(panel)
                dismissSheet = { [weak window, weak panel] in
                    if let panel { window?.endSheet(panel) }
                }
            } else {
                panel.makeKeyAndOrderFront(nil)
                dismissSheet = { [weak panel] in panel?.close() }
            }
        #endif
        Task { await refreshAccount() }
    }

    func dismiss() {
        dismissSheet?()
        dismissSheet = nil
    }
}

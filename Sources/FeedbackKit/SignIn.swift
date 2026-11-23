import AuthenticationServices
import CryptoKit
import Foundation

/// One sign-in attempt: the OAuth code flow with PKCE, through the system's
/// sign-in sheet, ending at the app's own registered address.
struct PKCE: Sendable {
    let verifier: String
    let state: String

    init() {
        verifier = Self.random(48)
        state = Self.random(32)
    }

    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func random(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum SignInError: LocalizedError, Equatable {
    case cancelled
    case couldNotStart
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .couldNotStart: "The sign-in sheet could not open."
        case .refused(let reason): reason
        }
    }
}

/// The one-time code in the address the sign-in came back to.
func code(from callback: URL, state: String) throws -> String {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard value("state") == state else {
        throw SignInError.refused("The sign-in answer did not match. Try again.")
    }
    if let error = value("error") {
        throw SignInError.refused(value("error_description") ?? error)
    }
    guard let code = value("code") else {
        throw SignInError.refused("The sign-in came back without a code.")
    }
    return code
}

@MainActor
final class SignInSheet: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Shows `url` in the system sheet and answers the address it ends at.
    func run(_ url: URL, callbackScheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            // AuthenticationServices calls this on its own XPC queue, so it
            // must not inherit the main actor from this method.
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: callbackScheme
            ) { @Sendable callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError,
                    error.code == .canceledLogin
                {
                    continuation.resume(throwing: SignInError.cancelled)
                } else {
                    continuation.resume(
                        throwing: SignInError.refused(
                            error?.localizedDescription ?? "The sign-in failed."))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: SignInError.couldNotStart)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession)
        -> ASPresentationAnchor
    {
        MainActor.assumeIsolated { Capture.keyWindow() ?? ASPresentationAnchor() }
    }
}

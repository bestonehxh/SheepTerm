import CryptoKit
import Foundation

/// The app's registration with Google (Google Cloud Console → Clients →
/// Desktop app). Both values ship inside the app: Google's own guidance is
/// that an installed app cannot keep a secret, and PKCE is what protects the
/// sign-in, not the "secret".
public struct GoogleClient: Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String?

    public init(clientID: String, clientSecret: String?) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    /// Placeholder values from an unconfigured build count as "not set up".
    public var isConfigured: Bool {
        clientID.hasSuffix(".apps.googleusercontent.com") && !clientID.hasPrefix("$(")
    }
}

/// The pure half of "Sign in with Google" for an installed app: PKCE
/// (RFC 7636), the URLs, the token requests and their answers. The loopback
/// listener and the network calls are elsewhere, so all of this is testable
/// without a browser or a network.
public enum GoogleOAuth {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    /// The narrowest Drive scope there is: a hidden folder only this Google
    /// client can see — not the user's files. Plus the address and the
    /// profile picture, to show who is signed in.
    public static let scopes = ["https://www.googleapis.com/auth/drive.appdata", "openid", "email", "profile"]

    public struct PKCE: Sendable, Equatable {
        public var verifier: String
        public var challenge: String

        public init(verifier: String) {
            self.verifier = verifier
            challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }

        public static func make() throws -> PKCE {
            PKCE(verifier: base64URL(try SecureRandom.bytes(32)))
        }
    }

    public static func makeState() throws -> String { base64URL(try SecureRandom.bytes(16)) }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func authorizationURL(client: GoogleClient, redirectURI: String, pkce: PKCE,
                                        state: String, loginHint: String? = nil) -> URL {
        var parts = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // A refresh token, so the Mac stays signed in.
            URLQueryItem(name: "access_type", value: "offline"),
            // Without consent Google only returns a refresh token the first
            // time an account ever grants this client — a second Mac, or a
            // sign-in after sign-out, would get none.
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        parts.queryItems = items
        return parts.url!
    }

    static func form(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }

    static func post(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        return request
    }

    public static func codeExchangeRequest(client: GoogleClient, code: String, pkce: PKCE,
                                           redirectURI: String) -> URLRequest {
        var fields = [("client_id", client.clientID), ("code", code), ("code_verifier", pkce.verifier),
                      ("grant_type", "authorization_code"), ("redirect_uri", redirectURI)]
        if let secret = client.clientSecret, !secret.isEmpty { fields.append(("client_secret", secret)) }
        return post(tokenEndpoint, fields)
    }

    public static func refreshRequest(client: GoogleClient, refreshToken: String) -> URLRequest {
        var fields = [("client_id", client.clientID), ("grant_type", "refresh_token"),
                      ("refresh_token", refreshToken)]
        if let secret = client.clientSecret, !secret.isEmpty { fields.append(("client_secret", secret)) }
        return post(tokenEndpoint, fields)
    }

    public static func revokeRequest(token: String) -> URLRequest {
        post(revokeEndpoint, [("token", token)])
    }

    public struct TokenResponse: Equatable, Sendable {
        public var accessToken: String
        public var expiresIn: Int
        public var refreshToken: String?
        public var email: String?
        public var picture: URL?
    }

    public enum OAuthError: Error, Equatable, Sendable, LocalizedError {
        /// `invalid_grant`: the refresh token is dead (revoked, expired,
        /// password changed). Only a new sign-in fixes it.
        case invalidGrant
        case server(String)
        case denied(String)
        case stateMismatch
        case timedOut
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .invalidGrant: return "Google sign-in has expired or was revoked — sign in again."
            case .server(let message): return "Google sign-in failed: \(message)"
            case .denied(let reason): return "Sign-in was not completed (\(reason))."
            case .stateMismatch: return "The sign-in answer did not belong to this request — try again."
            case .timedOut: return "Sign-in timed out — try again."
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    public static func parseTokenResponse(_ data: Data, status: Int) throws -> TokenResponse {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let error = object["error"] as? String ?? "HTTP \(status)"
            if error == "invalid_grant" { throw OAuthError.invalidGrant }
            let detail = object["error_description"] as? String
            throw OAuthError.server(detail.map { "\(error): \($0)" } ?? error)
        }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw OAuthError.server("no access token in the answer")
        }
        let expires = (object["expires_in"] as? NSNumber)?.intValue ?? 3600
        let claims = (object["id_token"] as? String).flatMap(idTokenClaims) ?? [:]
        return TokenResponse(accessToken: access, expiresIn: expires,
                             refreshToken: object["refresh_token"] as? String,
                             email: claims["email"] as? String,
                             picture: (claims["picture"] as? String).flatMap(URL.init(string:))
                                .flatMap { $0.scheme == "https" ? $0 : nil })
    }

    /// The `email` claim of an ID token. Display only — the token came
    /// straight from Google's token endpoint over TLS, and nothing is
    /// authorised on the strength of it, so the signature is not checked.
    public static func emailFromIDToken(_ token: String) -> String? {
        idTokenClaims(token)?["email"] as? String
    }

    static func idTokenClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return claims
    }

    /// The query of the browser's redirect back to the loopback listener,
    /// from the first line of its HTTP request ("GET /?code=…&state=… HTTP/1.1").
    public static func redirectParameters(requestLine: String) -> [String: String]? {
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2, pieces[0] == "GET",
              let parts = URLComponents(string: "http://127.0.0.1" + pieces[1]) else { return nil }
        var result: [String: String] = [:]
        for item in parts.queryItems ?? [] { result[item.name] = item.value ?? "" }
        return result
    }

    /// The authorization code from the redirect, or why there is none.
    public static func code(from parameters: [String: String], expectedState: String) throws -> String {
        if let error = parameters["error"] { throw OAuthError.denied(error) }
        guard parameters["state"] == expectedState else { throw OAuthError.stateMismatch }
        guard let code = parameters["code"], !code.isEmpty else { throw OAuthError.denied("no code") }
        return code
    }
}

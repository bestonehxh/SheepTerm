import Foundation

/// What the engine needs from a signed-in Google account besides Drive files. `GoogleAccount` (URLSession, Apple) and the Windows port's
/// WinHTTP account both conform.
public protocol GoogleAccountProtocol: AnyObject, Sendable {
    /// A valid access token (refreshing it when needed); `OAuthError.invalidGrant` when the sign-in is dead.
    func token() async throws -> String
    /// After a 401: the next `token()` asks Google again.
    func invalidate() async
    /// The account's address and photo (`userinfo`), or nil.
    func profile() async -> GoogleOAuth.Profile?
    /// Sign-out: tell Google to forget this grant (best effort).
    func revoke() async
}

/// Everything that talks HTTP to Google, as two closures, so a platform without URLSession (Windows) can bring its own. The default on Apple
/// is `GoogleTransport.urlSession` (GoogleDrive.swift) - exactly the code that used to be inline in the engine.
public struct GoogleTransport: Sendable {
    /// Sign-in: the authorization code -> tokens (+ the id token's address and photo).
    public var exchangeCode: @Sendable (_ client: GoogleClient, _ code: String, _ pkce: GoogleOAuth.PKCE, _ redirectURI: String) async throws -> GoogleOAuth.TokenResponse
    /// An account for a stored refresh token, with the Drive backend that uses it. `onNewRefreshToken` is called when Google rotates it.
    public var makeAccount: @Sendable (_ client: GoogleClient, _ refreshToken: String, _ onNewRefreshToken: @escaping @Sendable (String) -> Void) -> (account: any GoogleAccountProtocol, backend: SyncBackend)

    public init(exchangeCode: @escaping @Sendable (GoogleClient, String, GoogleOAuth.PKCE, String) async throws -> GoogleOAuth.TokenResponse,
                makeAccount: @escaping @Sendable (GoogleClient, String, @escaping @Sendable (String) -> Void) -> (account: any GoogleAccountProtocol, backend: SyncBackend)) {
        self.exchangeCode = exchangeCode
        self.makeAccount = makeAccount
    }
}

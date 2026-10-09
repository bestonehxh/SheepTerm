import Network
import XCTest
@testable import SheepSync

final class GoogleOAuthTests: XCTestCase {
    let client = GoogleClient(clientID: "123-abc.apps.googleusercontent.com", clientSecret: "s3cr+t")

    /// RFC 7636 Appendix B.
    func testPKCEChallengeMatchesRFC7636() {
        let pkce = GoogleOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testFreshPKCEIsURLSafeAndLongEnough() throws {
        let pkce = try GoogleOAuth.PKCE.make()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertNil(pkce.verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertNotEqual(try GoogleOAuth.PKCE.make(), pkce)
    }

    func testAuthorizationURLAsksForOnlyTheAppFolderAndOfflineAccess() throws {
        let url = GoogleOAuth.authorizationURL(client: client, redirectURI: "http://127.0.0.1:5555",
                                               pkce: GoogleOAuth.PKCE(verifier: "v"), state: "st")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(items["scope"], "https://www.googleapis.com/auth/drive.appdata openid email profile")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5555")
        XCTAssertEqual(items["state"], "st")
        XCTAssertFalse(url.absoluteString.contains("s3cr"), "the client secret never goes to the browser")
    }

    func testTokenRequestsAreFormEncoded() {
        let request = GoogleOAuth.codeExchangeRequest(client: client, code: "4/a+b", pkce: GoogleOAuth.PKCE(verifier: "ver"),
                                                      redirectURI: "http://127.0.0.1:1")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(body.contains("code=4%2Fa%2Bb"))
        XCTAssertTrue(body.contains("code_verifier=ver"))
        XCTAssertTrue(body.contains("client_secret=s3cr%2Bt"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1"))
        let refresh = String(data: GoogleOAuth.refreshRequest(client: GoogleClient(clientID: "x", clientSecret: nil),
                                                               refreshToken: "r").httpBody!, encoding: .utf8)!
        XCTAssertEqual(refresh, "client_id=x&grant_type=refresh_token&refresh_token=r")
    }

    func testTokenResponseParsing() throws {
        let claims = GoogleOAuth.base64URL(Data(#"{"email":"sheep@example.com","sub":"1","picture":"https://lh3.googleusercontent.com/a/x=s96-c"}"#.utf8))
        let ok = #"{"access_token":"ya29","expires_in":3599,"refresh_token":"1//r","id_token":"h.\#(claims).s"}"#
        let answer = try GoogleOAuth.parseTokenResponse(Data(ok.utf8), status: 200)
        XCTAssertEqual(answer, .init(accessToken: "ya29", expiresIn: 3599, refreshToken: "1//r", email: "sheep@example.com",
                                      picture: URL(string: "https://lh3.googleusercontent.com/a/x=s96-c")))
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)) {
            XCTAssertEqual($0 as? GoogleOAuth.OAuthError, .invalidGrant)
        }
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(Data("<html>".utf8), status: 500))
        XCTAssertThrowsError(try GoogleOAuth.parseTokenResponse(Data("{}".utf8), status: 200))
    }

    func testRedirectParsing() throws {
        let params = try XCTUnwrap(GoogleOAuth.redirectParameters(requestLine: "GET /?state=abc&code=4%2F0Ab&scope=x HTTP/1.1"))
        XCTAssertEqual(try GoogleOAuth.code(from: params, expectedState: "abc"), "4/0Ab")
        XCTAssertThrowsError(try GoogleOAuth.code(from: params, expectedState: "other")) {
            XCTAssertEqual($0 as? GoogleOAuth.OAuthError, .stateMismatch)
        }
        let denied = try XCTUnwrap(GoogleOAuth.redirectParameters(requestLine: "GET /?error=access_denied&state=abc HTTP/1.1"))
        XCTAssertThrowsError(try GoogleOAuth.code(from: denied, expectedState: "abc")) {
            XCTAssertEqual($0 as? GoogleOAuth.OAuthError, .denied("access_denied"))
        }
        XCTAssertNil(GoogleOAuth.redirectParameters(requestLine: "POST / HTTP/1.1"))
        XCTAssertEqual(GoogleOAuth.redirectParameters(requestLine: "GET /favicon.ico HTTP/1.1"), [:])
    }

    func testClientConfiguredOnlyWithARealID() {
        XCTAssertTrue(client.isConfigured)
        XCTAssertFalse(GoogleClient(clientID: "", clientSecret: nil).isConfigured)
        XCTAssertFalse(GoogleClient(clientID: "$(SHEEPSYNC_GOOGLE_CLIENT_ID)", clientSecret: nil).isConfigured)
    }

    func testDriveRequestsStayInTheAppFolder() {
        let list = GoogleDriveBackend.listURL(name: "it's.sealed").absoluteString.removingPercentEncoding!
        XCTAssertTrue(list.contains("spaces=appDataFolder"))
        XCTAssertTrue(list.contains(#"name = 'it\'s.sealed'"#))
        let create = GoogleDriveBackend.createRequest(name: "a.sealed", data: Data([1, 2]), boundary: "BB")
        let body = String(decoding: create.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains(#""parents":["appDataFolder"]"#))
        XCTAssertTrue(body.hasSuffix("\r\n--BB--\r\n"))
        XCTAssertEqual(create.value(forHTTPHeaderField: "Content-Type"), "multipart/related; boundary=BB")
    }

    /// The real listener on 127.0.0.1: a favicon request is ignored, the
    /// redirect with a code is delivered, and the browser gets a page.
    func testLoopbackReceiverDeliversTheRedirect() async throws {
        let receiver = try LoopbackReceiver(appName: "Test")
        let redirect = try await receiver.start(expectedState: "S")
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:"))
        let favicon = try await URLSession.shared.data(from: URL(string: redirect + "/favicon.ico")!)
        XCTAssertEqual((favicon.1 as? HTTPURLResponse)?.statusCode, 404)
        // Any local process can reach the port: an answer with the wrong
        // state must neither end nor abort the sign-in.
        let stray = try await URLSession.shared.data(from: URL(string: redirect + "/?error=x&state=WRONG")!)
        XCTAssertEqual((stray.1 as? HTTPURLResponse)?.statusCode, 404)
        let (page, response) = try await URLSession.shared.data(from: URL(string: redirect + "/?code=C1&state=S")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Signed in"))
        let params = try await receiver.waitForRedirect(timeout: 5)
        XCTAssertEqual(params["code"], "C1")
    }

    /// Regression: cancelling before the listener was ready left `start`
    /// waiting forever (`.cancelled` was not handled).
    func testCancelBeforeReadyEndsStart() async throws {
        let receiver = try LoopbackReceiver(appName: "Test")
        receiver.cancel()
        do {
            _ = try await receiver.start(expectedState: "S")
            // Ready won the race: then waiting must end with .cancelled.
            do { _ = try await receiver.waitForRedirect(timeout: 2); XCTFail("redirect after cancel") }
            catch { XCTAssertEqual(error as? GoogleOAuth.OAuthError, .cancelled) }
        } catch {
            XCTAssertEqual(error as? GoogleOAuth.OAuthError, .cancelled)
        }
    }

    /// The request line can arrive in more than one packet.
    func testRedirectSplitAcrossPackets() async throws {
        let receiver = try LoopbackReceiver(appName: "Test")
        let redirect = try await receiver.start(expectedState: "S")
        let port = UInt16(redirect.split(separator: ":").last!)!
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        connection.send(content: Data("GET /?code=C2&st".utf8), completion: .contentProcessed { _ in })
        try await Task.sleep(for: .milliseconds(100))
        connection.send(content: Data("ate=S HTTP/1.1\r\nHost: x\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        let params = try await receiver.waitForRedirect(timeout: 5)
        XCTAssertEqual(params["code"], "C2")
        connection.cancel()
    }
}

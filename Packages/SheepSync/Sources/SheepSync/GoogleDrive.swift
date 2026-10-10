import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A signed-in Google account: turns the stored refresh token into short-
/// lived access tokens, one refresh at a time.
public actor GoogleAccount {
    public let client: GoogleClient
    private var refreshToken: String
    private var accessToken: String?
    private var expiry = Date.distantPast
    private let session: URLSession
    /// Called when Google rotates the refresh token, so it can be stored.
    private let onNewRefreshToken: @Sendable (String) -> Void
    /// One refresh at a time: callers arriving while one is in flight wait
    /// for it (an actor alone does not give that — it is reentrant at the
    /// await, and two refreshes could each rotate the token).
    private var refreshing: Task<String, Error>?
    /// Set by `revoke`: a refresh finishing afterwards must not store a
    /// rotated token back into the Keychain the sign-out just cleared.
    private var revoked = false

    public init(client: GoogleClient, refreshToken: String, session: URLSession = .shared,
                onNewRefreshToken: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client
        self.refreshToken = refreshToken
        self.session = session
        self.onNewRefreshToken = onNewRefreshToken
    }

    public func token() async throws -> String {
        if revoked { throw GoogleOAuth.OAuthError.invalidGrant }
        if let accessToken, Date() < expiry { return accessToken }
        if let refreshing { return try await refreshing.value }
        let request = GoogleOAuth.refreshRequest(client: client, refreshToken: refreshToken)
        let session = self.session
        let task = Task { () throws -> String in
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer = try GoogleOAuth.parseTokenResponse(data, status: status)
            self.store(answer)
            return answer.accessToken
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func store(_ answer: GoogleOAuth.TokenResponse) {
        guard !revoked else { return }
        accessToken = answer.accessToken
        // A minute early: a token that expires in flight is a 401 for nothing.
        expiry = Date().addingTimeInterval(TimeInterval(max(answer.expiresIn - 60, 30)))
        if let rotated = answer.refreshToken, rotated != refreshToken {
            refreshToken = rotated
            onNewRefreshToken(rotated)
        }
    }

    /// The signed-in account's address and photo (`userinfo`), or nil.
    public func profile() async -> GoogleOAuth.Profile? {
        guard let token = try? await token() else { return nil }
        var request = URLRequest(url: GoogleOAuth.userInfoEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GoogleOAuth.parseUserInfo(data)
    }

    /// After a 401: the next `token()` asks Google again.
    public func invalidate() { accessToken = nil; expiry = .distantPast }

    /// Sign-out: tell Google to forget this grant (best effort).
    public func revoke() async {
        revoked = true
        accessToken = nil
        _ = try? await session.data(for: GoogleOAuth.revokeRequest(token: refreshToken))
    }
}

/// Google Drive's per-app hidden folder as a `SyncBackend`. Only files this
/// Google client created are visible to it, and the user's own Drive files
/// are out of reach entirely (scope `drive.appdata`).
public actor GoogleDriveBackend: SyncBackend {
    static var api: String { GoogleOAuth.endpoint("/drive/v3/files", "https://www.googleapis.com/drive/v3/files").absoluteString }
    static var upload: String { GoogleOAuth.endpoint("/upload/drive/v3/files", "https://www.googleapis.com/upload/drive/v3/files").absoluteString }

    private let account: GoogleAccount
    private let session: URLSession
    /// name → Drive file id, learned from listings.
    private var ids: [String: String] = [:]

    public init(account: GoogleAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    public func read(_ name: String) async throws -> Data? {
        // Twice at most: a cached id that 404s means the file was replaced
        // (another Mac reset the vault), NOT that there is no file — so
        // forget the id and look again before answering "none".
        for _ in 0..<2 {
            guard let id = try await fileID(name) else { return nil }
            var request = URLRequest(url: URL(string: "\(Self.api)/\(id)?alt=media")!)
            do {
                return try await send(&request)
            } catch SyncBackendError.http(404, _) {
                ids[name] = nil
            }
        }
        return nil
    }

    public func write(_ name: String, _ data: Data) async throws {
        if let id = try await fileID(name) {
            var request = URLRequest(url: URL(string: "\(Self.upload)/\(id)?uploadType=media")!)
            request.httpMethod = "PATCH"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
            do {
                _ = try await send(&request)
                return
            } catch SyncBackendError.http(404, _) {
                ids[name] = nil   // deleted elsewhere: create it again below
            }
        }
        var request = Self.createRequest(name: name, data: data, boundary: "sheepsync-\(UUID().uuidString)")
        let answer = try await send(&request)
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let id = object["id"] as? String else { throw SyncBackendError.badResponse("create") }
        // Two Macs creating the same name at once make two files, and each
        // would go on using its own. Everyone settles on the OLDEST one:
        // if that is not ours, write there too and drop ours.
        let all = try await listIDs(name)
        if let oldest = all.first, oldest != id {
            var patch = URLRequest(url: URL(string: "\(Self.upload)/\(oldest)?uploadType=media")!)
            patch.httpMethod = "PATCH"
            patch.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            patch.httpBody = data
            _ = try await send(&patch)
            var drop = URLRequest(url: URL(string: "\(Self.api)/\(id)")!)
            drop.httpMethod = "DELETE"
            _ = try? await send(&drop)
            ids[name] = oldest
        } else {
            ids[name] = id
        }
    }

    public func delete(_ name: String) async throws {
        // Every copy: two Macs creating the same file at once leaves two.
        for id in try await listIDs(name) {
            var request = URLRequest(url: URL(string: "\(Self.api)/\(id)")!)
            request.httpMethod = "DELETE"
            do { _ = try await send(&request) } catch SyncBackendError.http(404, _) {}
        }
        ids[name] = nil
    }

    static func createRequest(name: String, data: Data, boundary: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(upload)?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = try! JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]],
                                                    options: [.sortedKeys])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += metadata
        body += Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }

    public func versions(_ names: [String]) async throws -> [String: String] {
        var parts = URLComponents(string: Self.api)!
        let clause = names.map { "name = '\(Self.quote($0))'" }.joined(separator: " or ")
        parts.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "(\(clause)) and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,version,createdTime)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "50"),
        ]
        var request = URLRequest(url: parts.url!)
        let answer = try await send(&request)
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let files = object["files"] as? [[String: Any]] else { throw SyncBackendError.badResponse("list") }
        var out: [String: String] = [:]
        // Oldest copy per name, the same one `fileID` picks.
        for file in files {
            guard let name = file["name"] as? String, out[name] == nil, let id = file["id"] as? String else { continue }
            // The id is part of it: Drive counts versions PER FILE, so a
            // file deleted and re-created (a reset on another Mac) can come
            // back with the very version number we cached.
            let version = (file["version"] as? String) ?? (file["version"] as? NSNumber)?.stringValue ?? "?"
            out[name] = "\(id)/\(version)"
            ids[name] = id
        }
        return out
    }

    static func quote(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    static func listURL(name: String) -> URL {
        var parts = URLComponents(string: api)!
        let quoted = quote(name)
        parts.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "name = '\(quoted)' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,createdTime)"),
            // Oldest first, a fixed order every Mac agrees on — not
            // modifiedTime, which would make the chosen copy flip.
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        return parts.url!
    }

    private func fileID(_ name: String) async throws -> String? {
        if let id = ids[name] { return id }
        let id = try await listIDs(name).first
        ids[name] = id
        return id
    }

    /// Oldest first.
    private func listIDs(_ name: String) async throws -> [String] {
        var request = URLRequest(url: Self.listURL(name: name))
        let answer = try await send(&request)
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let files = object["files"] as? [[String: Any]] else { throw SyncBackendError.badResponse("list") }
        return files.compactMap { $0["id"] as? String }
    }

    /// One request with a bearer token; on 401 the token is refreshed and
    /// the request tried once more.
    private func send(_ request: inout URLRequest) async throws -> Data {
        for attempt in 0..<2 {
            let token: String
            do { token = try await account.token() } catch GoogleOAuth.OAuthError.invalidGrant {
                throw SyncBackendError.notAuthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { return data }
            if status == 401, attempt == 0 { await account.invalidate(); continue }
            if status == 401 { throw SyncBackendError.notAuthorized }
            let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "request failed"
            throw SyncBackendError.http(status, message)
        }
        throw SyncBackendError.notAuthorized
    }
}

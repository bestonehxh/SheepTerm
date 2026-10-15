// The share-link Drive calls over URLSession. Apple only: Windows brings its own `ShareBackend` / `ShareDownloader` through `GoogleTransport`.
#if !os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The sender: files the app creates in the user's own Drive (scope `drive.file`, the only share scope there is), in a folder
/// "SheepTerm Shares" the app creates. The single permission is `type=anyone, role=reader, allowFileDiscovery=false`: the file is ciphertext
/// that needs the link key and the passphrase.
public actor GoogleDriveShareBackend: ShareBackend {
    static var api: String { GoogleOAuth.endpoint("/drive/v3/files", "https://www.googleapis.com/drive/v3/files").absoluteString }
    static var upload: String { GoogleOAuth.endpoint("/upload/drive/v3/files", "https://www.googleapis.com/upload/drive/v3/files").absoluteString }
    public static let folderName = "SheepTerm Shares"

    private let account: any GoogleAccountProtocol
    private let session: URLSession
    private var folderID: String?

    public init(account: any GoogleAccountProtocol, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    public func upload(name: String, data: Data) async throws -> String {
        let folder = try await ensureFolder()
        var request = Self.uploadRequest(name: name, folderID: folder, data: data, boundary: "sheepshare-\(UUID().uuidString)")
        let answer = try await send(&request)
        guard let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
              let id = object["id"] as? String else { throw SyncBackendError.badResponse("create") }
        return id
    }

    public func makePublic(fileID: String) async throws {
        var request = Self.permissionRequest(fileID: fileID)
        _ = try await send(&request)
    }

    public func delete(fileID: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.api)/\(Self.escape(fileID))")!)
        request.httpMethod = "DELETE"
        do { _ = try await send(&request) } catch SyncBackendError.http(404, _) {}
    }

    // MARK: Requests (static so tests can read exactly what would be sent)

    static func escape(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id }

    static func permissionRequest(fileID: String) -> URLRequest {
        var parts = URLComponents(string: "\(api)/\(escape(fileID))/permissions")!
        parts.queryItems = [URLQueryItem(name: "fields", value: "id")]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONSerialization.data(
            withJSONObject: ["type": "anyone", "role": "reader", "allowFileDiscovery": false] as [String: Any], options: [.sortedKeys])
        return request
    }

    static func uploadRequest(name: String, folderID: String, data: Data, boundary: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(upload)?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = try! JSONSerialization.data(withJSONObject: ["name": name, "parents": [folderID]], options: [.sortedKeys])
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body += metadata
        body += Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body += data
        body += Data("\r\n--\(boundary)--\r\n".utf8)
        request.httpBody = body
        return request
    }

    private func ensureFolder() async throws -> String {
        if let folderID { return folderID }
        var parts = URLComponents(string: Self.api)!
        parts.queryItems = [
            URLQueryItem(name: "q", value: "name = '\(Self.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "5"),
        ]
        var list = URLRequest(url: parts.url!)
        let answer = try await send(&list)
        if let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any],
           let id = (object["files"] as? [[String: Any]])?.first?["id"] as? String {
            folderID = id
            return id
        }
        var create = URLRequest(url: URL(string: "\(Self.api)?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: ["name": Self.folderName,
                                                                       "mimeType": "application/vnd.google-apps.folder"])
        let made = try await send(&create)
        guard let object = (try? JSONSerialization.jsonObject(with: made)) as? [String: Any],
              let id = object["id"] as? String else { throw SyncBackendError.badResponse("folder") }
        folderID = id
        return id
    }

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

/// The recipient: Drive's public download page, no token and no scope (an API key would be needed for the v3 API, which is why this is not
/// `alt=media`). Small files answer with the bytes at once; a larger one answers with an HTML "can't scan for viruses" page whose form is
/// followed once.
public struct PublicDriveDownloader: ShareDownloader {
    static var endpoint: URL { GoogleOAuth.endpoint("/download", "https://drive.usercontent.google.com/download") }
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(fileID: String) async throws -> Data {
        var items = [URLQueryItem(name: "id", value: fileID), URLQueryItem(name: "export", value: "download")]
        for attempt in 0..<2 {
            var parts = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
            parts.queryItems = items
            var request = URLRequest(url: parts.url!)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw SyncBackendError.http(status, "download failed") }
            guard Self.looksLikeHTML(data) else { return data }
            // The confirm page: carry its hidden inputs (id, export, confirm, uuid …) into one more request.
            guard attempt == 0, let form = Self.hiddenInputs(in: data), form["confirm"] != nil else {
                throw SyncBackendError.http(404, "not a downloadable file")
            }
            items = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        throw SyncBackendError.badResponse("download")
    }

    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    static func hiddenInputs(in data: Data) -> [String: String]? {
        let text = String(decoding: data.prefix(200_000), as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"<input[^>]*type="hidden"[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        var out: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let tag = String(text[Range(match.range, in: text)!])
            func attribute(_ name: String) -> String? {
                guard let r = tag.range(of: "\(name)=\"") else { return nil }
                let rest = tag[r.upperBound...]
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                return String(rest[..<end]).replacingOccurrences(of: "&amp;", with: "&")
            }
            if let name = attribute("name"), let value = attribute("value") { out[name] = value }
        }
        return out.isEmpty ? nil : out
    }
}
#endif

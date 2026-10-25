import Foundation
@_exported import SheepWebScripts

/// The page a web tab shows when a page can't be loaded (5.0 (53), from another Sheep app):
/// Safari's look — a plain grey page, a grey bold title — with Chrome's plain words under it:
/// what went wrong in one sentence, what to try, and Chrome's error code (the one people search
/// for). Loaded with `loadSimulatedRequest` under the failing address, so the URL field still
/// shows it and Reload / Return / the page coming back online load the REAL address again.
/// SheepTerm ARCHITECTURE.md §21; the other Sheep apps use the same page.
public nonisolated enum WebErrorPage {
    /// The page's web process kept crashing (not a network error).
    public static let crashDomain = "SheepTerm.PageCrash"

    /// Return on the page asks for this (handled by the tab's navigation policy; never reaches
    /// the network, never another app).
    public static let retryScheme = "sheep-retry"

    public struct Description: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var tips: [String] = []
        public var code: String?
        /// Offline: the page retries by itself when the Mac comes back online.
        public var offline = false
    }

    /// A navigation error worth a page: not a cancel (another load replaced it), not a load
    /// that became a download (WebKit 102).
    public static func showsPage(for error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return false }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return false }
        return true
    }

    /// `marker`: an app-chosen secret written into the page (`<meta name="sheep-error">`), so the app can
    /// tell its own error page from a real page restored at the same history entry (the page cannot know it).
    public static func html(for error: NSError, url: URL, marker: String? = nil) -> String {
        let host = escape(url.host ?? url.absoluteString)
        // The address as Safari writes it there: no "http://" / "https://".
        let info = describe(error, host: host, page: escape(shown(url)))
        let tips = info.tips.isEmpty ? "" :
            "<div class=\"tips\"><p>\(escape(L("Try:")))</p><ul>"
            + info.tips.map { "<li>\(escape($0))</li>" }.joined() + "</ul></div>"
        let code = info.code.map { "<p class=\"code\">\(escape($0))</p>" } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <meta name="viewport" content="width=device-width">\(marker.map { "<meta name=\"sheep-error\" content=\"\(escape($0))\">" } ?? "")<title>\(info.title)</title>
        <style>
        html,body{height:100%;margin:0}
        body{font:14px -apple-system,system-ui,sans-serif;display:grid;place-items:center;background:#f5f5f5;color:#6e6e73;
             cursor:default;padding:0 24px}
        .box{max-width:620px;text-align:center;margin-top:-4vh}
        h1{font-size:30px;font-weight:700;letter-spacing:-.01em;color:#8a8a8e;margin:0 0 14px;-webkit-user-select:none;user-select:none}
        p{margin:0;line-height:1.45;font-size:14.5px}
        .tips{display:inline-block;text-align:left;margin-top:18px}
        .tips ul{margin:4px 0 0;padding-left:20px;line-height:1.6}
        .code{margin-top:18px;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;color:#a1a1a6;letter-spacing:.02em}
        @media (prefers-color-scheme: dark){ body{background:#1e1e1e;color:#98989d} h1{color:#8e8e93} .code{color:#6e6e73} }
        </style></head><body><div class="box"><h1>\(info.title)</h1><p>\(info.detail)</p>\(tips)\(code)</div>
        <script>
        const go = () => { location.href = '\(retryScheme):'; };
        addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
        \(info.offline ? "addEventListener('online', go);" : "")
        </script></body></html>
        """
    }

    /// Every error a page load can end with. `host` and `page` arrive HTML-escaped; the
    /// sentences are the app's own, so `html` escapes only what came from outside.
    public static func describe(_ error: NSError, host: String, page: String) -> Description {
        let cantOpen = L("Can’t Open This Page")
        let cantReach = L("Can’t Connect to the Server")
        let cantFind = L("Can’t Find the Server")
        let connection = L("Checking the network connection")
        let firewall = L("Checking the proxy and the firewall")
        let vpn = L("If it’s a company address, connecting to that network or its VPN first")
        if error.domain == crashDomain {
            return Description(title: cantOpen, detail: L("A problem repeatedly occurred on “\(page)”."),
                               tips: [L("Reloading the page")], code: "RESULT_CODE_KILLED")
        }
        if error.domain == "WebKitErrorDomain" {
            switch error.code {
            case 103:   // a port browsers never connect to (SMTP, IRC…)
                return Description(title: cantOpen,
                                   detail: L("Pages on this port aren’t opened, because the service there isn’t a website."),
                                   code: "ERR_UNSAFE_PORT")
            case 104:   // the app's own content blocker 
                return Description(title: cantOpen, detail: L("\(host) is blocked by the content blocker."),
                                   code: "ERR_BLOCKED_BY_CLIENT")
            case 105, 106:
                return Description(title: cantOpen,
                                   detail: L("Access to \(host) is restricted on this Mac (Screen Time or a content filter)."),
                                   code: "ERR_BLOCKED_BY_ADMINISTRATOR")
            case 101:
                return Description(title: cantOpen, detail: L("“\(page)” isn’t an address a web page can have."),
                                   tips: [L("Checking the spelling of the address")], code: "ERR_UNKNOWN_URL_SCHEME")
            default:
                return Description(title: cantOpen, detail: L("The page “\(page)” can’t be opened."),
                                   code: "ERR_FAILED (\(error.domain) \(error.code))")
            }
        }
        guard error.domain == NSURLErrorDomain else {
            return Description(title: cantOpen,
                               detail: L("The page “\(page)” can’t be opened.") + " " + escape(error.localizedDescription),
                               code: "ERR_FAILED (\(error.domain) \(error.code))")
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff, NSURLErrorCallIsActive:
            return Description(title: L("You Are Not Connected to the Internet"),
                               detail: L("This page can’t be displayed because this Mac is currently offline."),
                               tips: [L("Checking the Wi-Fi or network cable")],
                               code: "ERR_INTERNET_DISCONNECTED", offline: true)
        case NSURLErrorCannotFindHost:
            return Description(title: cantFind, detail: L("\(host)’s server IP address could not be found (DNS)."),
                               tips: [L("Checking the spelling of the address"), connection,
                                      L("Checking the proxy, firewall and DNS settings"), vpn],
                               code: "DNS_PROBE_FINISHED_NXDOMAIN")
        case NSURLErrorDNSLookupFailed:
            return Description(title: cantFind, detail: L("The DNS lookup for \(host) failed: the DNS server didn’t answer."),
                               tips: [connection, L("Checking the proxy, firewall and DNS settings"), vpn],
                               code: "ERR_NAME_RESOLUTION_FAILED")
        case NSURLErrorCannotConnectToHost:
            // A device's web UI: the usual reason is that its HTTP/HTTPS server is off, or the other scheme is the one on.
            return Description(title: cantReach, detail: L("\(host) refused to connect."),
                               tips: [L("Checking that the device’s web server (HTTP or HTTPS) is turned on"),
                                      L("Trying http:// instead of https:// (or the other way round)"), firewall, vpn],
                               code: "ERR_CONNECTION_REFUSED")
        case NSURLErrorTimedOut:
            return Description(title: cantReach, detail: L("\(host) took too long to respond."),
                               tips: [L("Checking that the device answers ping"), connection, firewall, vpn],
                               code: "ERR_CONNECTION_TIMED_OUT")
        case NSURLErrorNetworkConnectionLost:
            return Description(title: cantOpen, detail: L("The connection to \(host) was reset."),
                               tips: [connection, firewall], code: "ERR_CONNECTION_RESET")
        case NSURLErrorSecureConnectionFailed, NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return Description(title: cantOpen,
                               detail: L("\(host) can’t provide a secure connection: it sent a response that can’t be accepted."),
                               tips: [L("Checking the time and date on this Mac"),
                                      L("If it’s your own device, updating its TLS settings or firmware")],
                               code: "ERR_SSL_PROTOCOL_ERROR")
        case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
            return Description(title: cantOpen,
                               detail: L("Your connection to \(host) isn’t private: its certificate has expired or isn’t valid yet."),
                               tips: [L("Checking the time and date on this Mac")], code: "NET::ERR_CERT_DATE_INVALID")
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
            return Description(title: cantOpen,
                               detail: L("Your connection to \(host) isn’t private: its certificate isn’t trusted."),
                               tips: [L("Reloading the page")], code: "NET::ERR_CERT_AUTHORITY_INVALID")
        case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return Description(title: cantOpen,
                               detail: L("\(host) didn’t accept your login certificate, or one wasn’t provided."),
                               tips: [L("Checking that the certificate is in your keychain")],
                               code: "ERR_BAD_SSL_CLIENT_AUTH_CERT")
        case NSURLErrorHTTPTooManyRedirects:
            return Description(title: cantOpen, detail: L("\(host) redirected you too many times."),
                               tips: [L("Clearing the website’s cookies and data")],
                               code: "ERR_TOO_MANY_REDIRECTS")
        case NSURLErrorRedirectToNonExistentLocation:
            return Description(title: cantOpen, detail: L("\(host) redirected to an address that doesn’t exist."),
                               code: "ERR_INVALID_REDIRECT")
        case NSURLErrorBadServerResponse:
            return Description(title: cantOpen, detail: L("\(host) sent an invalid response."), code: "ERR_INVALID_RESPONSE")
        case NSURLErrorZeroByteResource:
            return Description(title: cantOpen, detail: L("\(host) didn’t send any data."), code: "ERR_EMPTY_RESPONSE")
        case NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData, NSURLErrorCannotParseResponse:
            return Description(title: cantOpen, detail: L("\(host) sent data that can’t be read."),
                               code: "ERR_CONTENT_DECODING_FAILED")
        case NSURLErrorDataLengthExceedsMaximum:
            return Description(title: cantOpen, detail: L("The page at \(host) is too large to open."), code: "ERR_FILE_TOO_BIG")
        case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
            return Description(title: cantOpen, detail: L("\(host) needs a user name and password, and none was accepted."),
                               tips: [L("Reloading the page and signing in again")], code: "ERR_INVALID_AUTH_CREDENTIALS")
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL:
            return Description(title: cantOpen, detail: L("“\(page)” isn’t an address a web page can have."),
                               tips: [L("Checking the spelling of the address")], code: "ERR_INVALID_URL")
        case NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory:
            return Description(title: cantOpen, detail: L("The file at “\(page)” couldn’t be found. It may have been moved, renamed or deleted."),
                               code: "ERR_FILE_NOT_FOUND")
        case NSURLErrorNoPermissionsToReadFile:
            return Description(title: cantOpen, detail: L("The file at “\(page)” can’t be read."), code: "ERR_ACCESS_DENIED")
        case NSURLErrorResourceUnavailable, NSURLErrorCannotLoadFromNetwork:
            return Description(title: cantOpen, detail: L("The page at \(host) isn’t available right now."),
                               tips: [connection], code: "ERR_CACHE_MISS")
        default:
            return Description(title: cantOpen,
                               detail: L("The page “\(page)” can’t be opened.") + " " + escape(error.localizedDescription),
                               tips: [connection], code: "ERR_FAILED (\(error.code))")
        }
    }

    /// The address as Safari writes it on the page: no scheme, no user:password@, no lone "/".
    static func shown(_ url: URL) -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host, !host.isEmpty else {
            return url.absoluteString
        }
        var text = host.contains(":") ? "[\(host)]" : host
        if let port = parts.port { text += ":\(port)" }
        let path = parts.path.removingPercentEncoding ?? parts.path
        if path != "/" { text += path }
        if let query = parts.percentEncodedQuery { text += "?" + query }
        return text
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

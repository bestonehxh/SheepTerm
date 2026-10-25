import Foundation
import SheepWeb
import XCTest

final class WebSuggestTests: XCTestCase {
    /// The owner's rule: a private address never goes to Google.
    func testPrivateAddressesStayHome() {
        let home = ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.9.9", "192.168.222.254", "192.168.1.1:8443",
                    "192.168.1.1/login", "169.254.10.1", "127.0.0.1", "100.64.0.1", "100.127.255.1", "0.0.0.0",
                    "[fd00::1]", "[fd00::1]:443/x", "fe80::1", "fe80::1%en0", "::1", "fc00::abcd", "::ffff:192.168.1.1",
                    "localhost", "localhost:8080", "sw1.local", "fw.lab.internal", "core.lan", "nas.home.arpa",
                    // Partly typed.
                    "192.168.", "192.168.1", "10.0", "172.16.", "172.", "192.", "169.254.", "100.64.",
                    // Inside a phrase.
                    "ping 10.1.1.1", "show 192.168.1.1 interface",
                    // Review 5.0 (53): forms WebKit itself reads as an address, wrapped, or partly typed.
                    "0300.0250.1.1", "3232235777", "0xC0A80101", "0xc0.0xa8.1.1", "192.168.257", "１０.０.０.１",
                    "10。0。0。1", "10.0.0.1,", "(10.0.0.1)", "http:10.0.0.1", "10.0.0.1\\admin", "10.0.0.1:8080:",
                    "ping\u{00A0}10.0.0.1", "core-sw1:8443", "host.localdomain", "sw1.corp", "172.1", "192.16",
                    "[::ffff:10.0.0.1]", "010.0.0.1", "10.0.0.1.", "100.6", "169.2", "nas.home", "fs.intranet"]
        for text in home { XCTAssertFalse(WebSuggest.mayAsk(text), text) }
    }

    func testPublicTextMayGo() {
        let out = ["fortigate", "aruba cx 6300 release notes", "8.8.8.8", "1.1.1.1", "172.32.0.1", "100.128.0.1",
                   "192.169.1.1", "2001:4860:4860::8888", "example.com", "show interface brief", "10 best switches",
                   "2.5", "ไทย", "華為 交換機"]
        for text in out { XCTAssertTrue(WebSuggest.mayAsk(text), text) }
    }

    func testKnownHostsStayHome() {
        XCTAssertFalse(WebSuggest.mayAsk("acme-core-fw01 config", known: ["ACME-CORE-FW01"]))
        XCTAssertFalse(WebSuggest.mayAsk("fw01.customer.co.th", known: ["fw01.customer.co.th"]))
        XCTAssertTrue(WebSuggest.mayAsk("fortigate", known: ["ACME-CORE-FW01", "ab"]))   // under 3 letters: ignored
    }

    func testNeverLinksOrAccounts() {
        for text in ["https://example.com/?token=abc", "http://8.8.8.8/", "user@example.com", "file:///etc/passwd",
                     "about:blank", "", "   ", String(repeating: "a", count: 201)] {
            XCTAssertFalse(WebSuggest.mayAsk(text), text)
        }
    }

    func testParse() {
        XCTAssertEqual(WebSuggest.parse(Data(#"["for",["fortigate","fortinet"]]"#.utf8)), ["fortigate", "fortinet"])
        XCTAssertEqual(WebSuggest.parse(Data("not json".utf8)), [])
        XCTAssertEqual(WebSuggest.parse(Data(#"["q"]"#.utf8)), [])
        XCTAssertEqual(WebSuggest.parse(nil), [])
        let many = (0..<30).map { "\"w\($0)\"" }.joined(separator: ",")
        XCTAssertEqual(WebSuggest.parse(Data("[\"q\",[\(many)]]".utf8)).count, 10)
    }

    func testFetchRefusesPrivateWithoutNetwork() {
        XCTAssertNil(WebSuggest.fetch("192.168.1.1") { _ in })
    }
}

final class WebErrorPageTests: XCTestCase {
    private func code(_ domain: String, _ code: Int) -> String? {
        WebErrorPage.describe(NSError(domain: domain, code: code), host: "h", page: "p").code
    }

    func testCodes() {
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorCannotConnectToHost), "ERR_CONNECTION_REFUSED")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorTimedOut), "ERR_CONNECTION_TIMED_OUT")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorCannotFindHost), "DNS_PROBE_FINISHED_NXDOMAIN")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorNotConnectedToInternet), "ERR_INTERNET_DISCONNECTED")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorServerCertificateUntrusted), "NET::ERR_CERT_AUTHORITY_INVALID")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate), "NET::ERR_CERT_DATE_INVALID")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorSecureConnectionFailed), "ERR_SSL_PROTOCOL_ERROR")
        XCTAssertEqual(code(NSURLErrorDomain, NSURLErrorHTTPTooManyRedirects), "ERR_TOO_MANY_REDIRECTS")
        XCTAssertEqual(code("WebKitErrorDomain", 103), "ERR_UNSAFE_PORT")
        XCTAssertEqual(code("WebKitErrorDomain", 104), "ERR_BLOCKED_BY_CLIENT")
        XCTAssertEqual(code(WebErrorPage.crashDomain, 1), "RESULT_CODE_KILLED")
        XCTAssertEqual(code(NSURLErrorDomain, -123456), "ERR_FAILED (-123456)")
        XCTAssertTrue(WebErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                                            host: "h", page: "p").offline)
        // A device's web UI that refuses: the tips say what to check on a device.
        let refused = WebErrorPage.describe(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost), host: "h", page: "p")
        XCTAssertTrue(refused.tips.contains { $0.contains("HTTP") })
    }

    func testNoPageForCancelOrDownload() {
        XCTAssertFalse(WebErrorPage.showsPage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertFalse(WebErrorPage.showsPage(for: NSError(domain: "WebKitErrorDomain", code: 102)))
        XCTAssertTrue(WebErrorPage.showsPage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }

    /// Nothing from outside reaches the page unescaped: the host, the address, the error's text.
    func testEscaping() {
        let url = URL(string: "http://a%3Cb.example/%3Cscript%3Ealert(1)%3C/script%3E")!
        let html = WebErrorPage.html(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: url)
        XCTAssertFalse(html.contains("<script>alert"))
        let odd = NSError(domain: "x<y", code: 1, userInfo: [NSLocalizedDescriptionKey: "<img src=x onerror=alert(1)>"])
        let other = WebErrorPage.html(for: odd, url: URL(string: "http://10.0.0.1/")!)
        XCTAssertFalse(other.contains("<img"))
        XCTAssertFalse(other.contains("x<y"))
        // Return retries through the app's own scheme, never anything the page names.
        XCTAssertTrue(html.contains("location.href = '\(WebErrorPage.retryScheme):'"))
        XCTAssertTrue(other.contains("10.0.0.1"))
    }

    /// Review 5.0 (53) #8: the app's marker, so a real page restored at an error page's entry is told apart.
    func testMarker() {
        let page = WebErrorPage.html(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: URL(string: "http://10.0.0.1/")!,
                                     marker: "abc\"<x")
        XCTAssertTrue(page.contains(#"<meta name="sheep-error" content="abc&quot;&lt;x">"#))
        XCTAssertFalse(WebErrorPage.html(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: URL(string: "http://10.0.0.1/")!)
            .contains("sheep-error"))
    }

    func testOfflineRetriesWhenOnline() {
        let page = WebErrorPage.html(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                                     url: URL(string: "http://10.0.0.1/")!)
        XCTAssertTrue(page.contains("addEventListener('online', go)"))
        let other = WebErrorPage.html(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: URL(string: "http://10.0.0.1/")!)
        XCTAssertFalse(other.contains("'online'"))
    }

    func testLocalisedInEveryLanguage() throws {
        // Each language the catalog carries has every key the page uses.
        let bundle = SheepWebResources.bundle
        for language in ["de", "es", "fr", "pt-BR", "ru", "ja", "ko", "zh-Hans"] {
            let path = try XCTUnwrap(bundle.path(forResource: language, ofType: "lproj"), language)
            let localized = try XCTUnwrap(Bundle(path: path))
            let title = localized.localizedString(forKey: "Can’t Connect to the Server", value: "??", table: nil)
            XCTAssertNotEqual(title, "??", language)
            XCTAssertNotEqual(title, "Can’t Connect to the Server", language)
        }
    }
}

final class WebFaviconRulesTests: XCTestCase {
    private let page = URL(string: "https://192.168.222.1:8443/ng/page")!

    func testSameOriginOnlyBestFirst() {
        let links: [(href: String, sizes: String)] = [
            ("https://192.168.222.1:8443/small.png", "16x16"),
            ("https://192.168.222.1:8443/good.png", "32x32"),
            ("https://cdn.example/evil.png", "32x32"),
            ("http://192.168.222.1:8443/http.png", "32x32"),
            ("https://192.168.222.1/otherport.png", "32x32"),
            ("https://192.168.222.1:8443/big.png", "180x180"),
            ("javascript:alert(1)", ""),
        ]
        XCTAssertEqual(WebFaviconRules.candidates(links: links, page: page), [
            "https://192.168.222.1:8443/good.png", "https://192.168.222.1:8443/big.png",
            "https://192.168.222.1:8443/small.png", "https://192.168.222.1:8443/favicon.ico",
        ])
    }

    func testFaviconIcoAlwaysTriedAndCapped() {
        XCTAssertEqual(WebFaviconRules.candidates(links: [], page: page), ["https://192.168.222.1:8443/favicon.ico"])
        let many = (0..<10).map { (href: "https://192.168.222.1:8443/i\($0).png", sizes: "32x32") }
        XCTAssertEqual(WebFaviconRules.candidates(links: many, page: page).count, 5)
        // The default port written or not is the same origin.
        XCTAssertEqual(WebFaviconRules.candidates(links: [("https://fw.lab:443/a.png", "")], page: URL(string: "https://fw.lab/")!).first,
                       "https://fw.lab:443/a.png")
    }

    func testPNGFromThePage() throws {
        XCTAssertNil(WebFaviconRules.png(fromDataURL: "data:image/svg+xml;base64,AAAA"))
        XCTAssertNil(WebFaviconRules.png(fromDataURL: "data:image/png;base64," + String(repeating: "A", count: 400_000)))
        // A real 1×1 PNG decodes; text pretending to be one does not.
        let onePixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        let png = try XCTUnwrap(WebFaviconRules.png(fromDataURL: "data:image/png;base64," + onePixel))
        XCTAssertNotNil(WebFaviconRules.decode(png))
        XCTAssertNil(WebFaviconRules.decode(Data("<svg/>".utf8)))
    }
}

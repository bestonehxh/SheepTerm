import AppKit
import ImageIO

/// Page-drawn site icons (SheepTerm 5.0 (53), shared): which icon URLs to try (same origin
/// as the page only), the scripts that make the PAGE draw one into a 64 px canvas — so it goes
/// through WebKit's own connection and the app never calls another host for it — and what the
/// page may hand back. Each app keeps its own cache.
public nonisolated enum WebFaviconRules {
    public static let maxPNGBytes = 150_000

    /// The page's icon links, same origin as `page` only (http/https), best first — a 32–64 px
    /// icon, then larger, then smaller (an SVG counts as 48) — then `/favicon.ico`; at most 5.
    public static func candidates(links: [(href: String, sizes: String)], page: URL) -> [String] {
        func sameOrigin(_ url: URL) -> Bool {
            url.scheme?.lowercased() == page.scheme?.lowercased() && url.host?.lowercased() == page.host?.lowercased()
                && (url.port ?? defaultPort(url)) == (page.port ?? defaultPort(page))
        }
        var ranked: [(String, Int)] = []
        for link in links {
            guard let url = URL(string: link.href), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  sameOrigin(url) else { continue }
            let size = Int(link.sizes.lowercased().split(separator: "x").first ?? "") ?? (url.pathExtension.lowercased() == "svg" ? 48 : 16)
            let rank = size >= 32 && size <= 64 ? 0 : size > 64 ? 1 : 2
            ranked.append((url.absoluteString, rank * 10_000 + abs(size - 32)))
        }
        var out: [String] = []
        for (url, _) in ranked.enumerated().sorted(by: { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }).map(\.element)
        where !out.contains(url) { out.append(url) }
        if let root = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL.absoluteString, !out.contains(root) { out.append(root) }
        return Array(out.prefix(5))
    }

    /// The canvas's answer: a PNG data URL of a sane size, else nil.
    public static func png(fromDataURL value: String) -> Data? {
        let prefix = "data:image/png;base64,"
        guard value.hasPrefix(prefix), value.count < maxPNGBytes * 4 / 3 + prefix.count + 4 else { return nil }
        return Data(base64Encoded: String(value.dropFirst(prefix.count)))
    }

    private static func defaultPort(_ url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// PNG only (the page's canvas always writes one), decoded by ImageIO straight to a
    /// small thumbnail — a "30000×30000" image never becomes a full bitmap.
    public static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png" else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 64,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // 64 px drawn at 32 pt: crisp at 12–16 pt on Retina.
        return NSImage(cgImage: cg, size: NSSize(width: 32, height: 32))
    }

    /// Runs in the app's own content world with `urls` (from `WebFaviconRules.candidates`):
    /// the first one that loads, drawn into a 64 px canvas, as a PNG data URL (nil = none).
    public static let pageScript = """
    const load = src => new Promise((ok, no) => {
      const img = new Image();
      const timer = setTimeout(() => no('timeout'), 5000);
      img.onload = () => { clearTimeout(timer); ok(img); };
      img.onerror = () => { clearTimeout(timer); no('error'); };
      img.src = src;
    });
    for (const u of urls) {
      try {
        if (new URL(u).origin !== location.origin) continue;
        const img = await load(u);
        if (!img.naturalWidth && !img.width) continue;
        const c = document.createElement('canvas');
        c.width = 64; c.height = 64;
        c.getContext('2d').drawImage(img, 0, 0, 64, 64);
        return c.toDataURL('image/png');
      } catch (e) {}
    }
    return null;
    """

    /// Lists the page's icon links (href, sizes) — run in the app's own content world.
    public static let linksScript = """
    return [...document.querySelectorAll('link[rel~="icon"], link[rel="shortcut icon"], link[rel="apple-touch-icon"]')]
      .slice(0, 20).map(l => [l.href, (l.sizes && l.sizes.value) || '']);
    """
}

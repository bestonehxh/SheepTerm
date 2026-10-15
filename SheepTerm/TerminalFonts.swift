import Foundation
import CoreText

/// The terminal font list (5.0 (17)): the same curated shape as SheepTerm for
/// Windows (Settings > Font there) so a family picked on one side means
/// something on the other.
///
///   1. the system face (`""` = SF Mono here, the platform default on Windows)
///   2. this platform's terminal faces worth having — only when installed
///   3. the Linux classics BUNDLED with the app on both platforms
///      (DejaVu Sans Mono = Debian, Liberation Mono = Fedora, Fira Mono =
///      Mozilla; Regular + Bold; licences beside them in Resources)
///   4. any other installed fixed-pitch family (a submenu in View), so a font
///      the user installed themselves is still reachable
///
/// Pure (Foundation + CoreText only) so the harness can test it and the
/// Windows port can share the list.
enum TerminalFonts {
    /// The bundled families, in menu order. Must match the `.ttf` files in
    /// `SheepTerm/Fonts` (the harness registers them and checks the names).
    static let bundled = ["DejaVu Sans Mono", "Liberation Mono", "Fira Mono"]
    /// Terminal faces worth having, in menu order; shown only when installed.
    /// The Mac's own first, then the Windows list (Cascadia comes with Windows
    /// Terminal, Consolas / Lucida Console with Office) so a family synced from
    /// SheepTerm for Windows is offered here whenever this Mac has it too.
    static let platformFaces = ["Menlo", "Monaco", "SF Mono", "Andale Mono", "PT Mono",
                                "Cascadia Code", "Cascadia Mono", "Consolas", "Lucida Console", "Courier New"]

    struct Sections: Equatable {
        var platform: [String]
        var bundled: [String]
        var other: [String]
        var all: [String] { platform + bundled + other }
    }

    /// The menu from what is installed (bundled faces included once they are
    /// registered). A bundled family that failed to register is left out
    /// rather than offered and silently replaced by the system font.
    static func sections(installed: [String]) -> Sections {
        let have = Set(installed)
        let platform = platformFaces.filter(have.contains)
        let bundledHere = bundled.filter(have.contains)
        let curated = Set(platform + bundledHere)
        let other = Array(have.subtracting(curated))
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Sections(platform: platform, bundled: bundledHere, other: other)
    }

    /// The face to draw for a requested weight, on NSFontManager's 0–15
    /// scale (5 regular, 6 medium, 8 semibold, 9 bold): the nearest weight
    /// the family has, a tie going to the lighter one. Most terminal families
    /// (Menlo and the bundled three) ship only Regular + Bold, and asking
    /// CoreText for Medium there returned Bold — every line drew bold at the
    /// default weight. Here Medium → Regular, Semibold → Bold.
    static func nearestWeight(_ requested: Int, available: [Int]) -> Int? {
        available.min { a, b in
            let da = abs(a - requested), db = abs(b - requested)
            return da != db ? da < db : a < b
        }
    }

    /// Registers every bundled `.ttf` for this process only (nothing is
    /// installed system-wide). Idempotent; returns the files that failed.
    @discardableResult
    static func registerBundled(in directory: URL?) -> [String] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var failed: [String] = []
        for url in files where url.pathExtension.lowercased() == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (a second call) is not a failure.
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
                if code != CTFontManagerError.alreadyRegistered.rawValue { failed.append(url.lastPathComponent) }
            }
        }
        return failed
    }
}

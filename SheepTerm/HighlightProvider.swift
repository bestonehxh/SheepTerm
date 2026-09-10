import Foundation
import SheepVTRender

/// The app's half of the highlighter: rules in, coloured byte spans out.
///
/// Everything that used to sit between the grid and the matcher —
/// which rows form a paragraph, how a cell becomes one byte, the per-paragraph
/// cache, "never clobber the colour the device set" — now lives in
/// `SheepVTRender.HighlightOverlay` and the row builder (ARCHITECTURE.md §5.2
/// and §5.6). Nothing is written into the grid any more, so there is no
/// palette of borrowed terminal attributes, no `owned` set, no `strip`, and no
/// full-buffer repaint: the overlay hands the renderer a per-column foreground
/// override, applied only where `cell.fgSource == .default`.
///
/// What is left here is the mapping the app owns: rule index → colour.
/// `Highlighter.spans` reports which RULE claimed a byte range; the rules'
/// colours are fixed constants in `Highlighter.makeConfigs`, so the palette is
/// just those `colorHex` literals in rule order.
final class VendorHighlightProvider: HighlightProvider {
    private(set) var vendor: Vendor

    /// Rule index → the colour that rule paints. Indexed exactly like
    /// `Highlighter.active(for:)`, which is `defaultConfigs(for:)` with the
    /// configs that fail to compile dropped — so the palette is built by
    /// walking the same list through the same filter.
    private var palette: [Int: (rgb: UInt32, bold: Bool)] = [:]

    /// What the overlay keys its per-paragraph cache on. Bumped by a vendor
    /// switch and by a rule recompile.
    private var ownRevision: UInt64 = 1
    /// `Highlighter.revision` the palette was built against.
    private var builtRevision: UInt64 = 0

    /// A recompile can change which rule sits at an index, so the palette has
    /// to be checked against `Highlighter.revision` before it is used — the
    /// same guard `GridHighlighter.syncRules` used to do before every paint.
    /// In 3.0 the rules are compiled once at startup and never again, so this
    /// costs one atomic read per frame and normally finds nothing to do.
    var revision: UInt64 {
        if Highlighter.revision != builtRevision { rebuild() }
        return ownRevision
    }

    init(vendor: Vendor) {
        self.vendor = vendor
        rebuild()
    }

    /// Live device-family switch. The overlay drops every cached paragraph
    /// when `revision` moves, so the next frame re-matches what is on screen.
    func setVendor(_ vendor: Vendor) {
        guard vendor != self.vendor else { return }
        self.vendor = vendor
        rebuild()
    }

    func spans(in paragraph: [UInt8]) -> [HighlightSpan] {
        let claimed = Highlighter.spans(in: paragraph, vendor: vendor)
        guard !claimed.isEmpty else { return [] }
        var out: [HighlightSpan] = []
        out.reserveCapacity(claimed.count)
        for span in claimed {
            guard let colour = palette[span.rule] else { continue }
            let location = span.range.location
            guard location != NSNotFound, span.range.length > 0 else { continue }
            out.append(HighlightSpan(range: location..<(location + span.range.length),
                                     rgb: colour.rgb,
                                     bold: colour.bold))
        }
        return out
    }

    private func rebuild() {
        // Read the revision BEFORE the rules, so a recompile that lands
        // between the two reads is caught by the next comparison rather than
        // being lost.
        builtRevision = Highlighter.revision
        palette.removeAll(keepingCapacity: true)
        var index = 0
        for config in Highlighter.defaultConfigs(for: vendor) {
            // Same filter `installDefaults` applies, so `index` lines up with
            // the rule index `Highlighter.spans` reports.
            guard HighlightRule(config: config, vendor: vendor) != nil else { continue }
            palette[index] = (rgb: UInt32(config.colorHex, radix: 16) ?? 0xFFFFFF,
                              bold: config.bold)
            index += 1
        }
        ownRevision &+= 1
    }
}

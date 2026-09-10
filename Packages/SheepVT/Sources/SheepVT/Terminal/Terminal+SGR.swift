// SheepVT — SGR (`CSI Pm m`): everything that changes the pen.
//
// Both spellings of the extended-colour forms are accepted, because both are
// in the wild:
//
//     38;5;n            38:5:n
//     38;2;r;g;b        38:2:r:g:b        38:2::r:g:b   (with colour-space id)
//
// The colon forms arrive as sub-parameters of one top-level parameter, the
// semicolon forms as separate top-level parameters — `CSIParams` keeps them
// apart (`isSub`) so we never have to guess.

extension Terminal {

    func selectGraphicRendition(_ params: CSIParams) {
        // `CSI m` with no parameters at all is `CSI 0 m`.
        guard params.count > 0 else {
            resetPen()
            touch()
            return
        }

        var i = 0
        while i < params.count {
            guard let vi = params.index(ofParam: i) else { break }
            let raw = params.values[vi]
            let code = raw < 0 ? 0 : Int(raw)
            let subs = Array(params.subParams(after: vi))

            switch code {
            case 0: resetPen()

            case 1: pen.fg |= Cell.FgFlag.bold
            case 2: pen.fg |= Cell.FgFlag.dim
            case 3: pen.fg |= Cell.FgFlag.italic
            case 4: applyUnderline(subs.isEmpty ? 1 : Int(subs[0]))
            case 5, 6: pen.fg |= Cell.FgFlag.blink
            case 7: pen.fg |= Cell.FgFlag.inverse
            case 8: pen.bg |= Cell.BgFlag.invisible
            case 9: pen.bg |= Cell.BgFlag.strikethrough
            case 21: applyUnderline(2)

            case 22: pen.fg &= ~(Cell.FgFlag.bold | Cell.FgFlag.dim)
            case 23: pen.fg &= ~Cell.FgFlag.italic
            case 24: applyUnderline(0)
            case 25: pen.fg &= ~Cell.FgFlag.blink
            case 27: pen.fg &= ~Cell.FgFlag.inverse
            case 28: pen.bg &= ~Cell.BgFlag.invisible
            case 29: pen.bg &= ~Cell.BgFlag.strikethrough

            case 30...37: setForeground(.palette16, UInt32(code - 30))
            case 39: setForeground(.default, 0)
            case 40...47: setBackground(.palette16, UInt32(code - 40))
            case 49: setBackground(.default, 0)
            case 90...97: setForeground(.palette16, UInt32(code - 90 + 8))
            case 100...107: setBackground(.palette16, UInt32(code - 100 + 8))

            case 53: pen.bg |= Cell.BgFlag.overline
            case 55: pen.bg &= ~Cell.BgFlag.overline

            case 38, 48, 58:
                if subs.isEmpty {
                    i += consumeSemicolonColor(target: code, params: params, at: i)
                } else {
                    applyColonColor(target: code, subs: subs)
                }

            case 59:
                pen.extended.underlineColor = 0

            default:
                break // unknown attribute: ignore, never abort the rest
            }
            i += 1
        }
        touch()
    }

    // MARK: - Reset

    /// SGR 0. The hyperlink survives — it is scoped by OSC 8, not by SGR.
    private func resetPen() {
        pen.fg = 0
        // DECSCA's protection is not an SGR attribute (xterm keeps it outside
        // the SGR mask): only DECSCA and DECSTR change it.
        pen.bg = pen.bg & Cell.BgFlag.protected
        pen.extended.underlineStyle = .none
        pen.extended.underlineColor = 0
    }

    // MARK: - Underline

    /// `4:n` sub-parameter styles, plus the plain spellings (4 = single,
    /// 21 = double, 24 = off). Anything out of range is a single underline.
    private func applyUnderline(_ style: Int) {
        let resolved: ExtendedAttributes.UnderlineStyle
        switch style {
        case 0: resolved = .none
        case 1: resolved = .single
        case 2: resolved = .double
        case 3: resolved = .curly
        case 4: resolved = .dotted
        case 5: resolved = .dashed
        default: resolved = .single
        }
        pen.extended.underlineStyle = resolved
        if resolved == .none {
            pen.fg &= ~Cell.FgFlag.underline
        } else {
            pen.fg |= Cell.FgFlag.underline
        }
    }

    // MARK: - Colours

    private func setForeground(_ source: ColorSource, _ value: UInt32) {
        pen.fg = Cell.colorWord(source: source, value: value, flags: pen.fg & Cell.flagsMask)
    }

    private func setBackground(_ source: ColorSource, _ value: UInt32) {
        pen.bg = Cell.colorWord(source: source, value: value, flags: pen.bg & Cell.flagsMask)
    }

    private func setUnderlineColor(_ source: ColorSource, _ value: UInt32) {
        pen.extended.underlineColor = Cell.colorWord(source: source, value: value)
    }

    private func apply(target: Int, source: ColorSource, value: UInt32) {
        switch target {
        case 38: setForeground(source, value)
        case 48: setBackground(source, value)
        default: setUnderlineColor(source, value)
        }
    }

    @inline(__always)
    private func channel(_ v: Int32) -> UInt32 { UInt32(Swift.max(0, Swift.min(255, Int(v)))) }

    @inline(__always)
    private func channel(_ v: Int) -> UInt32 { UInt32(Swift.max(0, Swift.min(255, v))) }

    /// `38;5;n` / `38;2;r;g;b`. Returns how many *extra* top-level parameters
    /// were consumed.
    private func consumeSemicolonColor(target: Int, params: CSIParams, at i: Int) -> Int {
        switch params.param(i + 1, default: 0) {
        case 5:
            // A truncated `38;5` selects nothing rather than colour 0.
            guard i + 2 < params.count else { return 1 }
            apply(target: target, source: .palette256, value: channel(params.param(i + 2, default: 0)))
            return 2
        case 2:
            guard i + 4 < params.count else { return Swift.min(4, params.count - i - 1) }
            let r = channel(params.param(i + 2, default: 0))
            let g = channel(params.param(i + 3, default: 0))
            let b = channel(params.param(i + 4, default: 0))
            apply(target: target, source: .rgb, value: (r << 16) | (g << 8) | b)
            return 4
        default:
            return 1
        }
    }

    /// `38:5:n`, `38:2:r:g:b` (4 sub-params) and `38:2:cs:r:g:b` (5 sub-params,
    /// the colour-space id present and ignored).
    private func applyColonColor(target: Int, subs: [Int32]) {
        guard let mode = subs.first else { return }
        switch mode {
        case 5:
            guard subs.count >= 2 else { return }
            apply(target: target, source: .palette256, value: channel(subs[1]))
        case 2:
            let base: Int
            if subs.count >= 5 { base = 2 }          // 2 : cs : r : g : b
            else if subs.count >= 4 { base = 1 }     // 2 : r : g : b
            else { return }
            let r = channel(subs[base])
            let g = channel(subs[base + 1])
            let b = channel(subs[base + 2])
            apply(target: target, source: .rgb, value: (r << 16) | (g << 8) | b)
        default:
            break
        }
    }
}

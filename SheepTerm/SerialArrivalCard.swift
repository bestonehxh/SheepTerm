import CoreGraphics
import Foundation

/// The "Console cable" card (6.0 (14), the owner's design "B"; it replaced the
/// 5.0 (29) shadow chip at the end of the tab strip): a USB serial cable
/// plugged in while the app runs shows ONE card at the bottom right of the
/// window — the cable icon, "Console cable", ×; the device name and kind; a
/// speed menu and Connect. The rules of when it is up are §29's, unchanged
/// (`SerialArrival.isCable`, USB ancestry and the 5 s after wake in
/// `SerialWatcher`/`AppModel`).
///
/// Several cables (6.1 (3), the owner: "เผื่อเสียบ 5 สายพร้อมกัน"): still ONE
/// card, a row per cable in the order they came, each with its own speed and
/// Connect, plus Connect All / Open All in Split. A cable plugged in while
/// the card is up ADDS a row and gives the card its 15 s again; a row goes
/// when its cable is pulled, a tab holds its device or its Connect is used;
/// the card goes with its last row, after 15 s, or with ×.
///
/// The card's whole lifecycle is this pure state machine (`reduce`), so no
/// path can leave a card stuck, stacked or behind another: AppModel only
/// feeds events and performs the returned effect; the view only draws
/// `state.card` in the window it names.
nonisolated enum SerialArrivalCard {
    static let lifetime: TimeInterval = SerialArrival.lifetime
    /// A card that resumes with less than this left gets this much (it does
    /// not vanish the moment the pointer leaves it).
    static let resumeFloor: TimeInterval = 2
    /// The speed menu, then "Other…".
    static let menuRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]
    /// What "Other…" accepts (= `Host.serialBaudRange`, what SerialWorker opens).
    static let customRange = 50...4_000_000
    /// Rows the card holds; a cable past them is not listed (a hub of
    /// adapters re-enumerating must not grow it without end).
    static let maxRows = 16
    /// Rows shown before the list scrolls inside the card.
    static let visibleRows = 6

    /// Why the 15 s stand still.
    enum Pause: Hashable {
        /// The pointer is over the card.
        case hover
        /// The speed menu is open.
        case menu
        /// The "Other…" field is open.
        case field
        /// Another element has the corner and there is no room (`frame` → nil): not drawn.
        case yield
        /// The app is hidden: nobody can see it.
        case hidden
    }

    enum CustomError: Error, Equatable {
        case notANumber
        case outOfRange
    }

    /// One cable on the card.
    struct Row: Equatable {
        let path: String
        /// "usbserial-1410 · FTDI" (`detail(path:usb:)`).
        let detail: String
        var baud: Int

        var name: String { SerialArrival.shortName(path) }
    }

    /// The "Other…" field — one at a time, on one row.
    struct Custom: Equatable {
        let path: String
        var text: String
        var error: CustomError?
    }

    /// Open this console at this speed.
    struct Opening: Equatable {
        let path: String
        let baud: Int
    }

    struct Card: Equatable {
        /// Bumped on every new card: a timer or a click meant for the card it
        /// replaced never touches this one. A row added to a card keeps it.
        let generation: Int
        /// The cables, in the order they came; never empty.
        var rows: [Row]
        /// The window (number) it lives in — the front main window when the
        /// latest cable arrived. One card in the whole app.
        var window: Int
        /// Seconds left, as of `runningSince` (or for good while paused).
        var remaining: TimeInterval
        /// nil = paused.
        var runningSince: Date?
        var pauses: Set<Pause> = []
        var custom: Custom?

        /// Drawn (`yield` hides it, the app being hidden hides everything).
        var isVisible: Bool { !pauses.contains(.yield) && !pauses.contains(.hidden) }
        /// When the 15 s run out, nil while paused.
        var deadline: Date? { runningSince.map { $0.addingTimeInterval(remaining) } }
        /// Several cables: the list and its Connect All / Open All in Split.
        var isList: Bool { rows.count > 1 }

        func row(_ path: String) -> Row? {
            rows.first { SerialArrival.calloutPath($0.path) == SerialArrival.calloutPath(path) }
        }
    }

    struct State: Equatable {
        var card: Card?
        var generation = 0
    }

    enum Event: Equatable {
        /// A USB serial cable appeared. `window`: the front main window (nil =
        /// none on screen → no new card); `openPaths`: devices tabs hold.
        case arrived(path: String, detail: String, baud: Int, window: Int?, openPaths: Set<String>)
        /// A device went away.
        case gone(path: String)
        /// The tabs changed: one may hold a row's device now.
        case tabsChanged(openPaths: Set<String>)
        /// The timer fired (any timer, any time).
        case tick
        case pause(Pause)
        case resume(Pause)
        case pickBaud(path: String, Int)
        case openCustom(path: String)
        case editCustom(String)
        case submitCustom
        case cancelCustom
        case dismiss
        /// That row's Connect; `openPaths` decides open vs select.
        case connect(path: String, openPaths: Set<String>)
        /// Connect All (`split` false) / Open All in Split (`split` true).
        case connectAll(split: Bool, openPaths: Set<String>)
        case windowClosed(Int)
    }

    enum Effect: Equatable {
        case none
        /// Open that console at that speed.
        case open(Opening)
        /// A tab already holds the port: select it.
        case select(path: String)
        /// Every row's console, in their order; `split` = one tab, as a grid.
        case openAll([Opening], split: Bool)
    }

    /// "Other…": a positive whole number of baud within `customRange`.
    static func customBaud(_ text: String) -> Result<Int, CustomError> {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 9, t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t) else { return .failure(.notANumber) }
        return customRange.contains(n) ? .success(n) : .failure(.outOfRange)
    }

    private static func holds(_ open: Set<String>, _ path: String) -> Bool {
        Set(open.map(SerialArrival.calloutPath)).contains(SerialArrival.calloutPath(path))
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        SerialArrival.calloutPath(a) == SerialArrival.calloutPath(b)
    }

    /// Takes the rows `drop` picks off the card; its field goes with its row;
    /// the card goes with its last row.
    private static func removeRows(_ state: inout State, now: Date, where drop: (Row) -> Bool) {
        guard var card = state.card else { return }
        card.rows.removeAll(where: drop)
        guard !card.rows.isEmpty else { state.card = nil; return }
        let fieldGone = card.custom.map { custom in !card.rows.contains { same($0.path, custom.path) } } ?? false
        state.card = card
        if fieldGone {
            state.card?.custom = nil
            reduce(&state, .resume(.field), now: now)
        }
    }

    /// An open "Other…" field is taken before any Connect: its value, or —
    /// junk in it — false (the error shows, nothing opens).
    private static func settleField(_ state: inout State, now: Date) -> Bool {
        guard state.card?.custom != nil else { return true }
        reduce(&state, .submitCustom, now: now)
        return state.card?.custom == nil
    }

    /// Applies one event; returns what AppModel must do.
    @discardableResult
    static func reduce(_ state: inout State, _ event: Event, now: Date) -> Effect {
        switch event {
        case .arrived(let path, let detail, let baud, let window, let open):
            guard SerialArrival.isCable(path), !holds(open, path) else { return .none }
            if var card = state.card {
                // On the card already (re-enumerated, replugged): its row stays as it is.
                if card.row(path) == nil {
                    guard card.rows.count < maxRows else { return .none }
                    card.rows.append(Row(path: path, detail: detail, baud: baud))
                }
                // The ONE card follows the front window, and has its 15 s again.
                if let window { card.window = window }
                card.remaining = lifetime
                card.runningSince = card.pauses.isEmpty ? now : nil
                state.card = card
                return .none
            }
            guard let window else { return .none }
            state.generation += 1
            state.card = Card(generation: state.generation, rows: [Row(path: path, detail: detail, baud: baud)],
                              window: window, remaining: lifetime, runningSince: now)
            return .none
        case .gone(let path):
            removeRows(&state, now: now) { same($0.path, path) }
            return .none
        case .tabsChanged(let open):
            removeRows(&state, now: now) { holds(open, $0.path) }
            return .none
        case .tick:
            if let deadline = state.card?.deadline, now >= deadline { state.card = nil }
            return .none
        case .pause(let reason):
            guard var card = state.card else { return .none }
            if let since = card.runningSince {
                card.remaining = max(0, card.remaining - now.timeIntervalSince(since))
                card.runningSince = nil
            }
            card.pauses.insert(reason)
            state.card = card
            return .none
        case .resume(let reason):
            guard var card = state.card else { return .none }
            card.pauses.remove(reason)
            if card.pauses.isEmpty, card.runningSince == nil {
                card.remaining = max(card.remaining, resumeFloor)
                card.runningSince = now
            }
            state.card = card
            return .none
        case .pickBaud(let path, let baud):
            guard customRange.contains(baud), let i = state.card?.rows.firstIndex(where: { same($0.path, path) }) else { return .none }
            state.card?.rows[i].baud = baud
            return .none
        case .openCustom(let path):
            guard state.card?.row(path) != nil else { return .none }
            // One field: opening it on another row moves it there.
            state.card?.custom = Custom(path: path, text: "")
            return reduce(&state, .pause(.field), now: now)
        case .editCustom(let text):
            // The field's binding also writes back the SAME text (on focus):
            // only a real change clears the error.
            guard let old = state.card?.custom?.text, old != text else { return .none }
            state.card?.custom?.text = text
            state.card?.custom?.error = nil
            return .none
        case .submitCustom:
            guard let custom = state.card?.custom else { return .none }
            switch customBaud(custom.text) {
            case .success(let baud):
                if let i = state.card?.rows.firstIndex(where: { same($0.path, custom.path) }) { state.card?.rows[i].baud = baud }
                state.card?.custom = nil
                return reduce(&state, .resume(.field), now: now)
            case .failure(let error):
                state.card?.custom?.error = error
                return .none
            }
        case .cancelCustom:
            guard state.card?.custom != nil else { return .none }
            state.card?.custom = nil
            return reduce(&state, .resume(.field), now: now)
        case .dismiss:
            state.card = nil
            return .none
        case .connect(let path, let open):
            guard settleField(&state, now: now), let row = state.card?.row(path) else { return .none }
            removeRows(&state, now: now) { same($0.path, path) }
            return holds(open, row.path) ? .select(path: row.path) : .open(Opening(path: row.path, baud: row.baud))
        case .connectAll(let split, let open):
            guard settleField(&state, now: now), let rows = state.card?.rows else { return .none }
            state.card = nil
            let opening = rows.filter { !holds(open, $0.path) }.map { Opening(path: $0.path, baud: $0.baud) }
            return opening.isEmpty ? .none : .openAll(opening, split: split)
        case .windowClosed(let window):
            if state.card?.window == window { state.card = nil }
            return .none
        }
    }

    // MARK: Text

    /// The kind after the device name: the adapter's maker for a console
    /// cable, the device's own name for a console that names itself (an
    /// Aruba CX: "HPN Serial Port"); nil when nothing is known.
    static func kind(_ usb: ConsoleBaud.USBDevice?) -> String? {
        guard let usb else { return nil }
        switch usb.vendorID {
        case 0x0403: return "FTDI"
        case 0x067B: return "Prolific"
        case 0x1A86: return "CH340"
        case 0x10C4: return "Silicon Labs"
        default:
            let product = usb.product?.trimmingCharacters(in: .whitespaces) ?? ""
            return product.isEmpty ? nil : product
        }
    }

    /// Row 2: "usbserial-1410 · FTDI", "usbmodem1101 · HPN Serial Port".
    static func detail(path: String, usb: ConsoleBaud.USBDevice?) -> String {
        let name = SerialArrival.shortName(path)
        return kind(usb).map { "\(name) · \($0)" } ?? name
    }

    // MARK: Layout

    /// Room between the card and the area's edges / anything it stands clear of.
    static let margin: CGFloat = 12

    /// Where the card goes in the terminal area (top-left origin; the area is
    /// above the status bar and left of the AI panel, so neither is ever
    /// covered): the bottom-right corner; when that overlaps something else
    /// up in the area (`obstacles`: the File Server popover, a connection
    /// card or its panel, the status HUD / baud hint, a pane header), it
    /// moves straight up until clear of all of them; nil when there is no
    /// clear spot (the card then yields: hidden, its time paused).
    static func frame(area: CGSize, card: CGSize, obstacles: [CGRect]) -> CGRect? {
        let x = area.width - margin - card.width
        guard x >= margin else { return nil }
        var rect = CGRect(x: x, y: area.height - margin - card.height, width: card.width, height: card.height)
        let blocking = obstacles.filter { !$0.isNull && !$0.isEmpty }
        // Each step moves above one obstacle; at most one step per obstacle.
        for _ in 0...blocking.count {
            guard let hit = blocking.filter({ $0.insetBy(dx: -margin / 2, dy: -margin / 2).intersects(rect) }).min(by: { $0.minY < $1.minY })
            else { return rect.minY >= margin ? rect : nil }
            rect.origin.y = hit.minY - margin - card.height
            if rect.minY < margin { return nil }
        }
        return nil
    }
}

import CoreGraphics
import Foundation

/// The "Console cable" card (6.0 (14), the owner's design "B"; it replaced the
/// 5.0 (29) shadow chip at the end of the tab strip): a USB serial cable
/// plugged in while the app runs shows ONE card at the bottom right of the
/// window — the cable icon, "Console cable", ×; the device name and kind; a
/// speed menu and Connect. The rules of when it is up are §29's, unchanged
/// (`SerialArrival.isCable`, USB ancestry and the 5 s after wake in
/// `SerialWatcher`/`AppModel`): the newest cable REPLACES the card, it goes
/// after 15 s, when the cable is pulled, when a tab holds that device, or
/// with ×.
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

    struct Card: Equatable {
        /// Bumped on every new card: a timer or a click meant for the card it
        /// replaced never touches this one.
        let generation: Int
        let path: String
        /// Row 2: "usbserial-1410 · FTDI" (`detail(path:usb:)`).
        let detail: String
        /// The window (number) it lives in — the front main window when the
        /// cable arrived. It stays there; one card in the whole app.
        let window: Int
        var baud: Int
        /// Seconds left, as of `runningSince` (or for good while paused).
        var remaining: TimeInterval
        /// nil = paused.
        var runningSince: Date?
        var pauses: Set<Pause> = []
        /// The "Other…" field: nil = closed, else its text.
        var customText: String?
        var customError: CustomError?

        var name: String { SerialArrival.shortName(path) }
        /// Drawn (`yield` hides it, the app being hidden hides everything).
        var isVisible: Bool { !pauses.contains(.yield) && !pauses.contains(.hidden) }
        /// When the 15 s run out, nil while paused.
        var deadline: Date? { runningSince.map { $0.addingTimeInterval(remaining) } }
    }

    struct State: Equatable {
        var card: Card?
        var generation = 0
    }

    enum Event: Equatable {
        /// A USB serial cable appeared. `window`: the front main window (nil =
        /// none on screen → no card); `openPaths`: devices tabs hold.
        case arrived(path: String, detail: String, baud: Int, window: Int?, openPaths: Set<String>)
        /// A device went away.
        case gone(path: String)
        /// The tabs changed: one may hold the card's device now.
        case tabsChanged(openPaths: Set<String>)
        /// The timer fired (any timer, any time).
        case tick
        case pause(Pause)
        case resume(Pause)
        case pickBaud(Int)
        case openCustom
        case editCustom(String)
        case submitCustom
        case cancelCustom
        case dismiss
        /// Connect; `openPaths` decides open vs select.
        case connect(openPaths: Set<String>)
        case windowClosed(Int)
    }

    enum Effect: Equatable {
        case none
        /// Open that console at that speed.
        case open(path: String, baud: Int)
        /// A tab already holds the port: select it.
        case select(path: String)
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

    /// Applies one event; returns what AppModel must do.
    @discardableResult
    static func reduce(_ state: inout State, _ event: Event, now: Date) -> Effect {
        switch event {
        case .arrived(let path, let detail, let baud, let window, let open):
            guard SerialArrival.isCable(path), let window, !holds(open, path) else { return .none }
            state.generation += 1
            // The newest cable REPLACES the card — never a second one.
            state.card = Card(generation: state.generation, path: path, detail: detail, window: window, baud: baud,
                              remaining: lifetime, runningSince: now)
            return .none
        case .gone(let path):
            if let card = state.card, SerialArrival.calloutPath(card.path) == SerialArrival.calloutPath(path) { state.card = nil }
            return .none
        case .tabsChanged(let open):
            if let card = state.card, holds(open, card.path) { state.card = nil }
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
        case .pickBaud(let baud):
            guard customRange.contains(baud) else { return .none }
            state.card?.baud = baud
            return .none
        case .openCustom:
            guard state.card != nil else { return .none }
            state.card?.customText = ""
            state.card?.customError = nil
            return reduce(&state, .pause(.field), now: now)
        case .editCustom(let text):
            // The field's binding also writes back the SAME text (on focus):
            // only a real change clears the error.
            guard let old = state.card?.customText, old != text else { return .none }
            state.card?.customText = text
            state.card?.customError = nil
            return .none
        case .submitCustom:
            guard let text = state.card?.customText else { return .none }
            switch customBaud(text) {
            case .success(let baud):
                state.card?.baud = baud
                state.card?.customText = nil
                state.card?.customError = nil
                return reduce(&state, .resume(.field), now: now)
            case .failure(let error):
                state.card?.customError = error
                return .none
            }
        case .cancelCustom:
            guard state.card?.customText != nil else { return .none }
            state.card?.customText = nil
            state.card?.customError = nil
            return reduce(&state, .resume(.field), now: now)
        case .dismiss:
            state.card = nil
            return .none
        case .connect(let open):
            // An open "Other…" field: its value, or nothing happens (the error shows).
            if state.card?.customText != nil {
                reduce(&state, .submitCustom, now: now)
                if state.card?.customText != nil { return .none }
            }
            guard let card = state.card else { return .none }   // a second Connect finds no card
            state.card = nil
            return holds(open, card.path) ? .select(path: card.path) : .open(path: card.path, baud: card.baud)
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

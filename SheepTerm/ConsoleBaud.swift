import Foundation

// The console speed a serial port wants, read from the USB device behind it
// (5.0 (39), the user: an SI moves between Cisco, Huawei and Aruba every day).
// A console CABLE is an adapter (FTDI, Prolific, CH340, Silicon Labs): the Mac
// sees the adapter's maker, never the box at the far end, and every box the
// user plugs one into — Cisco, Huawei, Fortinet, even an Aruba controller —
// runs 9600 8N1. An Aruba CX switch's USB-C console is the switch's OWN USB
// serial port and it runs 115200; it is the one console that names itself.
// Foundation only and in `sharedSources` (root Package.swift): SheepTerm for
// Windows reads VID/PID from the port's hardware ID and asks the same rule.
public nonisolated enum ConsoleBaud {
    /// Network gear consoles ship 9600 8N1.
    public static let standard = 9600
    /// What the forms and the status bar menu offer.
    public static let rates = [9600, 19200, 38400, 57600, 115200, 230400]

    /// The USB device a serial port belongs to, as far as the OS told us.
    public struct USBDevice: Equatable, Sendable {
        public var vendorID: Int?
        public var productID: Int?
        public var product: String?

        public init(vendorID: Int?, productID: Int?, product: String?) {
            self.vendorID = vendorID
            self.productID = productID
            self.product = product
        }
    }

    /// A console that identifies itself: its speed and what to call it.
    public struct Known: Equatable, Sendable {
        public let baud: Int
        public let label: String
    }

    /// Aruba CX 6000/6100/6200/6300/6400/8xxx USB-C console: HP vendor 0x03F0,
    /// product 0x013F, "HPN Serial Port". The product name is checked too, for
    /// a later CX model that keeps the name under another product id.
    public static func known(_ device: USBDevice?) -> Known? {
        guard let device else { return nil }
        let arubaCX = (device.vendorID == 0x03F0 && device.productID == 0x013F)
            || (device.product?.range(of: "HPN Serial", options: .caseInsensitive) != nil)
        return arubaCX ? Known(baud: 115_200, label: "Aruba CX USB console") : nil
    }

    /// The speed to open a port at when nobody chose one.
    public static func baud(for device: USBDevice?) -> Int {
        known(device)?.baud ?? standard
    }
}

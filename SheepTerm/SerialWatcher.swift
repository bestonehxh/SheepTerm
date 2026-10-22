import Foundation
import IOKit
import IOKit.serial

/// Serial devices coming and going (5.0 (29)), from IOKit's own
/// notifications — no polling, nothing runs while nothing is plugged.
/// Devices present at start are taken as known (no shadow for a cable that
/// was already in). Paths are callout devices (`/dev/cu.*`).
@MainActor final class SerialWatcher {
    var onArrived: ((String) -> Void)?
    var onGone: ((String) -> Void)?

    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0

    func start() {
        guard port == nil, let notify = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = notify
        IONotificationPortSetDispatchQueue(notify, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let arrived: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<SerialWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, event: .arrived) }
        }
        let gone: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let watcher = Unmanaged<SerialWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.drain(iterator, event: .gone) }
        }
        // Each call consumes its matching dictionary.
        if IOServiceAddMatchingNotification(notify, kIOFirstMatchNotification, IOServiceMatching(kIOSerialBSDServiceValue),
                                            arrived, context, &added) == KERN_SUCCESS {
            drain(added, event: nil)           // arms it; what is already there is not news
        }
        if IOServiceAddMatchingNotification(notify, kIOTerminatedNotification, IOServiceMatching(kIOSerialBSDServiceValue),
                                            gone, context, &removed) == KERN_SUCCESS {
            drain(removed, event: nil)
        }
    }

    /// The USB device behind a serial port (`/dev/cu.X` or `/dev/tty.X`),
    /// for `ConsoleBaud` (5.0 (39)); nil when the port is gone or not USB.
    /// One registry walk, only when a console is opened or picked.
    nonisolated static func usbDevice(at path: String) -> ConsoleBaud.USBDevice? {
        let wanted = SerialArrival.calloutPath(path)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let callout = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, callout == wanted else { continue }
            func parent(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            let vendor = (parent("idVendor") as? NSNumber)?.intValue
            guard vendor != nil else { return nil }
            return ConsoleBaud.USBDevice(vendorID: vendor,
                                         productID: (parent("idProduct") as? NSNumber)?.intValue,
                                         product: (parent("USB Product Name") ?? parent("kUSBProductString")) as? String)
        }
        return nil
    }

    private enum Event { case arrived, gone }

    /// Takes every service off `iterator` (that is what re-arms it) and
    /// reports each; `event` nil = priming, nothing reported.
    private func drain(_ iterator: io_iterator_t, event: Event?) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let event,
                  let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String else { continue }
            switch event {
            case .arrived:
                // A cable is a USB device somewhere above the port; a paired
                // Bluetooth serial port is not (review 5.0 (29)).
                let isUSB = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault,
                                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) != nil
                if isUSB { onArrived?(path) }
            case .gone:
                // A port going away may have lost its parents: reported as is.
                onGone?(path)
            }
        }
    }
}

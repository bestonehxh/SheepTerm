// SheepVTRender — present frames through IOSurfaces on a plain CALayer.
//
// Ghostty's trick (design study §2.4). A CAMetalLayer presents on its own
// schedule: measured key→pixel 47 ms against Terminal.app's 25 ms, because an
// asynchronous drawable present reaches the compositor a frame or two later
// than a layer committed with the CA transaction, and `presentsWithTransaction`
// serialises drawables and lands even later. Rendering into an IOSurface-backed
// texture and handing that surface to `layer.contents` inside the current
// transaction gets the ordinary CA-layer path: whatever is set before the
// commit shows at the next vsync, and a resize is synchronous by construction.
//
// Three surfaces rotate so the compositor can still be reading one while the
// GPU writes the next; a frame waits for its own GPU work (1–3 ms) before the
// surface is handed over, so the compositor never samples a half-drawn frame.
// The ring skips any surface the window server still has in use, which is what
// keeps that promise on a 120 Hz display where frames come twice as often —
// and when every surface is in use it makes a new one rather than overwriting
// one that is being read (see `nextTexture`).

import AppKit
import IOSurface
import Metal
import QuartzCore
import SheepVT

final class SurfacePresenter {
    private struct Slot {
        let surface: IOSurface
        let texture: MTLTexture
    }
    private let device: MTLDevice
    private var slots: [Slot] = []
    private var next = 0
    private(set) var pixelSize = CGSize.zero

    /// How a slot is asked whether the window server still holds it.
    /// Injectable because `IOSurfaceIsInUse` cannot be forced from a test, and
    /// the all-in-use path is precisely the one that used to tear.
    var isInUse: (IOSurface) -> Bool = { $0.isInUse }

    /// Surfaces the ring starts with: one on screen, one queued, one to draw.
    static let baseSlots = 3
    /// Ceiling on the ring. A slot costs width × height × 4 bytes, so the cap
    /// is stated in both: at most six surfaces, and at most 96 MB of them.
    /// Six covers a compositor two full frames behind at 120 Hz; past that,
    /// more depth only postpones the same question.
    static let maxSlots = 6
    static let maxRingBytes = 96 << 20

    init(device: MTLDevice) { self.device = device }

    /// (Re)create the ring for a pixel size. Cheap when unchanged.
    func prepare(pixelSize: CGSize) {
        let w = Int(max(1, pixelSize.width.rounded())), h = Int(max(1, pixelSize.height.rounded()))
        // `slots.count` is not compared: a ring that grew under compositor
        // pressure is still the right ring for this size, and rebuilding it
        // here would throw that away every frame.
        if !slots.isEmpty, Int(self.pixelSize.width) == w, Int(self.pixelSize.height) == h { return }
        self.pixelSize = CGSize(width: w, height: h)
        slots.removeAll()
        next = 0
        for _ in 0..<SurfacePresenter.baseSlots {
            guard let slot = makeSlot(width: w, height: h) else { continue }
            slots.append(slot)
        }
    }

    /// Free the ring (a hidden view). The next `prepare` rebuilds it.
    func release() {
        slots.removeAll()
        next = 0
        pixelSize = .zero
    }

    /// The texture to render the next frame into (nil until `prepare` succeeded).
    ///
    /// Round-robin, but skipping any surface the window server still holds:
    /// on a 120 Hz display a frame can be encoded while the compositor is
    /// reading the one presented a moment ago, and drawing into that one would
    /// show half of the new frame. `IOSurfaceIsInUse` is exactly that question.
    func nextTexture() -> MTLTexture? {
        guard !slots.isEmpty else { return nil }
        let count = slots.count
        for k in 0..<count {
            let slot = slots[(next + k) % count]
            if !isInUse(slot.surface) {
                next = (next + k + 1) % count
                return slot.texture
            }
        }
        // Every surface is being read. Two things are NOT options here.
        // Reusing one anyway is the tear this ring exists to prevent —
        // `waitUntilCompleted` proves our own GPU work is done, not that the
        // compositor has let go. And returning nil is not a deferral: by the
        // time `TerminalView.paintIfNeeded` calls the renderer it has already
        // cleared `needsFrame` and recorded `changeCounter`, so the next tick
        // sees nothing changed and the frame is dropped for good — including a
        // keystroke's immediate paint.
        //
        // So: draw into a surface nobody is reading. Append one while the ring
        // is under budget (which also stops the next frame having to allocate
        // at all), and once it is at the cap replace the oldest slot instead —
        // the compositor keeps whatever it still holds alive through the
        // layer's own reference and releases it when it is done. nil is left
        // for the one case with no safe answer: the allocation failed.
        guard let fresh = makeSlot(width: Int(pixelSize.width), height: Int(pixelSize.height)) else { return nil }
        let index: Int
        if count < SurfacePresenter.maxSlots, (count + 1) * surfaceBytes <= SurfacePresenter.maxRingBytes {
            slots.append(fresh)
            index = count
        } else {
            index = next % count
            slots[index] = fresh
        }
        next = (index + 1) % slots.count
        return fresh.texture
    }

    /// Hand the surface behind `texture` to the layer.
    func present(_ texture: MTLTexture, on layer: CALayer, scale: CGFloat) {
        guard let surface = surface(for: texture) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.contents = surface
        CATransaction.commit()
    }

    /// Take the last surface back off a layer (a view that left the window).
    /// `release()` frees the ring, but the layer holds a reference of its own
    /// to whatever it is showing — one more full-screen surface per hidden tab
    /// (7.9 MB at 1440×900 ×2, 14.7 MB at 2560×1440), for a picture that is not
    /// on screen. The layer falls back to its own background colour, which is
    /// the terminal's, and the view paints again inside the transaction that
    /// puts it back on screen.
    static func clear(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = nil
        CATransaction.commit()
    }

    // MARK: - internals

    private var surfaceBytes: Int { Int(pixelSize.width) * Int(pixelSize.height) * 4 }

    private func makeSlot(width w: Int, height h: Int) -> Slot? {
        guard w >= 1, h >= 1 else { return nil }
        let props: [IOSurfacePropertyKey: Any] = [
            .width: w, .height: h, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x42475241),   // 'BGRA'
        ]
        guard let surface = IOSurface(properties: props) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else { return nil }
        return Slot(surface: surface, texture: texture)
    }

    /// The surface a texture was made from. Used by `present`, and by the tests
    /// to name the slot a frame landed in.
    func surface(for texture: MTLTexture) -> IOSurface? {
        slots.first(where: { $0.texture === texture })?.surface
    }

    /// Ring depth, for the tests: the budget above is only a promise if
    /// something checks it.
    var slotCount: Int { slots.count }

    /// The ring's surfaces, for the tests.
    var ringSurfaces: [IOSurface] { slots.map(\.surface) }
}

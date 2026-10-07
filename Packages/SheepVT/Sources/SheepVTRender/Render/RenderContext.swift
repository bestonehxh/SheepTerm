// SheepVTRender — what every renderer on a device shares.
//
// A `MetalRenderer` used to own the whole stack: command queue, compiled
// shaders, sampler, both glyph atlases with their CPU shadows, the glyph cache
// and the three-deep buffer ring. The app keeps one renderer per tab, hidden
// tabs included, so each tab paid for all of it again — measured 4.2 (2) with
// `footprint`: ~14 MB per hidden tab (4 MB colour atlas + 4 MB shadow, 1 MB
// gray atlas + 1 MB shadow, buffers, row cache) at the default sizes, before
// a single byte of scrollback. Eight SSH tabs = 100 MB of identical glyphs.
//
// None of that is per tab in nature. Glyphs are the same picture whichever
// terminal shows them, the pipelines are the same code, and only one frame is
// ever encoded at a time (everything here is main-actor). So the device-wide
// pieces live here, once per `MTLDevice`, and a renderer keeps only what is
// truly its own: the row cache (keyed on ITS terminal's lines), palette and
// font generations, and the surfaces behind ITS layer.
//
// Two fonts at once: the glyph cache keys on the font (`FontKey`), so views
// mid-way through a font-size change — the visible one already on the new
// size, hidden ones still on the old — never see each other's glyphs. Space
// is reclaimed when the LAST renderer using a font lets go of it: the atlases
// are cleared (a shelf packer cannot evict one font) and the next frame
// rasterises its working set again, once.

import Foundation
import Metal

/// What a glyph's picture depends on, besides the character itself.
nonisolated struct FontKey: Hashable, Sendable {
    var name: String
    var pointSize: CGFloat
    var scale: CGFloat
    var smoothing: Bool
}

extension FontSet {
    /// The cache key for glyphs rasterised from this set (plus smoothing,
    /// which belongs to the rasteriser rather than the font).
    func key(smoothing: Bool) -> FontKey {
        FontKey(name: baseFont.fontName, pointSize: pointSize, scale: metrics.scale, smoothing: smoothing)
    }
}

final class RenderContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let backgroundPipeline: MTLRenderPipelineState
    let glyphGrayPipeline: MTLRenderPipelineState
    let glyphColorPipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let grayAtlas: GlyphAtlas
    let colorAtlas: GlyphAtlas
    let rasterizer: GlyphRasterizer
    let glyphCache: GlyphCache

    /// The buffer ring and its gate. Shared because a slot is reused once the
    /// GPU has finished the frame that used it — a fact about the device, not
    /// about which renderer encoded that frame.
    let frameSemaphore = DispatchSemaphore(value: MetalRenderer.framesInFlight)
    let frameSlots: [FrameSlot]
    private(set) var frameIndex = 0

    /// Renderers per font, so a font is let go of exactly once.
    private var fontUsers: [FontKey: Int] = [:]
    /// `glyphCache.rasterised` at the last clear — a clear that would remove
    /// nothing is skipped (the default font every renderer starts on is let go
    /// of before it ever drew a glyph).
    private var rasterisedAtClear = 0

    /// The colour atlas starts small. It holds emoji and other colour glyphs
    /// only, which most sessions never show; at 1024² it was 4 MB of texture
    /// plus a 4 MB shadow for nothing. It grows the usual way when it has to
    /// (`GlyphAtlas.ensureRegion`), copying what it holds.
    static let colorAtlasInitialSize = 256

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueueUnavailable }
        self.commandQueue = queue

        guard let gray = GlyphAtlas(device: device,
                                    maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .grayscale),
                                    format: .grayscale),
              let color = GlyphAtlas(device: device,
                                     size: RenderContext.colorAtlasInitialSize,
                                     maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .bgra),
                                     format: .bgra) else {
            throw RendererError.atlasUnavailable
        }
        self.grayAtlas = gray
        self.colorAtlas = color

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RendererError.libraryCompilationFailed("\(error)")
        }
        self.backgroundPipeline = try RenderContext.pipeline(device: device,
                                                             library: library,
                                                             vertex: Shaders.backgroundVertex,
                                                             fragment: Shaders.backgroundFragment,
                                                             premultiplied: false)
        self.glyphGrayPipeline = try RenderContext.pipeline(device: device,
                                                            library: library,
                                                            vertex: Shaders.glyphVertex,
                                                            fragment: Shaders.glyphFragmentGray,
                                                            premultiplied: true)
        self.glyphColorPipeline = try RenderContext.pipeline(device: device,
                                                             library: library,
                                                             vertex: Shaders.glyphVertex,
                                                             fragment: Shaders.glyphFragmentBGRA,
                                                             premultiplied: true)

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw RendererError.samplerUnavailable
        }
        self.sampler = sampler

        self.rasterizer = GlyphRasterizer()
        self.rasterizer.fontSmoothing = false
        self.glyphCache = GlyphCache(rasterizer: rasterizer, gray: gray, color: color)
        self.frameSlots = (0..<MetalRenderer.framesInFlight).map { _ in FrameSlot() }
    }

    // MARK: - one per device

    private static var contexts: [UInt64: RenderContext] = [:]

    /// The context for a device — built on first use, kept for the life of
    /// the process (a device outlives every window).
    static func shared(for device: MTLDevice) throws -> RenderContext {
        if let existing = contexts[device.registryID] { return existing }
        let made = try RenderContext(device: device)
        contexts[device.registryID] = made
        return made
    }

    // MARK: - frames

    /// The slot for the next frame. Called once per frame, after
    /// `frameSemaphore.wait()` admitted it.
    func takeFrameSlot() -> FrameSlot {
        let slot = frameSlots[frameIndex % MetalRenderer.framesInFlight]
        frameIndex &+= 1
        return slot
    }

    // MARK: - fonts

    func retainFont(_ key: FontKey) {
        fontUsers[key, default: 0] += 1
    }

    /// The counterpart of `retainFont`. When nobody is left on a font its
    /// glyphs are dead weight in a packer that cannot evict: clear everything
    /// and let the next frame put its own working set back.
    func releaseFont(_ key: FontKey) {
        guard let users = fontUsers[key] else { return }
        if users > 1 {
            fontUsers[key] = users - 1
            return
        }
        fontUsers[key] = nil
        clearGlyphs()
    }

    /// Fonts with at least one renderer on them — for the tests.
    var fontsInUse: Int { fontUsers.count }

    private func clearGlyphs() {
        guard glyphCache.rasterised != rasterisedAtClear else { return }
        rasterisedAtClear = glyphCache.rasterised
        glyphCache.reset()
        grayAtlas.clear()
        colorAtlas.clear()
    }

    // MARK: - pipelines

    private static func pipeline(device: MTLDevice,
                                 library: MTLLibrary,
                                 vertex: String,
                                 fragment: String,
                                 premultiplied: Bool) throws -> MTLRenderPipelineState {
        guard let vfn = library.makeFunction(name: vertex),
              let ffn = library.makeFunction(name: fragment) else {
            throw RendererError.pipelineCreationFailed("\(vertex)/\(fragment)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vfn
        descriptor.fragmentFunction = ffn
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = MetalRenderer.pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        // Glyph fragments come out premultiplied by their coverage; flat quads
        // carry a straight alpha so a tint lies over the cell colour.
        attachment.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RendererError.pipelineCreationFailed("\(vertex)/\(fragment): \(error)")
        }
    }
}

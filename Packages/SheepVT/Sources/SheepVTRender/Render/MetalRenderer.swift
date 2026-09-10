// SheepVTRender — the Metal frame.
//
// One drawable per frame, cleared to the theme background, then four instanced
// draws in a fixed order: cell backgrounds (with the selection and search tints
// laid over them), decorations, gray glyphs, colour glyphs. Nothing here knows
// about the scrollback: every frame builds instances for the visible
// `rows × cols` only.
//
// Two caches carry the work between frames:
//
//   * a **row cache** keyed on everything that changes a row's pixels — the
//     row's `generation`, the overlay state on that line, the cursor *if this
//     is the row it is painted on*, the palette/font generation, the column
//     count and the scale. A hit is a memcpy of the row's
//     `RowBuilder.Output`; a miss rebuilds one row.
//   * a **glyph cache** keyed on (scalar or cluster, bold, italic) plus the
//     atlas generation. When an atlas fills up it resets and bumps its
//     generation: the caches are dropped and the frame is built once more with
//     the atlases *frozen*, so an overflow degrades to a few skipped glyphs
//     instead of looping (SwiftTerm's rule).
//
// Buffers come from a three-deep ring guarded by a semaphore — a slot is only
// touched again once the GPU has finished the frame that used it, so there is
// no lock anywhere in this file.

import AppKit
import CoreGraphics
import Metal
import QuartzCore
import SheepVT

public enum RendererError: Error {
    case commandQueueUnavailable
    case atlasUnavailable
    case libraryCompilationFailed(String)
    case pipelineCreationFailed(String)
    case samplerUnavailable
}

public final class MetalRenderer {
    // MARK: - stored

    public let device: MTLDevice

    /// The font set the glyphs come from. Replacing it drops both caches — the
    /// view builds a new one when the font or the backing scale changes.
    public var fontSet: FontSet {
        didSet {
            glyphCache.fontSet = fontSet
            glyphCache.reset()
            fontGeneration &+= 1
            invalidateRows()
        }
    }

    /// The theme + 256-colour table. Replacing it drops the row cache.
    public var palette: Palette {
        didSet { paletteGeneration &+= 1; invalidateRows() }
    }

    public var fontSmoothing: Bool {
        didSet {
            guard fontSmoothing != oldValue else { return }
            rasterizer.fontSmoothing = fontSmoothing
            glyphCache.reset()
            fontGeneration &+= 1
            invalidateRows()
        }
    }

    public private(set) var lastFrameStats: (rowsRebuilt: Int, rowsCached: Int, glyphsRasterised: Int) = (0, 0, 0)

    private let commandQueue: MTLCommandQueue
    private let backgroundPipeline: MTLRenderPipelineState
    private let glyphGrayPipeline: MTLRenderPipelineState
    private let glyphColorPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let grayAtlas: GlyphAtlas
    private let colorAtlas: GlyphAtlas
    private let rasterizer: GlyphRasterizer
    private let glyphCache: GlyphCache

    private var rowCache: [Int: RowCacheEntry] = [:]
    private var paletteGeneration: UInt64 = 0
    private var fontGeneration: UInt64 = 0
    /// `Terminal.defaultColorGeneration` as of the last sync — see `encode`.
    /// Starts at the value a fresh terminal has, so an OSC 10/11 that arrived
    /// before the very first frame is still a difference and still applies.
    private var appliedDefaultColorGeneration: UInt64 = 0
    private var appliedPaletteOverrides: [UInt32?] = Array(repeating: nil, count: 256)

    private let frameSemaphore = DispatchSemaphore(value: MetalRenderer.framesInFlight)
    private var frameSlots: [FrameSlot]
    private var frameIndex = 0

    /// How many frames the CPU may run ahead of the GPU.
    public static let framesInFlight = 3
    /// The pixel format both the layer and the offscreen test texture use.
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    // MARK: - init

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.commandQueueUnavailable }
        self.commandQueue = queue

        guard let gray = GlyphAtlas(device: device,
                                    maxSize: GlyphAtlas.recommendedMaxSize(device: device, format: .grayscale),
                                    format: .grayscale),
              let color = GlyphAtlas(device: device,
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
        self.backgroundPipeline = try MetalRenderer.pipeline(device: device,
                                                             library: library,
                                                             vertex: Shaders.backgroundVertex,
                                                             fragment: Shaders.backgroundFragment,
                                                             premultiplied: false)
        self.glyphGrayPipeline = try MetalRenderer.pipeline(device: device,
                                                            library: library,
                                                            vertex: Shaders.glyphVertex,
                                                            fragment: Shaders.glyphFragmentGray,
                                                            premultiplied: true)
        self.glyphColorPipeline = try MetalRenderer.pipeline(device: device,
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

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        let set = FontSet(font: font, scale: NSScreen.main?.backingScaleFactor ?? 2)
        self.fontSet = set
        self.palette = Palette(colors: .sheepTerm)
        self.fontSmoothing = false
        self.rasterizer = GlyphRasterizer()
        self.rasterizer.fontSmoothing = false
        self.glyphCache = GlyphCache(fontSet: set, rasterizer: rasterizer, gray: gray, color: color)
        self.frameSlots = (0..<MetalRenderer.framesInFlight).map { _ in FrameSlot() }
    }

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

    // MARK: - public entry points

    /// Drop every cached row (a theme change, a resize, a new overlay revision).
    public func invalidateRows() {
        rowCache.removeAll(keepingCapacity: true)
    }

    /// Draw one frame of `terminal` into `layer`'s next drawable.
    ///
    /// - Returns: whether a frame reached the layer. The caller keeps its dirty
    ///   state when it did not — a frame nobody drew is a frame nobody will
    ///   draw again unless the view asks for it.
    @discardableResult
    public func render(terminal: Terminal, overlay: FrameOverlay, layer: CAMetalLayer, scale: CGFloat) -> Bool {
        layer.device = layer.device ?? device
        layer.pixelFormat = MetalRenderer.pixelFormat
        let size = layer.drawableSize
        guard size.width >= 1, size.height >= 1 else { return false }
        guard let drawable = layer.nextDrawable() else { return false }
        if layer.presentsWithTransaction {
            // Synchronous presentation (live resize): the drawable must be
            // presented after the command buffer is scheduled, not queued on
            // it, so that it lands inside the current CA transaction.
            return encode(terminal: terminal, overlay: overlay, texture: drawable.texture, scale: scale,
                          present: nil) { commandBuffer in
                commandBuffer.waitUntilScheduled()
                drawable.present()
            }
        } else {
            return encode(terminal: terminal, overlay: overlay, texture: drawable.texture, scale: scale,
                          present: { commandBuffer in commandBuffer.present(drawable) }, afterCommit: nil)
        }
    }

    /// The same frame, into a texture the caller owns. Used by the tests (and by
    /// anything that wants a snapshot) — it shares the encode path exactly.
    @discardableResult
    public func render(terminal: Terminal, overlay: FrameOverlay, into texture: MTLTexture, scale: CGFloat) -> Bool {
        encode(terminal: terminal, overlay: overlay, texture: texture, scale: scale, present: nil, afterCommit: nil)
    }

    private lazy var surfaces = SurfacePresenter(device: device)

    /// Draw one frame into an IOSurface and hand it to a plain `CALayer`
    /// (see `SurfacePresenter`). `pixelSize` = layer bounds × scale.
    @discardableResult
    public func render(terminal: Terminal, overlay: FrameOverlay, surfaceLayer layer: CALayer, pixelSize: CGSize, scale: CGFloat) -> Bool {
        guard pixelSize.width >= 1, pixelSize.height >= 1 else { return false }
        surfaces.prepare(pixelSize: pixelSize)
        guard let texture = surfaces.nextTexture() else { return false }
        let drawn = encode(terminal: terminal, overlay: overlay, texture: texture, scale: scale, present: nil) { commandBuffer in
            commandBuffer.waitUntilCompleted()
        }
        // A frame that was never encoded must not be shown: the slot still
        // holds the picture from three frames ago.
        if drawn { surfaces.present(texture, on: layer, scale: scale) }
        return drawn
    }

    // MARK: - the frame

    /// Returns false when nothing was submitted (no command buffer / encoder).
    @discardableResult
    private func encode(terminal: Terminal,
                        overlay: FrameOverlay,
                        texture: MTLTexture,
                        scale: CGFloat,
                        present: ((MTLCommandBuffer) -> Void)?,
                        afterCommit: ((MTLCommandBuffer) -> Void)?) -> Bool {
        let effectiveScale = scale > 0 ? scale : 1
        // OSC 4 overrides only reach the palette when they actually changed —
        // assigning `palette` drops the row cache.
        if terminal.palette != appliedPaletteOverrides {
            appliedPaletteOverrides = terminal.palette
            palette.apply(overrides: terminal.palette)
        }
        // OSC 10/11: the device asked for different default colours. The core
        // records them (and answers queries with them); the picture has to
        // follow, or a program that sets its own scheme reports one thing and
        // shows another. Driven by the core's generation counter, not by
        // comparing colours: the host's theme owns fg/bg and sets both sides
        // itself, so a value comparison would overwrite the theme every frame.
        if terminal.defaultColorGeneration != appliedDefaultColorGeneration {
            appliedDefaultColorGeneration = terminal.defaultColorGeneration
            var colors = palette.colors
            colors.foreground = terminal.defaultForeground
            colors.background = terminal.defaultBackground
            palette.colors = colors        // `palette` didSet drops the row cache
        }

        var frameOverlay = overlay
        frameOverlay.cursorVisible = overlay.cursorVisible && terminal.cursorVisible
        if frameOverlay.highlightOverrides == nil, let highlight = overlay.highlight {
            frameOverlay.highlightOverrides = { [weak terminal] line in
                guard let terminal else { return nil }
                return highlight.overrides(line: line, in: terminal)
            }
        }

        var frame = buildFrame(terminal: terminal, overlay: frameOverlay, scale: effectiveScale)
        // An atlas that filled up during the pass invalidated every placement:
        // drop the caches and build the frame once more with the atlases frozen,
        // so a pathological page loses glyphs instead of spinning.
        if frame.atlasReset {
            glyphCache.reset()
            invalidateRows()
            grayAtlas.frozen = true
            colorAtlas.frozen = true
            frame = buildFrame(terminal: terminal, overlay: frameOverlay, scale: effectiveScale)
            grayAtlas.frozen = false
            colorAtlas.frozen = false
        }
        frameSemaphore.wait()
        // Atlas uploads happen only once no frame that may sample the old
        // texels is in flight past the ring depth.
        grayAtlas.flush()
        colorAtlas.flush()
        let slot = frameSlots[frameIndex % MetalRenderer.framesInFlight]
        frameIndex &+= 1

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return false
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        let clear = palette.rgba(frameOverlay.reverseVideo ? palette.colors.foreground : palette.colors.background)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x),
                                                                  green: Double(clear.y),
                                                                  blue: Double(clear.z),
                                                                  alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()   // an uncommitted buffer counts against the queue's 64
            frameSemaphore.signal()
            return false
        }

        var viewport = SIMD2<Float>(Float(CGFloat(texture.width) / effectiveScale),
                                    Float(CGFloat(texture.height) / effectiveScale))
        draw(frame.backgrounds, slot: slot, index: 0, pipeline: backgroundPipeline,
             texture: nil, viewport: &viewport, encoder: encoder)
        draw(frame.decorations, slot: slot, index: 1, pipeline: backgroundPipeline,
             texture: nil, viewport: &viewport, encoder: encoder)
        draw(frame.grayGlyphs, slot: slot, index: 2, pipeline: glyphGrayPipeline,
             texture: grayAtlas.texture, viewport: &viewport, encoder: encoder)
        draw(frame.colorGlyphs, slot: slot, index: 3, pipeline: glyphColorPipeline,
             texture: colorAtlas.texture, viewport: &viewport, encoder: encoder)

        encoder.endEncoding()
        present?(commandBuffer)
        // Built in a nonisolated context: under this target's default MainActor
        // isolation an inline closure would be inferred main-actor and trap when
        // Metal's completion thread runs it.
        commandBuffer.addCompletedHandler(MetalRenderer.completion(signalling: frameSemaphore))
        commandBuffer.commit()
        afterCommit?(commandBuffer)
        if present == nil && afterCommit == nil { commandBuffer.waitUntilCompleted() }

        lastFrameStats = (frame.rowsRebuilt, frame.rowsCached, frame.glyphsRasterised)
        return true
    }

    private nonisolated static func completion(signalling semaphore: DispatchSemaphore) -> @Sendable (MTLCommandBuffer) -> Void {
        { _ in semaphore.signal() }
    }

    static let cacheDebug = ProcessInfo.processInfo.environment["SHEEPVT_CACHEDEBUG"] == "1"
    private struct Frame {
        var debugged = false
        var backgrounds: [BackgroundInstance] = []
        var decorations: [BackgroundInstance] = []
        var grayGlyphs: [GlyphInstance] = []
        var colorGlyphs: [GlyphInstance] = []
        var rowsRebuilt = 0
        var rowsCached = 0
        var glyphsRasterised = 0
        var atlasReset = false
    }

    private func buildFrame(terminal: Terminal, overlay: FrameOverlay, scale: CGFloat) -> Frame {
        var frame = Frame()
        let buffer = terminal.buffer
        let cols = terminal.cols
        let rows = terminal.rows
        let grayGeneration = grayAtlas.generation
        let colorGeneration = colorAtlas.generation
        let rasterisedBefore = glyphCache.rasterised

        let builder = RowBuilder(palette: palette, metrics: fontSet.metrics, glyphs: glyphCache)
        let cellH = Float(fontSet.metrics.height)
        // Search tints for the visible lines, built once per frame instead of
        // scanning every match for every row (O(matches) per row was the
        // most expensive thing a fully cached frame did).
        let firstLine = buffer.lineNumber(ofViewportRow: 0)
        let lastLine = buffer.lineNumber(ofViewportRow: Swift.max(rows - 1, 0))
        let searchMap = searchMap(overlay: overlay, cols: cols, firstLine: firstLine, lastLine: lastLine)
        var overlay = overlay
        // Installed even when the map came back empty. An empty map is not
        // "no answer", it is the answer "no match is on screen" — and a search
        // whose 10,000 matches are all in the scrollback produces exactly that.
        // Leaving the closure nil there dropped the row builder into its
        // O(matches)-per-row fallback for every row it rebuilt: 0.41 s vs
        // 0.003 s for 40 rows x 50 rounds, Release. The fallback is for callers
        // that never compute a map at all (`RowBuilder` used directly).
        overlay.searchTints = { line in (searchMap[line] ?? []).map { ($0.lo..<$0.hi, $0.current) } }
        // Where the cursor sits in the viewport (it may be scrolled out of it).
        let cursorViewportRow = buffer.ybase + buffer.y - buffer.ydisp
        let cursorCol = Swift.min(Swift.max(buffer.x, 0), Swift.max(cols - 1, 0))
        // Nothing is drawn for the cursor in the off half of the blink, so the
        // whole cursor half of the key is absent on those frames — and absent
        // on every row that is not the cursor's, always. It used to be in all
        // of them: a cursor blinking twice a second then rebuilt the whole
        // screen twice a second for as long as the window was open, idle or
        // not (40 rows out of 40, +67% frame time, measured at 120x40).
        let cursorPainted = overlay.cursorVisible && overlay.cursorBlinkOn

        for screenRow in 0..<rows {
            let line = buffer.lineNumber(ofViewportRow: screenRow)
            let row = buffer.row(line: line)
            // A move without a blink still repaints both ends: the row the
            // cursor left drops its `CursorKey`, the row it arrived on gains one.
            let cursor: (col: Int, style: CursorStyle)? =
                cursorPainted && screenRow == cursorViewportRow ? (cursorCol, terminal.cursorStyle) : nil
            let key = RowKey(rowID: row.map(ObjectIdentifier.init),
                             generation: row?.generation ?? 0,
                             materialised: row != nil,
                             cols: cols,
                             scale: scale,
                             paletteGeneration: paletteGeneration,
                             fontGeneration: fontGeneration,
                             reverseVideo: overlay.reverseVideo,
                             selection: overlay.selection?.columnRange(onLine: line),
                             searches: searchMap[line] ?? [],
                             highlight: overlay.highlightOverrides?(line),
                             cursor: cursor.map { CursorKey(col: $0.col,
                                                            style: $0.style.rawValue,
                                                            focused: overlay.focused) })

            // Rows are cached y-relative (built as if they were viewport row
            // 0) and shifted into place here, so a scroll — every new line
            // of output — keeps every row that did not change. Before, the
            // screen row was part of the key and a scroll missed all of them.
            let output: RowBuilder.Output
            if let cached = rowCache[line], cached.key == key {
                output = cached.output
                frame.rowsCached += 1
            } else {
                if MetalRenderer.cacheDebug, let c = rowCache[line], !frame.debugged {
                    frame.debugged = true
                    let k = c.key
                    var why: [String] = []
                    if k.generation != key.generation { why.append("generation \(k.generation)->\(key.generation)") }
                    if k.materialised != key.materialised { why.append("materialised") }
                    if k.cols != key.cols { why.append("cols") }
                    if k.scale != key.scale { why.append("scale") }
                    if k.paletteGeneration != key.paletteGeneration { why.append("palette") }
                    if k.fontGeneration != key.fontGeneration { why.append("font") }
                    if k.reverseVideo != key.reverseVideo { why.append("reverse") }
                    if k.selection != key.selection { why.append("selection") }
                    if k.searches != key.searches { why.append("searches") }
                    if k.highlight != key.highlight { why.append("highlight") }
                    if k.cursor != key.cursor { why.append("cursor \(String(describing: k.cursor))->\(String(describing: key.cursor))") }
                    FileHandle.standardError.write("[cache] line \(line) screenRow \(screenRow) miss: \(why.isEmpty ? "no field differs?!" : why.joined(separator: ", "))\n".data(using: .utf8)!)
                } else if MetalRenderer.cacheDebug, rowCache[line] == nil, !frame.debugged {
                    frame.debugged = true
                    FileHandle.standardError.write("[cache] line \(line) screenRow \(screenRow) miss: no entry (cache count \(rowCache.count))\n".data(using: .utf8)!)
                }
                output = builder.build(row: row, line: line, screenRow: 0,
                                       cols: cols, overlay: overlay, cursor: cursor)
                rowCache[line] = RowCacheEntry(key: key, output: output)
                frame.rowsRebuilt += 1
            }
            let dy = Float(screenRow) * cellH
            MetalRenderer.append(output.backgrounds, to: &frame.backgrounds, dy: dy)
            MetalRenderer.append(output.decorations, to: &frame.decorations, dy: dy)
            MetalRenderer.append(output.grayGlyphs, to: &frame.grayGlyphs, dy: dy)
            MetalRenderer.append(output.colorGlyphs, to: &frame.colorGlyphs, dy: dy)
        }

        // Lines that scrolled out of the retained range never come back.
        if rowCache.count > rows * 4 {
            let visible = Set((0..<rows).map { buffer.lineNumber(ofViewportRow: $0) })
            rowCache = rowCache.filter { visible.contains($0.key) }
        }

        frame.glyphsRasterised = glyphCache.rasterised - rasterisedBefore
        frame.atlasReset = grayAtlas.generation != grayGeneration || colorAtlas.generation != colorGeneration
        return frame
    }

    /// The search tints touching a line, as the row-cache key sees them.
    /// line → tints, for the lines in the viewport only. O(matches + rows).
    private func searchMap(overlay: FrameOverlay, cols: Int, firstLine: Int, lastLine: Int) -> [Int: [SearchKeyEntry]] {
        guard !overlay.searchMatches.isEmpty, firstLine <= lastLine else { return [:] }
        var map: [Int: [SearchKeyEntry]] = [:]
        for match in overlay.searchMatches {
            let lo = Swift.max(match.start.line, firstLine)
            let hi = Swift.min(match.end.line, lastLine)
            guard lo <= hi else { continue }
            let current = overlay.currentMatch == match
            for line in lo...hi {
                let a = line == match.start.line ? match.start.col : 0
                let b = line == match.end.line ? match.end.col + 1 : cols
                map[line, default: []].append(SearchKeyEntry(lo: a, hi: b, current: current))
            }
        }
        return map
    }

    @inline(__always)
    private static func append(_ src: [BackgroundInstance], to dst: inout [BackgroundInstance], dy: Float) {
        dst.reserveCapacity(dst.count + src.count)
        for var inst in src { inst.position.y += dy; dst.append(inst) }
    }
    @inline(__always)
    private static func append(_ src: [GlyphInstance], to dst: inout [GlyphInstance], dy: Float) {
        dst.reserveCapacity(dst.count + src.count)
        for var inst in src { inst.position.y += dy; dst.append(inst) }
    }

    /// Drop the presentation surfaces (a hidden tab); `render` recreates them.
    public func releaseSurfaces() { surfaces.release() }

    // MARK: - drawing

    private func draw<T>(_ instances: [T],
                         slot: FrameSlot,
                         index: Int,
                         pipeline: MTLRenderPipelineState,
                         texture: MTLTexture?,
                         viewport: inout SIMD2<Float>,
                         encoder: MTLRenderCommandEncoder) {
        guard !instances.isEmpty else { return }
        guard let buffer = slot.buffer(index, instances: instances, device: device) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: instances.count * 6)
    }
}

// MARK: - the row cache key

/// Everything that changes a row's pixels. Two frames with the same key produce
/// the same instances, so a hit is a straight copy of the cached arrays.
nonisolated struct SearchKeyEntry: Equatable, Sendable {
    var lo: Int
    var hi: Int
    var current: Bool
}

/// The cursor, as the one row that paints it sees it. Nil everywhere else — a
/// single optional rather than four loose fields so that "no cursor here" is one
/// value and the blink cannot leak into a row that draws nothing for it.
/// `focused` lives in here because it only ever changes the cursor's shape.
nonisolated struct CursorKey: Equatable, Sendable {
    var col: Int
    var style: Int
    var focused: Bool
}

nonisolated struct RowKey: Equatable, Sendable {
    /// Which `Row` object the cached instances were built from — a region
    /// scroll moves references between line numbers and two rows written the
    /// same number of times share a generation.
    var rowID: ObjectIdentifier?
    var generation: UInt64
    var materialised: Bool
    var cols: Int
    var scale: CGFloat
    var paletteGeneration: UInt64
    var fontGeneration: UInt64
    var reverseVideo: Bool
    var selection: Range<Int>?
    var searches: [SearchKeyEntry]
    var highlight: [UInt32]?
    var cursor: CursorKey?
}

nonisolated struct RowCacheEntry: Sendable {
    var key: RowKey
    var output: RowBuilder.Output
}

// MARK: - buffer ring

/// One slot of the three-deep ring: four growable buffers, reused for as long as
/// they are big enough. A slot is only touched again after the semaphore admits
/// the frame that owns it, so nothing here needs a lock.
private final class FrameSlot {
    private var buffers: [MTLBuffer?] = [nil, nil, nil, nil]

    func buffer<T>(_ index: Int, instances: [T], device: MTLDevice) -> MTLBuffer? {
        let length = instances.count * MemoryLayout<T>.stride
        guard length > 0 else { return nil }
        if buffers[index] == nil || buffers[index]!.length < length {
            var size = 4096
            while size < length { size *= 2 }
            buffers[index] = device.makeBuffer(length: size, options: .storageModeShared)
        }
        guard let buffer = buffers[index] else { return nil }
        instances.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer.contents(), base, length) }
        }
        return buffer
    }
}

// MARK: - the glyph cache

/// `GlyphSource` over agent A's rasteriser and atlases. Keyed on the text (one
/// scalar, or a whole grapheme cluster) plus bold/italic; an entry is stale as
/// soon as its atlas bumps its generation.
private final class GlyphCache: GlyphSource {
    private struct Key: Hashable {
        var text: String
        var bold: Bool
        var italic: Bool
        var span: Int = 1
    }
    private struct Entry {
        var placement: GlyphPlacement?
        var generation: UInt64
        var format: GlyphAtlasFormat
    }

    var fontSet: FontSet
    private let rasterizer: GlyphRasterizer
    private let gray: GlyphAtlas
    private let color: GlyphAtlas
    private var cache: [Key: Entry] = [:]
    /// Total glyphs rasterised since creation (the renderer reports deltas).
    private(set) var rasterised = 0

    init(fontSet: FontSet, rasterizer: GlyphRasterizer, gray: GlyphAtlas, color: GlyphAtlas) {
        self.fontSet = fontSet
        self.rasterizer = rasterizer
        self.gray = gray
        self.color = color
    }

    func reset() { cache.removeAll(keepingCapacity: true) }

    func glyph(_ scalar: Unicode.Scalar, bold: Bool, italic: Bool) -> GlyphPlacement? {
        lookup(Key(text: String(scalar), bold: bold, italic: italic), scalar: scalar)
    }

    func glyph(cluster: String, span: Int, bold: Bool, italic: Bool) -> GlyphPlacement? {
        lookup(Key(text: cluster, bold: bold, italic: italic, span: Swift.max(1, Swift.min(2, span))), scalar: nil)
    }

    private func lookup(_ key: Key, scalar: Unicode.Scalar?) -> GlyphPlacement? {
        if let entry = cache[key] {
            let generation = entry.format == .bgra ? color.generation : gray.generation
            if entry.placement == nil || entry.generation == generation { return entry.placement }
        }
        // nil = the atlas had no room right now (frozen rebuild pass): not
        // cached, so the glyph is retried next frame instead of vanishing.
        guard let made = rasterise(key: key, scalar: scalar) else { return nil }
        cache[key] = made
        return made.placement
    }

    private func rasterise(key: Key, scalar: Unicode.Scalar?) -> Entry? {
        let metrics = fontSet.metrics
        let scale = Swift.max(metrics.scale, 1)
        var bitmap: GlyphBitmap?
        if let scalar {
            let font = fontSet.font(for: scalar, bold: key.bold, italic: key.italic)
            let glyphID = FontSet.glyph(scalar, in: font)
            if glyphID != 0 { bitmap = rasterizer.rasterize(font: font, glyph: glyphID) }
        } else {
            let line = fontSet.line(for: key.text, bold: key.bold, italic: key.italic)
            bitmap = rasterizer.rasterize(line: line,
                                          cellWidthPx: Int((metrics.width * scale).rounded()) * key.span,
                                          cellHeightPx: Int((metrics.height * scale).rounded()),
                                          baselinePx: metrics.baseline * scale)
        }
        guard let bm = bitmap, bm.width > 0, bm.height > 0 else {
            return Entry(placement: nil, generation: 0, format: .grayscale)
        }
        let format: GlyphAtlasFormat = bm.isColor ? .bgra : .grayscale
        let atlas = bm.isColor ? color : gray
        guard let region = atlas.ensureRegion(width: bm.width, height: bm.height) else {
            return nil
        }
        atlas.write(region: region, bitmap: bm)
        rasterised += 1

        // The bitmap and the atlas are both top-down, so the region maps
        // straight onto the quad: v0 is its top row.
        let size = Float(atlas.size)
        let uvOrigin = SIMD2<Float>(Float(region.x) / size, Float(region.y) / size)
        let uvSize = SIMD2<Float>(Float(region.width) / size, Float(region.height) / size)
        // `bearing` is the bitmap's bottom-left relative to the pen origin, in
        // pixels; the pen sits on the baseline at the cell's left edge.
        let offset = SIMD2<Float>(Float(bm.bearing.x / scale),
                                  Float(metrics.baseline - (bm.bearing.y + CGFloat(bm.height)) / scale))
        let pointSize = SIMD2<Float>(Float(CGFloat(bm.width) / scale), Float(CGFloat(bm.height) / scale))
        let placement = GlyphPlacement(atlas: format,
                                       uvOrigin: uvOrigin,
                                       uvSize: uvSize,
                                       offset: offset,
                                       size: pointSize)
        return Entry(placement: placement, generation: atlas.generation, format: format)
    }
}

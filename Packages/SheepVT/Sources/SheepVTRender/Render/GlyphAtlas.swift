// SheepVT — the glyph atlas: a shelf packer over one MTLTexture with a CPU
// shadow copy.
//
// Ported from SwiftTerm `GlyphAtlas.swift` (MIT), with two changes:
//
//  * uploads are **deferred**: `write` only touches the shadow copy and marks
//    rows dirty; `flush()` does one `MTLTexture.replace` for the dirty band. A
//    frame that rasterises 200 new glyphs pays one upload, not 200.
//  * `didReset` is replaced by `generation`, bumped on every grow *and* reset:
//    a cached `AtlasRegion` is valid only while the generation it was taken at
//    still matches.

import CoreGraphics
import Foundation
import Metal
import os

/// A rectangle of atlas pixels. Content only — the 1-px padding lives outside it.
public nonisolated struct AtlasRegion: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public nonisolated enum GlyphAtlasFormat: Sendable {
    /// `r8Unorm`: coverage only, colour comes from the shader.
    case grayscale
    /// `bgra8Unorm`: colour glyphs (emoji) that carry their own pixels.
    case bgra

    public var label: String {
        switch self {
        case .grayscale: return "grayscale"
        case .bgra: return "bgra"
        }
    }

    public var bytesPerPixel: Int {
        switch self {
        case .grayscale: return 1
        case .bgra: return 4
        }
    }

    public var pixelFormat: MTLPixelFormat {
        switch self {
        case .grayscale: return .r8Unorm
        case .bgra: return .bgra8Unorm
        }
    }
}

public final class GlyphAtlas {
    /// Slack reserved on every side of a glyph so bilinear sampling never bleeds
    /// a neighbour in.
    public static let padding = 1

    private static let log = Logger(subsystem: "Bestchaan.SheepVT", category: "GlyphAtlas")

    private let device: MTLDevice
    public let format: GlyphAtlasFormat
    private let bytesPerPixel: Int
    public let maxSize: Int

    public private(set) var size: Int
    public private(set) var texture: MTLTexture
    /// Bumped on grow and on reset: every region cached against an older
    /// generation is stale and must be re-packed.
    public private(set) var generation: UInt64 = 0

    /// While frozen, `ensureRegion` never grows or resets: a request that does
    /// not fit returns nil. The renderer freezes the atlases on its final
    /// rebuild pass so an overflowing working set degrades to skipped glyphs
    /// instead of invalidating regions the frame already references.
    public var frozen = false

    /// CPU shadow copy of the whole texture.
    private var data: [UInt8]
    private var nextX = 0
    private var nextY = 0
    private var rowHeight = 0

    /// Dirty band since the last flush, as a half-open row range.
    private var dirtyMinY = Int.max
    private var dirtyMaxY = 0

    /// One-shot guards for the overflow diagnostics, re-armed on a real
    /// capacity gain so a sustained overflow logs once per episode.
    private var loggedFrozenMiss = false
    private var loggedResetOverflow = false

    public init?(device: MTLDevice, size: Int = 1024, maxSize: Int, format: GlyphAtlasFormat) {
        self.device = device
        self.format = format
        self.bytesPerPixel = format.bytesPerPixel
        // The starting size never exceeds maxSize (tests use a small one) and
        // never drops below a useful minimum.
        let clampedMin = max(min(size, maxSize), 64)
        self.maxSize = max(maxSize, clampedMin)
        self.size = clampedMin
        guard let texture = GlyphAtlas.makeTexture(device: device, size: clampedMin, format: format) else {
            return nil
        }
        self.texture = texture
        self.data = [UInt8](repeating: 0, count: clampedMin * clampedMin * format.bytesPerPixel)
    }

    // MARK: - packing

    /// Reserve room for a `width × height` glyph, growing (then, as a last
    /// resort, resetting) the atlas as needed. Returns the **content** region;
    /// the padding around it is already reserved.
    public func ensureRegion(width: Int, height: Int) -> AtlasRegion? {
        guard width > 0, height > 0 else { return nil }
        let paddedWidth = width + GlyphAtlas.padding * 2
        let paddedHeight = height + GlyphAtlas.padding * 2

        if let region = reserve(width: paddedWidth, height: paddedHeight) {
            return contentRegion(in: region, width: width, height: height)
        }
        if frozen {
            if !loggedFrozenMiss {
                loggedFrozenMiss = true
                GlyphAtlas.log.fault("glyph atlas (\(self.format.label, privacy: .public)) frozen and full; glyphs skipped this frame")
            }
            return nil
        }
        // A glyph larger than the biggest atlas we may allocate never fits.
        if paddedWidth > maxSize || paddedHeight > maxSize {
            return nil
        }

        var newSize = size
        while newSize < maxSize && (newSize < max(paddedWidth, paddedHeight) || !canFit(height: paddedHeight, size: newSize)) {
            newSize *= 2
        }
        newSize = min(newSize, maxSize)
        if newSize > size {
            grow(to: newSize)
            if let region = reserve(width: paddedWidth, height: paddedHeight) {
                return contentRegion(in: region, width: width, height: height)
            }
        }

        if !loggedResetOverflow {
            loggedResetOverflow = true
            GlyphAtlas.log.error("glyph atlas (\(self.format.label, privacy: .public)) reset at size \(self.size): working set exceeds capacity")
        }
        reset()
        return reserve(width: paddedWidth, height: paddedHeight).map {
            contentRegion(in: $0, width: width, height: height)
        }
    }

    private func contentRegion(in padded: AtlasRegion, width: Int, height: Int) -> AtlasRegion {
        AtlasRegion(x: padded.x + GlyphAtlas.padding,
                    y: padded.y + GlyphAtlas.padding,
                    width: width,
                    height: height)
    }

    private func reserve(width: Int, height: Int) -> AtlasRegion? {
        guard width <= size, height <= size else { return nil }
        if nextX + width > size {
            nextX = 0
            nextY += rowHeight
            rowHeight = 0
        }
        guard nextY + height <= size else { return nil }
        let region = AtlasRegion(x: nextX, y: nextY, width: width, height: height)
        nextX += width
        rowHeight = max(rowHeight, height)
        return region
    }

    private func canFit(height: Int, size: Int) -> Bool {
        nextY + height <= size
    }

    // MARK: - writing

    /// Copy `bitmap` into `region` (grayscale atlases keep the alpha channel),
    /// replicating the edge pixels into the padding. The upload happens in
    /// `flush()`.
    public func write(region: AtlasRegion, bitmap: GlyphBitmap) {
        guard bitmap.width == region.width, bitmap.height == region.height else { return }
        guard region.x >= 0, region.y >= 0,
              region.x + region.width <= size, region.y + region.height <= size,
              region.width > 0, region.height > 0 else { return }
        let expected = bitmap.width * bitmap.height * 4
        guard bitmap.pixels.count >= expected else { return }

        let width = region.width
        let height = region.height
        let atlasStride = size * bytesPerPixel
        let srcStride = width * 4
        let padding = GlyphAtlas.padding

        let paddedX = max(0, region.x - padding)
        let paddedY = max(0, region.y - padding)
        let paddedRight = min(size, region.x + width + padding)
        let paddedBottom = min(size, region.y + height + padding)

        let contentRowBytes = width * bytesPerPixel
        let firstRowOffset = region.y * atlasStride + region.x * bytesPerPixel
        let lastRowOffset = (region.y + height - 1) * atlasStride + region.x * bytesPerPixel

        bitmap.pixels.withUnsafeBufferPointer { src in
            data.withUnsafeMutableBytes { raw in
                guard let dst = raw.baseAddress, let srcBase = src.baseAddress else { return }
                // 1. Content rows. A CGBitmapContext keeps its first scanline at
                //    the TOP of the image (verified 2026-09-07 by dumping an "L":
                //    the bar lands in the last rows), and the atlas is top-down
                //    too, so rows copy straight across. SwiftTerm flipped here
                //    because its quads were y-up; ours are top-left based.
                for row in 0..<height {
                    let srcOffset = row * srcStride
                    let dstOffset = (region.y + row) * atlasStride + region.x * bytesPerPixel
                    switch format {
                    case .bgra:
                        memcpy(dst + dstOffset, srcBase + srcOffset, srcStride)
                    case .grayscale:
                        // A gather of every fourth byte: no bulk form of this one.
                        for col in 0..<width {
                            raw[dstOffset + col] = src[srcOffset + col * 4 + 3]
                        }
                    }
                }

                // 2. Replicate the first/last content rows into the top/bottom
                //    padding.
                for row in paddedY..<region.y {
                    memcpy(dst + row * atlasStride + region.x * bytesPerPixel,
                           dst + firstRowOffset, contentRowBytes)
                }
                for row in (region.y + height)..<paddedBottom {
                    memcpy(dst + row * atlasStride + region.x * bytesPerPixel,
                           dst + lastRowOffset, contentRowBytes)
                }

                // 3. Replicate the left/right edge pixels across the padded
                //    height. Step 2 already filled column `region.x` of the top
                //    and bottom rows, so the four corners come out right.
                for row in paddedY..<paddedBottom {
                    let rowBase = row * atlasStride
                    let leftSrc = rowBase + region.x * bytesPerPixel
                    let rightSrc = rowBase + (region.x + width - 1) * bytesPerPixel
                    for col in paddedX..<region.x {
                        memcpy(dst + rowBase + col * bytesPerPixel, dst + leftSrc, bytesPerPixel)
                    }
                    for col in (region.x + width)..<paddedRight {
                        memcpy(dst + rowBase + col * bytesPerPixel, dst + rightSrc, bytesPerPixel)
                    }
                }
            }
        }

        markDirty(from: paddedY, to: paddedBottom)
    }

    /// Upload every row touched since the last flush. Cheap and idempotent when
    /// nothing changed.
    public func flush() {
        guard dirtyMinY < dirtyMaxY else { return }
        let minY = max(0, dirtyMinY)
        let maxY = min(size, dirtyMaxY)
        dirtyMinY = Int.max
        dirtyMaxY = 0
        guard minY < maxY else { return }

        let stride = size * bytesPerPixel
        let regionMTL = MTLRegionMake2D(0, minY, size, maxY - minY)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: regionMTL,
                            mipmapLevel: 0,
                            withBytes: base.advanced(by: minY * stride),
                            bytesPerRow: stride)
        }
    }

    private func markDirty(from minY: Int, to maxY: Int) {
        dirtyMinY = min(dirtyMinY, minY)
        dirtyMaxY = max(dirtyMaxY, maxY)
    }

    // MARK: - grow / reset

    private func grow(to newSize: Int) {
        guard newSize > size, !frozen else { return }
        guard let newTexture = GlyphAtlas.makeTexture(device: device, size: newSize, format: format) else {
            GlyphAtlas.log.error("glyph atlas (\(self.format.label, privacy: .public)) grow to \(newSize) failed")
            return
        }
        var updated = [UInt8](repeating: 0, count: newSize * newSize * bytesPerPixel)
        let oldStride = size * bytesPerPixel
        let newStride = newSize * bytesPerPixel
        updated.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                for row in 0..<size {
                    memcpy(dstBase + row * newStride, srcBase + row * oldStride, oldStride)
                }
            }
        }
        size = newSize
        data = updated
        texture = newTexture
        generation &+= 1
        loggedFrozenMiss = false
        loggedResetOverflow = false
        // The new texture starts empty: everything has to go up again.
        dirtyMinY = 0
        dirtyMaxY = newSize
    }

    private func reset() {
        guard !frozen else { return }
        nextX = 0
        nextY = 0
        rowHeight = 0
        // One memset: the shadow copy is 64 MB for an 8192² grey atlas, and a
        // per-byte loop over that is tens of milliseconds inside a frame.
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset(base, 0, raw.count)
        }
        generation &+= 1
        dirtyMinY = 0
        dirtyMaxY = size
        loggedResetOverflow = false   // a later overflow episode logs again
    }

    // MARK: - sizing

    /// The largest 2D texture dimension the device supports.
    public static func maxTextureDimension(of device: MTLDevice) -> Int {
        if device.supportsFamily(.apple3) || device.supportsFamily(.mac2) {
            return 16384
        }
        return 8192
    }

    /// Cap that balances CJK-sized working sets against memory (the atlas keeps
    /// a CPU shadow copy, so the cost is 2 × size² × bytesPerPixel).
    public static func recommendedMaxSize(device: MTLDevice, format: GlyphAtlasFormat) -> Int {
        let cap = format == .grayscale ? 8192 : 4096
        return min(cap, maxTextureDimension(of: device))
    }

    private static func makeTexture(device: MTLDevice, size: Int, format: GlyphAtlasFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.pixelFormat,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}

import Foundation

/// Libretro pixel formats (mirrors RETRO_PIXEL_FORMAT_*).
enum RetroPixelFormat: Int32 {
    case rgb1555 = 0
    case xrgb8888 = 1
    case rgb565 = 2
}

/// Converts libretro framebuffers into tightly-packed RGBA8 (byte order
/// B,G,R,A — matches Metal's bgra8Unorm) for upload into a texture.
///
/// Pure Swift, no Metal dependency, so the self-test can reuse it to
/// inspect mock-core frames headlessly.
enum PixelConverter {
    private static let expand5: [UInt8] = (0..<32).map { UInt8(($0 * 255 + 15) / 31) }
    private static let expand6: [UInt8] = (0..<64).map { UInt8(($0 * 255 + 31) / 63) }

    /// Converts one frame. `srcRowBytes` is the source row stride (pitch);
    /// destination is tightly packed (width * 4 bytes per row).
    static func convert(
        format: RetroPixelFormat,
        src: UnsafeRawPointer,
        width: Int,
        height: Int,
        srcRowBytes: Int,
        dst: UnsafeMutableRawPointer
    ) {
        let dstRowBytes = width * 4
        switch format {
        case .rgb565:
            convert565(src: src, width: width, height: height, srcRowBytes: srcRowBytes, dst: dst, dstRowBytes: dstRowBytes)
        case .rgb1555:
            convert1555(src: src, width: width, height: height, srcRowBytes: srcRowBytes, dst: dst, dstRowBytes: dstRowBytes)
        case .xrgb8888:
            convertXRGB(src: src, width: width, height: height, srcRowBytes: srcRowBytes, dst: dst, dstRowBytes: dstRowBytes)
        }
    }

    private static func convert565(src: UnsafeRawPointer, width: Int, height: Int, srcRowBytes: Int, dst: UnsafeMutableRawPointer, dstRowBytes: Int) {
        for y in 0..<height {
            let s = src.advanced(by: y * srcRowBytes)
            let d = dst.advanced(by: y * dstRowBytes)
            var x = 0
            while x < width {
                let p = s.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)
                let r5 = (p >> 11) & 0x1F
                let g6 = (p >> 5) & 0x3F
                let b5 = p & 0x1F
                d.storeBytes(of: expand5[Int(b5)], toByteOffset: x * 4 + 0, as: UInt8.self)
                d.storeBytes(of: expand6[Int(g6)], toByteOffset: x * 4 + 1, as: UInt8.self)
                d.storeBytes(of: expand5[Int(r5)], toByteOffset: x * 4 + 2, as: UInt8.self)
                d.storeBytes(of: 255, toByteOffset: x * 4 + 3, as: UInt8.self)
                x += 1
            }
        }
    }

    private static func convert1555(src: UnsafeRawPointer, width: Int, height: Int, srcRowBytes: Int, dst: UnsafeMutableRawPointer, dstRowBytes: Int) {
        for y in 0..<height {
            let s = src.advanced(by: y * srcRowBytes)
            let d = dst.advanced(by: y * dstRowBytes)
            var x = 0
            while x < width {
                let p = s.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self)
                let r5 = (p >> 10) & 0x1F
                let g5 = (p >> 5) & 0x1F
                let b5 = p & 0x1F
                d.storeBytes(of: expand5[Int(b5)], toByteOffset: x * 4 + 0, as: UInt8.self)
                d.storeBytes(of: expand5[Int(g5)], toByteOffset: x * 4 + 1, as: UInt8.self)
                d.storeBytes(of: expand5[Int(r5)], toByteOffset: x * 4 + 2, as: UInt8.self)
                d.storeBytes(of: 255, toByteOffset: x * 4 + 3, as: UInt8.self)
                x += 1
            }
        }
    }

    private static func convertXRGB(src: UnsafeRawPointer, width: Int, height: Int, srcRowBytes: Int, dst: UnsafeMutableRawPointer, dstRowBytes: Int) {
        // XRGB8888 little-endian memory order is B,G,R,X — same as bgra8Unorm,
        // so we only need to force the alpha byte to opaque.
        let rowBytes = width * 4
        for y in 0..<height {
            let s = src.advanced(by: y * srcRowBytes)
            let d = dst.advanced(by: y * dstRowBytes)
            memcpy(d, s, rowBytes)
            var x = 0
            while x < width {
                d.storeBytes(of: 255, toByteOffset: x * 4 + 3, as: UInt8.self)
                x += 1
            }
        }
    }
}

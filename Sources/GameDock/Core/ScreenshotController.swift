import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshot capture. Two paths:
///   • emulator: snapshot the in-process libretro frame (FrameSlot → CGImage).
///   • Steam/anything else: ScreenCaptureKit full-display capture (requires
///     Screen Recording permission — explained in-app first).
final class ScreenshotController {
    /// Provides the active emulator session's frame slot (nil when not emulating).
    var emulatorFrameSlot: (() -> FrameSlot?)?

    /// Fired on the main thread after a capture is written to disk (the game
    /// title it was saved under) — drives the "Capture saved" toast.
    var onSaved: ((String) -> Void)?
    static let directory: URL = {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Leblanc Captures", isDirectory: true)
    }()

    // MARK: - Emulator (in-process frame)

    func captureEmulator(title: String) {
        guard let slot = emulatorFrameSlot?() else {
            Log.warn("ScreenshotController: no emulator frame available")
            return
        }
        var image: CGImage?
        slot.withLatest { ptr, width, height, rowBytes, _ in
            image = cgImage(fromBGRA: ptr, width: width, height: height, rowBytes: rowBytes)
        }
        if let image {
            save(image: image, title: title)
        }
    }

    /// BGRA (little-endian) buffer → CGImage.
    private func cgImage(fromBGRA ptr: UnsafeRawPointer, width: Int, height: Int, rowBytes: Int) -> CGImage? {
        let data = Data(bytes: ptr, count: rowBytes * height) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: space, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Steam / external (ScreenCaptureKit)

    func captureScreen(title: String) async {
        if !CGPreflightScreenCaptureAccess() {
            // First use: explain, then let macOS prompt.
            await MainActor.run {
                // (The env error banner is shown by the caller before this.)
            }
            _ = CGRequestScreenCaptureAccess()
            if !CGPreflightScreenCaptureAccess() {
                Log.warn("ScreenshotController: screen recording permission denied")
                return
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2
            config.height = Int(display.height) * 2
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            save(image: image, title: title)
        } catch {
            Log.error("ScreenshotController: screen capture failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Saving

    /// Filename-safe version of a game title — the shared prefix used both when
    /// saving captures and when matching them back to a game (CaptureStore).
    static func sanitizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func save(image: CGImage, title: String) {
        try? FileManager.default.createDirectory(at: ScreenshotController.directory, withIntermediateDirectories: true)

        let safeTitle = ScreenshotController.sanitizedTitle(title)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let url = ScreenshotController.directory
            .appendingPathComponent("\(safeTitle) \(stamp).png")

        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url, options: .atomic)
            Log.info("ScreenshotController: saved \(url.lastPathComponent)")
            let savedTitle = title
            DispatchQueue.main.async { [weak self] in
                self?.onSaved?(savedTitle)
            }
        }
    }
}

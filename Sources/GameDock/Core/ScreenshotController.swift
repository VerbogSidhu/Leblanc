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
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
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
            // First use: request access. macOS shows its prompt asynchronously
            // — the answer cannot exist yet, so don't attempt a doomed capture;
            // bail and let the user grant, then retry.
            _ = CGRequestScreenCaptureAccess()
            Log.warn("ScreenshotController: screen recording permission needed — grant in System Settings → Privacy & Security → Screen Recording, then retry")
            return
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

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    private func save(image: CGImage, title: String) {
        do {
            try FileManager.default.createDirectory(at: ScreenshotController.directory, withIntermediateDirectories: true)
        } catch {
            Log.error("ScreenshotController: could not create captures directory — \(error.localizedDescription)")
            return
        }

        let safeTitle = ScreenshotController.sanitizedTitle(title)
        let stamp = Self.filenameFormatter.string(from: Date())
        var url = ScreenshotController.directory
            .appendingPathComponent("\(safeTitle) \(stamp).png")
        if FileManager.default.fileExists(atPath: url.path) {
            // Same-second capture: append milliseconds instead of overwriting.
            let ms = Calendar.current.component(.nanosecond, from: Date()) / 1_000_000
            url = ScreenshotController.directory
                .appendingPathComponent("\(safeTitle) \(stamp).\(String(format: "%03d", ms)).png")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            Log.error("ScreenshotController: PNG encoding failed")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("ScreenshotController: write failed — \(error.localizedDescription)")
            return
        }
        Log.info("ScreenshotController: saved \(url.lastPathComponent)")
        let savedTitle = title
        DispatchQueue.main.async { [weak self] in
            self?.onSaved?(savedTitle)
        }
    }
}

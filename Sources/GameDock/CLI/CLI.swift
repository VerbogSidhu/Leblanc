import Foundation
import GameController

/// Dumps the parsed Steam library. Used to validate VDF/ACF parsing against
/// a real Steam install (this machine has one).
enum CLIScanSteam {
    static func run() -> Bool {
        let library = SteamLibrary()
        let folders = library.steamAppsFolders()
        Log.cliPrint("Steam root: \(library.steamRoot()?.path ?? "NOT FOUND")")
        Log.cliPrint("steamapps folders (\(folders.count)):")
        for folder in folders {
            Log.cliPrint("  \(folder.path)")
        }

        let games = library.installedGames()
        Log.cliPrint("\nInstalled games (\(games.count)):")
        for game in games {
            let played = game.lastPlayed.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "never"
            let art = library.gridArtPath(forAppID: game.appID)?.path ?? "-"
            Log.cliPrint("  [\(game.appID)] \(game.name)  (lastPlayed: \(played))  art: \(art)")
        }
        Log.cliPrint("\nScan \(games.isEmpty ? "FAILED" : "OK")")
        return !games.isEmpty
    }
}

// MARK: - --selftest (emulator end-to-end)

/// Loads the mock libretro core, runs frames, and asserts the full
/// dlopen → callback → frame → audio → input round-trip headlessly.
enum CLISelfTest {
    static let JOYPAD_RIGHT: Int = 7

    static func run() -> Bool {
        let corePath = ProcessInfo.processInfo.environment["GAMEDOCK_CORE_PATH"] ?? "build/mockcore.dylib"
        Log.cliPrint("SELFTEST: loading core \(corePath)")

        let session = EmulatorSession(corePath: corePath, romPath: nil, romData: nil)

        // 1. Load.
        do {
            try session.load()
        } catch {
            Log.cliPrint("SELFTEST FAIL: load error \(error)")
            return false
        }

        guard let info = session.systemInfo else {
            Log.cliPrint("SELFTEST FAIL: no system info")
            return false
        }
        let libName = info.library_name.map { String(cString: $0) } ?? "?"
        if libName.isEmpty {
            Log.cliPrint("SELFTEST FAIL: empty library name")
            return false
        }
        Log.cliPrint("  core: \(libName) need_fullpath=\(info.need_fullpath)")

        guard let av = session.avInfo else {
            Log.cliPrint("SELFTEST FAIL: no av info")
            return false
        }
        Log.cliPrint("  geometry: \(av.geometry.base_width)x\(av.geometry.base_height) fps=\(av.timing.fps)")

        // 2. Start.
        session.start()

        // Helper to sleep approximate frames.
        func runFrames(_ n: Int) {
            let interval = (av.timing.fps > 0 ? av.timing.fps : 60.0)
            Thread.sleep(forTimeInterval: Double(n) / interval + 0.05)
        }

        // Capture the square's current X centroid from the latest frame.
        func currentSquareX() -> Float? {
            var x: Float? = nil
            session.frameSlot.withLatest { ptr, width, height, _, _ in
                x = squareCenter(from: ptr, width: width, height: height)?.x
            }
            return x
        }

        // Short windows (10 frames) so the square never wraps around, keeping
        // the X displacement monotonic. Base rate = 1 px/frame; holding RIGHT
        // adds 3 px/frame.

        // 3a. Measure a released (slow) window.
        session.inputSnapshot.setButton(port: 0, id: JOYPAD_RIGHT, pressed: false)
        runFrames(10)
        let relStart = currentSquareX()
        runFrames(10)
        let relEnd = currentSquareX()
        let releasedDelta = abs((relEnd ?? 0) - (relStart ?? 0))

        // 3b. Measure a held (fast) window over the same frame count.
        session.inputSnapshot.setButton(port: 0, id: JOYPAD_RIGHT, pressed: true)
        runFrames(10)
        let heldStart = currentSquareX()
        runFrames(10)
        let heldEnd = currentSquareX()
        let heldDelta = abs((heldEnd ?? 0) - (heldStart ?? 0))

        let seqB = session.frameSlot.latestSeq

        // 5. Stop and teardown.
        session.requestStop()
        session.teardown()

        // 6. Assertions.
        var failures: [String] = []

        if seqB == 0 {
            failures.append("no video frames received")
        }

        // Geometry
        session.frameSlot.withLatest { _, width, height, _, _ in
            if width != 320 || height != 240 {
                failures.append("unexpected geometry \(width)x\(height)")
            }
        }

        // Format must be RGB565 (the mock requests it).
        if session.frameSlot.format != .rgb565 {
            failures.append("unexpected pixel format \(session.frameSlot.format)")
        }

        // Audio received.
        let audioSamples = session.audioRing.availableSamples
        if audioSamples == 0 {
            failures.append("no audio frames received")
        }

        // Movement: input-driven. Holding RIGHT must accelerate the square
        // relative to the released baseline over the same frame count.
        if relStart == nil || relEnd == nil || heldStart == nil || heldEnd == nil {
            failures.append("could not locate square in frame")
        } else if releasedDelta <= 0 || heldDelta <= 0 {
            failures.append("square did not move")
        } else if heldDelta <= releasedDelta {
            failures.append("input did not accelerate square (held=\(heldDelta) released=\(releasedDelta))")
        }

        // Cyan color check: sample the square's current position.
        session.frameSlot.withLatest { ptr, width, height, _, _ in
            if let center = squareCenter(from: ptr, width: width, height: height) {
                let bgra = pixel(at: center, ptr: ptr, width: width)
                // cyan = B=0xFF, G=0xFF, R=0x00, A=0xFF
                if !(bgra.b > 200 && bgra.g > 200 && bgra.r < 80) {
                    failures.append("square color not cyan (bgra=\(bgra.b),\(bgra.g),\(bgra.r),\(bgra.a))")
                }
            }
        }

        if failures.isEmpty {
            Log.cliPrint("  video frames: ok  audio samples: \(audioSamples)  movement: ok")
            Log.cliPrint("SELFTEST PASS")
            return true
        } else {
            for f in failures {
                Log.cliPrint("SELFTEST FAIL: \(f)")
            }
            return false
        }
    }

    /// Finds the centroid of the cyan square by scanning for cyan-ish pixels.
    private static func squareCenter(from ptr: UnsafeRawPointer, width: Int, height: Int) -> (x: Float, y: Float)? {
        let rowBytes = width * 4
        var sumX = 0, sumY = 0, count = 0
        for y in stride(from: 0, to: height, by: 2) {
            let row = ptr.advanced(by: y * rowBytes)
            for x in stride(from: 0, to: width, by: 2) {
                let off = x * 4
                let b = row.load(fromByteOffset: off, as: UInt8.self)
                let g = row.load(fromByteOffset: off + 1, as: UInt8.self)
                let r = row.load(fromByteOffset: off + 2, as: UInt8.self)
                if b > 200 && g > 200 && r < 80 {
                    sumX += x
                    sumY += y
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        return (Float(sumX) / Float(count), Float(sumY) / Float(count))
    }

    private static func pixel(at p: (x: Float, y: Float), ptr: UnsafeRawPointer, width: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let rowBytes = width * 4
        let off = Int(p.y) * rowBytes + Int(p.x) * 4
        let b = ptr.load(fromByteOffset: off, as: UInt8.self)
        let g = ptr.load(fromByteOffset: off + 1, as: UInt8.self)
        let r = ptr.load(fromByteOffset: off + 2, as: UInt8.self)
        let a = ptr.load(fromByteOffset: off + 3, as: UInt8.self)
        return (b, g, r, a)
    }
}

// MARK: - --diagnose-input

/// Prints connected GameController devices + their button inventory, plus the
/// raw HID device/element summary. Needs a live run loop to observe
/// GameController notifications, so we spin the main run loop briefly.
enum CLIDiagnoseInput {
    static func run() -> Bool {
        // Spin the main run loop so GCController notifications can arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            finish()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        return true
    }

    private static func finish() {
        Log.cliPrint("GameController devices:")
        let controllers = GCController.controllers()
        if controllers.isEmpty {
            Log.cliPrint("  (none connected)")
        }
        for controller in controllers {
            Log.cliPrint("  \(controller.productCategory) — extended: \(controller.extendedGamepad != nil)")
            let buttons = controller.physicalInputProfile.buttons
            Log.cliPrint("    buttons: \(buttons.keys.sorted().joined(separator: ", "))")
        }
        Log.cliPrint("")
        Log.cliPrint("Raw HID gamepads:")
        Log.cliPrint(GlobalHIDMonitor.shared.describeDevices())
    }
}

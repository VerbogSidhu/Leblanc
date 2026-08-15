import Foundation

/// Pure-logic assertion battery run via `--unit-test` (wired as `make test`).
///
/// This machine builds with Command Line Tools only — neither XCTest nor
/// swift-testing ships with CLT — so `swift test` can't link a test target
/// here. This CLI harness gives the same regression value for the pure-logic
/// modules (VDFParser, RomTitle, PixelConverter, entry-id derivation) with zero
/// toolchain dependencies. If Xcode is ever available, migrating these to a
/// real test target is a clean follow-up.
enum CLIUnitTest {
    static func run() -> Bool {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                Log.cliPrint("  ok   \(name)")
            } else {
                failures.append(name)
                Log.cliPrint("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        // MARK: - VDFParser

        Log.cliPrint("VDFParser:")
        do {
            let basic = """
            "AppState"
            {
            	"appid" "440"
            	"name" "Team Fortress 2"
            }
            """
            let v = VDFParser.parse(basic)
            check("root has AppState dict", v?["AppState"]?.dict != nil)
            check("appid parsed", v?["AppState"]?["appid"]?.string == "440")
            check("name parsed", v?["AppState"]?["name"]?.string == "Team Fortress 2")

            check("flat pair", VDFParser.parse("\"key\" \"value\"")?["key"]?.string == "value")

            let winPath = "\"path\" \"D:\\Games\\Steam\""
            check("backslashes preserved (no escape mangling)",
                  VDFParser.parse(winPath)?["path"]?.string == "D:\\Games\\Steam")

            let quoted = "\"name\" \"He said \\\"hi\\\"\""
            check("escaped quotes", VDFParser.parse(quoted)?["name"]?.string == "He said \"hi\"")

            let lineComment = "\"a\" \"b\" // trailing comment\n\"c\" \"d\""
            check("line comment skipped", VDFParser.parse(lineComment)?["c"]?.string == "d")

            let blockComment = "/* block */ \"a\" \"b\""
            check("block comment skipped", VDFParser.parse(blockComment)?["a"]?.string == "b")

            check("BOM tolerated", VDFParser.parse("\u{FEFF}\"a\" \"b\"")?["a"]?.string == "b")

            let nested = "\"root\" { \"child\" { \"x\" \"1\" } }"
            check("nested dicts", VDFParser.parse(nested)?["root"]?["child"]?["x"]?.string == "1")

            check("unbalanced brace → nil", VDFParser.parse("\"a\" {") == nil)
            check("unterminated string → nil", VDFParser.parse("\"a\" \"b") == nil)
        }

        // MARK: - RomTitle

        Log.cliPrint("RomTitle:")
        do {
            check("artKey keeps exact stem",
                  RomTitle.artKey(from: "Shin Megami Tensei - Persona 2 - Innocent Sin (USA).iso")
                    == "Shin Megami Tensei - Persona 2 - Innocent Sin (USA)")
            check("cleanedTitle strips region tag",
                  RomTitle.cleanedTitle(from: "Shin Megami Tensei - Persona 2 - Innocent Sin (USA).iso")
                    == "Shin Megami Tensei - Persona 2 - Innocent Sin")
            check("cleanedTitle strips tags + region + rev",
                  RomTitle.cleanedTitle(from: "Super Game [b] (Europe) (Rev 1).nes") == "Super Game")
            check("cleanedTitle strips multi-region",
                  RomTitle.cleanedTitle(from: "Game (En,Fr,De,Es,It).nds") == "Game")
            check("cleanedTitle strips translation tag",
                  RomTitle.cleanedTitle(from: "Game [T+Eng1.0] (USA).gba") == "Game")
            check("cleanedTitle normalizes underscores",
                  RomTitle.cleanedTitle(from: "Game_With_Underscores (USA).zip") == "Game With Underscores")
            check("cleanedTitle collapses whitespace",
                  RomTitle.cleanedTitle(from: "Game   [b]  (USA).iso") == "Game")
            check("cleanedTitle trailing year tag is stripped (defined behavior)",
                  RomTitle.cleanedTitle(from: "Pokemon (2001).zip") == "Pokemon")
        }

        // MARK: - PixelConverter

        Log.cliPrint("PixelConverter:")
        do {
            func convert(_ format: RetroPixelFormat, src: [UInt8], srcRowBytes: Int) -> [UInt8] {
                var dst = [UInt8](repeating: 0, count: src.count == 4 ? 4 : 4)
                src.withUnsafeBytes { sb in
                    dst.withUnsafeMutableBytes { db in
                        PixelConverter.convert(format: format, src: sb.baseAddress!, width: 1, height: 1,
                                               srcRowBytes: srcRowBytes, dst: db.baseAddress!)
                    }
                }
                return dst
            }

            // rgb565: red 0xF800 → BGRA(0, 0, 255, 255)
            let red = convert(.rgb565, src: [0x00, 0xF8], srcRowBytes: 2)
            check("rgb565 red", red == [0, 0, 255, 255], "got \(red)")
            // rgb565: green 0x07E0 → BGRA(0, 255, 0, 255)
            let green = convert(.rgb565, src: [0xE0, 0x07], srcRowBytes: 2)
            check("rgb565 green", green == [0, 255, 0, 255], "got \(green)")
            // rgb565: blue 0x001F → BGRA(255, 0, 0, 255)
            let blue = convert(.rgb565, src: [0x1F, 0x00], srcRowBytes: 2)
            check("rgb565 blue", blue == [255, 0, 0, 255], "got \(blue)")
            // rgb565: mid-gray (r=16,g=8,b=8) → expand5/6 rounding
            let mid: UInt16 = (16 << 11) | (8 << 5) | 8
            let midBytes = [UInt8(truncatingIfNeeded: mid & 0xFF), UInt8(truncatingIfNeeded: mid >> 8)]
            let gray = convert(.rgb565, src: midBytes, srcRowBytes: 2)
            check("rgb565 mid-gray rounded",
                  gray == [UInt8((8 * 255 + 15) / 31), UInt8((8 * 255 + 31) / 63), UInt8((16 * 255 + 15) / 31), 255],
                  "got \(gray)")

            // rgb1555: red (alpha bit + r5=31) 0x7C00 → BGRA(0, 0, 255, 255)
            let r1555 = convert(.rgb1555, src: [0x00, 0x7C], srcRowBytes: 2)
            check("rgb1555 red", r1555 == [0, 0, 255, 255], "got \(r1555)")
            // rgb1555: r5=16, g5=8, b5=4 (0x4104) → distinct channel values
            let m1555 = convert(.rgb1555, src: [0x04, 0x41], srcRowBytes: 2)
            check("rgb1555 distinct channels",
                  m1555 == [UInt8((4 * 255 + 15) / 31), UInt8((8 * 255 + 15) / 31), UInt8((16 * 255 + 15) / 31), 255],
                  "got \(m1555)")

            // xrgb8888: memory order BGRA is copied through, alpha forced opaque
            let xrgb = convert(.xrgb8888, src: [10, 20, 30, 40], srcRowBytes: 4)
            check("xrgb8888 passthrough + opaque alpha", xrgb == [10, 20, 30, 255], "got \(xrgb)")
        }

        // MARK: - Entry-id derivation (Models)

        Log.cliPrint("GameEntry.romID:")
        do {
            let a = GameEntry.romID(source: .psp, path: "/Games/Game.iso")
            check("deterministic", a == GameEntry.romID(source: .psp, path: "/Games/Game.iso"))
            check("case-insensitive",
                  a == GameEntry.romID(source: .psp, path: "/games/game.ISO"))
            check("different paths differ",
                  a != GameEntry.romID(source: .psp, path: "/Games/Other.iso"))
            check("different sources differ",
                  a != GameEntry.romID(source: .ds, path: "/Games/Game.nds"))
        }

        // MARK: - CoreOptionParser

        Log.cliPrint("CoreOptionParser:")
        do {
            check("parses title", CoreOptionParser.parse("Resolution; 1x|2x|4x")?.title == "Resolution")
            check("parses values", CoreOptionParser.parse("Resolution; 1x|2x|4x")?.values == ["1x", "2x", "4x"])
            check("trims whitespace", CoreOptionParser.parse("  Res ;  a | b  ")?.values == ["a", "b"])
            check("rejects missing values", CoreOptionParser.parse("NoOptions") == nil)
            check("rejects empty option list", CoreOptionParser.parse("Title; |") == nil)
        }

        // MARK: - SettingsStore per-game core options

        Log.cliPrint("SettingsStore coreOptions:")
        do {
            let suiteName = "clitest-\(UUID().uuidString)"
            guard let suite = UserDefaults(suiteName: suiteName) else {
                failures.append("could not create test UserDefaults suite")
                return false
            }
            let store = SettingsStore(defaults: suite)
            store.setCoreOption("4x", key: "mockcore_resolution", core: "ds", game: "game-1")
            store.setCoreOption("disabled", key: "mockcore_threaded", core: "ds", game: "game-1")
            check("round-trip", store.coreOption("mockcore_resolution", core: "ds", game: "game-1") == "4x")
            check("per-game isolation", store.coreOption("mockcore_resolution", core: "ds", game: "game-2") == nil)
            check("per-core isolation", store.coreOption("mockcore_resolution", core: "psp", game: "game-1") == nil)
            let reloaded = SettingsStore(defaults: suite)
            check("persists across instances",
                  reloaded.coreOption("mockcore_threaded", core: "ds", game: "game-1") == "disabled")
        }

        // MARK: - QuickBarModel wrap-around (contextual items)

        Log.cliPrint("QuickBarModel:")
        do {
            let model = QuickBarModel()
            let items: [QuickBarItem] = [.home, .coreOptions, .saveState, .loadState, .reset, .discord, .settings]
            model.reset()
            check("starts at home", model.selection == .home)
            _ = model.handle(.down, items: items)
            check("down moves to next", model.selection == .coreOptions)
            for _ in 1..<items.count { _ = model.handle(.down, items: items) }
            check("wraps back to home", model.selection == .home)
            _ = model.handle(.up, items: items)
            check("up wraps to last", model.selection == .settings)
            let confirmed = model.handle(.confirm, items: items)
            check("confirm returns selection", confirmed == .settings)
            check("left is a no-op", model.handle(.left, items: items) == nil)
            // Context switch: selection not in the new list resets to first.
            let xmbItems: [QuickBarItem] = [.home, .favorite, .discord, .settings]
            _ = model.handle(.down, items: xmbItems) // selection (.settings) is in the list
            _ = model.handle(.up, items: xmbItems)
            check("stays in range across contexts", xmbItems.contains(model.selection))
            let emuItems: [QuickBarItem] = [.home, .coreOptions, .saveState]
            model.reset()
            _ = model.handle(.down, items: emuItems)
            _ = model.handle(.down, items: emuItems)
            _ = model.handle(.down, items: emuItems)
            check("wraps within emulator list", model.selection == .home)
        }

        if failures.isEmpty {
            Log.cliPrint("UNIT TESTS PASS")
            return true
        }
        Log.cliPrint("UNIT TESTS FAIL — \(failures.count) failure(s)")
        return false
    }
}

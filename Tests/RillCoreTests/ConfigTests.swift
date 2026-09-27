import Foundation
import Testing
@testable import RillCore

struct ConfigTests {
    @Test func emptyFileIsDefaults() throws {
        let (config, warnings) = try Config.parse("")
        #expect(config == Config())
        #expect(warnings.isEmpty)
    }

    @Test func fullExample() throws {
        let (config, warnings) = try Config.parse("""
        [picker]
        roots = ["~/github", "~/Papers"]
        [synctex]
        inverse_command = "code -g %file:%line"
        activate_on_inverse = ""
        activate_on_forward = true
        [view]
        default_zoom = 1.5
        dark_mode = "on"
        page_gap = 12
        change_markers = false
        spread = "book"
        trim = true
        rounded_corners = 10
        scroll_step = 0.25
        zoom_step = 1.5
        dark_paper = "#1d2021"
        dark_ink = "#EBDBB2"
        background = "glass"
        overlays = "glass"
        glass_style = "clear"
        glass_tint = "#00000040"
        [keys]
        "<C-f>" = "screen_down"
        "J" = "nop"
        "<S-Down>" = "page_next"
        """)
        #expect(warnings.isEmpty)
        #expect(config.pickerRoots == ["~/github", "~/Papers"])
        #expect(config.inverseCommand.template == "code -g %file:%line")
        #expect(config.activateOnInverse == nil)
        #expect(config.activateOnForward)
        #expect(config.defaultZoom == .magnification(1.5))
        #expect(config.darkMode == .on)
        #expect(config.pageGap == 12)
        #expect(!config.changeMarkers)
        #expect(config.spread == .book)
        #expect(config.trim)
        #expect(config.cornerRadius == 10)
        #expect(config.scrollStep == 0.25)
        #expect(config.zoomStep == 1.5)
        #expect(config.darkPaper == RGBColor(red: 0x1d / 255.0, green: 0x20 / 255.0, blue: 0x21 / 255.0))
        #expect(config.darkInk == RGBColor(red: 0xeb / 255.0, green: 0xdb / 255.0, blue: 0xb2 / 255.0))
        #expect(config.background == .glass)
        #expect(config.overlays == .glass)
        #expect(config.glassStyle == .clear)
        #expect(config.glassTint == RGBColor(red: 0, green: 0, blue: 0, alpha: 0x40 / 255.0))
        #expect(config.keymap["<C-f>"] == .screenDown)
        #expect(config.keymap["J"] == nil)
        #expect(config.keymap["<S-Down>"] == .pageNext)
        #expect(config.keymap["j"] == .scrollDown) // defaults kept
    }

    @Test func badValuesWarnAndKeepDefaults() throws {
        let (config, warnings) = try Config.parse("""
        stray = 1
        [view]
        default_zoom = "huge"
        dark_mode = true
        page_gap = 500
        colour = "red"
        background = "frosted"
        overlays = 1
        glass_style = "frosted"
        glass_tint = "#0000"
        rounded_corners = "round"
        scroll_step = 2
        zoom_step = 1
        dark_paper = "#fff"
        dark_ink = 0.8
        [keys]
        "x" = "explode"
        "y" = 3
        [fonts]
        size = 12
        """)
        #expect(config == Config())
        #expect(warnings == [
            #"[fonts]: unknown table"#,
            #"[keys] x: unknown action explode"#,
            #"[keys] y: expected an action name, got integer"#,
            #"[view] background: expected "solid", "blur" or "glass""#,
            #"[view] colour: unknown setting"#,
            ##"[view] dark_ink: expected a colour like "#1d2021""##,
            #"[view] dark_mode: expected "system", "on" or "off""#,
            ##"[view] dark_paper: expected a colour like "#1d2021""##,
            #"[view] default_zoom: expected "fit-width", "fit-page" or a number"#,
            #"[view] glass_style: expected "regular" or "clear""#,
            ##"[view] glass_tint: expected a colour like "#1d2021" or "#1d202180""##,
            #"[view] overlays: expected "blur" or "glass""#,
            #"[view] page_gap: expected a number from 0 to 100"#,
            "[view] rounded_corners: expected true, false or a number from 0 to 100",
            "[view] scroll_step: expected a number from 0.01 to 1",
            "[view] zoom_step: expected a number from 1.01 to 4",
            "stray: settings belong in a [table]",
        ])
    }

    @Test func roundedCornersTakesABoolOrARadius() throws {
        #expect(try Config.parse("[view]\nrounded_corners = true").config.cornerRadius == Config.defaultCornerRadius)
        #expect(try Config.parse("[view]\nrounded_corners = false").config.cornerRadius == 0)
        #expect(try Config.parse("[view]\nrounded_corners = 3.5").config.cornerRadius == 3.5)
    }

    @Test func defaultDarkColoursMatchTheirHex() throws {
        let (config, warnings) = try Config.parse("[view]\ndark_paper = \"#242424\"\ndark_ink = \"#dbdbdb\"")
        #expect(warnings.isEmpty)
        #expect(config == Config())
    }

    @Test func hexColoursAreStrict() {
        for bad in ["242424", "#24242", "#2424244", "#gggggg", "#+24242", "black"] { #expect(RGBColor(hex: bad) == nil) }
        #expect(RGBColor(hex: "#ffffff") == RGBColor(red: 1, green: 1, blue: 1))
        #expect(RGBColor(hex: "#ffffff80") == nil)
        for bad in ["#fff", "#ffffff8", "#ffffffgg", "#ffffff+8"] { #expect(RGBColor(hexWithAlpha: bad) == nil) }
        #expect(RGBColor(hexWithAlpha: "#ffffff") == RGBColor(red: 1, green: 1, blue: 1))
        #expect(RGBColor(hexWithAlpha: "#ff000080") == RGBColor(red: 1, green: 0, blue: 0, alpha: 0x80 / 255.0))
    }

    @Test func malformedTOMLThrows() {
        #expect(throws: TOMLError.self) { try Config.parse("[view\ndefault_zoom = 1") }
    }

    @Test func remappedKeysReachTheResolver() throws {
        let (config, _) = try Config.parse("[keys]\n\"<S-Down>\" = \"page_next\"\n\"J\" = \"nop\"")
        var resolver = KeyResolver(keymap: config.keymap)
        #expect(resolver.feed("<S-Down>") == .action(.pageNext, count: nil))
        #expect(resolver.feed("J") == .unbound)
    }

    @Test func defaultURLHonoursXDG() {
        #expect(Config.defaultURL(environment: ["XDG_CONFIG_HOME": "/x"]).path == "/x/rill/config.toml")
        #expect(Config.defaultURL(environment: [:]).path.hasSuffix("/.config/rill/config.toml"))
    }

    @Test func everyActionHasASummary() {
        for action in Action.allCases { #expect(!action.summary.isEmpty) }
    }
}

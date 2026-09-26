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
            #"[view] colour: unknown setting"#,
            #"[view] dark_mode: expected "system", "on" or "off""#,
            #"[view] default_zoom: expected "fit-width", "fit-page" or a number"#,
            #"[view] page_gap: expected a number from 0 to 100"#,
            "stray: settings belong in a [table]",
        ])
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

import Testing
@testable import RillCore

struct TOMLTests {
    @Test func specExampleConfig() throws {
        let doc = try TOML.parse(#"""
        # rill config
        [picker]
        roots = ["~/github", "~/Papers"]

        [synctex]
        inverse_command = "nvim --headless -c \"VimtexInverseSearch %line '%file'\""
        activate_on_inverse = "com.mitchellh.ghostty"
        activate_on_forward = false

        [view]
        default_zoom = "fit-width"   # or 1.25
        page_gap = 8
        scale = 1.25

        [keys]
        "J" = "page_next"
        "<C-d>" = 'half_page_down'
        "g?" = "nop"
        """#)
        #expect(doc["picker"]?["roots"] == .array([.string("~/github"), .string("~/Papers")]))
        #expect(doc["synctex"]?["inverse_command"]?.string == #"nvim --headless -c "VimtexInverseSearch %line '%file'""#)
        #expect(doc["synctex"]?["activate_on_forward"] == .bool(false))
        #expect(doc["view"]?["default_zoom"] == .string("fit-width"))
        #expect(doc["view"]?["page_gap"] == .integer(8))
        #expect(doc["view"]?["scale"] == .float(1.25))
        #expect(doc["keys"]?["<C-d>"] == .string("half_page_down"))
        #expect(doc["keys"]?["g?"] == .string("nop"))
    }

    @Test func multiLineArrayWithComments() throws {
        let doc = try TOML.parse("""
        roots = [
          "~/a",  # first
          "~/b",
        ]
        after = 1
        """)
        #expect(doc[""]?["roots"] == .array([.string("~/a"), .string("~/b")]))
        #expect(doc[""]?["after"] == .integer(1))
    }

    @Test func hashInsideStringIsNotAComment() throws {
        let doc = try TOML.parse(#"k = "a # b" # real comment"#)
        #expect(doc[""]?["k"] == .string("a # b"))
    }

    @Test func escapes() throws {
        let doc = try TOML.parse(#"k = "tab\there é \\ \"q\"""#)
        #expect(doc[""]?["k"] == .string("tab\there é \\ \"q\""))
    }

    @Test func numbers() throws {
        let doc = try TOML.parse("a = -3\nb = 1_000\nc = 0.5\nd = 1e2")
        #expect(doc[""]?["a"] == .integer(-3))
        #expect(doc[""]?["b"] == .integer(1000))
        #expect(doc[""]?["c"] == .float(0.5))
        #expect(doc[""]?["d"] == .float(100))
    }

    @Test func errorsNameTheLine() {
        #expect(throws: TOMLError(line: 2, message: "unrecognized value fit-width; strings need quotes")) {
            try TOML.parse("[view]\ndefault_zoom = fit-width")
        }
        #expect(throws: TOMLError(line: 1, message: "unterminated string")) { try TOML.parse(#"k = "abc"#) }
        #expect(throws: TOMLError(line: 3, message: "k is set twice")) { try TOML.parse("[t]\nk = 1\nk = 2") }
        #expect(throws: TOMLError(line: 3, message: "table [t] defined twice")) { try TOML.parse("[t]\na = 1\n[t]") }
        #expect(throws: TOMLError(line: 1, message: "inline tables are not supported")) { try TOML.parse("k = { a = 1 }") }
    }

    @Test func emptyDocument() throws {
        #expect(try TOML.parse("") == ["": [:]])
        #expect(try TOML.parse("# only a comment\n\n") == ["": [:]])
    }
}

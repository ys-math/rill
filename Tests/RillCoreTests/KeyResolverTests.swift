import Testing
@testable import RillCore

struct KeyResolverTests {
    @Test func singleKeyFiresImmediately() {
        var r = KeyResolver()
        #expect(r.feed("j") == .action(.scrollDown, count: nil))
        #expect(r.isIdle)
    }

    @Test func countPrefixesAction() {
        var r = KeyResolver()
        #expect(r.feed("1") == .pending(display: "1"))
        #expect(r.feed("2") == .pending(display: "12"))
        #expect(r.feed("G") == .action(.goToPage, count: 12))
    }

    @Test func zeroOnlyContinuesACount() {
        var r = KeyResolver()
        #expect(r.feed("0") == .unbound)
        #expect(r.feed("1") == .pending(display: "1"))
        #expect(r.feed("0") == .pending(display: "10"))
        #expect(r.feed("j") == .action(.scrollDown, count: 10))
    }

    @Test func multiKeySequence() {
        var r = KeyResolver()
        #expect(r.feed("g") == .pending(display: "g"))
        #expect(r.feed("g") == .action(.firstPage, count: nil))
        #expect(r.feed("3") == .pending(display: "3"))
        #expect(r.feed("g") == .pending(display: "3g"))
        #expect(r.feed("!") == .action(.toggleFrameHUD, count: 3))
    }

    @Test func unboundClearsBuffer() {
        var r = KeyResolver()
        _ = r.feed("5")
        _ = r.feed("g")
        #expect(r.feed("x") == .unbound)
        #expect(r.isIdle)
        #expect(r.feed("j") == .action(.scrollDown, count: nil))
    }

    @Test func escapeCancels() {
        var r = KeyResolver()
        _ = r.feed("4")
        #expect(r.feed("<Esc>") == .unbound)
        #expect(r.feed("k") == .action(.scrollUp, count: nil))
    }

    @Test func namedAndModifiedKeys() {
        var r = KeyResolver()
        #expect(r.feed("<C-d>") == .action(.halfPageDown, count: nil))
        #expect(r.feed("<S-Space>") == .action(.screenUp, count: nil))
    }

    @Test func customKeymap() {
        var r = KeyResolver(keymap: ["<C-f>": .screenDown, "zz": .fitPage])
        #expect(r.feed("j") == .unbound)
        #expect(r.feed("<C-f>") == .action(.screenDown, count: nil))
        #expect(r.feed("z") == .pending(display: "z"))
        #expect(r.feed("z") == .action(.fitPage, count: nil))
    }

    @Test func tokenizesBindings() {
        #expect(KeyMap.tokens(of: "g<C-d>x") == ["g", "<C-d>", "x"])
        #expect(KeyMap.tokens(of: "<") == ["<"])
        #expect(KeyMap.tokens(of: "<>") == ["<", ">"])
    }
}

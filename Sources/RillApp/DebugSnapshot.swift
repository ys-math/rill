import AppKit
import RillCore

/// Headless-ish visual check: with `RILL_SNAPSHOT=/path/out.png` set, the app types the keys in
/// `RILL_SNAPSHOT_KEYS` (space-separated sequences, one every 0.6 s), lets rendering settle,
/// writes the window's layer tree to a PNG and quits.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(window: NSWindow, document: DocumentViewController) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RILL_SNAPSHOT"] else { return }
        let steps = (env["RILL_SNAPSHOT_KEYS"] ?? "").split(separator: " ").map(String.init)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.8))
            var log = "active=\(NSApp.isActive) key=\(window.isKeyWindow) firstResponder=\(String(describing: window.firstResponder))\n"
            for step in steps {
                if env["RILL_SNAPSHOT_REAL_EVENTS"] != nil {
                    for token in KeyMap.tokens(of: step) { post(token, window: window) }
                } else {
                    document.feed(keys: step)
                }
                try? await Task.sleep(for: .seconds(0.6))
                log += "after \(step): \(document.debugStatus)\n"
            }
            let delay = Double(env["RILL_SNAPSHOT_DELAY"] ?? "") ?? 1.0
            try? await Task.sleep(for: .seconds(delay))
            let state = document.currentState()
            log += "final: pages=\(document.source.pageCount) page=\(state.position.page) offset=\(state.position.offset)\n"
            log += "final status: \(document.debugStatus)\n"
            try? log.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            write(window: window, to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Named keys: (keyCode, characters, charactersIgnoringModifiers, modifiers).
    private static let namedKeys: [String: (UInt16, String, String, NSEvent.ModifierFlags)] = [
        "<Left>": (123, "\u{F702}", "\u{F702}", [.function, .numericPad]),
        "<Right>": (124, "\u{F703}", "\u{F703}", [.function, .numericPad]),
        "<Down>": (125, "\u{F701}", "\u{F701}", [.function, .numericPad]),
        "<Up>": (126, "\u{F700}", "\u{F700}", [.function, .numericPad]),
        "<Esc>": (53, "\u{1B}", "\u{1B}", []),
        "<CR>": (36, "\r", "\r", []),
        "<BS>": (51, "\u{7F}", "\u{7F}", []),
        "<S-Down>": (125, "\u{F701}", "\u{F701}", [.function, .numericPad, .shift]),
        "<C-o>": (31, "\u{0F}", "o", [.control]),
        "<C-i>": (34, "\t", "i", [.control]),
    ]

    /// Posts a real key down/up pair through the app's event queue, exercising the responder
    /// chain (and text fields, for search).
    private static func post(_ token: KeyToken, window: NSWindow) {
        let (code, characters, unmodified, flags): (UInt16, String, String, NSEvent.ModifierFlags)
        if let named = namedKeys[token] {
            (code, characters, unmodified, flags) = named
        } else {
            let keyCodes: [Character: UInt16] = ["j": 38, "k": 40, "d": 2, "u": 32, "g": 5, "+": 24, "-": 27, "w": 13, "z": 6,
                                                 "/": 44, "?": 44, "n": 45, "m": 46, "'": 39, "f": 3, "y": 16, "a": 0, "s": 1,
                                                 "i": 34, ".": 47, "!": 18, "q": 12]
            let c = Character(token)
            code = keyCodes[Character(c.lowercased())] ?? 0
            (characters, unmodified) = (token, token)
            flags = c.isUppercase || "+?!".contains(c) ? [.shift] : []
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func write(window: NSWindow, to url: URL) {
        guard let view = window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

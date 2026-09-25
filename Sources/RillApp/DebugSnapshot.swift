import AppKit

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
                    for character in step { postKey(character, window: window) }
                } else {
                    document.feed(keys: step)
                }
                try? await Task.sleep(for: .seconds(0.6))
                log += "after \(step): origin=\(window.contentView.map { _ in document.debugOrigin } ?? .zero)\n"
            }
            try? log.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .seconds(1.0))
            write(window: window, to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    /// Posts a real key down/up pair through the app's event queue, exercising the responder chain.
    private static func postKey(_ character: Character, window: NSWindow) {
        let keyCodes: [Character: UInt16] = ["j": 38, "k": 40, "d": 2, "u": 32, "G": 5, "g": 5, "+": 24, "-": 27, "w": 13, "z": 6]
        let code = keyCodes[character] ?? 0
        let shift = character.isUppercase || character == "+"
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: String(character),
                charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: code) {
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

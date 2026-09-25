import AppKit
import RillCore

extension NSEvent {
    /// This key press in rill's Vim-style notation, or nil for keys rill doesn't handle
    /// (anything with ⌘ belongs to the menu bar).
    var keyToken: KeyToken? {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }
        if let arrow = Self.arrowNames[keyCode] {
            // Arrow events always carry the function/numeric-pad flags; only real modifiers count.
            var prefix = ""
            if flags.contains(.control) { prefix += "C-" }
            if flags.contains(.option) { prefix += "M-" }
            if flags.contains(.shift) { prefix += "S-" }
            return "<\(prefix)\(arrow)>"
        }
        switch keyCode {
        case 53: return "<Esc>"
        case 49: return flags.contains(.shift) ? "<S-Space>" : "<Space>"
        case 36: return "<CR>"
        case 48: return "<Tab>"
        case 51: return "<BS>"
        default: break
        }
        if flags.contains(.control), let c = charactersIgnoringModifiers?.lowercased(), c.count == 1 {
            return "<C-\(c)>"
        }
        guard let c = characters, c.count == 1, let scalar = c.unicodeScalars.first,
              scalar.value >= 0x20, !(0xF700...0xF8FF).contains(scalar.value) // function keys
        else { return nil }
        return c
    }

    private static let arrowNames: [UInt16: String] = [123: "Left", 124: "Right", 125: "Down", 126: "Up"]
}

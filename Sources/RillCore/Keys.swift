/// Everything a key sequence can trigger. Grows with each milestone.
public enum Action: String, CaseIterable, Sendable {
    case scrollDown = "scroll_down"
    case scrollUp = "scroll_up"
    case scrollLeft = "scroll_left"
    case scrollRight = "scroll_right"
    case halfPageDown = "half_page_down"
    case halfPageUp = "half_page_up"
    case screenDown = "screen_down"
    case screenUp = "screen_up"
    case pageNext = "page_next"
    case pagePrev = "page_prev"
    /// `gg`: first page, or page N with a count.
    case firstPage = "first_page"
    /// `G`: last page, or page N with a count.
    case goToPage = "goto_page"
    case zoomIn = "zoom_in"
    case zoomOut = "zoom_out"
    case zoomReset = "zoom_reset"
    case fitWidth = "fit_width"
    case fitPage = "fit_page"
    case toggleFrameHUD = "toggle_frame_hud"
    case reload = "reload"

    /// Actions that scroll continuously while their key is held.
    public var isContinuous: Bool {
        switch self {
        case .scrollDown, .scrollUp, .scrollLeft, .scrollRight: true
        default: false
        }
    }
}

/// Vim-style key notation: printable characters as themselves ("j", "G", "+"),
/// named and modified keys in angle brackets ("<Space>", "<S-Space>", "<C-d>", "<Esc>").
public typealias KeyToken = String

public enum KeyMap {
    public static let defaults: [KeyToken: Action] = [
        "j": .scrollDown, "k": .scrollUp, "h": .scrollLeft, "l": .scrollRight,
        "d": .halfPageDown, "u": .halfPageUp, "<C-d>": .halfPageDown, "<C-u>": .halfPageUp,
        "<Space>": .screenDown, "<S-Space>": .screenUp,
        "J": .pageNext, "K": .pagePrev,
        "gg": .firstPage, "G": .goToPage,
        "+": .zoomIn, "-": .zoomOut, "=": .zoomReset,
        "w": .fitWidth, "z": .fitPage,
        "g!": .toggleFrameHUD,
        "r": .reload,
    ]

    /// Splits a binding like "g<C-d>" into tokens ["g", "<C-d>"].
    public static func tokens(of sequence: String) -> [KeyToken] {
        var result: [KeyToken] = []
        var i = sequence.startIndex
        while i < sequence.endIndex {
            if sequence[i] == "<", let close = sequence[i...].firstIndex(of: ">"), close > sequence.index(after: i) {
                result.append(String(sequence[i...close]))
                i = sequence.index(after: close)
            } else {
                result.append(String(sequence[i]))
                i = sequence.index(after: i)
            }
        }
        return result
    }
}

/// Turns a stream of key tokens into actions, handling counts and multi-key sequences.
public struct KeyResolver: Sendable {
    public enum Result: Equatable, Sendable {
        /// A prefix of a binding (or a count) is buffered; `display` echoes what's pending.
        case pending(display: String)
        case action(Action, count: Int?)
        /// Nothing bound; the buffer was cleared.
        case unbound
    }

    private let bindings: [[KeyToken]: Action]
    private let prefixes: Set<[KeyToken]>
    private var count = ""
    private var pending: [KeyToken] = []

    public init(keymap: [String: Action] = KeyMap.defaults) {
        var bindings: [[KeyToken]: Action] = [:]
        var prefixes: Set<[KeyToken]> = []
        for (sequence, action) in keymap {
            let tokens = KeyMap.tokens(of: sequence)
            bindings[tokens] = action
            for n in 1..<max(tokens.count, 1) { prefixes.insert(Array(tokens.prefix(n))) }
        }
        self.bindings = bindings
        self.prefixes = prefixes
    }

    public var isIdle: Bool { count.isEmpty && pending.isEmpty }

    public mutating func reset() {
        count = ""
        pending = []
    }

    public mutating func feed(_ token: KeyToken) -> Result {
        if token == "<Esc>" {
            reset()
            return .unbound
        }
        if pending.isEmpty, let digit = token.first, token.count == 1, digit.isASCII, digit.isNumber,
           digit != "0" || !count.isEmpty {
            count.append(digit)
            return .pending(display: count)
        }

        pending.append(token)
        if let action = bindings[pending] {
            let n = Int(count)
            reset()
            return .action(action, count: n)
        }
        if prefixes.contains(pending) {
            return .pending(display: count + pending.joined())
        }
        reset()
        return .unbound
    }
}

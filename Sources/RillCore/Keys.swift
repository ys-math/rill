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
    case jumpBack = "jump_back"
    case jumpForward = "jump_forward"
    /// `m{a-z}`: takes the mark name as its argument.
    case setMark = "set_mark"
    /// `'{a-z}`, or `''` for the position before the latest jump.
    case goToMark = "goto_mark"
    case searchForward = "search_forward"
    case searchBackward = "search_backward"
    case searchNext = "search_next"
    case searchPrevious = "search_previous"
    /// `Esc` in normal mode: clear search highlights and any pending keys.
    case clearHighlights = "clear_highlights"
    case hintFollowLink = "hint_follow_link"
    case hintInverseSearch = "hint_inverse_search"
    case hintYankLine = "hint_yank_line"
    case toggleDarkMode = "toggle_dark_mode"
    case toggleStatus = "toggle_status"
    case showCheatsheet = "show_cheatsheet"
    case closeDocument = "close_document"

    /// Actions followed by one more key that names their target, like `m` + `a`.
    public var takesArgument: Bool {
        self == .setMark || self == .goToMark
    }

    /// Actions that scroll continuously while their key is held.
    public var isContinuous: Bool {
        switch self {
        case .scrollDown, .scrollUp, .scrollLeft, .scrollRight: true
        default: false
        }
    }
}

extension Action {
    public enum Category: String, CaseIterable, Sendable {
        case scroll = "Scroll"
        case jump = "Jump"
        case zoom = "Zoom & view"
        case search = "Search"
        case hints = "Hints"
        case other = "Other"
    }

    public var category: Category {
        switch self {
        case .scrollDown, .scrollUp, .scrollLeft, .scrollRight, .halfPageDown, .halfPageUp, .screenDown, .screenUp:
            .scroll
        case .pageNext, .pagePrev, .firstPage, .goToPage, .jumpBack, .jumpForward, .setMark, .goToMark:
            .jump
        case .zoomIn, .zoomOut, .zoomReset, .fitWidth, .fitPage, .toggleDarkMode, .toggleStatus:
            .zoom
        case .searchForward, .searchBackward, .searchNext, .searchPrevious, .clearHighlights:
            .search
        case .hintFollowLink, .hintInverseSearch, .hintYankLine:
            .hints
        case .reload, .toggleFrameHUD, .showCheatsheet, .closeDocument:
            .other
        }
    }

    /// For the `g?` cheatsheet.
    public var summary: String {
        switch self {
        case .scrollDown: "scroll down (hold to glide)"
        case .scrollUp: "scroll up (hold to glide)"
        case .scrollLeft: "scroll left"
        case .scrollRight: "scroll right"
        case .halfPageDown: "half screen down"
        case .halfPageUp: "half screen up"
        case .screenDown: "screen down"
        case .screenUp: "screen up"
        case .pageNext: "next page"
        case .pagePrev: "previous page"
        case .firstPage: "first page (N: page N)"
        case .goToPage: "last page (N: page N)"
        case .zoomIn: "zoom in"
        case .zoomOut: "zoom out"
        case .zoomReset: "actual size"
        case .fitWidth: "fit width"
        case .fitPage: "fit page"
        case .toggleFrameHUD: "frame-rate overlay"
        case .reload: "reload"
        case .jumpBack: "jump back"
        case .jumpForward: "jump forward"
        case .setMark: "set mark {a-z}"
        case .goToMark: "go to mark {a-z} ('' last jump)"
        case .searchForward: "search forward"
        case .searchBackward: "search backward"
        case .searchNext: "next match"
        case .searchPrevious: "previous match"
        case .clearHighlights: "clear highlights"
        case .hintFollowLink: "follow a link"
        case .hintInverseSearch: "jump Neovim to a line"
        case .hintYankLine: "copy a line"
        case .toggleDarkMode: "dark mode"
        case .toggleStatus: "pin page / zoom status"
        case .showCheatsheet: "this cheatsheet"
        case .closeDocument: "close document"
        }
    }
}

/// Vim-style key notation: printable characters as themselves ("j", "G", "+"),
/// named and modified keys in angle brackets ("<Space>", "<S-Space>", "<C-d>", "<Esc>").
public typealias KeyToken = String

public enum KeyMap {
    public static let defaults: [KeyToken: Action] = [
        "j": .scrollDown, "k": .scrollUp, "h": .scrollLeft, "l": .scrollRight,
        "<Down>": .scrollDown, "<Up>": .scrollUp, "<Left>": .scrollLeft, "<Right>": .scrollRight,
        "d": .halfPageDown, "u": .halfPageUp, "<C-d>": .halfPageDown, "<C-u>": .halfPageUp,
        "<Space>": .screenDown, "<S-Space>": .screenUp,
        "J": .pageNext, "K": .pagePrev,
        "gg": .firstPage, "G": .goToPage,
        "+": .zoomIn, "-": .zoomOut, "=": .zoomReset,
        "w": .fitWidth, "z": .fitPage,
        "g!": .toggleFrameHUD,
        "r": .reload,
        "<C-o>": .jumpBack, "<C-i>": .jumpForward,
        "m": .setMark, "'": .goToMark,
        "/": .searchForward, "?": .searchBackward, "n": .searchNext, "N": .searchPrevious,
        "f": .hintFollowLink, "F": .hintInverseSearch, "yf": .hintYankLine,
        "i": .toggleDarkMode, "g.": .toggleStatus, "g?": .showCheatsheet, "q": .closeDocument,
    ]

    /// A binding as it reads on a Mac keyboard: "<C-d>" → "⌃d", "<S-Space>" → "⇧Space", "<Down>" → "↓".
    public static func display(_ sequence: String) -> String {
        tokens(of: sequence).map { token -> String in
            guard token.count > 2, token.hasPrefix("<"), token.hasSuffix(">") else { return token }
            var name = token.dropFirst().dropLast()[...]
            var modifiers = ""
            while name.count > 2, name.dropFirst().first == "-", let m = name.first {
                modifiers += ["C": "⌃", "M": "⌥", "S": "⇧"][m] ?? ""
                name = name.dropFirst(2)
            }
            let named = ["Down": "↓", "Up": "↑", "Left": "←", "Right": "→", "CR": "↩", "BS": "⌫"][String(name)]
            return modifiers + (named ?? String(name))
        }.joined()
    }

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
        /// An action that took one more key as its argument (`ma` → setMark, "a").
        case actionWithArgument(Action, argument: KeyToken, count: Int?)
        /// Nothing bound; the buffer was cleared. `Esc` also lands here, as `.escape`.
        case unbound
        /// `Esc` with nothing pending, so the caller can treat it as its own command.
        case escape
    }

    private let bindings: [[KeyToken]: Action]
    private let prefixes: Set<[KeyToken]>
    private var count = ""
    private var pending: [KeyToken] = []
    /// An argument-taking action waiting for its argument key.
    private var awaiting: Action?

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

    public var isIdle: Bool { count.isEmpty && pending.isEmpty && awaiting == nil }

    public mutating func reset() {
        count = ""
        pending = []
        awaiting = nil
    }

    public mutating func feed(_ token: KeyToken) -> Result {
        if token == "<Esc>" {
            let wasIdle = isIdle
            reset()
            return wasIdle ? .escape : .unbound
        }
        if let action = awaiting {
            let n = Int(count)
            reset()
            // Arguments are single printable characters (mark names); anything else cancels.
            return token.count == 1 ? .actionWithArgument(action, argument: token, count: n) : .unbound
        }
        if pending.isEmpty, let digit = token.first, token.count == 1, digit.isASCII, digit.isNumber,
           digit != "0" || !count.isEmpty {
            count.append(digit)
            return .pending(display: count)
        }

        pending.append(token)
        if let action = bindings[pending] {
            if action.takesArgument {
                awaiting = action
                pending = []
                return .pending(display: count + KeyMap.tokens(of: token).joined())
            }
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

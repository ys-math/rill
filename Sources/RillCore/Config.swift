import Foundation

/// `~/.config/rill/config.toml`. Every setting has a default; a bad value is reported as a
/// warning and leaves that one setting at its default, so a typo never loses the whole file.
public struct Config: Equatable, Sendable {
    public enum DarkMode: String, Sendable, CaseIterable {
        case system, on, off
    }

    /// What shows around the pages.
    public enum Background: String, Sendable, CaseIterable {
        /// A plain gray.
        case solid
        /// Whatever is behind the window, blurred.
        case blur
        /// Liquid Glass over whatever is behind the window.
        case glass
    }

    /// The material of the search bar, status pill, toasts, picker and cheatsheet.
    public enum OverlayStyle: String, Sendable, CaseIterable {
        case blur, glass
    }

    public var pickerRoots: [String] = []
    public var inverseCommand = InverseSearchCommand.vimtexDefault
    /// Bundle ID of the app to bring forward after inverse search (the terminal running Neovim).
    public var activateOnInverse: String? = "com.mitchellh.ghostty"
    public var activateOnForward = false
    public var defaultZoom = ZoomSetting.fitWidth
    public var darkMode = DarkMode.system
    public var pageGap: Double = 8
    /// Mark what changed in the margin after a recompile.
    public var changeMarkers = true
    /// Pages side by side, two per row.
    public var spread = PageLayout.Spread.off
    /// Cut away the white margins around the text.
    public var trim = false
    public var background = Background.solid
    /// Round the corners of the pages.
    public var roundedCorners = false
    public var overlays = OverlayStyle.blur
    /// The effective bindings: defaults with the `[keys]` table applied.
    public var keymap: [String: Action] = KeyMap.defaults

    public init() {}

    /// `$XDG_CONFIG_HOME/rill/config.toml`, else `~/.config/rill/config.toml`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("rill/config.toml")
    }

    /// The config in `text`, plus warnings for anything ignored. Throws only if the TOML itself is malformed.
    public static func parse(_ text: String) throws(TOMLError) -> (config: Config, warnings: [String]) {
        let document = try TOML.parse(text)
        var config = Config()
        var warnings: [String] = []

        func warnWrongType(_ table: String, _ key: String, expected: String, got value: TOMLValue) {
            warnings.append("[\(table)] \(key): expected \(expected), got \(value.typeName)")
        }

        for (table, entries) in document {
            switch table {
            case "":
                for key in entries.keys.sorted() { warnings.append("\(key): settings belong in a [table]") }
            case "picker":
                for (key, value) in entries {
                    switch key {
                    case "roots":
                        guard case .array(let items) = value, let roots = Optional(items.compactMap(\.string)),
                              roots.count == items.count
                        else { warnWrongType(table, key, expected: "an array of strings", got: value); continue }
                        config.pickerRoots = roots
                    default: warnings.append("[picker] \(key): unknown setting")
                    }
                }
            case "synctex":
                for (key, value) in entries {
                    switch key {
                    case "inverse_command":
                        guard let s = value.string, !s.isEmpty else { warnWrongType(table, key, expected: "a command", got: value); continue }
                        config.inverseCommand = InverseSearchCommand(template: s)
                    case "activate_on_inverse":
                        guard let s = value.string else { warnWrongType(table, key, expected: "a bundle ID", got: value); continue }
                        config.activateOnInverse = s.isEmpty ? nil : s
                    case "activate_on_forward":
                        guard let b = value.bool else { warnWrongType(table, key, expected: "true or false", got: value); continue }
                        config.activateOnForward = b
                    default: warnings.append("[synctex] \(key): unknown setting")
                    }
                }
            case "view":
                for (key, value) in entries {
                    switch key {
                    case "default_zoom":
                        switch value {
                        case .string("fit-width"): config.defaultZoom = .fitWidth
                        case .string("fit-page"): config.defaultZoom = .fitPage
                        case .integer, .float:
                            let m = value.number!
                            guard (0.1...10).contains(m) else { warnings.append("[view] default_zoom: \(m) is outside 0.1–10"); continue }
                            config.defaultZoom = .magnification(m)
                        default: warnings.append(#"[view] default_zoom: expected "fit-width", "fit-page" or a number"#)
                        }
                    case "dark_mode":
                        guard let s = value.string, let mode = DarkMode(rawValue: s) else {
                            warnings.append(#"[view] dark_mode: expected "system", "on" or "off""#); continue
                        }
                        config.darkMode = mode
                    case "change_markers":
                        guard let b = value.bool else { warnWrongType(table, key, expected: "true or false", got: value); continue }
                        config.changeMarkers = b
                    case "spread":
                        guard let s = value.string, let spread = PageLayout.Spread(rawValue: s) else {
                            warnings.append(#"[view] spread: expected "off", "pairs" or "book""#); continue
                        }
                        config.spread = spread
                    case "trim":
                        guard let b = value.bool else { warnWrongType(table, key, expected: "true or false", got: value); continue }
                        config.trim = b
                    case "rounded_corners":
                        guard let b = value.bool else { warnWrongType(table, key, expected: "true or false", got: value); continue }
                        config.roundedCorners = b
                    case "background":
                        guard let s = value.string, let background = Background(rawValue: s) else {
                            warnings.append(#"[view] background: expected "solid", "blur" or "glass""#); continue
                        }
                        config.background = background
                    case "overlays":
                        guard let s = value.string, let style = OverlayStyle(rawValue: s) else {
                            warnings.append(#"[view] overlays: expected "blur" or "glass""#); continue
                        }
                        config.overlays = style
                    case "page_gap":
                        guard let gap = value.number, (0...100).contains(gap) else {
                            warnings.append("[view] page_gap: expected a number from 0 to 100"); continue
                        }
                        config.pageGap = gap
                    default: warnings.append("[view] \(key): unknown setting")
                    }
                }
            case "keys":
                for (sequence, value) in entries.sorted(by: { $0.key < $1.key }) {
                    guard let name = value.string else { warnWrongType(table, sequence, expected: "an action name", got: value); continue }
                    guard !KeyMap.tokens(of: sequence).isEmpty else { warnings.append("[keys] empty key sequence"); continue }
                    if name == "nop" {
                        config.keymap[sequence] = nil
                    } else if let action = Action(rawValue: name) {
                        config.keymap[sequence] = action
                    } else {
                        warnings.append("[keys] \(sequence): unknown action \(name)")
                    }
                }
            default:
                warnings.append("[\(table)]: unknown table")
            }
        }
        return (config, warnings.sorted())
    }
}

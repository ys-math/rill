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

    /// `.clear` is more see-through than the default `.regular`.
    public enum GlassStyle: String, Sendable, CaseIterable {
        case regular, clear
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
    /// `edit_config`: a shell command with `%file` (quoted when substituted), or nil to open the file in the default app.
    public var editCommand: String?
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
    /// How the `glass` background looks: its style, and a colour (with alpha) to tint it toward.
    public var glassStyle = GlassStyle.regular
    public var glassTint: RGBColor?
    /// Corner radius of the pages in page points (0 for square corners).
    public var cornerRadius: Double = 0
    /// `5j` and other counted `j`/`k`/`h`/`l`: a fraction of the viewport per count.
    public var scrollStep: Double = 0.1
    /// Holding `j`/`k`/`h`/`l`: full speed in screen points per second, and the seconds it
    /// takes to reach it and, after release, to coast to a stop.
    public var scrollSpeed: Double = 1300
    public var scrollAccelTime: Double = 0.08
    public var scrollDecelTime: Double = 0.2
    /// `+`/`-`: the zoom multiplier.
    public var zoomStep: Double = 1.25
    /// Dark mode's page and text colours.
    public var darkPaper = RGBColor(hex: "#242424")!
    public var darkInk = RGBColor(hex: "#dbdbdb")!
    public var overlays = OverlayStyle.blur
    /// The effective bindings: defaults with the `[keys]` table applied.
    public var keymap: [String: Action] = KeyMap.defaults

    public init() {}

    /// The radius `rounded_corners = true` gives.
    public static let defaultCornerRadius: Double = 6

    /// `$XDG_CONFIG_HOME/rill/config.toml`, else `~/.config/rill/config.toml`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("rill/config.toml")
    }

    /// Written by `edit_config` when there's no config yet: every setting commented out, so
    /// it parses to the defaults.
    public static let template = """
        # rill config: saving this file applies it. Every setting is optional; uncomment to change.

        [config]
        # edit_command = "open -na Ghostty --args -e nvim %file"   # how g, / ⌘, open this file

        [view]
        # default_zoom = "fit-width"   # "fit-page", or a number like 1.25
        # dark_mode = "system"         # "on" | "off" | "system"
        # page_gap = 8
        # change_markers = true
        # spread = "off"               # "pairs" | "book"
        # trim = false
        # rounded_corners = false      # true | a radius in page points
        # scroll_step = 0.1            # 5j etc.: fraction of the window per count
        # scroll_speed = 1300          # holding j/k/h/l: screen points per second
        # scroll_accel_time = 0.08     # seconds to reach that speed (0: instantly)
        # scroll_decel_time = 0.2      # seconds to coast to a stop after release (0: instantly)
        # zoom_step = 1.25
        # dark_paper = "#242424"
        # dark_ink = "#dbdbdb"
        # background = "solid"         # "blur" | "glass"
        # glass_style = "regular"      # "clear": a more see-through glass background
        # glass_tint = "#00000026"     # tint the glass background ("#rrggbb" or "#rrggbbaa")
        # overlays = "blur"            # "glass"

        [synctex]
        # inverse_command = "nvim --headless -c \\"VimtexInverseSearch %line '%file'\\""
        # activate_on_inverse = "com.mitchellh.ghostty"
        # activate_on_forward = false

        [picker]
        # roots = ["~/github", "~/Papers"]

        [keys]
        # key sequence = action name, as listed by g? ("nop" removes a default binding)
        # "<C-f>" = "screen_down"

        """

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
            case "config":
                for (key, value) in entries {
                    switch key {
                    case "edit_command":
                        guard let s = value.string else { warnWrongType(table, key, expected: "a command", got: value); continue }
                        config.editCommand = s.isEmpty ? nil : s
                    default: warnings.append("[config] \(key): unknown setting")
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
                        if let b = value.bool {
                            config.cornerRadius = b ? Config.defaultCornerRadius : 0
                        } else if let radius = value.number, (0...100).contains(radius) {
                            config.cornerRadius = radius
                        } else {
                            warnings.append("[view] rounded_corners: expected true, false or a number from 0 to 100"); continue
                        }
                    case "scroll_step":
                        guard let step = value.number, (0.01...1).contains(step) else {
                            warnings.append("[view] scroll_step: expected a number from 0.01 to 1"); continue
                        }
                        config.scrollStep = step
                    case "scroll_speed":
                        guard let speed = value.number, (100...10000).contains(speed) else {
                            warnings.append("[view] scroll_speed: expected a number from 100 to 10000"); continue
                        }
                        config.scrollSpeed = speed
                    case "scroll_accel_time", "scroll_decel_time":
                        guard let time = value.number, (0...2).contains(time) else {
                            warnings.append("[view] \(key): expected a number from 0 to 2"); continue
                        }
                        if key == "scroll_accel_time" { config.scrollAccelTime = time } else { config.scrollDecelTime = time }
                    case "zoom_step":
                        guard let step = value.number, (1.01...4).contains(step) else {
                            warnings.append("[view] zoom_step: expected a number from 1.01 to 4"); continue
                        }
                        config.zoomStep = step
                    case "dark_paper", "dark_ink":
                        guard let s = value.string, let color = RGBColor(hex: s) else {
                            warnings.append(##"[view] \##(key): expected a colour like "#1d2021""##); continue
                        }
                        if key == "dark_paper" { config.darkPaper = color } else { config.darkInk = color }
                    case "background":
                        guard let s = value.string, let background = Background(rawValue: s) else {
                            warnings.append(#"[view] background: expected "solid", "blur" or "glass""#); continue
                        }
                        config.background = background
                    case "glass_style":
                        guard let s = value.string, let style = GlassStyle(rawValue: s) else {
                            warnings.append(#"[view] glass_style: expected "regular" or "clear""#); continue
                        }
                        config.glassStyle = style
                    case "glass_tint":
                        guard let s = value.string, let color = RGBColor(hexWithAlpha: s) else {
                            warnings.append(##"[view] glass_tint: expected a colour like "#1d2021" or "#1d202180""##); continue
                        }
                        config.glassTint = color
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

extension Config {
    /// `edit_command` with `%file` replaced by `path`, quoted for the shell; nil if there's no command.
    public func renderedEditCommand(path: String) -> String? {
        editCommand?.replacingOccurrences(of: "%file", with: "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'")
    }
}

/// An sRGB colour, components 0–1.
public struct RGBColor: Equatable, Sendable {
    public var red, green, blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    /// `#rrggbb`; nil for anything else.
    public init?(hex: String) {
        guard hex.count == 7 else { return nil }
        self.init(hexWithAlpha: hex)
    }

    /// `#rrggbb` or `#rrggbbaa`; nil for anything else.
    public init?(hexWithAlpha hex: String) {
        guard hex.count == 7 || hex.count == 9, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16),
              hex.dropFirst().allSatisfy(\.isHexDigit)
        else { return nil }
        let rgb = hex.count == 9 ? value >> 8 : value
        self.init(red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255, alpha: hex.count == 9 ? Double(value & 0xff) / 255 : 1)
    }
}

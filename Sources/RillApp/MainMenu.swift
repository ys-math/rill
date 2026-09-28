import AppKit

/// A minimal menu bar so standard shortcuts (⌘Q, ⌘W, ⌘M) work without a nib.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Edit Config…", action: #selector(AppDelegate.editConfig(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide rill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit rill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "rill")

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(DocumentWindowController.openDocument(_:)), keyEquivalent: "o")
        let panel = fileMenu.addItem(withTitle: "Open with Finder Panel…",
                                     action: #selector(DocumentWindowController.openWithPanel(_:)), keyEquivalent: "o")
        panel.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu: fileMenu, title: "File")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let tabItems: [(String, Selector, Int, NSEvent.ModifierFlags)] = [
            ("Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), NSLeftArrowFunctionKey, [.command, .control]),
            ("Next Tab", #selector(NSWindow.selectNextTab(_:)), NSRightArrowFunctionKey, [.command, .control]),
            ("Move Tab Left", #selector(DocumentWindow.moveTabLeft(_:)), NSLeftArrowFunctionKey, [.command, .control, .shift]),
            ("Move Tab Right", #selector(DocumentWindow.moveTabRight(_:)), NSRightArrowFunctionKey, [.command, .control, .shift]),
        ]
        for (title, action, arrow, modifiers) in tabItems {
            let item = windowMenu.addItem(withTitle: title, action: action, keyEquivalent: String(UnicodeScalar(arrow)!))
            item.keyEquivalentModifierMask = modifiers
        }
        main.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

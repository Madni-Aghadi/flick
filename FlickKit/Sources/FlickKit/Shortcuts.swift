import Foundation

public struct Shortcut: Sendable, Identifiable, Equatable {
    public var id: String { label }
    public var label: String
    public var symbol: String
    public var key: Key
    public var mods: [Mod]

    public init(_ label: String, _ symbol: String, _ key: Key, _ mods: [Mod]) {
        self.label = label; self.symbol = symbol; self.key = key; self.mods = mods
    }
}

/// Small, per-app shortcut sets for the front app on the Mac. Short on purpose.
public enum ShortcutCatalog {
    public static let common: [Shortcut] = [
        Shortcut("Copy", "doc.on.doc", .c, [.cmd]),
        Shortcut("Paste", "doc.on.clipboard", .v, [.cmd]),
        Shortcut("Undo", "arrow.uturn.backward", .z, [.cmd]),
        Shortcut("Select all", "selection.pin.in.out", .a, [.cmd]),
        Shortcut("Save", "square.and.arrow.down", .s, [.cmd]),
        Shortcut("Find", "magnifyingglass", .f, [.cmd]),
        Shortcut("Close", "xmark", .w, [.cmd]),
        Shortcut("Quit", "power", .q, [.cmd]),
    ]

    static let browser: [Shortcut] = [
        Shortcut("New tab", "plus.square", .t, [.cmd]),
        Shortcut("Close tab", "xmark.square", .w, [.cmd]),
        Shortcut("Reopen", "arrow.uturn.backward.square", .t, [.cmd, .shift]),
        Shortcut("Address", "link", .l, [.cmd]),
        Shortcut("Back", "chevron.left", .leftBracket, [.cmd]),
        Shortcut("Forward", "chevron.right", .rightBracket, [.cmd]),
        Shortcut("Reload", "arrow.clockwise", .r, [.cmd]),
        Shortcut("Next tab", "arrow.right.to.line", .tab, [.ctrl]),
    ]

    static let code: [Shortcut] = [
        Shortcut("Commands", "command", .p, [.cmd, .shift]),
        Shortcut("Open file", "doc.text.magnifyingglass", .p, [.cmd]),
        Shortcut("Terminal", "terminal", .grave, [.ctrl]),
        Shortcut("Sidebar", "sidebar.left", .b, [.cmd]),
        Shortcut("Comment", "text.bubble", .slash, [.cmd]),
        Shortcut("Save", "square.and.arrow.down", .s, [.cmd]),
        Shortcut("Find", "magnifyingglass", .f, [.cmd]),
        Shortcut("Undo", "arrow.uturn.backward", .z, [.cmd]),
    ]

    static let terminal: [Shortcut] = [
        Shortcut("Interrupt", "stop.circle", .c, [.ctrl]),
        Shortcut("Clear", "clear", .k, [.cmd]),
        Shortcut("New tab", "plus.square", .t, [.cmd]),
        Shortcut("Close", "xmark.square", .w, [.cmd]),
        Shortcut("Previous", "arrow.up", .up, []),
        Shortcut("Complete", "arrow.right.to.line", .tab, []),
        Shortcut("Paste", "doc.on.clipboard", .v, [.cmd]),
        Shortcut("Exit", "eject", .d, [.ctrl]),
    ]

    static let finder: [Shortcut] = [
        Shortcut("New window", "macwindow.badge.plus", .n, [.cmd]),
        Shortcut("New folder", "folder.badge.plus", .n, [.cmd, .shift]),
        Shortcut("Go to", "arrow.forward.folder", .g, [.cmd, .shift]),
        Shortcut("Downloads", "arrow.down.circle", .l, [.cmd, .opt]),
        Shortcut("Trash", "trash", .delete, [.cmd]),
        Shortcut("Quick Look", "eye", .space, []),
        Shortcut("Info", "info.circle", .i, [.cmd]),
        Shortcut("Find", "magnifyingglass", .f, [.cmd]),
    ]

    static let media: [Shortcut] = [
        Shortcut("Play", "playpause", .space, []),
        Shortcut("Back 10s", "gobackward.10", .left, []),
        Shortcut("Fwd 10s", "goforward.10", .right, []),
        Shortcut("Fullscreen", "arrow.up.left.and.arrow.down.right", .f, []),
        Shortcut("Mute", "speaker.slash", .m, []),
        Shortcut("Captions", "captions.bubble", .c, []),
        Shortcut("Louder", "speaker.plus", .up, []),
        Shortcut("Quieter", "speaker.minus", .down, []),
    ]

    static let slides: [Shortcut] = [
        Shortcut("Play", "play.rectangle", .returnKey, [.cmd, .opt]),
        Shortcut("Next", "chevron.right", .right, []),
        Shortcut("Previous", "chevron.left", .left, []),
        Shortcut("End", "stop", .escape, []),
    ]

    public static func shortcuts(for bundleID: String) -> [Shortcut] {
        let id = bundleID.lowercased()
        if id.contains("youtube") || id.contains("vlc") || id.contains("quicktime") || id.contains("iina") || id.contains("spotify") || id.contains("music") { return media }
        if id.contains("keynote") || id.contains("powerpoint") { return slides }
        if id.contains("chrome") || id.contains("safari") || id.contains("dia") || id.contains("arc") || id.contains("firefox") || id.contains("browser") || id.contains("brave") || id.contains("edge") { return browser }
        if id.contains("vscode") || id.contains("cursor") || id.contains("xcode") || id.contains("zed") || id.contains("sublime") || id.contains("jetbrains") || id.contains("windsurf") { return code }
        if id.contains("terminal") || id.contains("iterm") || id.contains("warp") || id.contains("ghostty") || id.contains("conductor") || id.contains("kitty") || id.contains("cmux") { return terminal }
        if id == "com.apple.finder" { return finder }
        return common
    }
}

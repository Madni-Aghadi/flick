import Foundation

/// Keys the phone can send. Raw values are stable wire names.
public enum Key: String, Codable, CaseIterable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case n0, n1, n2, n3, n4, n5, n6, n7, n8, n9
    case returnKey, tab, space, delete, forwardDelete, escape
    case left, right, up, down, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case minus, equal, leftBracket, rightBracket, semicolon, quote, comma, period, slash, backslash, grave

    /// macOS virtual key code (Carbon kVK_*).
    public var macKeyCode: UInt16 {
        switch self {
        case .a: 0x00; case .s: 0x01; case .d: 0x02; case .f: 0x03; case .h: 0x04; case .g: 0x05
        case .z: 0x06; case .x: 0x07; case .c: 0x08; case .v: 0x09; case .b: 0x0B; case .q: 0x0C
        case .w: 0x0D; case .e: 0x0E; case .r: 0x0F; case .y: 0x10; case .t: 0x11; case .o: 0x1F
        case .u: 0x20; case .i: 0x22; case .p: 0x23; case .l: 0x25; case .j: 0x26; case .k: 0x28
        case .n: 0x2D; case .m: 0x2E
        case .n1: 0x12; case .n2: 0x13; case .n3: 0x14; case .n4: 0x15; case .n6: 0x16; case .n5: 0x17
        case .n9: 0x19; case .n7: 0x1A; case .n8: 0x1C; case .n0: 0x1D
        case .equal: 0x18; case .minus: 0x1B; case .rightBracket: 0x1E; case .leftBracket: 0x21
        case .quote: 0x27; case .semicolon: 0x29; case .backslash: 0x2A; case .comma: 0x2B
        case .slash: 0x2C; case .period: 0x2F; case .grave: 0x32
        case .returnKey: 0x24; case .tab: 0x30; case .space: 0x31; case .delete: 0x33; case .escape: 0x35
        case .forwardDelete: 0x75
        case .left: 0x7B; case .right: 0x7C; case .down: 0x7D; case .up: 0x7E
        case .home: 0x73; case .end: 0x77; case .pageUp: 0x74; case .pageDown: 0x79
        case .f1: 0x7A; case .f2: 0x78; case .f3: 0x63; case .f4: 0x76; case .f5: 0x60; case .f6: 0x61
        case .f7: 0x62; case .f8: 0x64; case .f9: 0x65; case .f10: 0x6D; case .f11: 0x67; case .f12: 0x6F
        }
    }

    /// Single printable character → key (for shortcut definitions).
    public static func from(character: Character) -> Key? {
        let s = String(character).lowercased()
        if let k = Key(rawValue: s), s.count == 1 { return k }
        switch s {
        case "0": return .n0; case "1": return .n1; case "2": return .n2; case "3": return .n3
        case "4": return .n4; case "5": return .n5; case "6": return .n6; case "7": return .n7
        case "8": return .n8; case "9": return .n9
        case "-": return .minus; case "=": return .equal; case "[": return .leftBracket
        case "]": return .rightBracket; case ";": return .semicolon; case "'": return .quote
        case ",": return .comma; case ".": return .period; case "/": return .slash
        case "\\": return .backslash; case "`": return .grave; case " ": return .space
        default: return nil
        }
    }
}

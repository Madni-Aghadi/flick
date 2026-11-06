import Foundation

public let flickProtocolVersion = 1
public let flickServiceType = "_flick._tcp"
public let flickPairServiceType = "_flickpair._tcp"
public let flickDefaultPort: UInt16 = 47321

public enum Mod: String, Codable, CaseIterable, Sendable, Hashable {
    case cmd, opt, ctrl, shift, fn
}

public enum MouseButton: String, Codable, Sendable {
    case left, right, middle
}

public enum ScrollPhase: String, Codable, Sendable {
    case began, changed, ended, momentum
}

public enum MediaAction: String, Codable, CaseIterable, Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

public enum SystemAction: String, Codable, CaseIterable, Sendable {
    case missionControl, appWindows, desktop, spaceLeft, spaceRight, spotlight, lock, displaySleep, appSwitcher
}

public enum AskKind: String, Codable, Sendable {
    case text, tool, status
}

public struct DisplayInfo: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Phone → Mac
public enum ClientMessage: Codable, Sendable, Equatable {
    case hello(name: String, version: Int)
    case move(dx: Double, dy: Double)
    /// Absolute position, 0...1 on the main display (screen view taps).
    case point(x: Double, y: Double)
    case button(button: MouseButton, down: Bool)
    case click(button: MouseButton)
    case scroll(dx: Double, dy: Double, phase: ScrollPhase)
    case zoom(steps: Int)
    /// A key press (down + up) with modifiers.
    case key(key: Key, mods: [Mod])
    /// Hold or release a key (drive mode).
    case keyState(key: Key, down: Bool)
    case text(value: String)
    case media(action: MediaAction)
    case system(action: SystemAction)
    case laser(on: Bool)
    case stream(on: Bool, maxWidth: Int, fps: Int)
    case keyframe
    case ask(prompt: String)
    case askCancel
    case ping(t: Double)
    case releaseAll
}

/// Mac → phone
public enum ServerMessage: Codable, Sendable, Equatable {
    case welcome(name: String, macID: String, version: Int, addresses: [String], port: UInt16, display: DisplayInfo)
    case paired(secret: String, macID: String, name: String, addresses: [String], port: UInt16)
    case frontApp(bundleID: String, name: String, icon: Data?)
    case askEvent(kind: AskKind, text: String)
    case askDone(text: String, ok: Bool)
    case pong(t: Double)
    case status(accessibility: Bool, screen: Bool)
}

public enum FlickJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64
        return e
    }()
    static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(type, from: data)
    }
}

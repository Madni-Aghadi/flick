import Foundation

/// Wire format: [type: u8][length: u32 big-endian][payload].
public enum FrameType: UInt8, Sendable {
    case json = 1
    case video = 2
}

public struct Frame: Sendable, Equatable {
    public var type: FrameType
    public var payload: Data
    public init(type: FrameType, payload: Data) { self.type = type; self.payload = payload }

    public func encoded() -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(type.rawValue)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }
}

/// Accumulates stream bytes and yields complete frames.
public struct FrameReader: Sendable {
    public static let maxPayload = 32 * 1024 * 1024
    private var buffer = Data()
    public private(set) var corrupted = false

    public init() {}

    public mutating func append(_ data: Data) -> [Frame] {
        guard !corrupted else { return [] }
        buffer.append(data)
        var frames: [Frame] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let typeByte = buffer[start]
            let len = buffer[(start + 1)..<(start + 5)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard let type = FrameType(rawValue: typeByte), len <= Self.maxPayload else {
                corrupted = true
                buffer.removeAll()
                return frames
            }
            let total = 5 + Int(len)
            guard buffer.count >= total else { break }
            let payload = Data(buffer[(start + 5)..<(start + total)])
            frames.append(Frame(type: type, payload: payload))
            buffer.removeSubrange(start..<(start + total))
        }
        // Keep indices compact so slicing stays cheap.
        if buffer.startIndex != 0 { buffer = Data(buffer) }
        return frames
    }
}

/// Video payload: [flags: u8][pts µs: u64 BE][body]. flags bit0 = keyframe, bit1 = config.
/// Config body: [width u32][height u32][count u8] then per parameter set [len u16][bytes].
public struct VideoPacket: Sendable, Equatable {
    public var keyframe: Bool
    public var isConfig: Bool
    public var pts: UInt64
    public var body: Data

    public init(keyframe: Bool, isConfig: Bool, pts: UInt64, body: Data) {
        self.keyframe = keyframe; self.isConfig = isConfig; self.pts = pts; self.body = body
    }

    public func encoded() -> Data {
        var out = Data(capacity: body.count + 9)
        out.append((keyframe ? 1 : 0) | (isConfig ? 2 : 0))
        var p = pts.bigEndian
        withUnsafeBytes(of: &p) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public static func decode(_ data: Data) -> VideoPacket? {
        guard data.count >= 9 else { return nil }
        let s = data.startIndex
        let flags = data[s]
        let pts = data[(s + 1)..<(s + 9)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return VideoPacket(keyframe: flags & 1 != 0, isConfig: flags & 2 != 0, pts: pts, body: Data(data[(s + 9)...]))
    }

    public static func config(width: Int, height: Int, parameterSets: [Data]) -> VideoPacket {
        var body = Data()
        for v in [UInt32(width), UInt32(height)] {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { body.append(contentsOf: $0) }
        }
        body.append(UInt8(parameterSets.count))
        for ps in parameterSets {
            var len = UInt16(ps.count).bigEndian
            withUnsafeBytes(of: &len) { body.append(contentsOf: $0) }
            body.append(ps)
        }
        return VideoPacket(keyframe: false, isConfig: true, pts: 0, body: body)
    }

    public func parseConfig() -> (width: Int, height: Int, parameterSets: [Data])? {
        guard isConfig, body.count >= 9 else { return nil }
        let b = [UInt8](body)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        let w = u32(0), h = u32(4)
        let count = Int(b[8])
        var i = 9
        var sets: [Data] = []
        for _ in 0..<count {
            guard i + 2 <= b.count else { return nil }
            let len = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard i + len <= b.count else { return nil }
            sets.append(Data(b[i..<(i + len)]))
            i += len
        }
        return (w, h, sets)
    }
}

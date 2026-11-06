import Foundation
import Network

/// Framed, typed wrapper around NWConnection, shared by the Mac, the phone and the test client.
public final class FlickConnection: @unchecked Sendable {
    public enum Event {
        case ready
        case frame(Frame)
        case closed(Error?)
    }

    public let connection: NWConnection
    public let queue: DispatchQueue
    private var reader = FrameReader()
    private var handler: ((Event) -> Void)?
    private var closed = false
    private let lock = NSLock()
    private var _pendingVideo = 0

    /// Video frames handed to the network stack but not yet sent (for backpressure).
    public var pendingVideo: Int { lock.lock(); defer { lock.unlock() }; return _pendingVideo }

    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "flick.conn")) {
        self.connection = connection
        self.queue = queue
    }

    public convenience init(endpoint: NWEndpoint, parameters: NWParameters) {
        self.init(connection: NWConnection(to: endpoint, using: parameters))
    }

    public func start(_ handler: @escaping (Event) -> Void) {
        self.handler = handler
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.handler?(.ready)
                self.receive()
            case .failed(let err):
                self.finish(err)
            case .waiting(let err):
                // TLS/PSK mismatch or unreachable host: don't hang around.
                self.finish(err)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        let h = handler
        handler = nil
        connection.cancel()
        h?(.closed(error))
    }

    public func cancel() {
        queue.async { self.finish(nil) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for frame in self.reader.append(data) { self.handler?(.frame(frame)) }
                if self.reader.corrupted { self.finish(nil); return }
            }
            if let error { self.finish(error); return }
            if isComplete { self.finish(nil); return }
            self.receive()
        }
    }

    public func send<T: Encodable>(_ message: T) {
        sendFrame(Frame(type: .json, payload: FlickJSON.encode(message)))
    }

    public func sendFrame(_ frame: Frame, completion: (() -> Void)? = nil) {
        connection.send(content: frame.encoded(), completion: .contentProcessed { _ in completion?() })
    }

    public func sendVideo(_ packet: VideoPacket) {
        lock.lock(); _pendingVideo += 1; lock.unlock()
        sendFrame(Frame(type: .video, payload: packet.encoded())) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self._pendingVideo -= 1; self.lock.unlock()
        }
    }
}

public extension Frame {
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard self.type == .json else { return nil }
        return FlickJSON.decode(type, from: payload)
    }
}

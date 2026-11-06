import Foundation
import FlickKit

/// Runs Claude Code headless on this Mac for voice asks from the phone.
public final class ClaudeRunner {
    public static let shared = ClaudeRunner()

    public var onEvent: ((ServerMessage) -> Void)?
    public private(set) var busy = false

    private var process: Process?
    private var lastSession: (id: String, at: Date)?
    private var buffer = Data()
    private var finished = false
    private let queue = DispatchQueue(label: "flick.claude")

    /// When on, Claude may run shell commands without asking. Off: edits only.
    public var fullAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeFullAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeFullAccess") }
    }

    public var workingDirectory: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "claudeDir") { return URL(fileURLWithPath: p) }
            let conductor = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("conductor")
            return FileManager.default.fileExists(atPath: conductor.path) ? conductor : FileManager.default.homeDirectoryForCurrentUser
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "claudeDir") }
    }

    static let systemNote = """
    The user is talking to you by voice from their iPhone through Flick, a remote for this Mac. \
    Do what they ask on this Mac. Your final reply is read aloud on the phone: one or two short plain sentences, no markdown.
    """

    public func ask(_ prompt: String) {
        queue.async { self.launch(prompt) }
    }

    public func cancel() {
        queue.async {
            self.process?.terminate()
        }
    }

    private func launch(_ prompt: String) {
        if busy { process?.terminate() }
        var args = ["-lc", "exec claude \"$@\"", "flick", "-p", prompt,
                    "--output-format", "stream-json", "--verbose",
                    "--append-system-prompt", Self.systemNote,
                    "--permission-mode", fullAccess ? "bypassPermissions" : "acceptEdits"]
        if let last = lastSession, Date().timeIntervalSince(last.at) < 15 * 60 {
            args += ["--resume", last.id]
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        buffer.removeAll()
        finished = false
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            self?.queue.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] proc in
            self?.queue.async {
                guard let self else { return }
                out.fileHandleForReading.readabilityHandler = nil
                self.consume(out.fileHandleForReading.readDataToEndOfFile())
                self.busy = false
                self.process = nil
                if !self.finished {
                    self.finished = true
                    self.onEvent?(.askDone(text: proc.terminationReason == .uncaughtSignal ? "Stopped." : "Claude couldn't finish that.", ok: false))
                }
            }
        }
        do {
            try p.run()
            process = p
            busy = true
            onEvent?(.askEvent(kind: .status, text: "Thinking"))
        } catch {
            onEvent?(.askDone(text: "Claude Code isn't installed on this Mac.", ok: false))
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "assistant":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for block in content {
                if block["type"] as? String == "text", let t = block["text"] as? String, !t.isEmpty {
                    onEvent?(.askEvent(kind: .text, text: t))
                } else if block["type"] as? String == "tool_use" {
                    let name = block["name"] as? String ?? "Tool"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let detail = (input["description"] ?? input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["url"]) as? String ?? ""
                    onEvent?(.askEvent(kind: .tool, text: detail.isEmpty ? name : "\(name) · \(detail.prefix(80))"))
                }
            }
        case "result":
            let text = obj["result"] as? String ?? ""
            let isError = obj["is_error"] as? Bool ?? false
            if let id = obj["session_id"] as? String { lastSession = (id, Date()) }
            finished = true
            onEvent?(.askDone(text: text.isEmpty ? "Done." : text, ok: !isError))
        default:
            break
        }
    }
}

import Foundation

/// An Agent Client Protocol (ACP) agent: JSON-RPC 2.0, one message per line, driven by a client such as Xcode's
/// coding assistant. It answers `initialize`, `authenticate`, `session/new`, `session/prompt` and `session/cancel`,
/// streams replies as `agent_message_chunk` updates, and lets the model read project files, reporting each read as a
/// tool call. It never writes files or runs commands.
public actor ACPAgent {
    public struct Info: Sendable {
        public let name: String
        public let title: String
        public let version: String
        public init(name: String, title: String, version: String) {
            self.name = name; self.title = title; self.version = version
        }
    }

    public static let protocolVersion = 1
    /// Lines of a file the client is asked for, and characters of it handed to the model.
    static let readLineLimit = 400
    static let readCharacterLimit = 4_000

    private struct Session {
        let cwd: String
        let model: any ACPModelSession
        var turn: Task<Void, Never>?
    }

    private let info: Info
    private let provider: any ACPModelProvider
    private let output: @Sendable (Data) -> Void
    private var clientReadsFiles = false
    private var sessions: [String: Session] = [:]
    private var pendingCalls: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var lastCallID = 0

    /// `output` receives each outgoing message as one line without its line feed.
    public init(info: Info, provider: any ACPModelProvider, output: @escaping @Sendable (Data) -> Void) {
        self.info = info
        self.provider = provider
        self.output = output
    }

    /// Handle one incoming line.
    public func receive(_ line: Data) {
        guard let message = try? JSONDecoder().decode(JSON.self, from: line), case .object(let fields) = message else {
            sendError(id: .null, code: -32700, message: "Parse error")
            return
        }
        let id = fields["id"]
        if let method = fields["method"]?.string {
            let params = fields["params"] ?? .null
            if let id, id != .null {
                handleRequest(id: id, method: method, params: params)
            } else {
                handleNotification(method: method, params: params)
            }
        } else if case .int(let callID)? = id {
            resolveCall(callID, fields)
        }
    }

    // MARK: Requests from the client

    private func handleRequest(id: JSON, method: String, params: JSON) {
        switch method {
        case "initialize":
            clientReadsFiles = params["clientCapabilities"]?["fs"]?["readTextFile"]?.bool ?? false
            reply(id, [
                "protocolVersion": .int(Self.protocolVersion),
                "agentCapabilities": [
                    "loadSession": false,
                    "promptCapabilities": ["image": false, "audio": false, "embeddedContext": true]
                ],
                "agentInfo": ["name": .string(info.name), "title": .string(info.title), "version": .string(info.version)],
                "authMethods": []
            ])
        case "authenticate":
            reply(id, [:])
        case "session/new":
            guard let cwd = params["cwd"]?.string, cwd.hasPrefix("/") else {
                sendError(id: id, code: -32602, message: "session/new needs an absolute cwd")
                return
            }
            let sessionID = "apple-fm-" + UUID().uuidString.lowercased()
            let context = ACPSessionContext(cwd: cwd) { [self] path in
                await self.readFile(sessionID: sessionID, path: path)
            }
            sessions[sessionID] = Session(cwd: cwd, model: provider.makeSession(context))
            reply(id, ["sessionId": .string(sessionID)])
        case "session/prompt":
            guard let sessionID = params["sessionId"]?.string, sessions[sessionID] != nil else {
                sendError(id: id, code: -32602, message: "Unknown session")
                return
            }
            guard sessions[sessionID]?.turn == nil else {
                sendError(id: id, code: -32603, message: "A prompt is already running in this session")
                return
            }
            let blocks = params["prompt"]?.array ?? []
            sessions[sessionID]?.turn = Task { await self.runTurn(id: id, sessionID: sessionID, blocks: blocks) }
        default:
            sendError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleNotification(method: String, params: JSON) {
        if method == "session/cancel", let sessionID = params["sessionId"]?.string {
            sessions[sessionID]?.turn?.cancel()
        }
    }

    private func runTurn(id: JSON, sessionID: String, blocks: [JSON]) async {
        guard let model = sessions[sessionID]?.model else { return }
        let prompt = ACPPrompt.render(blocks)
        var stop = ACPStopReason.endTurn
        if let reason = provider.unavailableReason() {
            sendText(sessionID, reason)
        } else if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                stop = try await model.respond(to: prompt) { [self] text in
                    await self.sendText(sessionID, text)
                }
            } catch is CancellationError {
                stop = .cancelled
            } catch {
                sendText(sessionID, "\n\nThe on-device model couldn't finish this reply. Try again, or start a new chat.")
            }
        }
        if Task.isCancelled { stop = .cancelled }
        sessions[sessionID]?.turn = nil
        reply(id, ["stopReason": .string(stop.rawValue)])
    }

    // MARK: File reads for the model

    private func readFile(sessionID: String, path: String) async -> String {
        guard let cwd = sessions[sessionID]?.cwd else { return "The session has ended." }
        guard let absolute = ACPPaths.resolve(path, in: cwd) else {
            return "\(path) is outside the project folder, so it was not read."
        }
        let toolCallID = "read-" + UUID().uuidString.lowercased()
        let shown = absolute.hasPrefix(cwd) ? String(absolute.dropFirst(cwd.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : absolute
        sendUpdate(sessionID, [
            "sessionUpdate": "tool_call",
            "toolCallId": .string(toolCallID),
            "title": .string("Read \(shown.isEmpty ? absolute : shown)"),
            "kind": "read",
            "status": "in_progress",
            "locations": [["path": .string(absolute)]]
        ])
        var content: String?
        if clientReadsFiles {
            // The client's copy includes unsaved edits.
            let result = try? await call("fs/read_text_file", [
                "sessionId": .string(sessionID), "path": .string(absolute), "limit": .int(Self.readLineLimit)
            ])
            content = result?["content"]?.string
        }
        if content == nil { content = try? String(contentsOfFile: absolute, encoding: .utf8) }
        sendUpdate(sessionID, [
            "sessionUpdate": "tool_call_update",
            "toolCallId": .string(toolCallID),
            "status": content == nil ? "failed" : "completed"
        ])
        guard let content else { return "\(shown) could not be read as text." }
        return ACPPrompt.clip(content, to: Self.readCharacterLimit)
    }

    /// Send a request to the client and wait for its result.
    private func call(_ method: String, _ params: JSON) async throws -> JSON {
        lastCallID += 1
        let callID = lastCallID
        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[callID] = continuation
            send(["jsonrpc": "2.0", "id": .int(callID), "method": .string(method), "params": params])
        }
    }

    private func resolveCall(_ callID: Int, _ fields: [String: JSON]) {
        guard let continuation = pendingCalls.removeValue(forKey: callID) else { return }
        if let error = fields["error"] {
            continuation.resume(throwing: ACPRemoteError(message: error["message"]?.string ?? "Client error"))
        } else {
            continuation.resume(returning: fields["result"] ?? .null)
        }
    }

    // MARK: Output

    private func sendText(_ sessionID: String, _ text: String) {
        guard !text.isEmpty else { return }
        sendUpdate(sessionID, [
            "sessionUpdate": "agent_message_chunk",
            "content": ["type": "text", "text": .string(text)]
        ])
    }

    private func sendUpdate(_ sessionID: String, _ update: JSON) {
        send(["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": .string(sessionID), "update": update]])
    }

    private func reply(_ id: JSON, _ result: JSON) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func sendError(id: JSON, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]])
    }

    private func send(_ message: JSON) {
        output(message.encodedLine())
    }
}

public struct ACPRemoteError: Error, Sendable {
    public let message: String
}

/// Runs an agent on standard input and output until stdin closes.
public enum ACPStdio {
    public static func run(_ agent: ACPAgent) async {
        let lines = AsyncStream<Data> { continuation in
            let reader = Thread {
                var buffer = ACPLineBuffer()
                while true {
                    let chunk = FileHandle.standardInput.availableData
                    if chunk.isEmpty { break }
                    for line in buffer.append(chunk) { continuation.yield(line) }
                }
                continuation.finish()
            }
            reader.start()
        }
        for await line in lines { await agent.receive(line) }
    }

    /// Writes one message per line to stdout. ACP reserves stdout for messages, so log to stderr.
    public static let writeLine: @Sendable (Data) -> Void = { data in
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    private static let stdoutLock = NSLock()
}

import Foundation
import Testing
@testable import ACPAgent

// MARK: Test doubles

/// Collects what the agent writes, as decoded messages.
private final class Outbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [JSON] = []

    var write: @Sendable (Data) -> Void {
        { [self] data in
            #expect(!data.contains(0x0A), "a message must fit on one line")
            let message = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null
            lock.lock(); lines.append(message); lock.unlock()
        }
    }

    var messages: [JSON] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    /// Wait until a message matches, failing after a few seconds.
    func waitFor(_ match: @escaping (JSON) -> Bool) async -> JSON? {
        for _ in 0..<400 {
            if let found = messages.first(where: match) { return found }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    func response(_ id: Int) async -> JSON? {
        await waitFor { $0["id"] == .int(id) && $0["method"] == nil }
    }

    var chunks: String {
        messages.compactMap { message -> String? in
            guard message["params"]?["update"]?["sessionUpdate"] == "agent_message_chunk" else { return nil }
            return message["params"]?["update"]?["content"]?["text"]?.string
        }.joined()
    }
}

private struct FakeProvider: ACPModelProvider {
    var unavailable: String? = nil
    var reply: @Sendable (String, ACPSessionContext, @escaping @Sendable (String) async -> Void) async throws -> ACPStopReason

    func unavailableReason() -> String? { unavailable }
    func makeSession(_ context: ACPSessionContext) -> any ACPModelSession { FakeSession(context: context, reply: reply) }
}

private struct FakeSession: ACPModelSession {
    let context: ACPSessionContext
    let reply: @Sendable (String, ACPSessionContext, @escaping @Sendable (String) async -> Void) async throws -> ACPStopReason

    func respond(to prompt: String, emit: @escaping @Sendable (String) async -> Void) async throws -> ACPStopReason {
        try await reply(prompt, context, emit)
    }
}

private func makeAgent(_ provider: FakeProvider) -> (ACPAgent, Outbox) {
    let outbox = Outbox()
    let agent = ACPAgent(info: .init(name: "test", title: "Test", version: "0"), provider: provider, output: outbox.write)
    return (agent, outbox)
}

private func send(_ agent: ACPAgent, _ message: JSON) async {
    await agent.receive(message.encodedLine())
}

private func startSession(_ agent: ACPAgent, _ outbox: Outbox, cwd: String = "/tmp/project", readsFiles: Bool = false) async -> String {
    await send(agent, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": [
        "protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": .bool(readsFiles)]]
    ]])
    await send(agent, ["jsonrpc": "2.0", "id": 1, "method": "session/new", "params": ["cwd": .string(cwd), "mcpServers": []]])
    return (await outbox.response(1))?["result"]?["sessionId"]?.string ?? ""
}

private func prompt(_ sessionID: String, _ text: String, id: Int = 2) -> JSON {
    ["jsonrpc": "2.0", "id": .int(id), "method": "session/prompt", "params": [
        "sessionId": .string(sessionID), "prompt": [["type": "text", "text": .string(text)]]
    ]]
}

// MARK: Protocol

@Test func initializeAdvertisesVersionOneWithoutLoadOrImages() async {
    let (agent, outbox) = makeAgent(FakeProvider { _, _, _ in .endTurn })
    await send(agent, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": 1]])
    let result = await outbox.response(0)?["result"]
    #expect(result?["protocolVersion"] == 1)
    #expect(result?["agentCapabilities"]?["loadSession"] == false)
    #expect(result?["agentCapabilities"]?["promptCapabilities"]?["image"] == false)
    #expect(result?["agentCapabilities"]?["promptCapabilities"]?["embeddedContext"] == true)
    #expect(result?["authMethods"] == [])
    #expect(result?["agentInfo"]?["name"] == "test")
}

@Test func promptStreamsChunksThenEndsTurn() async {
    let (agent, outbox) = makeAgent(FakeProvider { prompt, _, emit in
        await emit("Hello, ")
        await emit("you asked: \(prompt)")
        return .endTurn
    })
    let sessionID = await startSession(agent, outbox)
    #expect(sessionID.hasPrefix("apple-fm-"))
    await send(agent, prompt(sessionID, "ping"))
    let done = await outbox.response(2)
    #expect(done?["result"]?["stopReason"] == "end_turn")
    #expect(outbox.chunks == "Hello, you asked: ping")
    let update = outbox.messages.first { $0["method"] == "session/update" }
    #expect(update?["params"]?["sessionId"]?.string == sessionID)
    #expect(update?["id"] == nil)
}

@Test func unavailableModelExplainsAndEndsTurn() async {
    let (agent, outbox) = makeAgent(FakeProvider(unavailable: "Turn on Apple Intelligence.") { _, _, _ in
        Issue.record("the model must not be called"); return .endTurn
    })
    let sessionID = await startSession(agent, outbox)
    await send(agent, prompt(sessionID, "hi"))
    #expect(await outbox.response(2)?["result"]?["stopReason"] == "end_turn")
    #expect(outbox.chunks == "Turn on Apple Intelligence.")
}

@Test func cancelEndsTheTurnAsCancelled() async {
    let (agent, outbox) = makeAgent(FakeProvider { _, _, emit in
        await emit("partial")
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return .endTurn
    })
    let sessionID = await startSession(agent, outbox)
    await send(agent, prompt(sessionID, "long"))
    _ = await outbox.waitFor { $0["params"]?["update"]?["sessionUpdate"] == "agent_message_chunk" }
    await send(agent, ["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": .string(sessionID)]])
    #expect(await outbox.response(2)?["result"]?["stopReason"] == "cancelled")

    // The session takes another prompt afterwards.
    await send(agent, prompt(sessionID, "again", id: 3))
    for _ in 0..<400 where outbox.chunks != "partialpartial" { try? await Task.sleep(nanoseconds: 10_000_000) }
    await send(agent, ["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": .string(sessionID)]])
    #expect(await outbox.response(3)?["result"]?["stopReason"] == "cancelled")
}

@Test func modelFailureIsReportedAsText() async {
    struct Boom: Error {}
    let (agent, outbox) = makeAgent(FakeProvider { _, _, _ in throw Boom() })
    let sessionID = await startSession(agent, outbox)
    await send(agent, prompt(sessionID, "x"))
    #expect(await outbox.response(2)?["result"]?["stopReason"] == "end_turn")
    #expect(outbox.chunks.contains("couldn't finish"))
}

@Test func errorsForUnknownMethodSessionAndBadCwd() async {
    let (agent, outbox) = makeAgent(FakeProvider { _, _, _ in .endTurn })
    await send(agent, ["jsonrpc": "2.0", "id": 5, "method": "session/load", "params": [:]])
    #expect(await outbox.response(5)?["error"]?["code"] == -32601)
    await send(agent, prompt("nope", "x", id: 6))
    #expect(await outbox.response(6)?["error"]?["code"] == -32602)
    await send(agent, ["jsonrpc": "2.0", "id": 7, "method": "session/new", "params": ["cwd": "relative"]])
    #expect(await outbox.response(7)?["error"]?["code"] == -32602)
    await agent.receive(Data("not json".utf8))
    #expect(await outbox.waitFor { $0["error"]?["code"] == -32700 } != nil)
}

@Test func stringIdsAreEchoed() async {
    let (agent, outbox) = makeAgent(FakeProvider { _, _, _ in .endTurn })
    await send(agent, ["jsonrpc": "2.0", "id": "abc", "method": "authenticate", "params": ["methodId": "x"]])
    #expect(await outbox.waitFor { $0["id"] == "abc" }?["result"] == [:])
}

// MARK: File reads

@Test func modelReadsAFileThroughTheClient() async {
    let (agent, outbox) = makeAgent(FakeProvider { _, context, emit in
        await emit(await context.readFile("Sources/App.swift"))
        return .endTurn
    })
    let sessionID = await startSession(agent, outbox, readsFiles: true)
    await send(agent, prompt(sessionID, "read it"))

    let request = await outbox.waitFor { $0["method"] == "fs/read_text_file" }
    #expect(request?["params"]?["path"] == "/tmp/project/Sources/App.swift")
    #expect(request?["params"]?["sessionId"]?.string == sessionID)
    let started = outbox.messages.first { $0["params"]?["update"]?["sessionUpdate"] == "tool_call" }
    #expect(started?["params"]?["update"]?["kind"] == "read")
    #expect(started?["params"]?["update"]?["title"] == "Read Sources/App.swift")

    await send(agent, ["jsonrpc": "2.0", "id": request?["id"] ?? .null, "result": ["content": "struct App {}"]])
    #expect(await outbox.response(2)?["result"]?["stopReason"] == "end_turn")
    #expect(outbox.chunks == "struct App {}")
    let finished = outbox.messages.first { $0["params"]?["update"]?["sessionUpdate"] == "tool_call_update" }
    #expect(finished?["params"]?["update"]?["status"] == "completed")
}

@Test func readsOutsideTheProjectAreRefusedWithoutAToolCall() async {
    let (agent, outbox) = makeAgent(FakeProvider { _, context, emit in
        await emit(await context.readFile("../../etc/passwd"))
        return .endTurn
    })
    let sessionID = await startSession(agent, outbox, readsFiles: true)
    await send(agent, prompt(sessionID, "x"))
    #expect(await outbox.response(2)?["result"]?["stopReason"] == "end_turn")
    #expect(outbox.chunks.contains("outside the project folder"))
    #expect(!outbox.messages.contains { $0["method"] == "fs/read_text_file" })
}

@Test func withoutClientFileSupportTheFileIsReadFromDisk() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "let x = 1".write(to: folder.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)

    let (agent, outbox) = makeAgent(FakeProvider { _, context, emit in
        await emit(await context.readFile("a.swift"))
        return .endTurn
    })
    let sessionID = await startSession(agent, outbox, cwd: folder.standardizedFileURL.path, readsFiles: false)
    await send(agent, prompt(sessionID, "x"))
    #expect(await outbox.response(2)?["result"]?["stopReason"] == "end_turn")
    #expect(outbox.chunks == "let x = 1")
    #expect(!outbox.messages.contains { $0["method"] == "fs/read_text_file" })
}

// MARK: Prompt shaping and helpers

@Test func promptPutsAttachedContextBeforeTheRequest() {
    let rendered = ACPPrompt.render([
        ["type": "text", "text": "What does this do?"],
        ["type": "resource", "resource": ["uri": "file:///p/View.swift", "text": "struct V {}"]],
        ["type": "resource_link", "uri": "file:///p/Model.swift", "name": "Model.swift"]
    ])
    #expect(rendered == """
    Context from /p/View.swift:
    struct V {}

    The user referenced /p/Model.swift. Read it with the readFile tool if you need its contents.

    Request:
    What does this do?
    """)
    #expect(ACPPrompt.render([["type": "text", "text": "hi"]]) == "hi")
}

@Test func promptStaysWithinBudget() {
    let big = String(repeating: "x", count: 50_000)
    let rendered = ACPPrompt.render([
        ["type": "text", "text": "Explain"],
        ["type": "resource", "resource": ["uri": "file:///p/A.swift", "text": .string(big)]],
        ["type": "resource", "resource": ["uri": "file:///p/B.swift", "text": .string(big)]]
    ], budget: 1_000)
    #expect(rendered.count <= 1_200)
    #expect(rendered.contains("[truncated]"))
    #expect(rendered.contains("/p/B.swift was attached but left out"))
    #expect(rendered.hasSuffix("Request:\nExplain"))
}

@Test func streamDeltasNeverRepeatText() {
    var sent = ""
    #expect(ACPStreamText.delta(sent: &sent, snapshot: "Hel") == "Hel")
    #expect(ACPStreamText.delta(sent: &sent, snapshot: "Hello") == "lo")
    #expect(ACPStreamText.delta(sent: &sent, snapshot: "Hello") == "")
    #expect(ACPStreamText.delta(sent: &sent, snapshot: "Help") == "")
    #expect(sent == "Hello")
}

@Test func pathsStayInsideTheProject() {
    #expect(ACPPaths.resolve("Sources/A.swift", in: "/p") == "/p/Sources/A.swift")
    #expect(ACPPaths.resolve("/p/B.swift", in: "/p/") == "/p/B.swift")
    #expect(ACPPaths.resolve("file:///p/C.swift", in: "/p") == "/p/C.swift")
    #expect(ACPPaths.resolve("../secret", in: "/p") == nil)
    #expect(ACPPaths.resolve("/pother/x", in: "/p") == nil)
    #expect(ACPPaths.resolve("/etc/passwd", in: "/p") == nil)
    #expect(ACPPaths.resolve("", in: "/p") == nil)
}

@Test func lineBufferSplitsOnLineFeedsOnly() {
    var buffer = ACPLineBuffer()
    #expect(buffer.append(Data("{\"a\":\"\u{2028}\"}\r\n{\"b\"".utf8)) == [Data("{\"a\":\"\u{2028}\"}".utf8)])
    #expect(buffer.append(Data(":1}\n\n".utf8)) == [Data("{\"b\":1}".utf8)])
}

@Test func encodedMessagesAreSingleLines() throws {
    let line = JSON.object(["text": "a\nb", "n": 1]).encodedLine()
    #expect(!line.contains(0x0A))
    #expect(try JSONDecoder().decode(JSON.self, from: line) == ["text": "a\nb", "n": 1])
}

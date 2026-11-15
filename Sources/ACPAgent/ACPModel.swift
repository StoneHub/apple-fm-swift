import Foundation

/// Why a prompt turn ended, using ACP's `stopReason` strings.
public enum ACPStopReason: String, Sendable, Equatable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case refusal = "refusal"
    case cancelled = "cancelled"
}

/// What a model session gets from the agent when it is created.
public struct ACPSessionContext: Sendable {
    /// The project folder Xcode opened the session in.
    public let cwd: String
    /// Reads a project file for the model and returns text to hand back to it, including a short explanation when
    /// the file can't be read. It never throws, so a bad path doesn't end the turn.
    public let readFile: @Sendable (String) async -> String

    public init(cwd: String, readFile: @escaping @Sendable (String) async -> String) {
        self.cwd = cwd
        self.readFile = readFile
    }
}

/// One conversation with the model. The agent sends at most one prompt at a time to a session.
public protocol ACPModelSession: Sendable {
    /// Answer `prompt`, passing reply text to `emit` as it arrives. Throws CancellationError when the turn is
    /// cancelled; any other error is reported to the user as a failed reply.
    func respond(to prompt: String, emit: @escaping @Sendable (String) async -> Void) async throws -> ACPStopReason
}

/// The model behind the agent. The on-device Foundation Models backend lives in the apple-fm-acp executable, so
/// this module stays free of Apple SDKs and its protocol handling can be tested anywhere.
public protocol ACPModelProvider: Sendable {
    /// Nil when the model can answer, otherwise a sentence telling the user what to do.
    func unavailableReason() -> String?
    func makeSession(_ context: ACPSessionContext) -> any ACPModelSession
}

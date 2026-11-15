import Foundation

/// Turns ACP prompt content into one bounded prompt for a small on-device model.
public enum ACPPrompt {
    /// Characters of prompt text per turn. The on-device model's whole context window is a few thousand tokens and
    /// also holds the instructions, earlier turns and the reply.
    public static let defaultBudget = 6_000
    /// The shortest excerpt worth sending; a smaller remainder is dropped with a note instead.
    static let minimumExcerpt = 200

    /// The user's text comes last, after any attached context, so the question is the freshest thing the model reads.
    public static func render(_ blocks: [JSON], budget: Int = defaultBudget) -> String {
        var request: [String] = []
        var attachments: [(title: String, text: String?)] = []
        var notes: [String] = []
        for block in blocks {
            switch block["type"]?.string {
            case "text":
                if let text = block["text"]?.string { request.append(text) }
            case "resource":
                let resource = block["resource"] ?? .null
                let name = displayPath(resource["uri"]?.string ?? "attachment")
                if let text = resource["text"]?.string {
                    attachments.append((name, text))
                } else {
                    notes.append("\(name) was attached but isn't text, so it isn't shown.")
                }
            case "resource_link":
                let name = displayPath(block["uri"]?.string ?? block["name"]?.string ?? "file")
                notes.append("The user referenced \(name). Read it with the readFile tool if you need its contents.")
            case "image", "audio":
                notes.append("An \(block["type"]?.string ?? "attachment") was attached, but this model can't take it here.")
            default:
                break
            }
        }

        let question = clip(request.joined(separator: "\n\n"), to: budget)
        var remaining = budget - question.count - notes.reduce(0) { $0 + $1.count + 1 }
        var sections: [String] = []
        for attachment in attachments {
            guard let text = attachment.text else { continue }
            let header = "Context from \(attachment.title):\n"
            let room = remaining - header.count
            if room < minimumExcerpt {
                notes.append("\(attachment.title) was attached but left out to fit the model's context. Read it with the readFile tool if needed.")
                continue
            }
            let excerpt = clip(text, to: room)
            sections.append(header + excerpt)
            remaining -= header.count + excerpt.count
        }
        if !notes.isEmpty { sections.append(notes.joined(separator: "\n")) }
        guard !sections.isEmpty else { return question }
        return sections.joined(separator: "\n\n") + "\n\nRequest:\n" + question
    }

    /// Cut `text` to at most `limit` characters, marking the cut.
    public static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "\n[truncated]"
        guard limit > marker.count else { return String(text.prefix(max(0, limit))) }
        return String(text.prefix(limit - marker.count)) + marker
    }

    /// A file URI shown as its path, anything else as given.
    static func displayPath(_ uri: String) -> String {
        if uri.hasPrefix("file://"), let url = URL(string: uri) { return url.path }
        return uri
    }
}

/// Converts the cumulative snapshots a streaming model returns into the increments ACP sends.
public enum ACPStreamText {
    /// The text in `snapshot` after what was already sent, updating `sent`. A snapshot that rewrites earlier text
    /// yields nothing, so nothing is sent twice.
    public static func delta(sent: inout String, snapshot: String) -> String {
        guard snapshot.hasPrefix(sent), snapshot.count > sent.count else { return "" }
        let delta = String(snapshot.dropFirst(sent.count))
        sent = snapshot
        return delta
    }
}

/// Keeps model file reads inside the session's project folder.
public enum ACPPaths {
    /// The absolute path for `path` (relative to `cwd`, absolute, or a file URI), or nil when it leaves `cwd`.
    public static func resolve(_ path: String, in cwd: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let root = URL(fileURLWithPath: cwd).standardizedFileURL.path
        let raw: String
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) { raw = url.path }
        else if trimmed.hasPrefix("/") { raw = trimmed }
        else { raw = root + "/" + trimmed }
        let resolved = URL(fileURLWithPath: raw).standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return resolved
    }
}

/// Splits stdin bytes into ACP messages, one per line feed.
public struct ACPLineBuffer: Sendable {
    private var pending = Data()
    public init() {}

    /// Complete lines in the bytes received so far, without their line endings. Blank lines are skipped.
    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}

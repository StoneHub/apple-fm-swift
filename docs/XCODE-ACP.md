# Apple Intelligence in Xcode's coding assistant (ACP)

`apple-fm-acp` is an [Agent Client Protocol](https://agentclientprotocol.com/) agent backed by the on-device
Apple Foundation Model. Register it in Xcode under **Settings > Intelligence > Add an Agent**, and it appears
next to the other agents in the coding assistant. Replies are generated on this Mac; nothing is sent to a server.

## Requirements

- macOS 26 or later on Apple Silicon, with Apple Intelligence turned on and its model downloaded.
- An Xcode release with custom ACP agents (Settings > Intelligence > Add an Agent).
- Xcode's Swift toolchain to build it.

## Build and install

```sh
cd /path/to/apple-fm-swift
swift build -c release --product apple-fm-acp
mkdir -p ~/.local/bin
cp .build/release/apple-fm-acp ~/.local/bin/apple-fm-acp
~/.local/bin/apple-fm-acp --version
```

Copying it out of `.build` keeps the agent working after `swift package clean`. Run the copy step again after
pulling changes.

## Values for the Add an ACP Agent dialog

| Field | Value |
| --- | --- |
| Name | `Apple Intelligence` |
| Executable | the absolute path, for example `/Users/you/.local/bin/apple-fm-acp` (Xcode doesn't expand `~`) |
| Interpreter | leave empty (it's a native binary) |
| Arguments | none |
| Environment Variables | none |

Click **Add**, then pick **Apple Intelligence** in the coding assistant and send a message.

## What it does

- Answers in the coding assistant, streaming the reply. Follow-up questions keep the conversation.
- Uses the code Xcode attaches to a message (the current file or selection) as context, trimmed to fit.
- Reads other project files when the model asks for one, through Xcode so unsaved edits are included. Each read
  shows in the chat as a tool call. Reads outside the project folder are refused.
- Stops when you press Stop in Xcode.

What it doesn't do: it never edits files, builds, runs commands or uses Xcode's MCP tools. It suggests changes as
code blocks you apply yourself. Images aren't accepted.

## Limits to expect

The on-device model is small and its context window holds a few thousand tokens, shared by the instructions, the
conversation, attached code and the reply. Each message's text and attachments are capped at 6,000 characters,
and a file read at 400 lines and 4,000 characters. When a conversation outgrows the window, the agent says so and
continues in a fresh one. Answers about large files or whole projects will be weaker than a cloud agent's.

If Apple Intelligence is off or the model isn't ready, the agent replies with what to change in System Settings
instead of failing.

## Checking it outside Xcode

`scripts/acp-smoke.py` plays Xcode's part: it starts the agent, opens a session in this repository, asks it to read
`Package.swift`, and prints the streamed reply and stop reason.

```sh
swift build -c release --product apple-fm-acp
python3 scripts/acp-smoke.py
python3 scripts/acp-smoke.py ~/.local/bin/apple-fm-acp "Say hello in five words."
```

stdout carries only ACP messages; the agent writes nothing else there.

## Code layout

- `Sources/ACPAgent`: the protocol (JSON-RPC over stdio, sessions, prompt shaping, file reads, cancellation). It
  imports no Apple SDK, so `ACPAgentTests` exercise it with a fake model.
- `Sources/apple-fm-acp`: the Foundation Models backend (one `LanguageModelSession` per chat, the `readFile` tool,
  context-overflow and guardrail handling) and the executable's entry point.

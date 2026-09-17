# Swift support status

Local prototype for the shared Apple Foundation Models path. The `AppleFM` library owns availability and one-shot asynchronous completion; `apple-fm-helper` owns one JSON request from stdin and one JSON result to stdout.

## Build and use

```sh
cd /Users/monroe/Developer/GitRepos/FM/swift
swift build -c release
echo '{"id":"shell-17","kind":"terminal","language":"zsh","before":"git sta","after":""}' | .build/release/apple-fm-helper
echo '{"id":"bad","kind":"terminal"}' | .build/release/apple-fm-helper
swift test
```

The release artifact is `swift/.build/release/apple-fm-helper`. No install step or background process is required; clients invoke it as a request-scoped child process. Remove the local prototype with `rm -rf` of this repository only if desired.

## Checks

- Xcode 27 SDK: `/Applications/Xcode.app/.../MacOSX27.0.sdk`; Swift 6.4.
- Installed `/usr/bin/fm respond --help` checked: `--model system`, `--no-stream`, `--greedy`, and piped stdin are supported.
- Native SDK interface checked: `SystemLanguageModel.default.availability` and `LanguageModelSession.respond(to:)`.
- `swift build -c release`: passed.
- `swift test`: passed, 2 tests.
- Live native completion: passed (`native-smoke`, returned `42`) on this Mac; model output was normalized when it echoed delimiters.
- Malformed JSON and empty-input behavior: passed helper smoke (`error` with empty id; `empty` with echoed id).

## Limitations

This is a macOS 26+ native target and uses the system model only. It does not stream, retain transcript state, log prompt content, or provide a server. The helper returns sanitized failure reasons; clients must reject stale results and enforce their own context bounds.

Commit: aa36a8d (local root commit; update this line if the commit is amended).

# Apple FM Swift support

Local Apple Foundation Models library and JSON completion helper for [Apple FM VS Code](https://github.com/StoneHub/apple-fm-vscode). The VS Code release bundles its helper; you do not need to install this separately.

The package supports macOS 14 deployment. Generation requires macOS 26 or later on an eligible Apple Silicon Mac with Apple Intelligence enabled and the system model downloaded. Build with Xcode 27 / Swift 6.4; API availability is checked at runtime. No cloud fallback.

```sh
swift build -c release
printf '%s\n' '{"id":"trial","kind":"terminal","language":"zsh","before":"git sta","after":""}' | .build/release/apple-fm-helper
```

The helper reads one JSON request and writes one JSON result. `kind` is `terminal` or `editor`; `before` and `after` are the text around the cursor, and optional `context` is extra text for the model. `context` can also say what belongs at the cursor; the helper does not add rules of its own for comments. An editor request with `"mode":"comment"` gets a shorter reply cap, and the caller trims the reply to the comment line. Apart from dropping an exact echo of `before` or `after`, and line breaks around a terminal reply, the helper returns what the model wrote. Completions use greedy sampling, so the same request gets the same answer, and stop after 48 tokens for terminal and comment requests and 160 for editor requests. Optional `keep` says how much of the reply the caller keeps: with `"line"` the helper stops generating once a first line is complete (unless it repeats a line above the cursor), with `"block"` after 12 non-blank lines, and with either after 1200 characters. The reply can then end partway through its last line. Without `keep` the whole reply is generated.

## Native Swift apps

Add the `AppleFM` library product to your app. `AppleFMClient().modelAvailability` returns typed availability on every supported deployment version. Keep generation inside a macOS 26 availability guard:

```swift
import AppleFM
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct EditedText {
    var text: String
}

@available(macOS 26.0, *)
func edit(_ input: String) async throws -> String {
    let output = try await AppleFMClient().generate(
        instructions: "Fix punctuation. Preserve meaning. Return the edited sentence in text.",
        prompt: input,
        generating: EditedText.self,
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 100)
    )
    return output.text
}
```

Omit `generating:` for plain text. Both overloads accept Apple's `GenerationOptions` directly and create a fresh session with the on-device system model. Instructions and prompt are separate. The library does not retain conversation history or log inputs, outputs, or underlying errors.

Generation throws `CancellationError`, `AppleFMError.unavailable(reason)`, or the sanitized `AppleFMError.generationFailed`. Cancellation is checked before and after the model call and remains in the caller's task; it does not promise that system inference stops instantly. Callers own deadlines, concurrency/backlog limits, input limits, schemas, and output validation. Structured generation constrains shape, not factual correctness.

`availability() -> String`, `complete(_:)`, and the helper JSON format remain compatible. Completion uses the same native generation path and keeps its existing terminal/editor validation and normalization.

Run model-independent tests with `swift test`. The separate [native example](Examples/NativeGeneration) compiles a macOS 14 consumer using a caller-owned `@Generable` type from a main-actor entry point. Run it explicitly on an eligible Mac with `swift run --package-path Examples/NativeGeneration`; it sends only a synthetic sentence to the on-device model. The host application should impose its own deadline.

## Releases

Download versioned source from [GitHub Releases](https://github.com/StoneHub/apple-fm-swift/releases/latest). Build locally to use the helper independently. For a prebuilt end-user install, use the VS Code release above.

To publish an iteration: update VERSION, commit and push main, run `./scripts/release.sh`, then publish the generated assets with `gh release create v$(cat VERSION) release/* --target main --generate-notes`. Releases are built locally, not on every push.

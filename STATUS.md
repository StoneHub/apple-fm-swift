# AppleFM status

Living document. Update it whenever work lands, a branch opens, or an issue changes state.

Last updated 2026-09-28. Version `0.1.0` (no release cut since #6).

## Now

| Where | What | State |
| --- | --- | --- |
| `main` | Native generation (#1), bounded completion generation (#6), comment ownership and early stop (#7) | Landed; #7 merged at `7f5f8f8` |
| `stonework/great-archimedes-aeme6x` | Image input for native callers and the helper (#8) | Branch; Swift uncompiled, needs the Mac checks below before merge |

Open issues: #8 (image input), which Jot #162 and apple-fm-vscode #24 depend on.

## What the helper does today

- **Request**: `id`, `kind` (`terminal` or `editor`), `language`, `before`, `after`, and optionally `context`, `mode` and `keep`. `before` + `after` + `context` must fit in 6,000 characters.
- **Prompting**: the instructions add a rule of their own only for terminal requests (one line). Everything else about the cursor comes from the caller's `context`, which the model may follow. The prefix and suffix are data. The prompt marks the cursor with `<CURSOR>` and doesn't use echoable `Prefix:`/`Suffix:` labels.
- **Sampling**: greedy. The cap is 48 tokens for terminal and `mode: "comment"` requests and 160 for other editor requests. `mode` also enables caller-owned comment instructions in bounded context.
- **Early stop** (branch): with `keep: "line"` or `"block"`, the helper streams and stops once the reply holds what the caller keeps. The rule matches the extension's `stopWhen`: a complete first line that doesn't repeat a line above the cursor, more than 12 non-blank lines, or more than 1,200 characters. The reply can end partway through a line. Without `keep`, the reply is generated in full.
- **Trimming** (`normalize(_:for:)`): drops an exact echo of `before` or `after`, and the line breaks around a terminal reply. Nothing else. Comment and block shaping belong to the extension.
- **Result**: one JSON line with `ok`, `empty`, `unavailable`, `cancelled` or `error`. A terminal reply with control characters or several lines is an error.

The native Swift API (`AppleFMClient.modelAvailability`, `generate(instructions:prompt:options:)` and the `Generable` overload, both for macOS 26 and later) hasn't changed since #1. Each call gets a fresh session. It throws only `CancellationError` or a sanitized `AppleFMError`, and it never logs or retains anything.

## Image input (#8, branch)

- **Native**: `generate(instructions:prompt:image:options:)` and a `generating:` overload take one `AppleFMImage` (`.cgImage` or `.file`). They are declared for macOS 26 so that callers get `AppleFMError.imageUnsupported(.requiresNewerOS)` there instead of needing a macOS 27 guard. `imageSupport` reads `SystemLanguageModel.default.capabilities.contains(.vision)` on macOS 27.
- **Checks before the model**: cancellation, model availability, image support, then the image's pixel size (the file header for a file). None of them calls the model.
- **Helper**: `kind: "image"` requests are routed before completion decoding. Bounds: 20 MB, 36 megapixels, 8,000 UTF-16 characters of text, 1–2048 response tokens (1024 by default). The caller owns the instructions and prompt, as apple-fm-vscode #16 asks for editor prompts.
- **Compatibility**: `AppleFMAvailability` is unchanged, since Jot switches over it exhaustively. `AppleFMError` gains `imageUnsupported` and `unreadableImage`; text generation never throws them, and Jot only matches `.unavailable`. Completion requests decode exactly as before.
- **Not measured yet**: image token accounting (the text token counter may not include the image), first-use and repeated latency, and the effect of image size. `Examples/NativeGeneration` with an image path prints both request times.

## Next

The editor integration is apple-fm-vscode #21 and version 0.1.8. Public releases are a separate step. The large-file fixture still restates code and therefore produces no suggestion; the editor tracks that quality issue separately.

## Validation on this Mac, 2026-09-24

- 21 Swift tests passed and the Release helper built.
- The original branch changed instructions for all requests and made the TypeScript call-argument fixture stop suggesting. Limiting that instruction change to comment mode restored the baseline.
- Editor tests passed, including 31 recorded replies and explicit `keep` request checks.
- Three live runs of all 13 Swift fixtures: 33 good, 6 empty, 0 bad or unchecked; no verdict regressed. The baseline was 11 good and 2 empty in one run.
- Large-file requests took 1.132–1.195 seconds, versus 1.204 seconds for the current helper in the baseline. This does not establish a material latency improvement on this model version.
- Code and terminal prompts stay unchanged. The native typed generation API is unchanged; Jot does not need a dependency update for this helper work.

## Known limits

- Runtime generation has only been exercised on macOS 27.2 (2026-09-20 checks). The macOS 14/15 unsupported path and macOS 26 model behavior were only reviewed at compile and link time.
- Stopping the stream ends the helper's wait, and the helper process exits right after. It is not proof that system inference stops at once.
- The example's `GenerationOptions(sampling:…)` produces an SDK 27 deprecation warning. `samplingMode:` replaces it and works back to macOS 26.
- There's no LICENSE file yet.

## Verification log

- **2026-09-28, #8 branch**: written in a Linux cloud session without Apple's SDK, so nothing was compiled or run. API names and signatures come from Apple's FoundationModels documentation for macOS 27 (`Attachment(_:orientation:)`, `Attachment(imageURL:orientation:)`, `LanguageModelCapabilities.Capability.vision`, `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)`). Before merging, on the Mac: `swift test`, `swift build -c release`, `swift build -c release --package-path Examples/NativeGeneration`, the example with a real screenshot, the helper image request in the README, and malformed/oversized/non-image/relative-path helper requests.

- **2026-09-24, #3 and #5 branch**: no Swift toolchain in the container (swift.org is blocked by the network policy, and Ubuntu doesn't package Swift), so `swift test` wasn't run. I checked the new stop-rule test expectations against the extension's `stopWhen` in Node: all 15 cases agree.
- **2026-09-20, #1 on macOS 27.2 with Swift 6.4**:
  - `swift test` passed with 10 tests, and the release builds of the helper and `Examples/NativeGeneration` both passed.
  - Both binaries have `minos 14.0`, and FoundationModels is weak-linked.
  - Live structured smoke passed in 1.01 s and live helper text smoke in 0.74 s.
  - For malformed, empty, invalid-kind and oversized requests, the helper printed the expected single JSON line, exited 0 and wrote nothing to stderr.

Reproduce:

```sh
swift test
swift build -c release
swift build -c release --package-path Examples/NativeGeneration
printf '%s\n' '{"id":"trial","kind":"editor","language":"swift","before":"let answer = ","after":"","context":"The answer is 42.","keep":"line"}' | .build/release/apple-fm-helper
```

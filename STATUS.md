# AppleFM status

Living document. Update it whenever work lands, a branch opens, or an issue changes state.

Last updated 2026-10-02. Version `0.1.0` (no release cut since #6).

## Now

| Where | What | State |
| --- | --- | --- |
| `main` | Native generation (#1), bounded completion generation (#6), comment ownership and early stop (#7) | Landed; #7 merged at `7f5f8f8` |
| `stonework/great-archimedes-aeme6x` | Image input for native callers and the helper (#8) | Branch; exact-head Mac functional checks passed; experimental model-quality limits below |

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
- **Measurements**: exact-head image generation, first/repeated call timings and three image sizes were exercised on the Mac; see the 2026-10-02 evidence below. Image token accounting remains unavailable because the SDK counter failed on attachments. Pixel count does not establish token usage.

## Next

The editor integration is apple-fm-vscode #21 and version 0.1.8. Public releases are a separate step. The large-file fixture still restates code and therefore produces no suggestion; the editor tracks that quality issue separately.

## Image validation on this Mac, 2026-10-02

Tested PR #9 head `bb7d0e84ef0e7aa04e3f521c61fe20e6dacb7f72`, base `5e6bbeade8eaa69a6f2a7cefe386a4ed32bfb73b`, on macOS 27.2 with Xcode 27 / Swift 6.4. These are functional harness checks; model answers remain experimental.

- 34 Swift tests, the Release helper and the Release NativeGeneration example passed. Live file-image generation and native `CGImage` plain-text/structured generation succeeded; availability and image support reported `available` / `supported`.
- The approved public [Jot General screenshot](https://github.com/StoneHub/jot/blob/fa518b7357b4560bf16dad25217dba678e88ba12/docs/images/jot-general-settings.png) (1608 × 1466, SHA-256 `860fff3be73a2b5fa873084aa3c780618993f3c823559ef8858e6416e8f5714e`) was inspected before testing. The native example and generic helper correctly described the visible local-dictation settings interface. No new screen capture or GUI interaction was needed.
- Screenshot native calls took **1.840 / 1.045 s** first/repeated in one process. Targeted helper processes took **1.179 / 1.142 s**. Native timing surrounds generation; helper timing includes process launch/exit. The model was already used that day: these are not proven cold-model timings and exclude capture time.
- Valid helper requests returned one JSON line with `status: ok`. Relative path, missing file, text disguised as PNG, >20 MB input and missing prompt each returned one JSON line with `status: error` and the expected short reason. All exited 0 with empty stderr. Real owned-helper cancellation returned `cancelled`; its child was gone after disposal.
- **Experimental model quality:** both targeted screenshot replies reversed two switch states: Mute built-in speakers was off but reported enabled; Clean up with Apple Intelligence was on but reported disabled. They omitted the General heading; a focused diagnostic read General correctly but still misread switch visuals. This is a recorded model-quality limitation, not a failure of image transport/input validation or a claim of reliable UI-state reading. The harness lets people experience current models as their capabilities evolve; consumers own factual validation.
- Earlier synthetic 384 × 256, 1152 × 768 and 2048 × 1365 images took first/repeated **0.822 / 0.524 s**, **1.207 / 0.546 s** and **0.712 / 0.550 s**. Larger circles were described as ovals. Two samples per size do not establish scaling or battery cost.
- **Image token accounting unavailable:** `SystemLanguageModel.default.tokenCount` returned 7 for text alone, but failed for attachments at all three sizes (FoundationModels -1 / ModelManagerServices 1001 / InferenceError 2008 / tokengenerationcore 1). Image generation succeeded separately. Whether image tokens are included remains unknown; no image-token guarantee is made.
- Native cancellation is checked before/after generation and preserves `CancellationError`, with automated precedence/late-response coverage. Direct live in-flight native Task cancellation was not separately measured. Owned-helper termination does not establish immediate cessation of system inference; callers own deadlines. Older-OS runtime checks and consumer crop/privacy/capture/UI acceptance remain separate and unverified by these checks.

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

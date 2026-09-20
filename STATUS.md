# AppleFM native generation status

Reviewable framework slice for Jot dogfooding, verified 2026-09-20. Parent owns final integration review and app delivery. No PR, merge, release, or app installation performed here.

Implementation commit: `1a822031ce86ae1aede2dde2f4598894d1b48241`.
Branch: `codex/jot-native-generation`.
Worktree: `/Users/monroe/Developer/GitRepos/FM/.worktrees/swift-jot-native-generation`.
Base: `d580e077877b886d7e9818d307d761c28734b43d` (`origin/main` when started).

## Contract

`AppleFMClient.modelAvailability` exposes `AppleFMAvailability` on macOS 14+. Two macOS 26-gated overloads accept caller instructions, prompt, and native `GenerationOptions`: `generate(instructions:prompt:options:) -> String` and `generate<Content: Generable>(instructions:prompt:generating:options:) -> Content`. Both are async throwing operations.

Each call creates a fresh `LanguageModelSession` explicitly using `SystemLanguageModel.default`. Cancellation remains in the caller's Swift task, is checked before and after execution, and throws `CancellationError`. Other failures expose only `AppleFMError.unavailable(reason)` or `.generationFailed`. No retained session, cloud path, log, queue, retry, timeout, or app-specific schema/policy was added. Jot retains its transcript instructions, schema, semantic checks, deadline, and no-backlog behavior.

The legacy `availability() -> String`, `complete(_:)`, and helper JSON shape are preserved. Completion routes through native text generation and retains the original prompts, 6,000-character limit, exact-boundary echo removal, whitespace behavior, and terminal control/multiline checks. The deliberate cancellation improvement gives cancellation precedence over an underlying model error.

## Reproduce

From this worktree:

```sh
swift test
swift build -c release
swift build -c release --package-path Examples/NativeGeneration
python3 - <<'PY'
import subprocess
subprocess.run(['Examples/NativeGeneration/.build/release/NativeGenerationExample'], check=True, timeout=40)
PY
printf '%s\n' '{"id":"trial","kind":"editor","language":"swift","before":"let answer = ","after":"","context":"The answer is 42."}' | .build/release/apple-fm-helper
xcrun vtool -show-build Examples/NativeGeneration/.build/release/NativeGenerationExample
otool -l Examples/NativeGeneration/.build/release/NativeGenerationExample
```

Artifacts: `.build/release/apple-fm-helper` and `Examples/NativeGeneration/.build/release/NativeGenerationExample`. No installation is needed to run either. Add the AppleFM library product as a package dependency to use the API in an app. Removal consists of removing that dependency or ceasing helper invocation; no shell/editor settings were changed.

## Checks actually run

- macOS 27.2 (26B5086k), Xcode toolchain Swift 6.4 (`swiftlang-6.4.0.34.1`). SDK signatures and Apple's public response documentation checked for the macOS 26 overloads.
- `swift test`: 10 tests passed. Covers JSON round-trip, legacy empty/invalid/oversized requests, all unavailable runner states, pre-cancellation without invoking availability/model work, external cancellation while running, response discard after cancellation, cancellation precedence over raw failure, and error redaction. Tests call an internal runner seam; no model generation is required.
- `swift build -c release`: passed, including helper.
- External native example release build: passed with its own macOS 14 manifest, caller-owned `@Generable` type, and main-actor caller. No extra public Sendable constraint was needed.
- `vtool`: helper and external consumer both have `minos 14.0`. `otool`: external consumer links FoundationModels with `LC_LOAD_WEAK_DYLIB`.
- Bounded live structured smoke: passed in 1.01 seconds, availability `available`, synthetic input `um hello there we can meet tomorrow`, structured text `Hello, we can meet tomorrow.`. Shape/nonempty content checked; exact wording is not an assertion.
- Actual release helper subprocess checks: malformed JSON, empty request, invalid kind, and oversized context returned the expected single JSON line, zero exit status, and empty stderr.
- Bounded live helper text smoke: passed in 0.74 seconds, result `{"id":"native-text-smoke","insertText":"42","status":"ok"}`.
- Lead reviewed public signatures, fresh-session ownership, task/cancellation flow, privacy/error boundaries, deployment guards, and legacy normalization diff. `git diff --check` passed.

## Limits and next gate

Runtime generation was exercised on this Mac's macOS 27.2 only. macOS 14/15 unsupported-system behavior and macOS 26 model behavior were compile/link reviewed but not exercised on those OS versions. Actual Jot Xcode integration is the Jot lead's next gate; parent owns final pinning, app build/install, and dogfooding acceptance.

The macOS 26-compatible `GenerationOptions(sampling:...)` example produces an SDK 27 deprecation warning; its newer replacement is macOS 27-only. Keep the older initializer to support macOS 26. Model results vary, and cancellation does not prove system inference stops instantly. No license selection was made; the pre-existing missing LICENSE was reported to parent and deferred.

Owned background processes: none. Build processes and bounded smoke subprocesses exited. Branch push is authorized solely to make the exact framework revision fetchable for Jot dependency validation; main and releases remain unchanged.

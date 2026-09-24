# AppleFM status

Living document. Update it whenever work lands, a branch opens, or an issue changes state.

Last updated 2026-09-24. Version `0.1.0` (no release cut since #6).

## Now

| Where | What | State |
| --- | --- | --- |
| `main` @ `d5755b6` | Native generation (#1), bounded completion generation (#6) | Landed |
| `stonework/jolly-faraday-4ifbvg` | #3 comment-mode ownership, #5 early stop | Pushed; needs `swift test` and dogfood on a Mac before merging |

Open issues: [#3](https://github.com/StoneHub/apple-fm-swift/issues/3) and [#5](https://github.com/StoneHub/apple-fm-swift/issues/5), both addressed on the branch above and closed by its merge.

## What the helper does today

- **Request**: `id`, `kind` (`terminal` or `editor`), `language`, `before`, `after`, and optionally `context`, `mode` and `keep`. `before` + `after` + `context` must fit in 6,000 characters.
- **Prompting**: the instructions add a rule of their own only for terminal requests (one line). Everything else about the cursor comes from the caller's `context`, which the model may follow. The prefix and suffix are data. The prompt marks the cursor with `<CURSOR>` and doesn't use echoable `Prefix:`/`Suffix:` labels.
- **Sampling**: greedy. The cap is 48 tokens for terminal and `mode: "comment"` requests and 160 for other editor requests. `mode` affects nothing else.
- **Early stop** (branch): with `keep: "line"` or `"block"`, the helper streams and stops once the reply holds what the caller keeps. The rule matches the extension's `stopWhen`: a complete first line that doesn't repeat a line above the cursor, more than 12 non-blank lines, or more than 1,200 characters. The reply can end partway through a line. Without `keep`, the reply is generated in full.
- **Trimming** (`normalize(_:for:)`): drops an exact echo of `before` or `after`, and the line breaks around a terminal reply. Nothing else. Comment and block shaping belong to the extension.
- **Result**: one JSON line with `ok`, `empty`, `unavailable`, `cancelled` or `error`. A terminal reply with control characters or several lines is an error.

The native Swift API (`AppleFMClient.modelAvailability`, `generate(instructions:prompt:options:)` and the `Generable` overload, both for macOS 26 and later) hasn't changed since #1. Each call gets a fresh session. It throws only `CancellationError` or a sanitized `AppleFMError`, and it never logs or retains anything.

## Next

1. **Verify the branch on a Mac**: run `swift test` and `swift build -c release`. The branch was written in a Linux container with no Swift toolchain, so it has not been compiled. The parts most likely to need a fix are the `streamResponse` loop (`snapshot.content`) and the trailing closure passed to the internal `generate(…, until:)`.
2. **Extension change for #5** (apple-fm-vscode): send `keep` from `prepare()` in `src/pipeline.ts`. Use `'line'` when `hint.comment || linePrefix.trim()` is true, otherwise `'block'`, the same test `stopWhen` uses. Add `keep?: 'line' | 'block'` to `Request` in `src/backend.ts`. An older helper ignores the field, so the order of the two releases doesn't matter.
3. **Dogfood**:
   - #3: the comment fixtures should score the same or better. The instructions no longer tell the model to treat `context` as data, so check non-comment fixtures too.
   - #5: `ruby_large_class.rb` should take about as long on the Swift backend as on the CLI backend (about 1.4 s), and the other fixtures' verdicts shouldn't change.
4. **Release**: once the branch is merged, bump `VERSION`, run `./scripts/release.sh`, and rebuild the helper the extension bundles.

## Known limits

- Runtime generation has only been exercised on macOS 27.2 (2026-09-20 checks). The macOS 14/15 unsupported path and macOS 26 model behavior were only reviewed at compile and link time.
- Stopping the stream ends the helper's wait, and the helper process exits right after. It is not proof that system inference stops at once.
- The example's `GenerationOptions(sampling:…)` produces an SDK 27 deprecation warning. `samplingMode:` replaces it and works back to macOS 26.
- There's no LICENSE file yet.

## Verification log

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

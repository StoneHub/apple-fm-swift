# Cloud work: AppleFM Swift

This is Jot's shared native library and the VS Code completion helper. Cloud preparation is documentation only; no generation, API change or release is assigned here.

## Environment boundary

Read `Package.swift`, `Sources/AppleFM/AppleFM.swift` and `Tests/AppleFMTests/AppleFMTests.swift`. The source imports FoundationModels. Installing Swift on Linux does not supply Apple's SDK. Even model-independent `swift test` needs the supported Mac build environment. Do not spend a cloud session trying to port this package or installing an unrelated model backend.

A source/design review needs only Git and a text reader. Record the checkout commit and assigned question. Read current code before expanding into callers. Missing local `/Users/...` instructions, `/usr/bin/fm`, Apple Intelligence and personal MCP services are not cloud setup tasks. Allow five minutes for preflight and one evidence-backed environment correction; report a repeated blocker.

## Ownership and dependencies

AppleFM owns generic on-device availability and generation. Callers own retrieval, schemas, deadlines, cancellation policy, bounds and output validation. Jot's planned shared suggestion context does not belong in this generic framework. Keep prompts and private transcript schemas out of it.

At preparation on 2026-09-25, this repo was `8f3f033`; Jot pinned `737fac9e7147403f2777e0901f02452e8fc25ae7` in `Package.swift`, `Package.resolved` and `project.yml`. A change here does not update Jot. Any dependency upgrade is a separate caller change, with matching pins and Mac verification. FluidAudio is another Jot dependency, maintained externally; it is outside this personal-repo task queue.

## Return contract

For a specifically assigned review, return a short report with source anchors, compatibility risks, a recommended change or a justified no-change result, and exact Mac acceptance checks. Do not manufacture an API change merely to create cloud work. For an assigned patch, return the scoped diff with unavailable checks explicitly listed; the local integrator runs `swift test`, `swift build -c release` and affected consumer checks before merge. Live model quality and cancellation behavior need separate eligible-Mac evidence. Packaging, signing, install and publication are local delivery steps.

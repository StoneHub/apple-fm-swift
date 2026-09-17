# Apple FM Swift support

Local Apple Foundation Models library and JSON completion helper for [Apple FM VS Code](https://github.com/StoneHub/apple-fm-vscode). The VS Code release bundles its helper; you do not need to install this separately.

Requires an Apple Silicon Mac with Apple Intelligence enabled and the system model downloaded. Build with Xcode 27 / Swift 6.4; API availability is checked at runtime. No cloud fallback.

```sh
swift build -c release
printf '%s\n' '{"id":"trial","kind":"terminal","language":"zsh","before":"git sta","after":""}' | .build/release/apple-fm-helper
```

## Releases

Download versioned source from [GitHub Releases](https://github.com/StoneHub/apple-fm-swift/releases/latest). Build locally to use the helper independently. For a prebuilt end-user install, use the VS Code release above.

To publish an iteration: update VERSION, commit and push main, run `./scripts/release.sh`, then publish the generated assets with `gh release create v$(cat VERSION) release/* --target main --generate-notes`. Releases are built locally, not on every push.

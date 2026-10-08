# Mac review build startup

The former ad-hoc review bundle passed signature verification but aborted before
startup when loading Sparkle. Ad-hoc app/framework signatures have no Team ID;
[Hardened Runtime library validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
requires Apple-signed libraries or libraries signed with the application's Team
ID. The bundle script now omits Hardened Runtime for ad-hoc review builds.
Developer ID builds retain Hardened Runtime and secure timestamps.

## Actual loader results

Tested on macOS 27 arm64 at source
`85725c5f6340d687a1d8c13a460b1d37eb981c64` (the exact commit is recorded in
`validation.json`). Both probes use the same assembled executable and ad-hoc
frameworks. The before copy reapplies the former app signature's runtime flag.
The `--verify-runtime-linkage` command exits before creating a menu-bar session
or asking for desktop permissions.

```text
Before: DYLD rejects Sparkle; process exits with SIGABRT (return code -6).
After:  Slightshot runtime linkage verified; process exits 0.
Developer ID: runtime remains enabled; linkage verified; process exits 0.
```

`validation.json` records the unedited process results, including the loader
error. CI now runs the same loader check on its assembled review app, alongside
signature and Info.plist verification.

The review image shows GitHub's rendered result document. This is an internal
packaging fix; the native capture interface does not change.

`loader-results.jpg` is the actual GitHub Markdown preview of this document at
`e5c472f`, captured on 8 October 2026. The process results themselves are stored
in `validation.json`.

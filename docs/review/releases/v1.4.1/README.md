# Version 1.4.1 release review

[Version 1.4.1](https://github.com/jmpijll/slightshot/releases/tag/v1.4.1) was
published on 8 October 2026 from source
`29a00652ea8114455dbcec080e1957c4ecfa591b`, using Sparkle build 10.
The [Release workflow](https://github.com/jmpijll/slightshot/actions/runs/37805440321)
and [update feed deployment](https://github.com/jmpijll/slightshot/actions/runs/37806793891)
succeeded.

## Published-file checks

All five downloaded assets match GitHub's SHA-256 values and file sizes.
The Mac app and DMG pass signature, stapled-ticket and Gatekeeper checks.
The app's runtime linkage and the live feed's Ed25519 signature also pass.
The Homebrew candidate cask fetched the same final disk image successfully.

| Download | Package check | Result |
| --- | --- | --- |
| Mac DMG | Signed, notarised, arm64, 1.4.1 (10) | Passed |
| Windows x64 ZIP | One executable, x64 PE32+, 1.4.1 and release source SHA | Passed |
| Windows ARM64 ZIP | One executable, ARM64 PE32+, 1.4.1 and release source SHA | Passed |
| Windows x64 setup | Installer version 1.4.1; native lifecycle CI | Passed |
| Windows ARM64 setup | Installer version 1.4.1; cross-built package inspection | Passed |

The exact-tag Windows workflow passed native app, clipboard, recording, delayed
capture, portable x64 and installer lifecycle checks. Windows downloads remain
unsigned. Native ARM64 execution remains pending. The local public-file check
inspects installer resources and corresponding portable payloads; it does not
unpack installer payloads or rerun Windows execution.

The [full validation record](../v1.4.1-validation.json) contains checksums,
signature results, source commits and workflow provenance. Actual app text
captures are preserved in the [project text review](../../independent-identity/README.md).

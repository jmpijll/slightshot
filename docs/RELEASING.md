# Releasing Slightshot

## Current status

Version [1.5.0](https://github.com/jmpijll/slightshot/releases/tag/v1.5.0) is live
with a signed, Apple-notarised Mac DMG and unsigned Windows x64/ARM64 setup and
portable previews. After stopping a recording, the native editor offers the
screenshot tools and a start/end interval for each mark. Play, scrub, Undo/Redo
and save the annotated MP4; cancelled or failed exports preserve the recording
and edits.

All five public downloads passed checksum, size and version checks. Mac app and
DMG signatures, stapled tickets, Gatekeeper, runtime linkage and the live
Sparkle signature passed. The exact-tag Windows native editor, 4K, portable x64
and installer lifecycle checks passed. See the
[published-file validation](review/releases/v1.5.0-validation.json) and
[release review](review/releases/v1.5.0/README.md) for results and native evidence.
The published Mac app also completed native 4K export and cancellation checks;
its first measured Blur gesture took 1.145 seconds, versus 16.96 ms when warm.
This remaining first-use startup delay is recorded with the successful export
measurements rather than presented as immediate responsiveness.

Sparkle uses build 12, following 1.4.2's build 11. The live feed and Homebrew cask
point to the verified final Mac download. The pinned appcast generator retains
the three latest entries per update branch. Windows updates remain manual.
ARM64 is cross-built and inspected; native ARM64 desktop acceptance is pending.

The GitHub Release workflow uses the repository secrets listed below to sign
and notarise both the app and disk image. The local Developer ID certificate,
Sparkle keys and `slightshot` notarisation profile are configured; the local
Keychain profile is not available to GitHub-hosted runners.

Manual runs default to verification: they keep a signed, notarised DMG as a
seven-day Actions artifact and exercise Sparkle signing, without publishing or
changing the public feed. Regular CI separately offers an ad-hoc-signed review
DMG; see [builds and runners](CI.md).

## Set up Apple notarisation locally

Create an app-specific password at [account.apple.com](https://account.apple.com/),
under **Sign-In and Security → App-Specific Passwords**. Use the Apple account
that belongs to the developer team.

Run this in your own terminal. It prompts for your Apple ID and password, checks
them with Apple and stores them in Keychain:

```bash
xcrun notarytool store-credentials slightshot --team-id PAW49RLWAA
```

Do not put the password in chat, source files or shell history. Confirm that the
saved profile works:

```bash
xcrun notarytool history --keychain-profile slightshot
```

## Configure GitHub releases

Export the **Developer ID Application** certificate with its private key from
Keychain Access as a password-protected `.p12`. Add these repository secrets in
[GitHub Actions settings](https://github.com/jmpijll/slightshot/settings/secrets/actions):

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64-encoded `.p12` certificate |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that export |
| `KEYCHAIN_PASSWORD` | A random password for the temporary CI keychain |
| `APPLE_ID` | Developer Apple account email |
| `TEAM_ID` | `PAW49RLWAA` |
| `APP_PASSWORD` | Apple app-specific password |
| `SPARKLE_PRIVATE_KEY` | Existing Sparkle EdDSA private key |
| `SPARKLE_PUBLIC_KEY` | Matching public key |

The Sparkle secrets are already configured. Keep the existing key pair so
installed versions can verify updates. Never commit the private key.

To upload the certificate without printing it, use the path to your export:

```bash
base64 -i /path/to/Certificates.p12 | gh secret set MACOS_CERTIFICATE
```

`gh secret set SECRET_NAME` prompts for the other values without echoing them.
The CI keychain and temporary private-key files are removed after the run.

Enable **Settings → Pages → Source: GitHub Actions** for the update feed.

## Verify GitHub signing before publication

Run the Release workflow from the branch to check, using the next unpublished
version and leaving **publish** disabled:

```bash
gh workflow run release.yml --ref BRANCH -f version=1.5.1 -F publish=false
```

A successful run confirms certificate import, app and DMG notarisation,
Gatekeeper assessment and Sparkle signing. Download the
`Slightshot-macos-signed-dmg` artifact from that run. No version tag, public
release, appcast commit or Pages deployment is created in this mode.
Notarisation diagnostics and the signed DMG expire after seven days.

The Release workflow also calls the native Windows checks and builds four
Windows assets with the requested version:

| Architecture | Installer | Portable |
| --- | --- | --- |
| x64 | `Slightshot-windows-x64-setup.exe` | `Slightshot-windows-x64.zip` |
| ARM64 | `Slightshot-windows-arm64-setup.exe` | `Slightshot-windows-arm64.zip` |

Each ZIP contains only `Slightshot.exe`, with its runtime bundled. Setup packages
wrap that same self-contained executable. The archives are extracted and checked
for layout, architecture and matching version metadata; the extracted x64 app
runs native screenshot and recording smoke tests. CI also checks the x64 setup's
installation, upgrade, downgrade rejection, running-app guard and uninstall,
including settings preservation and launch-at-login ownership. ARM64 is
cross-built and inspected, with native execution still pending. A release is
published only after the Windows checks and Mac notarisation succeed. Windows
previews, including the installers, are unsigned and update manually.

Installer evidence and logs are retained in the `windows-installer-evidence`
artifact. The reusable Windows workflow passes its four validated downloads to
Release through `Slightshot-windows-release-assets`; review runs provide the
`Slightshot-windows-installers` artifact. Windows setup does not use any of the
Apple signing secrets. See [Windows installation and local builds](windows.md#installer).

## Publish a version

Commit and push the release changes to `main`, then create a new version tag:

```bash
git tag v1.5.1
git push origin v1.5.1
```

Use a new version for every published binary. Do not replace an existing download
because its Sparkle signature and Homebrew checksum would no longer match.

A `v*` tag publishes automatically. A manual run publishes only when **publish**
is explicitly enabled.

The Release workflow checks credentials, signs the app, submits it to Apple,
and staples its ticket before building the disk image. It then signs, notarises
and staples the disk image. Publication requires all checks to pass.

The workflow signs the Sparkle appcast before publication. After publishing the
downloads, it commits the feed and explicitly starts the Pages workflow. A push
made with `GITHUB_TOKEN` does not trigger another
push workflow. See [GitHub's workflow event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

### Local release

```bash
NOTARY_PROFILE=slightshot make release VERSION=1.5.1
```

This produces a signed, notarised disk image locally. It does not publish a
GitHub release or update the Sparkle feed.

### If Apple rejects a submission

`Scripts/notarize.sh` saves `*.notary-result.json` beside the artifact. If Apple
provides a submission ID, the script also requests `*.notary-log.json`. CI keeps
these files as the `notarisation-diagnostics` artifact, including on failure.

A timeout does not cancel Apple's processing. Check the existing submission
before uploading the same build again:

```bash
xcrun notarytool info SUBMISSION_ID --keychain-profile slightshot
xcrun notarytool log SUBMISSION_ID --keychain-profile slightshot notary-log.json
```

Only an `Accepted` result permits stapling. Apps use Gatekeeper's `execute`
assessment; disk images use `open` with `context:primary-signature`. ZIP files
cannot carry a stapled ticket, so pass an `.app` or `.dmg` to the script.

See [Apple's notarisation workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
for submission and ticket details.

## Update Homebrew

After the release is live, update `version` and `sha256` in
[Casks/slightshot.rb](../Casks/slightshot.rb) using the final stapled disk image:

```bash
shasum -a 256 build/Slightshot-1.5.1.dmg
```

## Check release scripts

Published Mac builds and ordinary local bundles use the full Git commit count
as `CFBundleVersion`. Sparkle compares this internal number, rather than the
visible `CFBundleShortVersionString`. Older releases used the Release workflow's
run number: an affected local installation displaying `1.4.0 (128)` therefore
considered release `1.5.0 (12)` older, even though its visible version was newer.

The Release workflow now resolves the same counter as `Scripts/bundle.sh` and
checks that both the build and marketing version exceed every appcast entry in
the source checkout and freshly fetched canonical `main` publication record.
Fetching the latter preserves the selected source HEAD and prevents an old
branch or queued tag from using a stale feed. An unavailable canonical record,
shallow checkout, reused version, decreasing build or invalid feed
blocks publication. The workflow checks out full history; do not substitute a
workflow-run counter. Verify the next release's metadata before building with:

```bash
python3 Scripts/release_metadata.py --version 1.5.1 --appcast public/appcast.xml
```

```bash
python3 -m unittest discover -s Tests -v
shellcheck Scripts/notarize.sh
actionlint
```

The tests use mock Apple tools to check failure handling. They do not establish
that Apple has accepted a real build.

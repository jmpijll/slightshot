# Releasing Slightshot

## Current status

Version [1.6.0](https://github.com/jmpijll/slightshot/releases/tag/v1.6.0) is live
with a signed, Apple-notarised Mac DMG and unsigned Windows x64/ARM64 setup and
portable previews. Scroll up or down over the annotation canvas to change the
size of new marks. A translucent circle centered on the cursor grows and shrinks
with the size, follows cursor movement and disappears after scrolling stops.
Screenshot, clipboard and recording editors support it on both platforms.

Release source: `f9edab1c9864d17a502ca589b67dd885cceda056`. Mac build 207 uses the
full source Git-history counter and exceeds the previous public build 195.
All five public downloads passed checksum, size, version and provenance checks.
The Mac app and DMG passed Developer ID signature, stapled-ticket, Gatekeeper and
runtime-linkage checks. The deployed Sparkle feed matches its committed bytes,
and its Ed25519 signature authenticates the final DMG with both the current
embedded key and the immutable public 1.4.0 application's key.

The exact-tag Windows native editor, scroll halo, recording, timed editor, 4K,
extracted portable x64 and installer lifecycle checks passed. Windows updates
remain manual. ARM64 is cross-built and inspected; native ARM64 desktop
acceptance remains pending. See the [release verification](review/releases/v1.6.0/README.md)
and [published-file validation](review/releases/v1.6.0-validation.json).

The release workflow publishes after Windows validation, Mac notarisation and
an independent check of the update feed's signature. A separate publish job
makes the release public, commits the signed update feed onto `main` and waits
for Pages to deploy it. The local
Developer ID certificate, Sparkle keys and `slightshot` notarisation profile are
configured; the local Keychain profile is not available to GitHub-hosted runners.
Manual verification runs leave **publish** disabled and preserve a signed,
notarised DMG as a seven-day artifact without changing public downloads or feed.
Regular CI provides an ad-hoc-signed review DMG; see [builds and runners](CI.md).

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
gh workflow run release.yml --ref BRANCH -f version=1.6.1 -F publish=false
```

A successful run confirms certificate import, app and DMG notarisation,
Gatekeeper assessment and Sparkle signing. The Sparkle 2.10.0 tools must match
a pinned SHA-256 before they receive the private key. After `generate_appcast`,
a CryptoKit check finds the new feed item by build number, compares its URL and
length with the disk image and verifies its Ed25519 signature with both the
`SPARKLE_PUBLIC_KEY` secret and the `SUPublicEDKey` embedded in the built app.
Any mismatch fails the run before publication. The run summary lists both
verified keys. Download the
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

Commit and push the release changes to `main`, then tag a commit on `main`:

```bash
git tag v1.6.1
git push origin v1.6.1
```

Use a new version for every published binary. Do not replace an existing download
because its Sparkle signature and Homebrew checksum would no longer match.

A `v*` tag publishes automatically. A manual run publishes only when **publish**
is explicitly enabled and the run uses `main`. Before building, a publishing run
fetches `origin/main` and stops unless the source commit is contained in it.
Verification runs with **publish** disabled may use any branch.

The Release workflow checks credentials, signs the app, submits it to Apple,
and staples its ticket before building the disk image. It then signs, notarises
and staples the disk image. Publication requires all checks to pass.

The build job extends the feed fetched from `origin/main`, not the source
checkout's copy, so an older tag cannot drop published entries. It signs and
verifies the feed and keeps it as the `Slightshot-appcast` artifact beside the
signed disk image. The build job has read-only repository access and never
publishes.

The **Publish release and update feed** job runs only when publishing. It uses
those artifacts and the Windows downloads, in this order:

1. Stop if the version tag already exists on a commit other than the release
   source. GitHub would otherwise attach the downloads to that commit.
2. Upload the downloads to a draft release, or to the draft an earlier attempt
   left. Check every uploaded file's SHA-256 against the artifact, then make the
   release public. A release that is already public is reused only if every
   file matches.
3. Wait until every download in the new feed is publicly reachable at the length
   the feed states.
4. Commit the feed onto the current `origin/main` and push it. If `main` moved,
   fetch it again and retry up to five times. Skip the commit if `main` already
   has this exact feed. Stop if `public/appcast.xml` changed on `main` after
   the feed was generated.
5. Start the Pages workflow and wait for its deployment. A push made with
   `GITHUB_TOKEN` does not trigger another push workflow. See [GitHub's workflow event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

The feed is committed only after its downloads are public, so `main` never lists
an update that Sparkle cannot download. Pages also refuses to deploy a feed
unless every download it lists is an `https://` URL that ends, after redirects,
in HTTP 200 over HTTPS at the expected length. Network errors, 429 and 5xx
responses are retried up to five times, honouring `Retry-After`; any other
response fails at once. This applies to every Pages run, including a manual
dispatch or another push to `public/`.

### If publication fails

A failed publish job can leave a public release whose feed entry is not yet on
`main` or not yet deployed. Installed copies keep their current version until
the feed is deployed. Do not start a new Release run: its version check stops
once `main` lists the version, and a new build would produce different bytes.

Open the failed run and choose **Re-run failed jobs** within seven days, before
the artifacts expire. The publish job uses the same disk image, Windows files
and signed feed again. It reuses the matching public release, skips a feed
commit that `main` already has and deploys Pages again.

If a step fails again, read its error first. If `public/appcast.xml` changed on
`main` after generation, decide whether to revert that edit or publish a new
version. If Pages reports an unavailable download, check that the release is
public and has every file.

Every action in `.github/workflows` is pinned to a full commit SHA, with its
version in a trailing comment. Dependabot proposes grouped action updates weekly.

### Local release

```bash
NOTARY_PROFILE=slightshot make release VERSION=1.6.1
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
shasum -a 256 build/Slightshot-1.6.1.dmg
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
python3 Scripts/release_metadata.py --version 1.6.1 --appcast public/appcast.xml
```

```bash
python3 -m unittest discover -s Tests -v
shellcheck Scripts/notarize.sh
actionlint
```

The tests use mock Apple tools to check failure handling. They do not establish
that Apple has accepted a real build.

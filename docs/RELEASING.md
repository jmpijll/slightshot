# Releasing Slightshot

## Current status

Version 1.0.2 is signed and notarised by Apple. Versions 1.0.0 and 1.0.1 remain
unnotarised pre-releases. The local Developer ID certificate, Sparkle keys and
`slightshot` notarisation profile are configured.

Local releases work. Automated GitHub releases still need the Developer ID
certificate and Apple credentials in repository secrets. The local Keychain
profile is not available to GitHub-hosted runners.

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

## Publish a version

Commit and push the release changes to `main`, then create a new version tag:

```bash
git tag v1.0.2
git push origin v1.0.2
```

Use a new version for every published binary. Do not replace an existing download
because its Sparkle signature and Homebrew checksum would no longer match.

The Release workflow checks credentials, signs the app, submits it to Apple,
and staples its ticket before building the disk image. It then signs, notarises
and staples the disk image. Publication requires all checks to pass.

After publication, it signs the Sparkle appcast, commits the feed and explicitly
starts the Pages workflow. A push made with `GITHUB_TOKEN` does not trigger another
push workflow. See [GitHub's workflow event rules](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).

### Local release

```bash
NOTARY_PROFILE=slightshot make release VERSION=1.0.2
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
shasum -a 256 build/Slightshot-1.0.2.dmg
```

## Check release scripts

```bash
python3 -m unittest discover -s Tests -v
shellcheck Scripts/notarize.sh
actionlint
```

The tests use mock Apple tools to check failure handling. They do not establish
that Apple has accepted a real build.

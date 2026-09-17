# Releasing Slightshot

Everything below is a one-time setup except the last section.

## 1. Sparkle signing keys

Sparkle verifies every update with an EdDSA signature. Generate the key pair
once; the private half is stored in your login keychain.

```bash
SPARKLE_VERSION=2.10.0
curl -fsSL -o /tmp/sparkle.tar.xz \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
mkdir -p /tmp/sparkle && tar -xf /tmp/sparkle.tar.xz -C /tmp/sparkle
/tmp/sparkle/bin/generate_keys
```

It prints a **public** key. Save it so local builds embed it:

```bash
echo 'PASTE_PUBLIC_KEY_HERE' > .sparkle-public-key   # git-ignored
```

Export the **private** key for CI (keep it out of the repo):

```bash
/tmp/sparkle/bin/generate_keys -x /tmp/sparkle_private_key
cat /tmp/sparkle_private_key   # -> GitHub secret SPARKLE_PRIVATE_KEY
rm /tmp/sparkle_private_key
```

Without a public key the app still builds and runs; it simply refuses to apply
updates, and `Scripts/bundle.sh` says so.

## 2. Apple credentials

### Developer ID certificate

Export **Developer ID Application** from Keychain Access as a `.p12`, then:

```bash
base64 -i Certificates.p12 | pbcopy   # -> GitHub secret MACOS_CERTIFICATE
```

### Notarisation

Create an app-specific password at <https://appleid.apple.com>, then either
store it locally:

```bash
xcrun notarytool store-credentials slightshot \
  --apple-id "you@example.com" --team-id "PAW49RLWAA" --password "abcd-efgh-ijkl-mnop"
export NOTARY_PROFILE=slightshot
```

…or add the three CI secrets below.

## 3. GitHub secrets

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 of the Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password you set when exporting it |
| `KEYCHAIN_PASSWORD` | any random string; scopes the CI keychain |
| `APPLE_ID` | your Apple ID email |
| `TEAM_ID` | `PAW49RLWAA` |
| `APP_PASSWORD` | the app-specific password |
| `SPARKLE_PRIVATE_KEY` | private EdDSA key from step 1 |
| `SPARKLE_PUBLIC_KEY` | public EdDSA key from step 1 |

Also enable **Settings › Pages › Source: GitHub Actions** — that is where the
Sparkle appcast is published.

## 4. Cutting a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The `Release` workflow then builds, signs, notarises, staples, publishes the
GitHub release with the `.dmg`, regenerates `appcast.xml`, and deploys it to
Pages. Existing installs pick the update up from there.

### Doing it by hand

```bash
export NOTARY_PROFILE=slightshot
make release VERSION=1.0.0
```

## 5. Homebrew cask

After the release is live, refresh `Casks/slightshot.rb`:

```bash
shasum -a 256 build/Slightshot-1.0.0.dmg
```

Update `version` and `sha256`, then commit.

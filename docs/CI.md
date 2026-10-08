# Builds and runners

Regular CI produces a Mac review DMG; the Windows workflow produces self-contained portable x64 and ARM64 apps plus native rendering/recording evidence. Each Windows app artifact opens to one `Slightshot.exe`, with its runtime bundled. Download these under **Artifacts** on a successful workflow run. Review artifacts are retained for seven days on Mac and Windows. Mac review builds are explicitly ad-hoc signed, not notarised, and do not update the release or Sparkle feed.

Ad-hoc Mac review builds omit Hardened Runtime because their app and embedded
frameworks have no Team ID for library validation. CI invokes the assembled
app's `--verify-runtime-linkage` check to catch loader failures before packaging;
this check exits without creating windows, requesting permissions or owning a
capture session. Developer ID release builds retain Hardened Runtime and secure
timestamps. See the [before/after loader check](review/mac-review-launch/README.md).

The Mac job uses the existing `xcode-27` runner because the app requires macOS 27. Native Windows rendering and recording tests stay on `windows-latest`. Linux can run the release-gate tests, Windows core geometry/raster checks and a Windows cross-build; it cannot build/notarise a native Mac DMG or execute WPF.

## Unraid

Slightshot has its own `slightshot-runner` container on Unraid, registered as `slightshot-unraid-1` with `self-hosted`, `Linux`, `X64`, `slightshot-unraid` labels. Its repository variable is:

```text
LINUX_CI_RUNNER = ["self-hosted","Linux","X64","slightshot-unraid"]
```

The portable job uses that variable for main pushes and manual runs. All pull-request runs use GitHub-hosted Ubuntu. Remove the variable to return all Linux work to `ubuntu-latest`. If the runner is offline while the variable is set, trusted jobs wait for it; GitHub does not automatically fail over to a hosted runner.

The container reuses the existing local runner image, has its own work directory, two CPUs and a 4 GiB memory limit. It has no Docker socket, all capabilities are dropped, and privilege escalation is disabled. It restarts automatically after a host restart. Existing runners are untouched. The entrypoint and work files live under `/mnt/nvme_cache/appdata/slightshot-runner`; registration files live in the container's writable layer. Recreating/deleting the container requires fresh registration; restarting it does not. Registration used a short-lived repository registration token and did not store a personal access token in the container.

Do not put credentials in a workflow or runner template. A future container recreation should obtain a fresh registration token in GitHub's repository runner settings. Keep the current image available as `leep-runner:local` or replace it deliberately with an official runner version.

GitHub shares runners across repositories through organisations. Personal-account repositories require individual registration. This setup deliberately remains repository-specific; no organisation or repository transfer is needed.

[Standard GitHub-hosted runners for public repositories and self-hosted runners are free](https://docs.github.com/en/actions/concepts/billing-and-usage). Artifact storage has separate limits. Keeping Mac and native Windows on hosted runners therefore does not consume private-repository included minutes for this public project.

## Release DMG

`Release` signs and notarises the app and DMG and verifies Sparkle appcast signing. Manual runs default to verification only and retain the signed DMG as a seven-day artifact. A version tag, or a manual run with **publish** enabled, also publishes a GitHub release and Sparkle feed. It uses the same `xcode-27` toolchain as regular CI. A future dedicated Mac can be selected with `MACOS_RELEASE_RUNNER`, containing a JSON runner label or label array; Linux containers are not suitable.

All eight repository secrets are configured. The [signed verification run](https://github.com/jmpijll/slightshot/actions/runs/37664140165) at `2712cfe` passed certificate import, app and DMG notarisation, ticket stapling and appcast signing. Both Apple submissions were accepted. The downloaded disk image and enclosed app also passed local Gatekeeper assessment; the generated Sparkle signature verified against the embedded, existing public key. Release publication, appcast commits and Pages deployment were skipped in verification mode.

See [the validation record](review/releases/signing-validation.json) for the tested source commit, artifact hash and local checks, and [RELEASING.md](RELEASING.md) for verification and publishing instructions.

The [1.1.0 publication run](https://github.com/jmpijll/slightshot/actions/runs/37671914101)
also passed the reusable native Windows checks and attached portable x64/ARM64
ZIPs alongside the Mac DMG. The [downloaded release validation](review/releases/v1.1.0-validation.json)
confirms the actual public DMG's signatures, stapled tickets, Gatekeeper acceptance
and Sparkle signature against the live feed, plus both Windows ZIPs' integrity,
version, architecture and bundled runtime. Windows remains an unsigned preview;
the maintainer reported successful real Windows desktop capture/recording
acceptance on 8 October 2026 (see [Windows validation](windows.md#validation-and-evidence)). The public update feed
was deployed through [Pages](https://github.com/jmpijll/slightshot/actions/runs/37672469651).

The [1.2.0 publication run](https://github.com/jmpijll/slightshot/actions/runs/37702953604)
passed native Windows raster/recording tests, both portable architecture/version
checks, screenshot/recording tests of the extracted x64 single-file app, and Mac
app/DMG signing and notarisation. The [public-download validation](review/releases/v1.2.0-validation.json)
confirms each Windows ZIP contains only `Slightshot.exe`, with matching release
digests and actual PE version/architecture metadata. It also records Mac
Gatekeeper acceptance, both stapled tickets, the live Sparkle signature and
Homebrew's fetch/checksum check. ARM64 Windows execution was not tested.
The new feed was deployed through [Pages](https://github.com/jmpijll/slightshot/actions/runs/37703387744).

The [1.3.0 publication run](https://github.com/jmpijll/slightshot/actions/runs/37743497133)
passed native screenshot retry, numbered steps and raster parity at four display
scales, recording buffer reuse/lifecycle tests, both portable architecture/version
checks, and the extracted x64 app's screenshot/recording checks. Mac app/DMG
signing, notarisation and stapling passed. The [public-download validation](review/releases/v1.3.0-validation.json)
records both Windows digests and exact source-version metadata, Mac Gatekeeper
acceptance, tickets and the live Sparkle signature. The feed's build 8 preserves
the build 7 entry and was deployed through [Pages](https://github.com/jmpijll/slightshot/actions/runs/37744016338).

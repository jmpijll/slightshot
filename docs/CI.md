# Builds and runners

Regular CI produces a Mac review DMG; the Windows workflow produces self-contained portable x64 and ARM64 apps plus native rendering/recording evidence. Download these under **Artifacts** on a successful workflow run. Review artifacts are retained for seven days on Mac and Windows. Mac review builds are explicitly ad-hoc signed, not notarised, and do not update the release or Sparkle feed.

The Mac job uses the existing `xcode-27` runner because the app requires macOS 27. Native Windows rendering and recording tests stay on `windows-latest`. Linux can run the release-gate tests, 47 Windows core geometry checks and a Windows cross-build; it cannot build/notarise a native Mac DMG or execute WPF.

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
the CI fixtures do not establish real desktop acceptance. The public update feed
was deployed through [Pages](https://github.com/jmpijll/slightshot/actions/runs/37672469651).

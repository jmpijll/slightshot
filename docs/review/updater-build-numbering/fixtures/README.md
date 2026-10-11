# Isolated native Sparkle discovery evidence

This task-owned diagnostic application uses the production Sparkle 2.10.0 SDK,
its standard version comparator and its supported
`SPUUpdater.checkForUpdateInformation` API. The callback result is displayed in
a running native AppKit window. Captures come from ScreenCaptureKit, with an
explicitly reported native AppKit rendering fallback if necessary.

The installed metadata is synthetic: marketing version `1.4.0` with observed
installed build `128`, local review build `162`, or ordinary published build `9`. Each bundle has its own
`com.jmpijll.slightshot.updater-review.*` ID and preferences. These are ad-hoc
fixture applications, not unmodified published Slightshot binaries. No updater
controller or comparator is patched in the harness. The original user app and
its preferences are not targeted.

The only updater actions are `startUpdater` and `checkForUpdateInformation`.
Automatic checks and automatic downloads are disabled. Sparkle documents this
as a probing check that reports `didFindValidUpdate` / `updaterDidNotFindUpdate`
without offering an update. It neither downloads nor installs a DMG.

Before the fix, the actual published feed contained marketing version `1.5.0`,
build `12`. Sparkle returned `SUSparkleErrorDomain` code `1001` (“You’re up to
date!”) for installed builds `128` and `162`, but found version `1.5.0` for
installed build `9`. The SDK's reported no-update reason is `2`, documented as
`SPUNoUpdateFoundReasonOnNewerThanLatestVersion`: the higher installed build is
ordered ahead of the newer marketing release. All runs used the same feed,
real SDK and standard comparator.

`UpdateDiscoveryProbe.m` is the native harness source. `build_probe.py` creates a
new task-owned bundle and refuses to overwrite one. `run_probe.py` runs only a
fixture bundle with isolated metadata, saves the feed response and provenance,
and asserts that the operation was a probing check and its result matched the
requested expectation. `discovery-report.json` preserves actual Sparkle
callbacks, loaded appcast items, selected/rejected item and capture source.

Candidate-feed evidence is a prepublication test of release version ordering;
it does not prove a candidate enclosure can be downloaded, verified or installed.
Published-feed discovery should be repeated after the signed patch release is
published. Artifact trust checks and release payload validation are separate.

The after-fix candidate matrix used the exact appcast generated from committed
production policy at `1806a9eb8280cce7601f1807374d79d30ed4da72`: marketing
version `1.5.1`, build `192`. All three installed builds (`128`, `162`, `9`)
received `didFindValidUpdate` selecting that exact item. The immutable candidate
bytes were served on an owned loopback server; its request log records six
appcast GETs (three snapshots plus three Sparkle checks). The future enclosure
is synthetic and was not downloaded, installed or claimed to be signed.

The harness creates `SPUUpdater` with `NSBundle.mainBundle` as both host and
application bundle. Each synthetic host has a unique fixture identifier; no
production bundle, production defaults suite, `defaults` command or updater
preference setter is used. Automatic behavior is disabled by the fixture's
Info.plist. `run_probe.py` runs only bundles in the task-owned directory and
rejects production IDs or enabled automatic checks/downloads. It waits for the
owned subprocess to exit; the bounded native probe also exits after capture or
timeout. The candidate coordinator closes its owned loopback server in `finally`.
Process inspection after the matrix found no task-owned app/helper process;
the existing user app PID `43282` was still running. This is a scope and process
audit, not a claim that unrelated app/user preferences were compared byte-for-byte.

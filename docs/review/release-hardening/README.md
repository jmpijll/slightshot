# Release workflow hardening (#38)

![Release dry run on fix/38-release-hardening](dry-run.png)

The image shows [Release run 39409286689](https://github.com/jmpijll/slightshot/actions/runs/39409286689)
at source `13534da`, started with `version=1.7.0` and **publish** disabled. The
upper part is the public run summary. The lower part is copied from the job log
fetched with `gh api`. Both Apple submissions were accepted. The Sparkle tarball
matched its pinned SHA-256. `generate_appcast` added build 210 to the feed
fetched from `origin/main`, and the new signature verified with both the
`SPARKLE_PUBLIC_KEY` secret and the built app's `SUPublicEDKey`. The four
publication steps were skipped.

- [dry-run-log.txt](dry-run-log.txt) is the job log excerpt and every step result.
- [local-checks.txt](local-checks.txt) records the run blocks exercised locally:
  the source gate, the feed commit against a bare remote with a real
  non-fast-forward race, and the signature check against wrong keys, a modified
  disk image and the public 1.6.0 download.

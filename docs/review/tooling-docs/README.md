# Tooling and docs review (#39)

Captured on macOS from source `f38999a` (after) and `9bd9a83` (before, main).

`transcript.sh` records the checks: run it from the repository root. It
appends a temporary force cast to one Swift file, runs `make lint`, then
restores the file. It also runs `make lint` without SwiftLint on `PATH`,
`make -n release` in a clone made with `--no-tags`, `actionlint` and ShellCheck.
`before.txt` and `after.txt` are its output; the PNG shows them side by side.

| File | Content |
| --- | --- |
| [make-lint-version-before-after.png](make-lint-version-before-after.png) | `make lint` and `VERSION` before and after the fix. |
| [next-steps-rendered.png](next-steps-rendered.png) | `docs/NEXT_STEPS.md` rendered by the GitHub Markdown API. |
| [asset-audit-rendered.png](asset-audit-rendered.png) | `docs/asset-audit.md` rendered by the GitHub Markdown API. |
| [ci-doc-changes-rendered.png](ci-doc-changes-rendered.png) | The three changed `docs/CI.md` paragraphs, rendered the same way. |

Do not run `transcript.sh` while a build is in progress: SwiftPM rejects
source files that change during a build.

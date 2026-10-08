# Visual evidence requirement

`pr-template.jpg` is a browser screenshot of GitHub's rendered Markdown preview
for `.github/PULL_REQUEST_TEMPLATE.md` at source commit
`3a35dadeb73a2771bde27aaf91f5276ac555bbba`, captured on 8 October 2026.
It shows the new review sections exactly as contributors see the template.
This documentation change affects the review workflow, not either native app UI.

The same evidence rule is in `CONTRIBUTING.md` and the repository's `AGENTS.md`.
The template link targets the contributing section that this PR adds to `main`.

Validation: `git diff --check` and an inspection of all three review entry points
for the screenshot/video requirement, platform identification and source commit.

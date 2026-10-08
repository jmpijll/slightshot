# Focus after 1.3.0

The six bounded follow-ups identified after 1.2.0 are merged and shipped in
[1.3.0](https://github.com/jmpijll/slightshot/releases/tag/v1.3.0).

| Work | Result |
| --- | --- |
| [Screenshot retry](https://github.com/jmpijll/slightshot/pull/16) | Keep selection, annotations and Undo after cancellation or failed output; retry or explicitly close. |
| [Windows version/update polish](https://github.com/jmpijll/slightshot/pull/14) | Show the actual executable version and link to manual downloads. |
| [Numbered steps](https://github.com/jmpijll/slightshot/pull/15) | One additional annotation tool, current colour, Undo and numbering per screenshot. |
| [Mac command routing](https://github.com/jmpijll/slightshot/pull/17) | Strict capture URLs and one owner for cold/warm launches, with existing busy guards. |
| [Windows recording buffers](https://github.com/jmpijll/slightshot/pull/18) | A lazy pool of at most four buffers, reused only after native processing. |
| [Raster allocations](https://github.com/jmpijll/slightshot/pull/19) | Scalar Mac pixelation totals and pooled Windows blur scratch storage, with identical output pixels. |

Each PR passed independent review and native CI. The combined implementation
also passed Mac/Windows/Linux CI and desktop Mac acceptance before merging.
The exact release commit passed 39 Swift tests, 111 Windows core checks, 14 Python
tests, strict lint and a warning-free Windows build. See the
[published-file validation](review/releases/v1.3.0-validation.json),
[raster measurements](review/performance/README.md) and
[recording allocation measurements](recording-buffer-allocations.md).

## Review the bounded next release candidate

The following small changes are prepared as separate pull requests and await
review and merge. They are not shipped:

- [Windows installer (#20)](https://github.com/jmpijll/slightshot/pull/20)
- [Redo for annotations (#23)](https://github.com/jmpijll/slightshot/pull/23)
- [Five-second area capture (#22)](https://github.com/jmpijll/slightshot/pull/22)
- [Edit Image from Clipboard (#25)](https://github.com/jmpijll/slightshot/pull/25)

The review chain also includes the [visual evidence rule (#21)](https://github.com/jmpijll/slightshot/pull/21)
and [macOS review-bundle signing fix (#24)](https://github.com/jmpijll/slightshot/pull/24).
Review native screenshots, exports and run provenance in each PR, then test the
combined candidate before preparing a release. Keep the normal capture flow fast
and familiar; these additions stay behind explicit menu/tray actions or editor
shortcuts.

## Use the app and fix concrete problems

After this candidate, prioritize problems found while using Slightshot: broken
capture or editor interactions, output failures, and measured performance or
memory regressions. Verify fixes on the affected native platform and retain a
focused review diff with actual visual evidence when the UI changes.

History, uploads, OCR, and new multi-display behavior remain outside this bounded
candidate. Avoid expanding the app unless real usage shows a concrete need.

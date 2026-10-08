# Focus after 1.4.0

The bounded follow-ups after 1.3.0 are merged and shipped in
[1.4.0](https://github.com/jmpijll/slightshot/releases/tag/v1.4.0).

| Work | Result |
| --- | --- |
| [Windows installer (#20)](https://github.com/jmpijll/slightshot/pull/20) | Per-user x64/ARM64 setup packages alongside the portable ZIPs, with settings preserved across upgrades. |
| [Visual review evidence (#21)](https://github.com/jmpijll/slightshot/pull/21) | Every PR includes focused screenshots or a short video of the implemented result. |
| [Five-second area capture (#22)](https://github.com/jmpijll/slightshot/pull/22) | An explicit menu/tray action gives time to arrange transient content before capture. |
| [Annotation Redo (#23)](https://github.com/jmpijll/slightshot/pull/23) | Restore undone marks, text, raster effects and numbered steps through the toolbar or shortcut. |
| [macOS review-build startup (#24)](https://github.com/jmpijll/slightshot/pull/24) | Ad-hoc review bundles load their runtime dependencies; Developer ID release signing retains the hardened runtime. |
| [Clipboard image editor (#25)](https://github.com/jmpijll/slightshot/pull/25) | Crop or annotate a copied image in a normal editor window with Fit/100% viewing and original pixel/transparency preservation. |

All six PRs include durable visual evidence and passed independent review.
The combined implementation passed Mac/Windows/Linux CI and native Mac/Windows
checks before publication. See the
[published-file validation](review/releases/v1.4.0-validation.json) and the
native evidence linked from each PR. These additions stay behind explicit
menu/tray actions or editor shortcuts, keeping ordinary capture fast and familiar.

## Use the app and fix concrete problems

This release completes the agreed scope. Prioritize problems found while using
Slightshot: broken capture or editor interactions, output failures, and measured
performance or memory regressions. Verify fixes on the affected native platform
and retain a focused review diff with actual visual evidence when the UI changes.

History, uploads, OCR and new multi-display behavior remain outside this scope.
Add features only when real usage shows a concrete need.

## Previously shipped in 1.3.0

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

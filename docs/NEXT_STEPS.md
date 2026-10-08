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

## Next work

Use this version and address concrete reliability or performance issues as they
appear. Investigate a measured bottleneck before adding caches or settings.
Windows ARM64 desktop acceptance remains useful when a real ARM64 device is
available; automated native execution currently runs on x64.

Capture history, upload providers and selections across displays require clear
user demand. The current capture, annotate, copy/save and record workflow is a
good stopping point for feature additions.

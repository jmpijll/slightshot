# Focus after 1.7.0

[1.7.0](https://github.com/jmpijll/slightshot/releases/tag/v1.7.0) is the
current release. It includes the 20 October 2026 audit fixes for issues #38 to
#49, plus the inbox test fix in #58 and staging-bookkeeping fix in #70.
[Release verification](review/releases/v1.7.0/README.md) links their merged PRs
and review evidence.

## Audit fixes

The following audit issues shipped in 1.7.0. Each fix has its own pull request
with review evidence and an independent review.

| Issue | Reported problem or request |
| --- | --- |
| [#38](https://github.com/jmpijll/slightshot/issues/38) | Release workflow can publish half a release and trusts unverified signing tools. |
| [#39](https://github.com/jmpijll/slightshot/issues/39) | `make lint` never fails, VERSION fallback is broken, docs describe old releases. |
| [#40](https://github.com/jmpijll/slightshot/issues/40) | macOS: quitting or a stream error deletes unsaved recordings and annotations. |
| [#41](https://github.com/jmpijll/slightshot/issues/41) | macOS: save notification may move the saved file and needs a relaunch to work. |
| [#42](https://github.com/jmpijll/slightshot/issues/42) | macOS: committed text wraps and sits differently from typed text; paste does not work. |
| [#43](https://github.com/jmpijll/slightshot/issues/43) | macOS: shortcut settings accept unusable combos and hide registration failures. |
| [#44](https://github.com/jmpijll/slightshot/issues/44) | macOS: clicking outside the selection deletes annotations; Shift-rectangle and edge precision. |
| [#45](https://github.com/jmpijll/slightshot/issues/45) | Windows: Print Screen cannot be bound, crashes are silent, second launch does nothing. |
| [#46](https://github.com/jmpijll/slightshot/issues/46) | Windows: crashed recordings stay in `%TEMP%` and odd-sized areas are rescaled. |
| [#47](https://github.com/jmpijll/slightshot/issues/47) | Windows: corrupt settings are overwritten and launch-at-login can point at a moved copy. |
| [#48](https://github.com/jmpijll/slightshot/issues/48) | Windows: check for updates from inside the app. |
| [#49](https://github.com/jmpijll/slightshot/issues/49) | Trim the start and end of a recording before saving. |

Changes keep the current toolbars and default shortcuts. New behavior that
would change the default capture path goes behind a setting.

## Use the app and fix concrete problems

Prioritize problems found while using Slightshot:
broken capture or editor interactions, output failures, and measured
performance or memory regressions. Verify fixes on the affected native platform
and retain a focused review diff with actual visual evidence when the UI changes.

History, uploads, OCR, audio recording and new multi-display behavior remain
outside this scope. Add features only when real usage shows a concrete need.

## Shipped since 1.4.0

| Release | Change |
| --- | --- |
| [1.4.1](https://github.com/jmpijll/slightshot/releases/tag/v1.4.1) | Clearer About text, settings labels and project descriptions ([#28](https://github.com/jmpijll/slightshot/pull/28)). |
| [1.4.2](https://github.com/jmpijll/slightshot/releases/tag/v1.4.2) | Windows-key combinations can be recorded as global shortcuts ([#31](https://github.com/jmpijll/slightshot/pull/31)). |
| [1.5.0](https://github.com/jmpijll/slightshot/releases/tag/v1.5.0) | Timed video annotations in a native recording editor on Mac and Windows ([#33](https://github.com/jmpijll/slightshot/pull/33)). |
| [1.5.1](https://github.com/jmpijll/slightshot/releases/tag/v1.5.1) | macOS update discovery with one shared build counter ([#35](https://github.com/jmpijll/slightshot/pull/35)). |
| [1.6.0](https://github.com/jmpijll/slightshot/releases/tag/v1.6.0) | Scroll to resize new annotations, with a cursor circle showing the size ([#37](https://github.com/jmpijll/slightshot/pull/37)). |
| [1.7.0](https://github.com/jmpijll/slightshot/releases/tag/v1.7.0) | Audit fixes #38 to #49 cover release checks, tooling, Mac unsaved work, notifications, text, shortcuts and selection, Windows launch, recording, settings and updates, and recording trim. Merged PRs [#50](https://github.com/jmpijll/slightshot/pull/50), [#51](https://github.com/jmpijll/slightshot/pull/51), [#52](https://github.com/jmpijll/slightshot/pull/52), [#53](https://github.com/jmpijll/slightshot/pull/53), [#54](https://github.com/jmpijll/slightshot/pull/54), [#55](https://github.com/jmpijll/slightshot/pull/55), [#56](https://github.com/jmpijll/slightshot/pull/56), [#57](https://github.com/jmpijll/slightshot/pull/57), [#59](https://github.com/jmpijll/slightshot/pull/59), [#60](https://github.com/jmpijll/slightshot/pull/60), [#63](https://github.com/jmpijll/slightshot/pull/63), [#64](https://github.com/jmpijll/slightshot/pull/64), and [#65](https://github.com/jmpijll/slightshot/pull/65). Inbox test #58 shipped in [#62](https://github.com/jmpijll/slightshot/pull/62), and staging bookkeeping #70 in [#71](https://github.com/jmpijll/slightshot/pull/71). Version preparation shipped in [#69](https://github.com/jmpijll/slightshot/pull/69). |

Each release has a [published-file validation record](review/releases/).
Earlier releases are listed on the
[releases page](https://github.com/jmpijll/slightshot/releases).

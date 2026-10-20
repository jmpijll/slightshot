# Overlay shortcuts with a toolbar or palette control focused

Review round 1 on PR #59 found that the palette slider and toolbar buttons can
take focus, after which the Edit menu swallowed the overlay's ⌘C. This check
sends every row of the README's "While selecting or annotating" shortcut table
in both editor windows, with three different focused views.

Captured on macOS 27 on 20 October 2026 with debug builds launched as
`Slightshot --text-tool-shortcuts <dir>`. The fix column is source `d813e26`. The
main column is `9bd9a83` plus only the review fixture, with no Edit menu as on
main. The capture overlay rows use the production `OverlayView` in a titled
window over a synthetic 900×560 image. The clipboard editor rows use the
production `ClipboardEditorWindow`. Before each row, the fixture shrinks the
selection to 120,130 to 420,330 and keeps one rectangle annotation; for Redo it
keeps one undone rectangle. It then focuses the view with `makeFirstResponder`
and sends the key through `NSApp.sendEvent` while the app is active and the
window is key. Copy, save, save as and print are recorded through the overlay
delegate, not performed.

24 of 72 rows changed, all from "nothing" to the documented action
(bold). No row regressed. Return, Esc and the arrow keys still do nothing while the
palette slider has focus, or while a clipboard editor toolbar button has focus;
main behaves the same, so these predate this change and are tracked as a
follow-up.

| Shortcut | Window | Focus | main `9bd9a83` | fix `d813e26` |
| --- | --- | --- | --- | --- |
| ⌘A select all | Capture overlay | Overlay | selection 1920×1243 | selection 1920×1243 |
| ⌘C copy | Capture overlay | Overlay | copy | copy |
| ⌘S save | Capture overlay | Overlay | save | save |
| ⇧⌘S save as | Capture overlay | Overlay | saveAs | saveAs |
| ⌘P print | Capture overlay | Overlay | print | print |
| ⌘Z undo | Capture overlay | Overlay | undo | undo |
| ⇧⌘Z redo | Capture overlay | Overlay | redo | redo |
| Return confirm | Capture overlay | Overlay | copy | copy |
| Esc cancel | Capture overlay | Overlay | cancel | cancel |
| ⌘X cancel | Capture overlay | Overlay | cancel | cancel |
| ← move 1 pt | Capture overlay | Overlay | moved -1,0 | moved -1,0 |
| ⇧→ move 10 pt | Capture overlay | Overlay | moved 10,0 | moved 10,0 |
| ⌘A select all | Capture overlay | Palette slider | nothing | **selection 1920×1243** |
| ⌘C copy | Capture overlay | Palette slider | nothing | **copy** |
| ⌘S save | Capture overlay | Palette slider | nothing | **save** |
| ⇧⌘S save as | Capture overlay | Palette slider | nothing | **saveAs** |
| ⌘P print | Capture overlay | Palette slider | nothing | **print** |
| ⌘Z undo | Capture overlay | Palette slider | nothing | **undo** |
| ⇧⌘Z redo | Capture overlay | Palette slider | nothing | **redo** |
| Return confirm | Capture overlay | Palette slider | nothing | nothing |
| Esc cancel | Capture overlay | Palette slider | nothing | nothing |
| ⌘X cancel | Capture overlay | Palette slider | nothing | **cancel** |
| ← move 1 pt | Capture overlay | Palette slider | nothing | nothing |
| ⇧→ move 10 pt | Capture overlay | Palette slider | nothing | nothing |
| ⌘A select all | Capture overlay | Toolbar button | selection 1920×1243 | selection 1920×1243 |
| ⌘C copy | Capture overlay | Toolbar button | copy | copy |
| ⌘S save | Capture overlay | Toolbar button | save | save |
| ⇧⌘S save as | Capture overlay | Toolbar button | saveAs | saveAs |
| ⌘P print | Capture overlay | Toolbar button | print | print |
| ⌘Z undo | Capture overlay | Toolbar button | undo | undo |
| ⇧⌘Z redo | Capture overlay | Toolbar button | redo | redo |
| Return confirm | Capture overlay | Toolbar button | copy | copy |
| Esc cancel | Capture overlay | Toolbar button | cancel | cancel |
| ⌘X cancel | Capture overlay | Toolbar button | cancel | cancel |
| ← move 1 pt | Capture overlay | Toolbar button | moved -1,0 | moved -1,0 |
| ⇧→ move 10 pt | Capture overlay | Toolbar button | moved 10,0 | moved 10,0 |
| ⌘A select all | Clipboard editor | Overlay | selection 900×560 | selection 900×560 |
| ⌘C copy | Clipboard editor | Overlay | copy | copy |
| ⌘S save | Clipboard editor | Overlay | save | save |
| ⇧⌘S save as | Clipboard editor | Overlay | saveAs | saveAs |
| ⌘P print | Clipboard editor | Overlay | print | print |
| ⌘Z undo | Clipboard editor | Overlay | undo | undo |
| ⇧⌘Z redo | Clipboard editor | Overlay | redo | redo |
| Return confirm | Clipboard editor | Overlay | copy | copy |
| Esc cancel | Clipboard editor | Overlay | cancel | cancel |
| ⌘X cancel | Clipboard editor | Overlay | cancel | cancel |
| ← move 1 pt | Clipboard editor | Overlay | moved -1,0 | moved -1,0 |
| ⇧→ move 10 pt | Clipboard editor | Overlay | moved 10,0 | moved 10,0 |
| ⌘A select all | Clipboard editor | Palette slider | nothing | **selection 900×560** |
| ⌘C copy | Clipboard editor | Palette slider | nothing | **copy** |
| ⌘S save | Clipboard editor | Palette slider | nothing | **save** |
| ⇧⌘S save as | Clipboard editor | Palette slider | nothing | **saveAs** |
| ⌘P print | Clipboard editor | Palette slider | nothing | **print** |
| ⌘Z undo | Clipboard editor | Palette slider | nothing | **undo** |
| ⇧⌘Z redo | Clipboard editor | Palette slider | nothing | **redo** |
| Return confirm | Clipboard editor | Palette slider | nothing | nothing |
| Esc cancel | Clipboard editor | Palette slider | nothing | nothing |
| ⌘X cancel | Clipboard editor | Palette slider | nothing | **cancel** |
| ← move 1 pt | Clipboard editor | Palette slider | nothing | nothing |
| ⇧→ move 10 pt | Clipboard editor | Palette slider | nothing | nothing |
| ⌘A select all | Clipboard editor | Toolbar button | nothing | **selection 900×560** |
| ⌘C copy | Clipboard editor | Toolbar button | nothing | **copy** |
| ⌘S save | Clipboard editor | Toolbar button | nothing | **save** |
| ⇧⌘S save as | Clipboard editor | Toolbar button | nothing | **saveAs** |
| ⌘P print | Clipboard editor | Toolbar button | nothing | **print** |
| ⌘Z undo | Clipboard editor | Toolbar button | nothing | **undo** |
| ⇧⌘Z redo | Clipboard editor | Toolbar button | nothing | **redo** |
| Return confirm | Clipboard editor | Toolbar button | nothing | nothing |
| Esc cancel | Clipboard editor | Toolbar button | nothing | nothing |
| ⌘X cancel | Clipboard editor | Toolbar button | nothing | **cancel** |
| ← move 1 pt | Clipboard editor | Toolbar button | nothing | nothing |
| ⇧→ move 10 pt | Clipboard editor | Toolbar button | nothing | nothing |

Reproduce after `swift build`:

```sh
.build/debug/Slightshot --text-tool-shortcuts build/text-tool-shortcuts
```

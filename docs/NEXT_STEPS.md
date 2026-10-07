# Small next steps after 1.2.0

Reviewed on 8 October 2026 against release commit `87faf632`. The Windows
workflow has been accepted on a real desktop by the maintainer. Blur, Pixelate
and the single-executable Windows package are now shipped.

## Recommended order

| Priority | Work | Benefit | Scope |
| --- | --- | --- | --- |
| 1 | Preserve the screenshot when saving is cancelled or fails | Retry without selecting and annotating again | One focused Mac/Windows reliability PR |
| 2 | Correct Windows version labels and expose manual updates | Users can identify their build and find the latest download | Small Windows polish PR |
| 3 | Measure raster and recording allocations, then fix proven hotspots | Smoother large selections and longer recordings | Bounded profiling task followed by targeted changes |

### 1. Preserve an unfinished screenshot

The Mac [overlay coordinator](../Sources/Slightshot/Overlay/OverlayCoordinator.swift)
calls `dismiss()` before delivering the image. Its
[Save As service](../Sources/Slightshot/Services/OutputService.swift) returns
`nil` for cancellation and errors, but the coordinator ignores the result.
The Windows [capture callback](../Windows/Slightshot/App.xaml.cs) likewise
closes all overlays before calling
[OutputService.Perform](../Windows/Slightshot/OutputService.cs), whose failure
result is ignored. This is a confirmed control-flow issue, rather than a
performance hypothesis.

Retain the frozen display, selection and annotation history while a save panel
is open. Restore the editable session on cancellation or failure; release it
after success or explicit Escape. Panels must retain focus above the overlay.
Reuse the recording workflow's existing retry principle without adding capture
history or another permanent window.

Acceptance: cancel Save As, fail a write, retry successfully, and confirm that
selection, blur/pixelate, text and Undo survive on both platforms. Also check
that no second capture begins while a retained session is active.

### 2. Windows version and manual-update polish

[About](../Windows/Slightshot/App.xaml.cs) and
[General settings](../Windows/Slightshot/SettingsWindow.cs) still display
`0.1.0`, although the released executable's version is `1.2.0`. The tray's
Check for Updates item is disabled.

Use one assembly-derived display version and offer **Download updates…** to
open the latest GitHub release. Keep the current manual installation flow.
Acceptance: About and Settings match the actual portable executable's version,
and the link opens the release page from an extracted path containing spaces.

### 3. Profile before expanding caches or adding settings

Both [Mac](../Sources/Slightshot/Overlay/CanvasView.swift) and
[Windows](../Windows/Slightshot/AnnotationCompositor.cs) already cache committed
compositions. Dragging a raster effect only processes its new region; committed
edits, Undo and selection changes still rebuild the history. Mac
[pixelation](../Sources/Slightshot/Editor/RasterEffect.swift) constructs channel
arrays per block, and Windows blur allocates region and scratch buffers per
update. These are candidates to measure, not established responsiveness bugs.

Measure 4K selections with 1, 10 and 25 mixed annotations at supported display
scales. Compare p95 drag, commit, Undo and resize latency and allocations.
Only change demonstrated hotspots, retaining the existing pixel-parity tests.

Windows [recording capture](../Windows/Slightshot/GdiRecordingCapture.cs) reuses
its native DIB but creates a full managed byte array for every frame. At
3840 × 2160 × 4 bytes and 30 fps, that is about 949 MiB/s of cumulative array
allocations, not resident memory or measured throughput. A bounded buffer pool
may help; return a buffer only after the encoder's
[MediaStreamSample.Processed event](https://learn.microsoft.com/en-us/uwp/api/windows.media.core.mediastreamsample.processed?view=winrt-26100),
which Microsoft documents as the safe reuse point. Validate long recordings,
Stop, cancellation and capture failure before adopting it.

## One optional feature later

**Numbered steps** fits the existing annotation model: click to place 1, 2, 3
in circles, use the current colour choice and Undo, and reset per screenshot.
Derive the next number from retained annotations so Undo also restores numbering.
Check live/export parity on both platforms. This is the strongest small feature
after reliability and measured optimisation.

Mac scripting also deserves a focused reliability pass when Shortcuts/Alfred/
Raycast integration is needed. Current capture arguments are handled only at
process launch; reopening an existing app opens Settings. Apple's
[launch-argument documentation](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/arguments)
supports this limitation. A command route to one active app should work for
both cold and warm starts and avoid duplicate menu items/hotkey registrations
when another bundle copy is opened.

Keep capture history, upload providers and selections across multiple displays
for demonstrated demand. They add persistent data, configuration or substantial
geometry work to an otherwise small capture utility.

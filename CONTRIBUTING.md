# Contributing

Thanks for looking. Slightshot is small on purpose, so contributions are easy to
review.

## Getting set up

```bash
git clone https://github.com/jmpijll/slightshot.git
cd slightshot
make run
```

You need macOS 27 and the Xcode 27 command line tools. There is no `.xcodeproj`
— it is a plain Swift package, so `open Package.swift` works if you want Xcode.

## Before opening a pull request

- `make lint` passes (`swiftlint --strict`)
- `swift build` is warning-free
- You have actually run the app and used the feature you changed

## The one hard rule

**Interaction fidelity with Lightshot wins.** If a change makes Slightshot
faster or prettier but moves a toolbar, changes a shortcut, or adds a step, it
probably belongs behind a setting rather than in the default path. People are
switching to this because their hands already know Lightshot.

That applies to behaviour, not implementation — the internals should be as
modern and as fast as we can make them.

## Where things live

| Path | What |
| --- | --- |
| `Sources/Slightshot/Capture` | ScreenCaptureKit, permissions |
| `Sources/Slightshot/Overlay` | The capture UI — the heart of the app |
| `Sources/Slightshot/Editor` | Annotation model and the exporter |
| `Sources/Slightshot/Services` | Hotkeys, settings, output, updates |
| `Sources/Slightshot/Preferences` | SwiftUI settings window |
| `Scripts/` | Bundle, sign, notarise, disk image, icon |

## Coordinate systems

Everything drawn in the overlay uses **flipped display points, origin top-left**.
`Annotation.draw()` is shared between the live canvas and `Renderer.flatten()`,
which is why what you see is what gets saved. If you add a drawing tool, add it
to `Annotation.Shape` and it works in both places for free.

`ScreenshotView`, `DimView` and `MagnifierView` are deliberately *not* flipped,
because `CALayer.contents` and `CGContext.draw(_:in:)` render images upright in
default geometry. Each one converts at its own boundary.

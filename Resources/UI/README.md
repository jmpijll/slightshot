# Slightshot product icons

`icons.json` contains original project-owned vectors under the repository MIT license. The artwork uses ordinary tool/action concepts, a consistent rounded stroke and an 18-point canvas. It does not contain exported Apple SF Symbols, traced outlines or platform font glyphs.

Edit this source, then run `python3 Scripts/generate_ui_icons.py`. Commit the generated CoreGraphics and WPF paths with the source. Both CI workflows run `--check` to reject drift between the source and compiled native artwork; generation does not run in the application. Native code has no new package or runtime resource dependency.

AppKit displays the paths as tintable, accessible template images. WPF draws the same paths with the existing toolbar tint. Buttons remain 30 points with the same padding, ordering, tooltips and actions. The colour well stays a circle control. The existing logo and tray image remain project-owned artwork, and native fonts/materials/dialogs keep their existing platform behavior.

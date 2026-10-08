<p align="center">
  <img src="docs/hero.svg" alt="Slightshot. A screenshot with your point on it." width="100%">
</p>

<p align="center">
  A native screenshot and screen recording app for macOS and Windows, inspired by Lightshot.<br>
  Select an area, add a note or an arrow, and copy it into your conversation.
</p>

<p align="center">
  <a href="#get-started">Get started</a> ·
  <a href="#screenshot">Screenshot</a> ·
  <a href="#shortcuts">Shortcuts</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

<p align="center">macOS 27+ / Apple silicon · Windows / x64 &amp; ARM64 preview · MIT license</p>

## Get started

Choose your platform on [Releases](https://github.com/jmpijll/slightshot/releases).

| Platform | Download | Updates |
| --- | --- | --- |
| macOS 27+, Apple silicon | Signed and Apple-notarised `.dmg` | In-app updates with Sparkle, or Homebrew |
| Windows, x64 or ARM64 | Unsigned preview; portable `.zip` | Download the next version from Releases |

### macOS

Open the `.dmg`, move Slightshot to Applications, then open it. On first launch,
allow Screen Recording in **System Settings › Privacy & Security › Screen &
System Audio Recording**, then relaunch Slightshot.

You can also install it with Homebrew:

```bash
brew tap jmpijll/slightshot https://github.com/jmpijll/slightshot
brew install --cask slightshot
```

### Windows

Download the portable [x64 ZIP](https://github.com/jmpijll/slightshot/releases/latest/download/Slightshot-windows-x64.zip)
or [ARM64 ZIP](https://github.com/jmpijll/slightshot/releases/latest/download/Slightshot-windows-arm64.zip),
extract it, then run the single `Slightshot.exe` inside. The runtime is included;
you do not need to install .NET. Use a supported Windows 11 release; see the
[Windows guide](docs/windows.md) for compatibility and validation details.

Windows installers will join the portable downloads in the next release as
`Slightshot-windows-x64-setup.exe` and `Slightshot-windows-arm64-setup.exe`.
Setup installs for your user without administrator rights, adds a Start menu
shortcut and offers an optional desktop shortcut. Starting at login is an
opt-in setting in the app. Quit Slightshot from its tray menu before installing,
upgrading or uninstalling. Upgrades preserve your settings and saved captures.
See [installer review and build instructions](docs/windows.md#installer).

Windows builds remain unsigned previews and Windows may show a security warning.
**Download updates…** in the app opens Releases. The maintainer verified capture
and recording on an x64 Windows desktop; ARM64 is cross-built and inspected,
with native desktop acceptance still pending.

## Capture an area

Slightshot lives in the Mac menu bar or Windows notification area. Press
<kbd>⌘⇧9</kbd> on Mac or <kbd>Ctrl+Shift+9</kbd> on Windows and drag to select
part of your screen. The drawing tools appear beside the selection; copy, save,
print and record sit underneath it.

Use the pen, line, arrow, rectangle, marker or text tool to point something out.
Change the colour and thickness, undo an annotation, or resize the selection
before copying it. Save screenshots as PNG, JPEG or TIFF. Cancelling Save As
or Print, or failing a save, keeps the screenshot editable so you can try again.

Choose **Blur** or **Pixelate**, then drag a rectangle over details you want
to obscure. The effect appears while dragging and is included when you copy,
save or print. Undo removes it just like any other annotation. Both tools work
locally on Mac and Windows; they do not modify live screen recordings.

Choose **Numbered steps** and click to place 1, 2, 3 in circles using the current
colour. Undo restores the next number, and each screenshot starts at 1. Circles
grow for extra digits and keep their size independent of the thickness slider.

Choose **Capture Area in 5 Seconds** in the Mac menu bar or Windows tray menu
to arrange a menu, tooltip or other transient content before the screen freezes.
The small countdown has a **Cancel** button and leaves keyboard focus with your
current app. At five seconds the area editor opens using fresh screen pixels.
Choosing the delayed action again restarts the countdown; an ordinary capture
cancels it and captures immediately. An existing editor or recording blocks
another capture. There is no additional setting or shortcut.

See the [native delayed-capture review evidence](docs/review/delayed-capture/README.md).

## Record an area

Select an area and click the **Record** button underneath it. The frozen
selection disappears and Slightshot records that part of the live screen.
A compact timer and **Stop** button stay beside the selected area.

After stopping, choose where to save the MP4 and adjust its quality slider:
**Small & fast**, **Balanced**, or **High quality**. The choice is remembered.
Small exports use a lower resolution, frame rate and bitrate; high quality
keeps more detail. Recording controls and other Slightshot windows are excluded
from the video. Recordings contain video only; microphone and system audio are
not captured, and screenshot annotations are not added to the live screen.

Cancel an export to choose another quality or destination. Cancel the save
panel to keep the recording or discard it. Temporary source files are removed
after saving, discarding, or quitting.

See the [macOS recording review video](docs/review/recording/README.md)
for the Record, Stop and save-time quality flow, and the
[Windows recording validation](docs/windows.md#screen-recording) for that platform.

## Screenshot

<p align="center">
  <img src="docs/screenshot.png" width="900" alt="A selected area with a red arrow and text annotation, drawing tools on the right, and print, copy, save and close underneath">
</p>

The image above is a reframed illustration of the capture overlay, edited from
a screenshot. It contains no menu bar or personal widgets.

A pixel magnifier helps you place the selection. Its size stays visible as you
drag. Hold <kbd>Shift</kbd> for a square selection or a constrained line. Hold
<kbd>⌘</kbd> on Mac or <kbd>Ctrl</kbd> on Windows while selecting to copy the
area as soon as you release the mouse. A selection stays within one display.

## Shortcuts

Undo and Redo in the toolbar also work with text, blur, pixelation and numbered steps.
Redo restores the original mark; adding a new annotation or starting a new selection
clears Redo. While typing, the text field keeps its native Undo and Redo shortcuts.

You can change the three capture shortcuts in Settings.

| Action | macOS | Windows |
| --- | --- | --- |
| Capture an area | <kbd>⌘⇧9</kbd> | <kbd>Ctrl+Shift+9</kbd> |
| Save the display under the pointer | <kbd>⌘⇧8</kbd> | <kbd>Ctrl+Shift+8</kbd> |
| Copy the display under the pointer | <kbd>⌘⇧7</kbd> | <kbd>Ctrl+Shift+7</kbd> |

While selecting or annotating:

| Action | macOS | Windows |
| --- | --- | --- |
| Select the whole display | <kbd>⌘A</kbd> | <kbd>Ctrl+A</kbd> |
| Copy to clipboard | <kbd>⌘C</kbd> | <kbd>Ctrl+C</kbd> |
| Save to file | <kbd>⌘S</kbd> | <kbd>Ctrl+S</kbd> |
| Save as | <kbd>⌘⇧S</kbd> | <kbd>Ctrl+Shift+S</kbd> |
| Print | <kbd>⌘P</kbd> | <kbd>Ctrl+P</kbd> |
| Undo the last annotation | <kbd>⌘Z</kbd> | <kbd>Ctrl+Z</kbd> |
| Redo the last undone annotation | <kbd>⌘⇧Z</kbd> | <kbd>Ctrl+Y</kbd> or <kbd>Ctrl+Shift+Z</kbd> |
| Confirm, copying by default | <kbd>Return</kbd> | <kbd>Enter</kbd> |
| Cancel | <kbd>Esc</kbd> or <kbd>⌘X</kbd> | <kbd>Esc</kbd> or <kbd>Ctrl+X</kbd> |
| Move the selection by one point | Arrow keys | Arrow keys |
| Move the selection by ten points | <kbd>Shift</kbd> + arrow keys | <kbd>Shift</kbd> + arrow keys |

## Privacy

Slightshot saves screenshots and recordings to your computer or copies
screenshots to your clipboard.
It has no screenshot upload service, account system or application telemetry.
On macOS, the app uses Sparkle to check for updates. You can also check manually
in Settings. Windows preview updates are downloaded from Releases.

## macOS scripting

Start a capture from Shortcuts (Open URLs), Alfred, Raycast or a terminal.
These URLs work whether Slightshot is already running or starts with the command:

```bash
open 'slightshot://capture-area'
open 'slightshot://capture-full'
open 'slightshot://copy-full'
```

Only these exact URLs are accepted; paths, query parameters and fragments are
rejected. Commands received while a screenshot or recording session is busy are
ignored, keeping that session intact.

If several Slightshot bundles are installed, macOS chooses a registered bundle
for the URL. Updated copies forward the action to the one active Slightshot
process, without adding another menu item or registering competing hotkeys.
You can select a specific installed bundle with
`open -a '/Applications/Slightshot.app' 'slightshot://capture-area'`.
Quit an older version before switching to an updated copy; versions without the
URL route and ownership protocol cannot forward commands.

The existing `--capture-area`, `--capture-full` and `--copy-full` arguments
continue to work when starting a process, including a duplicate process which
forwards to the active owner. macOS does not deliver new arguments to an already
running process, so use the URLs for commands that must also work on warm starts.

## Build from source

Clone the repository, then run the app with your platform's tools:

```bash
git clone https://github.com/jmpijll/slightshot.git
cd slightshot
```

| Platform | Tools | Run |
| --- | --- | --- |
| macOS | macOS 27 and Xcode 27 command line tools | `make run` |
| Windows | [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) | `dotnet run --project Windows/Slightshot` |

The Mac app uses Swift, AppKit and ScreenCaptureKit; the Windows app uses C#,
WPF, Win32 and the Windows media pipeline. Each platform shares its screenshot
renderer between the editor and exports, and both use the same original toolbar
icons. Windows core checks and cross-building also run on Mac or Linux; native
Windows app checks require Windows.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout and development
checks, [the Windows guide](docs/windows.md#run-and-build) for packaging and
native validation, and [the release guide](docs/RELEASING.md) for publication.

## Further development

Slightshot stays focused on capture, annotation and recording. Further work
should address demonstrated reliability or performance problems. Capture
history, upload providers and selections across displays need clear user demand
before adding more scope.

## License

[MIT](LICENSE). Slightshot is an independent project inspired by Lightshot.
It shares no code with Lightshot and is not affiliated with Skillbrains.

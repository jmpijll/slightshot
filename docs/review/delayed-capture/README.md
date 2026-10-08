# Delayed capture review evidence

The Mac menu bar and Windows tray have **Capture Area in 5 Seconds**. The
fixed countdown leaves the target application's keyboard focus alone and has
an explicit **Cancel** button. At the deadline the normal area editor opens
with freshly captured pixels. Repeating the action restarts one countdown;
ordinary captures cancel it and capture immediately. Existing editors and
recordings reject another request. Quit invalidates the timer and stale queued
callbacks cannot open another editor.

## Windows native acceptance

The Windows CI `--delayed-capture-smoke-test` uses the production tray menu,
countdown controller, native WPF windows, GDI desktop capture and area editor.
The target is a real WPF acceptance window whose content changes from red to
green *after* scheduling. The smoke asserts that the frozen source contains the
later green pixels, that no editor appears before five seconds, that the
nonactivating countdown preserves target focus, that a busy editor rejects a
new timer, and that Cancel and ordinary capture prevent a late second editor.
The countdown is closed and the tray menu is dismissed before desktop
composition is flushed for capture.

The CI artifact `windows-native-delayed-capture-evidence` contains the native
menu/countdown/result screenshots and `delayed-capture-validation.json` with
source revision and checks. Durable copies and the source run will be added
here after the native run completes.

## Mac desktop acceptance

The countdown uses a nonactivating AppKit panel. It closes before capture;
ScreenCaptureKit also excludes Slightshot's own windows. The timer uses a
monotonic five-second deadline and runs while a popup menu is open.

Run the freshly built app bundle, then:

1. Open the Slightshot menu and verify **Capture Area in 5 Seconds** appears
   once, with no additional shortcut or preference.
2. Choose it. Confirm the small countdown and **Cancel** action appear and the
   target app retains keyboard focus. Open a target-app menu or tooltip before
   the deadline; confirm it appears in the frozen area editor afterward.
3. Cancel the editor, start the countdown again, click **Cancel**, and wait
   beyond five seconds. Confirm no editor opens.
4. Start the countdown, choose the delayed action again before it completes,
   and confirm the new five-second countdown produces only one editor.
5. Start a countdown and press the ordinary capture shortcut. Confirm immediate
   capture and no extra editor after five seconds. Repeat with full-screen copy.
6. Try the delayed action while an editor or recording is active; confirm the
   existing session stays in place. Quit during a countdown and confirm no
   callback survives termination.

The deterministic Swift and portable Windows tests exercise queued callbacks
after cancellation, replacement and termination, duplicate deadline delivery,
no capture before five seconds, and a busy owner at scheduling and deadline.

# Unsaved recording protection review

Captured on 20 October 2026 on macOS 27.0.1, Apple silicon, from source commit
`222433591226bc2b77f95258be72e43f55c68041` built as a Developer ID signed
`Slightshot.app` and started with `--lost-work-review`.

The fixture writes a synthetic four-second movie into a real
`ScreenRecordingSession` folder and simulates the ScreenCaptureKit callbacks.
The stream reports `didStopWithError` (user stopped) first, and the recording
output reports that it finished afterwards. Everything after that runs the
production code: the recording coordinator, the playability check, the video
editor, the quit guard and its prompt, and the save panel. Each quit is a real
`NSApplication.terminate` call. The fixture clicks the prompt and panel buttons
automatically. Captures include only Slightshot's own windows.

## Editor opens after a stream error

Before this change, the stream error would have deleted this recording.

![Edit Recording window showing the synthetic recording after a stream error](editor-after-stream-error.png)

## Quit prompt with an unsaved recording

![Save the recording before quitting prompt over the editor](quit-prompt.png)

The automated sequence:

1. Cancel. Slightshot keeps running, and the editor and temporary recording remain.
2. Save…. The existing save panel opens, shown below. The fixture cancels the
   panel, so the quit is cancelled and the editor returns.
3. Discard Recording. The temporary recording is deleted and Slightshot quits.

![Save recording panel opened from the quit prompt](save-panel-from-quit.png)

[validation.json](validation.json) records each step and check.

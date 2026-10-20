# Windows settings recovery and launch at login

Captured by the Windows workflow ([run 39413013096](https://github.com/jmpijll/slightshot/actions/runs/39413013096))
on `windows-latest` from source commit `be0f1a6d6a5ef132efbc541765e4d5176d2b2ad5`.
`SettingsRecoverySmokeTest` writes every fixture: the settings files and the
`HKCU\…\Run\Slightshot` value. It restores the Run value afterwards. No one
interacted with the app by hand.

| File | Shows |
| --- | --- |
| `settings-login-other-copy.png` | Run points at `C:\Users\Example\Downloads\Slightshot.exe`, so the switch is off |
| `settings-login-this-copy.png` | After the switch is turned on, Run points at the running executable and a new Settings window shows it on |
| `settings-recovery-report.png` | Outcomes of the truncated-JSON, invalid-field, single-repair and in-range fixtures, with the notice text shown in the tray |
| `validation.json` | The two native check lines from that run's `validation.json` |

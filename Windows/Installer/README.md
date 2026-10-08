# Installer assets

`Slightshot.iss` packages the existing self-contained, single-file Windows app.
Compile it through `Scripts/build_windows_installer.ps1`; its parameters validate
the app's version and native architecture before invoking Inno Setup.

The wizard uses Inno Setup's native controls with its modern Windows 11 light/dark
appearance. The PNG artwork reuses the 256 px image embedded in
`Windows/Slightshot/Assets/Slightshot.ico`, on matching light/dark green panels.
It is branding artwork, not a screenshot of the installer.

`Scripts/test_windows_installer.ps1` runs only on an isolated Windows CI runner.
It records actual light/dark welcome window screenshots and exercises installation, a real
version upgrade, downgrade refusal, running-app protection and uninstall. Its
previous-version installer must bundle an app with that earlier version; CI
publishes the same source as version `0.0.0` solely for this upgrade fixture.

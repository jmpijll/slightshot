#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][string]$PreviousInstallerPath,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:CI -ne 'true') {
    throw 'Installer lifecycle checks may only run on an isolated Windows CI runner.'
}
$installer = (Resolve-Path -LiteralPath $InstallerPath).Path
$previousInstaller = (Resolve-Path -LiteralPath $PreviousInstallerPath).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$installDirectory = Join-Path $env:LOCALAPPDATA ("Programs/Slightshot Installer CI " + [Guid]::NewGuid().ToString('N'))
$installedApp = Join-Path $installDirectory 'Slightshot.exe'
$uninstaller = Join-Path $installDirectory 'unins000.exe'
$settingsDirectory = Join-Path $env:LOCALAPPDATA 'Slightshot'
$settingsPath = Join-Path $settingsDirectory 'settings.json'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Slightshot.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Slightshot.lnk'
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{5740D31D-5083-4F95-8BD7-0F7669D86D77}_is1'
$runKey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
$checks = [Collections.Generic.List[string]]::new()
$normalApp = $null
$ownsFixtures = $false
$status = 'failed'
$failure = $null

function Require([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
    $checks.Add($Message)
    Write-Output "Passed: $Message"
}

function Read-RegistryValue([string]$Key, [string]$Name) {
    $handle = $registry.OpenSubKey($Key)
    if ($null -eq $handle) { return $null }
    try { return $handle.GetValue($Name, $null) } finally { $handle.Dispose() }
}

function Write-RunValue([string]$Command) {
    $handle = $registry.CreateSubKey($runKey)
    try { $handle.SetValue('Slightshot', $Command, [Microsoft.Win32.RegistryValueKind]::String) } finally { $handle.Dispose() }
}

function Remove-FixtureRunValue {
    $handle = $registry.OpenSubKey($runKey, $true)
    if ($null -ne $handle) { try { $handle.DeleteValue('Slightshot', $false) } finally { $handle.Dispose() } }
}

function Run-Setup([string]$Path, [string]$LogName, [string[]]$ExtraArguments = @(), [bool]$ExpectSuccess = $true) {
    $logPath = Join-Path $output "$LogName.log"
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="{0}"' -f $logPath)) + $ExtraArguments
    $process = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
    if (!$process.WaitForExit(120000)) {
        & taskkill.exe /PID $process.Id /T /F | Out-Null
        throw "Setup timed out: $LogName. See $logPath."
    }
    if (($ExpectSuccess -and $process.ExitCode -ne 0) -or (!$ExpectSuccess -and $process.ExitCode -eq 0)) {
        throw "Unexpected setup exit code $($process.ExitCode): $LogName. See $logPath."
    }
    Write-Output "$LogName exit code: $($process.ExitCode)"
}

function Wait-ForFileRemoval([string]$Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ((Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
    Require (!(Test-Path -LiteralPath $Path)) "Uninstall removed $([IO.Path]::GetFileName($Path))."
}

function Has-AppMutex {
    try { $mutex = [Threading.Mutex]::OpenExisting('Local\Slightshot'); $mutex.Dispose(); return $true }
    catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
}

function Assert-Shortcut([string]$Path) {
    Require (Test-Path -LiteralPath $Path -PathType Leaf) "Created shortcut $([IO.Path]::GetFileName($Path))."
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        try { Require ($shortcut.TargetPath -eq $installedApp) 'Shortcut targets the installed executable, including spaces.' }
        finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) | Out-Null }
    } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null }
}

function Run-InstalledSmoke([string]$Argument, [string]$Directory, [string]$Report) {
    $directoryPath = Join-Path $output $Directory
    $process = Start-Process -FilePath $installedApp -ArgumentList $Argument, ('"{0}"' -f $directoryPath) -PassThru
    if (!$process.WaitForExit(180000)) { $process.Kill(); throw "Installed app $Argument timed out." }
    Require ($process.ExitCode -eq 0) "Installed app passed $Argument from a path containing spaces."
    Require (Test-Path -LiteralPath (Join-Path $directoryPath $Report)) "Installed app wrote $Report."
}

# This captures real wizard HWNDs from the CI desktop, never a user's screen.
# The wizard is closed before installation begins.
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class InstallerWizardNative {
    public struct Rect { public int Left, Top, Right, Bottom; }
    public delegate bool EnumCallback(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumCallback callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr dc, uint flags);
    public static IntPtr FindWizard() {
        IntPtr result = IntPtr.Zero;
        EnumWindows((hwnd, data) => {
            var title = new StringBuilder(512); GetWindowText(hwnd, title, title.Capacity);
            var name = new StringBuilder(128); GetClassName(hwnd, name, name.Capacity);
            if (IsWindowVisible(hwnd) && title.ToString().Contains("Slightshot") && name.ToString() == "TWizardForm") {
                result = hwnd; return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

}
'@

function Capture-WizardWindow([IntPtr]$Window, [string]$Name) {
    $rect = New-Object InstallerWizardNative+Rect
    if (![InstallerWizardNative]::GetWindowRect($Window, [ref]$rect)) { throw 'Could not read wizard bounds.' }
    $bitmap = [Drawing.Bitmap]::new($rect.Right - $rect.Left, $rect.Bottom - $rect.Top)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try { $rendered = [InstallerWizardNative]::PrintWindow($Window, $dc, 2) }
        finally { $graphics.ReleaseHdc($dc) }
        if (!$rendered) { throw 'Could not render the actual wizard window.' }
        $bitmap.Save((Join-Path $output "$Name.png"), [Drawing.Imaging.ImageFormat]::Png)
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function Capture-Wizard([string]$Theme) {
    $themeKey = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $handle = $registry.CreateSubKey($themeKey)
    $originalValue = $handle.GetValue('AppsUseLightTheme', $null)
    $process = $null
    try {
        $light = if ($Theme -eq 'light') { 1 } else { 0 }
        $handle.SetValue('AppsUseLightTheme', $light, [Microsoft.Win32.RegistryValueKind]::DWord)
        $process = Start-Process -FilePath $installer -ArgumentList '/SP-', '/NORESTART' -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do { $window = [InstallerWizardNative]::FindWizard(); if ($window -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 200 } }
        while ($window -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
        if ($window -eq [IntPtr]::Zero) { throw 'The actual installer wizard did not appear.' }
        Start-Sleep -Milliseconds 500
        Capture-WizardWindow $window "wizard-$Theme-welcome"
        $checks.Add("Captured the actual $Theme wizard welcome page; installation was not started.")
    } finally {
        # This wizard belongs to the fixture and has not installed or launched anything.
        if ($null -ne $process -and !$process.HasExited) { & taskkill.exe /PID $process.Id /T /F | Out-Null }
        if ($null -ne $process) { $process.Dispose() }
        if ($null -eq $originalValue) { $handle.DeleteValue('AppsUseLightTheme', $false) }
        else { $handle.SetValue('AppsUseLightTheme', $originalValue, [Microsoft.Win32.RegistryValueKind]::DWord) }
        $handle.Dispose()
    }
}

try {
    # Refuse to overwrite anyone's existing settings, portable startup choice,
    # installation or shortcuts, even when mistakenly run on a persistent CI host.
    Require (!(Test-Path -LiteralPath $settingsDirectory)) 'CI runner has no pre-existing Slightshot settings.'
    Require ($null -eq (Read-RegistryValue $runKey 'Slightshot')) 'CI runner has no pre-existing Slightshot startup entry.'
    Require ($null -eq (Read-RegistryValue $uninstallKey 'DisplayVersion')) 'CI runner has no pre-existing Slightshot installation.'
    Require (!(Test-Path -LiteralPath $startMenuShortcut) -and !(Test-Path -LiteralPath $desktopShortcut)) 'CI runner has no pre-existing Slightshot shortcuts.'
    Require (!(Has-AppMutex)) 'CI runner has no running Slightshot instance.'
    $previousVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($previousInstaller).FileVersion
    Require ([version]$previousVersion -lt [version]$Version) 'Upgrade fixture has an actual earlier installer version.'
    Capture-Wizard 'light'
    Capture-Wizard 'dark'
    $ownsFixtures = $true
    $destination = '/DIR="{0}"' -f $installDirectory
    Run-Setup $previousInstaller 'install-previous' @($destination)
    Require (([Diagnostics.FileVersionInfo]::GetVersionInfo($installedApp).FileVersion) -eq $previousVersion) 'Installed previous payload has its actual earlier file version.'
    Assert-Shortcut $startMenuShortcut
    Require (!(Test-Path -LiteralPath $desktopShortcut)) 'Desktop shortcut is disabled by default.'
    Require ($null -eq (Read-RegistryValue $runKey 'Slightshot')) 'Installation does not enable launch at login.'
    Require ($null -ne (Read-RegistryValue $uninstallKey 'UninstallString')) 'Per-user Windows uninstall registration exists.'

    New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null
    $captureDirectory = Join-Path $output 'saved capture fixtures'
    New-Item -ItemType Directory -Path $captureDirectory -Force | Out-Null
    $capture = Join-Path $captureDirectory 'Capture retained.txt'
    [IO.File]::WriteAllText($capture, 'An existing user capture must remain untouched.')
    $fixture = @{ SaveDirectory = $captureDirectory; FilenameTemplate = 'Installer retained fixture'; AnnotationColor = '#0A84FF'; CopyAfterSave = $true; PlaySound = $false } | ConvertTo-Json
    [IO.File]::WriteAllText($settingsPath, $fixture)
    $settingsHash = (Get-FileHash -LiteralPath $settingsPath).Hash
    $captureHash = (Get-FileHash -LiteralPath $capture).Hash
    $ownRun = '"{0}"' -f $installedApp
    Write-RunValue $ownRun

    # Omit /DIR on upgrade to test reuse of the recorded install directory.
    Run-Setup $installer 'upgrade-current' @('/MERGETASKS=desktopicon')
    Require (([Diagnostics.FileVersionInfo]::GetVersionInfo($installedApp).ProductVersion.Split('+')[0]) -eq $Version) 'Upgrade installed the requested current app version.'
    Require ((Read-RegistryValue $uninstallKey 'DisplayVersion') -eq $Version) 'Upgrade retained one per-user uninstall registration with the current version.'
    Require ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $settingsHash) 'Version upgrade preserved user settings byte for byte.'
    Require ((Get-FileHash -LiteralPath $capture).Hash -eq $captureHash) 'Version upgrade preserved saved captures byte for byte.'
    Require ((Read-RegistryValue $runKey 'Slightshot') -eq $ownRun) 'Version upgrade preserved the existing installed-app launch-at-login choice.'
    Assert-Shortcut $startMenuShortcut
    Assert-Shortcut $desktopShortcut
    Run-InstalledSmoke '--smoke-test' 'installed-parity' 'validation.json'
    Run-InstalledSmoke '--recording-smoke-test' 'installed-recording' 'recording-validation.json'
    $currentHash = (Get-FileHash -LiteralPath $installedApp).Hash
    Run-Setup $previousInstaller 'downgrade-blocked' @($destination) $false
    Require ((Get-FileHash -LiteralPath $installedApp).Hash -eq $currentHash) 'Downgrade was refused without replacing the installed executable.'
    Require ((Read-RegistryValue $uninstallKey 'DisplayVersion') -eq $Version) 'Downgrade did not change the uninstall version.'
    Run-Setup $installer 'repair-current' @($destination)
    Require ((Get-FileHash -LiteralPath $installedApp).Hash -eq $currentHash) 'Same-version repair retained the current executable.'
    Require ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $settingsHash) 'Same-version repair preserved user settings byte for byte.'
    Require ((Read-RegistryValue $runKey 'Slightshot') -eq $ownRun) 'Same-version repair preserved the launch-at-login choice.'
    Assert-Shortcut $startMenuShortcut
    Assert-Shortcut $desktopShortcut

    $normalApp = Start-Process -FilePath $installedApp -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (!(Has-AppMutex) -and !$normalApp.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Require (!$normalApp.HasExited -and (Has-AppMutex)) 'Normal installed app creates the real Local\Slightshot mutex.'
    Run-Setup $installer 'running-install-blocked' @($destination) $false
    Require (!$normalApp.HasExited -and (Get-FileHash -LiteralPath $installedApp).Hash -eq $currentHash) 'Installer refused while the app was running and left its process and executable intact.'
    Run-Setup $uninstaller 'running-uninstall-blocked' @() $false
    Require (!$normalApp.HasExited -and (Test-Path -LiteralPath $installedApp)) 'Uninstaller refused while the app was running and left its process and installation intact.'
    # The harness owns this idle synthetic app; no screenshot or recording was started.
    $normalApp.Kill(); $normalApp.WaitForExit(); $normalApp.Dispose(); $normalApp = $null
    [IO.File]::WriteAllText($settingsPath, $fixture)

    $foreignRun = '"{0}"' -f (Join-Path $output 'portable Slightshot/Slightshot.exe')
    Write-RunValue $foreignRun
    Run-Setup $uninstaller 'uninstall-foreign-startup'
    Wait-ForFileRemoval $installedApp
    Wait-ForFileRemoval $uninstaller
    Require ((Read-RegistryValue $runKey 'Slightshot') -eq $foreignRun) 'Uninstall preserved a startup entry targeting another portable copy.'
    Require ($null -eq (Read-RegistryValue $uninstallKey 'DisplayVersion')) 'Uninstall removed its per-user Windows uninstall registration.'
    Require (!(Test-Path -LiteralPath $startMenuShortcut) -and !(Test-Path -LiteralPath $desktopShortcut)) 'Uninstall removed its Start menu and optional desktop shortcuts.'
    Require ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $settingsHash -and (Get-FileHash -LiteralPath $capture).Hash -eq $captureHash) 'Uninstall preserved user settings and saved captures.'

    # Reinstall while a portable Run entry exists: do not repoint or enroll it.
    Run-Setup $installer 'reinstall-foreign-startup' @($destination, '/MERGETASKS=desktopicon')
    Require ((Read-RegistryValue $runKey 'Slightshot') -eq $foreignRun) 'Reinstallation preserved another portable copy''s startup entry.'
    Write-RunValue $ownRun
    Run-Setup $uninstaller 'uninstall-own-startup'
    Wait-ForFileRemoval $installedApp
    Wait-ForFileRemoval $uninstaller
    Require ($null -eq (Read-RegistryValue $runKey 'Slightshot')) 'Uninstall removed only its own installed-app startup entry.'
    Require (!(Test-Path -LiteralPath $startMenuShortcut) -and !(Test-Path -LiteralPath $desktopShortcut)) 'Final uninstall removed both shortcuts.'
    Require ((Get-FileHash -LiteralPath $settingsPath).Hash -eq $settingsHash -and (Get-FileHash -LiteralPath $capture).Hash -eq $captureHash) 'Reinstall and final uninstall retained settings and captures.'
    $status = 'passed'
} catch {
    $failure = $_.ToString() + "`n" + $_.ScriptStackTrace
    [IO.File]::WriteAllText((Join-Path $output 'installer-failure.txt'), $failure)
    throw
} finally {
    if ($null -ne $normalApp) {
        if (!$normalApp.HasExited) { $normalApp.Kill(); $normalApp.WaitForExit() }
        $normalApp.Dispose()
    }
    if ($ownsFixtures) {
        if (Test-Path -LiteralPath $uninstaller) {
            try { Run-Setup $uninstaller 'cleanup-uninstall' } catch { Write-Warning "Fixture cleanup failed: $_" }
        }
        Remove-FixtureRunValue
        if (Test-Path -LiteralPath $settingsDirectory) { Remove-Item -LiteralPath $settingsDirectory -Recurse -Force }
        if (Test-Path -LiteralPath $installDirectory) { Remove-Item -LiteralPath $installDirectory -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $registry.Dispose()
    $report = [ordered]@{
        status = $status
        platform = 'Windows x64 native installer lifecycle'
        version = $Version
        installer_sha256 = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
        previous_installer_version = [Diagnostics.FileVersionInfo]::GetVersionInfo($previousInstaller).FileVersion
        source = 'Actual compiled installer windows and installed executable on an isolated CI runner; no live screenshot or recording capture.'
        checks = @($checks.ToArray())
        failure = $failure
    }
    [IO.File]::WriteAllText((Join-Path $output 'installer-validation.json'), ($report | ConvertTo-Json -Depth 8))
}

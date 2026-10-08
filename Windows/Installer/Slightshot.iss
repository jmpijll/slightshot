; Compile through Scripts/build_windows_installer.ps1, which validates the payload.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppArchitecture
  #error AppArchitecture is required
#endif
#ifndef PublishDirectory
  #error PublishDirectory is required
#endif
#ifndef InstallerOutputDirectory
  #error InstallerOutputDirectory is required
#endif

#if AppArchitecture == "arm64"
  #define AllowedArchitecture "arm64"
#elif AppArchitecture == "x64"
  #define AllowedArchitecture "x64compatible and not arm64"
#else
  #error AppArchitecture must be x64 or arm64
#endif

[Setup]
; Keep this ID identical across releases and architectures so upgrades replace
; the same per-user installation and Windows shows one uninstall entry.
AppId={{5740D31D-5083-4F95-8BD7-0F7669D86D77}
AppName=Slightshot
AppVersion={#AppVersion}
AppVerName=Slightshot {#AppVersion}
AppPublisher=Jamie van der Pijll
AppPublisherURL=https://github.com/jmpijll/slightshot
AppSupportURL=https://github.com/jmpijll/slightshot/issues
AppUpdatesURL=https://github.com/jmpijll/slightshot/releases/latest
DefaultDirName={localappdata}\Programs\Slightshot
DefaultGroupName=Slightshot
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableWelcomePage=no
DisableReadyPage=no
PrivilegesRequired=lowest
ArchitecturesAllowed={#AllowedArchitecture}
ArchitecturesInstallIn64BitMode={#AllowedArchitecture}
; An x86 bootstrapper also runs on ARM64; its bundled app is native ARM64.
SetupArchitecture=x86
MinVersion=10.0.19041
OutputDir={#InstallerOutputDirectory}
OutputBaseFilename=Slightshot-windows-{#AppArchitecture}-setup
VersionInfoVersion={#AppVersion}.0
VersionInfoDescription=Slightshot installer
SetupIconFile=..\Slightshot\Assets\Slightshot.ico
UninstallDisplayIcon={app}\Slightshot.exe
LicenseFile=..\..\LICENSE
WizardStyle=modern dynamic windows11
WizardSmallImageFile=wizard-logo.png
WizardSmallImageFileDynamicDark=wizard-logo.png
WizardImageFile=wizard-light.png
WizardImageFileDynamicDark=wizard-dark.png
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
AppMutex=Local\Slightshot
SetupMutex=Local\SlightshotInstaller
UninstallDisplayName=Slightshot
UsePreviousAppDir=yes
UsePreviousTasks=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "{#PublishDirectory}\Slightshot.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Slightshot"; Filename: "{app}\Slightshot.exe"; WorkingDir: "{app}"
Name: "{userdesktop}\Slightshot"; Filename: "{app}\Slightshot.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Slightshot.exe"; Description: "Launch Slightshot"; Flags: nowait postinstall skipifsilent

[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{5740D31D-5083-4F95-8BD7-0F7669D86D77}_is1';
var
  PreviousAppDirectory: String;
  PreserveLaunchAtLogin: Boolean;

function RunEntryMatches(const AppDirectory: String): Boolean;
var
  Command: String;
begin
  Result := (AppDirectory <> '') and
    RegQueryStringValue(HKCU, RunKey, 'Slightshot', Command);
  if Result then
    { The app writes a quoted executable path, without arguments. Do not alter
      a portable installation's entry or a different command with arguments. }
    Result := CompareText(RemoveQuotes(Trim(Command)),
      AddBackslash(AppDirectory) + 'Slightshot.exe') = 0;
end;

function NewerVersion(const Version: Int64): Boolean;
var
  RequestedVersion: Int64;
begin
  Result := StrToVersion('{#AppVersion}', RequestedVersion) and
    (ComparePackedVersion(Version, RequestedVersion) > 0);
end;

function InitializeSetup: Boolean;
var
  InstalledVersion: String;
  PackedVersion: Int64;
begin
  Result := False;
  if CheckForMutexes('Local\Slightshot') then begin
    Log('Slightshot is running; installation stopped without closing it.');
    SuppressibleMsgBox('Quit Slightshot from its tray menu before installing. ' +
      'Finish or save any capture first, then run this installer again.',
      mbInformation, MB_OK, IDOK);
    Exit;
  end;
  if RegQueryStringValue(HKCU64, UninstallKey, 'DisplayVersion', InstalledVersion) and
    StrToVersion(InstalledVersion, PackedVersion) and NewerVersion(PackedVersion) then begin
    Log('Downgrade blocked: installed version ' + InstalledVersion);
    SuppressibleMsgBox('A newer version of Slightshot is already installed. ' +
      'Download the latest installer from GitHub releases.',
      mbInformation, MB_OK, IDOK);
    Exit;
  end;
  RegQueryStringValue(HKCU64, UninstallKey, 'Inno Setup: App Path', PreviousAppDirectory);
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  InstalledVersion: Int64;
begin
  Result := '';
  { The application may have been opened since the wizard started. Never let
    Restart Manager close a screenshot editor or a live recording. }
  if CheckForMutexes('Local\Slightshot') then begin
    Result := 'Quit Slightshot from its tray menu before installing. ' +
      'Finish or save your capture, then try again.';
    Exit;
  end;
  if GetPackedVersion(ExpandConstant('{app}\Slightshot.exe'), InstalledVersion) and
    NewerVersion(InstalledVersion) then begin
    Result := 'A newer version of Slightshot is already installed in this folder.';
    Exit;
  end;
  PreserveLaunchAtLogin := RunEntryMatches(PreviousAppDirectory) or
    RunEntryMatches(ExpandConstant('{app}'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and PreserveLaunchAtLogin then
    if not RegWriteStringValue(HKCU, RunKey, 'Slightshot',
      AddQuotes(ExpandConstant('{app}\Slightshot.exe'))) then
      Log('Could not update the existing launch-at-login registration.');
end;

function InitializeUninstall: Boolean;
begin
  Result := not CheckForMutexes('Local\Slightshot');
  if not Result then begin
    Log('Slightshot is running; uninstall stopped without closing it.');
    SuppressibleMsgBox('Quit Slightshot from its tray menu before uninstalling. ' +
      'Finish or save any capture first, then try again.',
      mbInformation, MB_OK, IDOK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and RunEntryMatches(ExpandConstant('{app}')) then
    if not RegDeleteValue(HKCU, RunKey, 'Slightshot') then
      Log('Could not remove this installation''s launch-at-login registration.');
  { Settings live in LocalAppData\Slightshot and captures may live anywhere.
    Neither belongs to the installation, so the uninstaller never removes them. }
end;

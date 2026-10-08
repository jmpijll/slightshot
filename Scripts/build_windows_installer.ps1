#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-arm64')][string]$Runtime,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$PublishDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$CompilerPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'The Windows installer must be compiled on Windows.' }
$publish = (Resolve-Path -LiteralPath $PublishDirectory).Path
$compiler = (Resolve-Path -LiteralPath $CompilerPath).Path
$app = Join-Path $publish 'Slightshot.exe'
if (!(Test-Path -LiteralPath $app -PathType Leaf)) { throw "Missing published app: $app" }
$entries = @(Get-ChildItem -LiteralPath $publish -Force)
if ($entries.Count -ne 1 -or $entries[0].Name -ne 'Slightshot.exe' -or $entries[0].PSIsContainer) {
    throw 'Installer payload must contain only the self-contained single-file Slightshot.exe. Publish with the Portable profile first.'
}
$actualVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($app).ProductVersion.Split('+')[0]
if ($actualVersion -ne $Version) { throw "Payload version $actualVersion does not match installer version $Version." }

# Validate the embedded PE machine, not the directory name or requested runtime.
$stream = [IO.File]::OpenRead($app)
$reader = [IO.BinaryReader]::new($stream)
try {
    if ($reader.ReadUInt16() -ne 0x5A4D) { throw 'Published app is not a PE executable.' }
    $stream.Position = 0x3C
    $offset = $reader.ReadUInt32()
    if ($offset -gt $stream.Length - 6) { throw 'Published app has an invalid PE header.' }
    $stream.Position = $offset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Published app has an invalid PE signature.' }
    $machine = $reader.ReadUInt16()
} finally { $reader.Dispose(); $stream.Dispose() }
$expectedMachine = if ($Runtime -eq 'win-x64') { 0x8664 } else { 0xAA64 }
if ($machine -ne $expectedMachine) { throw ('Wrong payload architecture: 0x{0:X4} for {1}.' -f $machine, $Runtime) }

$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$architecture = $Runtime.Substring('win-'.Length)
$setup = Join-Path $output "Slightshot-windows-$architecture-setup.exe"
if (Test-Path -LiteralPath $setup) { Remove-Item -LiteralPath $setup }
$script = Join-Path $PSScriptRoot '../Windows/Installer/Slightshot.iss'
& $compiler '/Qp' "/DAppVersion=$Version" "/DAppArchitecture=$architecture" "/DPublishDirectory=$publish" "/DInstallerOutputDirectory=$output" $script
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE." }
if (!(Test-Path -LiteralPath $setup -PathType Leaf)) { throw 'Compiler did not create the expected setup executable.' }
$setupInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($setup)
$setupVersion = [version]::new($setupInfo.FileMajorPart, $setupInfo.FileMinorPart, $setupInfo.FileBuildPart, $setupInfo.FilePrivatePart)
if ($setupVersion -ne [version]"$Version.0") { throw "Wrong setup file version: $setupVersion" }
Write-Output "Installer: $setup"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant())"

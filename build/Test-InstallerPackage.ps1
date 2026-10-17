#requires -Version 5.1
<#
.SYNOPSIS
Checks installer packaging without starting the installer or changing NVIDIA settings.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '1.1.0',
    [string]$OutputDirectory
)

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $inboxPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $forwardArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Version', $Version)
    if ($OutputDirectory) { $forwardArguments += @('-OutputDirectory', $OutputDirectory) }
    & $inboxPowerShell @forwardArguments
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $sourceRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$executableName = 'Alexandres-WatchDogs2-Shadow-Flicker-Setup.exe'
$executable = Join-Path $OutputDirectory $executableName
$archive = Join-Path $OutputDirectory ('Alexandres-WatchDogs2-Shadow-Flicker-v' + $Version + '-win-x64.zip')
$script:checkCount = 0

function Assert-Package([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw "Package validation failed: $Description" }
    $script:checkCount++
    Write-Host ('PASS ' + $Description)
}

function Get-BytesHash([byte[]]$Bytes) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha256.ComputeHash($Bytes)).Replace('-', '') }
    finally { $sha256.Dispose() }
}

function Read-StreamBytes([IO.Stream]$Stream) {
    $buffer = [IO.MemoryStream]::new()
    try {
        $Stream.CopyTo($buffer)
        return ,$buffer.ToArray()
    } finally { $buffer.Dispose() }
}

Assert-Package ([Environment]::Is64BitProcess) 'validation is running in 64-bit Windows PowerShell'
Assert-Package (Test-Path -LiteralPath $executable -PathType Leaf) 'standalone executable exists'
Assert-Package (Test-Path -LiteralPath $archive -PathType Leaf) 'versioned ZIP exists'

$executableBytes = [IO.File]::ReadAllBytes($executable)
$assembly = [Reflection.Assembly]::Load($executableBytes)
Assert-Package ($assembly.GetName().Version.ToString() -eq ($Version + '.0')) 'managed assembly version matches the release'
Assert-Package ([Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion -eq ($Version + '.0')) 'Windows file version matches the release'
$peKind = [Reflection.PortableExecutableKinds]::NotAPortableExecutableImage
$imageMachine = [Reflection.ImageFileMachine]::I386
$assembly.ManifestModule.GetPEKind([ref]$peKind, [ref]$imageMachine)
Assert-Package ($imageMachine -eq [Reflection.ImageFileMachine]::AMD64) 'executable targets Windows x64'
Assert-Package (($peKind -band [Reflection.PortableExecutableKinds]::ILOnly) -ne 0) 'managed executable contains IL only'

$resourceNames = @($assembly.GetManifestResourceNames())
foreach ($resource in @(
    @{ Name = 'WatchDogs2FlickerFix.backend.ps1'; Source = (Join-Path $sourceRoot 'WatchDogs2-FlickerFix.ps1') },
    @{ Name = 'WatchDogs2FlickerFix.logo.png'; Source = (Join-Path $sourceRoot 'assets\logo.png') }
)) {
    Assert-Package ($resourceNames -contains $resource.Name) ('embedded resource exists: ' + $resource.Name)
    $resourceStream = $assembly.GetManifestResourceStream($resource.Name)
    try { $resourceBytes = Read-StreamBytes $resourceStream }
    finally { $resourceStream.Dispose() }
    $expectedHash = (Get-FileHash -LiteralPath $resource.Source -Algorithm SHA256).Hash
    Assert-Package ((Get-BytesHash $resourceBytes) -eq $expectedHash) ('embedded resource matches current source: ' + $resource.Name)
}

$backend = Join-Path $sourceRoot 'WatchDogs2-FlickerFix.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($backend, [ref]$tokens, [ref]$parseErrors)
Assert-Package ($parseErrors.Count -eq 0) 'embedded backend source parses in Windows PowerShell 5.1'
$parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($parameterName in @('Action', 'ProgressFile', 'CancellationFile')) {
    Assert-Package ($parameterNames -contains $parameterName) ('backend exposes ' + $parameterName)
}

if (-not ('Wd2InstallerPackage.NativeResources' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace Wd2InstallerPackage {
    public static class NativeResources {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryExW(string path, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LockResource(IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeLibrary(IntPtr module);
    }
}
"@
}
# LOAD_LIBRARY_AS_DATAFILE reads PE resources without executing application code.
$module = [Wd2InstallerPackage.NativeResources]::LoadLibraryExW($executable, [IntPtr]::Zero, 2)
Assert-Package ($module -ne [IntPtr]::Zero) 'PE resources can be read without launching the installer'
try {
    $manifestHandle = [Wd2InstallerPackage.NativeResources]::FindResourceW($module, [IntPtr]1, [IntPtr]24)
    Assert-Package ($manifestHandle -ne [IntPtr]::Zero) 'Windows application manifest is embedded'
    $manifestLength = [Wd2InstallerPackage.NativeResources]::SizeofResource($module, $manifestHandle)
    $loadedManifest = [Wd2InstallerPackage.NativeResources]::LoadResource($module, $manifestHandle)
    $manifestPointer = [Wd2InstallerPackage.NativeResources]::LockResource($loadedManifest)
    Assert-Package ($manifestLength -gt 0 -and $manifestPointer -ne [IntPtr]::Zero) 'embedded manifest can be read'
    $manifestBytes = New-Object byte[] $manifestLength
    [Runtime.InteropServices.Marshal]::Copy($manifestPointer, $manifestBytes, 0, [int]$manifestLength)
    [xml]$manifest = [Text.Encoding]::UTF8.GetString($manifestBytes).TrimStart([char]0xFEFF).TrimEnd([char]0)
    $requestedLevel = $manifest.SelectSingleNode('//*[local-name()="requestedExecutionLevel"]')
    Assert-Package ($null -ne $requestedLevel -and $requestedLevel.GetAttribute('level') -eq 'requireAdministrator') 'manifest requests administrator access'
    $supportedWindows = @($manifest.SelectNodes('//*[local-name()="supportedOS"]') | ForEach-Object { $_.GetAttribute('Id') })
    Assert-Package ($supportedWindows -contains '{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}') 'manifest declares Windows 10 and 11 compatibility'
    $iconHandle = [Wd2InstallerPackage.NativeResources]::FindResourceW($module, [IntPtr]32512, [IntPtr]14)
    if ($iconHandle -eq [IntPtr]::Zero) { $iconHandle = [Wd2InstallerPackage.NativeResources]::FindResourceW($module, [IntPtr]1, [IntPtr]14) }
    Assert-Package ($iconHandle -ne [IntPtr]::Zero) 'Windows executable icon is embedded'
} finally { [void][Wd2InstallerPackage.NativeResources]::FreeLibrary($module) }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $expectedEntries = @($executableName, 'README.txt', 'SHA256SUMS.txt')
    $actualEntries = @($zip.Entries | ForEach-Object FullName)
    Assert-Package ($actualEntries.Count -eq 3 -and @($actualEntries | Where-Object { $expectedEntries -notcontains $_ }).Count -eq 0) 'ZIP contains exactly the EXE, README, and checksum file'
    $zipContents = @{}
    foreach ($entry in $zip.Entries) {
        Assert-Package ($entry.Length -gt 0 -and $entry.Length -lt 20MB) ('ZIP entry has a reasonable size: ' + $entry.FullName)
        $entryStream = $entry.Open()
        try { $zipContents[$entry.FullName] = Read-StreamBytes $entryStream }
        finally { $entryStream.Dispose() }
    }
    Assert-Package ((Get-BytesHash $zipContents[$executableName]) -eq (Get-BytesHash $executableBytes)) 'ZIP executable matches the validated standalone executable'
    $checksumText = [Text.Encoding]::UTF8.GetString($zipContents['SHA256SUMS.txt'])
    $checksumLines = @($checksumText -split '\r?\n' | Where-Object { $_.Trim() })
    Assert-Package ($checksumLines.Count -eq 2) 'checksum file contains EXE and README digests'
    $verifiedNames = @()
    foreach ($line in $checksumLines) {
        $match = [regex]::Match($line, '^([0-9A-Fa-f]{64}) \*(.+)$')
        Assert-Package ($match.Success) 'checksum line uses the expected SHA256 format'
        $name = $match.Groups[2].Value
        Assert-Package (@($executableName, 'README.txt') -contains $name -and $verifiedNames -notcontains $name) ('checksum filename is expected and unique: ' + $name)
        Assert-Package ((Get-BytesHash $zipContents[$name]) -eq $match.Groups[1].Value.ToUpperInvariant()) ('ZIP payload checksum matches: ' + $name)
        $verifiedNames += $name
    }
    $readmeText = [Text.Encoding]::UTF8.GetString($zipContents['README.txt'])
    Assert-Package ($readmeText.Contains('Continue') -and $readmeText.Contains('Cancel') -and $readmeText.Contains('unsigned')) 'packaged instructions cover the wizard and unsigned executable'
    Assert-Package (@($actualEntries | Where-Object { $_ -like '*nvidiaProfileInspector*' }).Count -eq 0) 'third-party NVIDIA Profile Inspector executable is not redistributed'
} finally { $zip.Dispose() }

Write-Host ("Installer package validation passed: $script:checkCount checks. No installer or driver operation was executed.")

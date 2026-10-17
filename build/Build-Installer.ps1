#requires -Version 5.1
<#
.SYNOPSIS
Builds and packages the Windows x64 installer using the inbox .NET Framework compiler.
.DESCRIPTION
Run on 64-bit Windows with .NET Framework 4.8 reference assemblies installed.
No external NuGet packages, downloaded compilers, or signing credentials are required.
The resulting executable is unsigned. This script does not run the installer.
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
if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
    throw 'Build using 64-bit Windows PowerShell on 64-bit Windows.'
}

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$referenceDirectory = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8'
$source = Join-Path $sourceRoot 'installer\Program.cs'
$manifest = Join-Path $sourceRoot 'installer\app.manifest'
$icon = Join-Path $sourceRoot 'assets\app.ico'
$logo = Join-Path $sourceRoot 'assets\logo.png'
$backend = Join-Path $sourceRoot 'WatchDogs2-FlickerFix.ps1'
$packageValidator = Join-Path $PSScriptRoot 'Test-InstallerPackage.ps1'
foreach ($requiredFile in @($compiler, $source, $manifest, $icon, $logo, $backend, $packageValidator)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required build input is missing: $requiredFile" }
}
if (-not (Test-Path -LiteralPath $referenceDirectory -PathType Container)) {
    throw '.NET Framework 4.8 reference assemblies are required. Install the .NET Framework 4.8 Developer Pack on the build computer; users do not need the Developer Pack.'
}

$tokens = $null
$parseErrors = $null
$backendAst = [Management.Automation.Language.Parser]::ParseFile($backend, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ('Backend PowerShell syntax failed: ' + (($parseErrors | ForEach-Object Message) -join '; ')) }
$parameterNames = @($backendAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($requiredParameter in @('Action', 'ProgressFile', 'CancellationFile')) {
    if ($parameterNames -notcontains $requiredParameter) { throw "Backend installer integration parameter is missing: $requiredParameter" }
}

$assemblyVersion = $Version + '.0'
if ((Get-Content -LiteralPath $source -Raw) -notmatch ('AssemblyVersion\s*\(\s*"' + [regex]::Escape($assemblyVersion) + '"\s*\)')) {
    throw "Program.cs AssemblyVersion must match the requested release version: $assemblyVersion"
}
[xml]$manifestDocument = Get-Content -LiteralPath $manifest -Raw
$requestedLevel = $manifestDocument.SelectSingleNode('//*[local-name()="requestedExecutionLevel"]')
if ($null -eq $requestedLevel -or $requestedLevel.GetAttribute('level') -ne 'requireAdministrator') {
    throw 'Installer manifest must declare requireAdministrator.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$executableName = 'Alexandres-WatchDogs2-Shadow-Flicker-Setup.exe'
$executable = Join-Path $OutputDirectory $executableName
$archiveName = 'Alexandres-WatchDogs2-Shadow-Flicker-v' + $Version + '-win-x64.zip'
$archive = Join-Path $OutputDirectory $archiveName
$compilerArguments = @('/nologo', '/noconfig', '/nostdlib+', '/target:winexe', '/platform:x64', '/optimize+', '/warn:4', '/codepage:65001')
$compilerArguments += @(('/out:' + $executable), ('/win32manifest:' + $manifest), ('/win32icon:' + $icon))
$compilerArguments += @(('/resource:' + $logo + ',WatchDogs2FlickerFix.logo.png'), ('/resource:' + $backend + ',WatchDogs2FlickerFix.backend.ps1'))
foreach ($referenceName in @('mscorlib', 'Accessibility', 'System', 'System.Core', 'System.Drawing', 'System.Windows.Forms', 'System.Web.Extensions', 'System.Xml', 'System.Configuration', 'System.Runtime.Serialization', 'System.Security')) {
    $reference = Join-Path $referenceDirectory ($referenceName + '.dll')
    if (-not (Test-Path -LiteralPath $reference -PathType Leaf)) { throw "Missing .NET Framework reference assembly: $reference" }
    $compilerArguments += '/reference:' + $reference
}
$compilerArguments += $source
Write-Host ('Building Windows x64 installer v' + $Version + '...')
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw "C# compiler failed with exit code $LASTEXITCODE." }
$compiledVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable).FileVersion
if ($compiledVersion -ne $assemblyVersion) { throw "Executable file version '$compiledVersion' does not match '$assemblyVersion'." }

$stagingParent = Join-Path $OutputDirectory 'obj'
$stagingDirectory = Join-Path $stagingParent ('package-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
$stagedExecutable = Join-Path $stagingDirectory $executableName
$readme = Join-Path $stagingDirectory 'README.txt'
$checksums = Join-Path $stagingDirectory 'SHA256SUMS.txt'
try {
    Copy-Item -LiteralPath $executable -Destination $stagedExecutable
    $readmeText = @"
Alexandre's Watch Dogs 2 Shadow Flicker
Version $Version | Windows 10 / 11 x64 | NVIDIA graphics

1. Close Watch Dogs 2.
2. Extract all files from this ZIP into a folder of your choice.
3. Double-click $executableName and approve the Windows administrator prompt.
4. Choose Apply the shadow fix and click Continue.
5. Wait for the progress bar and result. Start the game normally after success.

The program detects Steam, Epic, and Ubisoft installations. If a moved or unusual
installation is not detected, use the optional Game folder field or Browse
button before Continue.
To undo the change later, run this program again and choose Undo the fix.
Check current status reads the NVIDIA game-profile settings without changing them.

Requirements: 64-bit Windows 10 or 11, NVIDIA graphics, .NET Framework 4.8,
and the built-in Windows PowerShell 5.1. Internet access is needed on first use
for the pinned, checksum-verified NVIDIA Profile Inspector download.
.NET Framework 4.8 is included in Windows 10 version 1903 onward and Windows 11;
older Windows 10 installations must install the .NET Framework 4.8 runtime first.

Only two values in the Watch Dogs 2 NVIDIA profile are changed. Game files and
graphics quality settings are preserved. Keep the original-setting backup in
%LOCALAPPDATA%\WatchDogs2FlickerFix so Undo the fix remains available.
Cancel before Continue exits without applying the fix. During an operation,
Cancel requests a safe stop; wait for the program's result before closing it.

This executable is unsigned; Windows may display an unknown-publisher or
SmartScreen warning. Download only from the project release page and compare
the SHA256 checksum with SHA256SUMS.txt if you need to verify the download.

Community project and source:
https://github.com/APouzi/WatchDogs2-Shadow-flicker-fix
This project is not affiliated with Ubisoft or NVIDIA. NVIDIA Profile Inspector
is a separate community tool downloaded from its official project at runtime;
its executable is not redistributed in this ZIP. Its notices and licensing
remain available at https://github.com/Orbmu2k/nvidiaProfileInspector.
"@
    [IO.File]::WriteAllText($readme, $readmeText.Replace("`n", "`r`n").Replace("`r`r`n", "`r`n"), [Text.UTF8Encoding]::new($false))
    $checksumLines = foreach ($packagedFile in @($stagedExecutable, $readme)) {
        (Get-FileHash -LiteralPath $packagedFile -Algorithm SHA256).Hash + ' *' + [IO.Path]::GetFileName($packagedFile)
    }
    [IO.File]::WriteAllLines($checksums, [string[]]$checksumLines, [Text.UTF8Encoding]::new($false))
    Compress-Archive -LiteralPath @($stagedExecutable, $readme, $checksums) -DestinationPath $archive -CompressionLevel Optimal -Force
    & $packageValidator -Version $Version -OutputDirectory $OutputDirectory
    if (-not $?) { throw 'Installer package validation failed.' }
} finally {
    # Remove only files created in this unique staging folder; never recurse over
    # an output directory supplied by the caller.
    foreach ($stagedFile in @($stagedExecutable, $readme, $checksums)) {
        if (Test-Path -LiteralPath $stagedFile -PathType Leaf) { Remove-Item -LiteralPath $stagedFile -Force }
    }
    if (Test-Path -LiteralPath $stagingDirectory -PathType Container) { Remove-Item -LiteralPath $stagingDirectory }
}

$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$archiveChecksum = $archive + '.sha256'
[IO.File]::WriteAllText($archiveChecksum, $archiveHash + ' *' + $archiveName + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Write-Host ('EXE: ' + $executable)
Write-Host ('ZIP: ' + $archive)
Write-Host ('ZIP CHECKSUM: ' + $archiveChecksum)
Write-Host ('ZIP SHA256: ' + $archiveHash)
Write-Host 'Build complete. The executable was not launched or signed.'

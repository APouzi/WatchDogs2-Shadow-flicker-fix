#requires -Version 5.1
<#
.SYNOPSIS
Applies, checks, or undoes the NVIDIA Watch Dogs 2 shadow/sky flicker workaround.
.DESCRIPTION
For 64-bit Windows 10 and 11 with NVIDIA graphics and .NET Framework 4.8.
Downloads the pinned official release of the community tool NVIDIA Profile Inspector 3.0.2.1, verifies
its SHA256, and changes only two settings in the existing Watch Dogs 2 profile.
Apply and Restore request administrator access. Status does not change profiles.
Close the game before making changes. No game files or global settings are edited.
.PARAMETER ProgressFile
Optional absolute local .json path with an existing parent directory. Receives atomic UTF-8
reports with Percent, Message, and State (Running, Succeeded, Failed, or Cancelled).
.PARAMETER CancellationFile
Optional separate absolute local .json path with an existing parent directory. Create this
marker to request cancellation before driver writes begin. Its contents are ignored.
Once writes begin, the operation finishes or rolls back safely. Exit codes are 0 for success,
1 for failure, and 2 for cancellation. These switches are optional for standalone use.
.EXAMPLE
.\WatchDogs2-FlickerFix.ps1
.EXAMPLE
.\WatchDogs2-FlickerFix.ps1 -Action Status
.EXAMPLE
.\WatchDogs2-FlickerFix.ps1 -Action Restore
.LINK
https://www.reddit.com/r/watch_dogs/comments/1d0wa4r/nvidiawatch_dogs_2_skyboxshadow_flicker_fix/
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Status', 'Restore')][string]$Action = 'Apply',
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'WatchDogs2FlickerFix'),
    [string]$ToolPath,
    [string]$GamePath,
    [string]$ProgressFile,
    [string]$CancellationFile
)

# Start-Process can inherit PowerShell 7 module paths unchanged. Use the inbox
# Windows PowerShell modules in the Desktop helper; this changes this process only.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    $env:PSModulePath = @((Join-Path $PSHOME 'Modules'), (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules')) -join [IO.Path]::PathSeparator
}

$script:Wd2ProfileName = 'Watch Dogs 2'
$script:Wd2Targets = @(
    [pscustomobject]@{ Id = [uint32]10810129; Present = $true; Value = '2729785185' },
    [pscustomobject]@{ Id = [uint32]16545312; Present = $true; Value = '1' }
)
$script:Wd2ExeHash = '1EBD8129B3C564BF226291FB3344819FD59668066F0C5E03334A69A04A62859E'
$script:Wd2ReferenceHash = '0EA7B055AEE5C543047243D2DD7ABDD1B8C6D96F5D2B7BB5FE17BE8130E005EF'
$script:Wd2ZipHash = '88DCF3514111E8DE630688467C03C36D8C2A8AD9EBC8073F27C069F82B75BB40'
$script:Wd2Messages = New-Object 'System.Collections.Generic.List[string]'
$script:Wd2ProgressPath = $null
$script:Wd2ProgressPercent = 0
$script:Wd2CancellationPath = $null

function Set-Wd2ProgressDestination([string]$Path) {
    $script:Wd2ProgressPath = $null
    $script:Wd2ProgressPercent = 0
    if (-not $Path) { return }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw 'ProgressFile must be an absolute local JSON file path.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($fullPath) -ine '.json' -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($fullPath))) {
        throw 'ProgressFile must have a .json extension and an existing parent directory.'
    }
    $script:Wd2ProgressPath = $fullPath
}

function Write-Wd2Progress([ValidateRange(0, 100)][int]$Percent, [string]$Message, [ValidateSet('Running', 'Succeeded', 'Failed', 'Cancelled')][string]$State = 'Running', [switch]$Reset) {
    if (-not $script:Wd2ProgressPath) { return }
    # A runtime/elevation helper shares the same file. Keep its last real phase if
    # the parent reports a helper failure, rather than moving the bar backwards.
    if (-not $Reset -and [IO.File]::Exists($script:Wd2ProgressPath)) {
        try {
            $previous = [IO.File]::ReadAllText($script:Wd2ProgressPath) | ConvertFrom-Json -ErrorAction Stop
            $previousPercent = 0
            if ([int]::TryParse([string]$previous.Percent, [ref]$previousPercent) -and $previousPercent -ge 0 -and $previousPercent -le 100) {
                $Percent = [Math]::Max($Percent, $previousPercent)
            }
        } catch { Write-Verbose 'Previous progress could not be read; replacing it with the current phase.' }
    }
    if (-not $Reset) { $Percent = [Math]::Max($Percent, $script:Wd2ProgressPercent) }
    $report = [ordered]@{ Percent = $Percent; Message = $Message; State = $State }
    $json = $report | ConvertTo-Json -Compress
    $temporary = $script:Wd2ProgressPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($script:Wd2ProgressPath)) {
            [IO.File]::Replace($temporary, $script:Wd2ProgressPath, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $script:Wd2ProgressPath)
        }
        $script:Wd2ProgressPercent = $Percent
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Set-Wd2CancellationDestination([string]$Path) {
    $script:Wd2CancellationPath = $null
    if (-not $Path) { return }
    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw 'CancellationFile must be an absolute local JSON file path.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($fullPath) -ine '.json' -or -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($fullPath))) {
        throw 'CancellationFile must have a .json extension and an existing parent directory.'
    }
    if ($fullPath -ieq $script:Wd2ProgressPath) { throw 'CancellationFile and ProgressFile must be different paths.' }
    $script:Wd2CancellationPath = $fullPath
}

function Assert-Wd2NotCancelled {
    if ($script:Wd2CancellationPath -and [IO.File]::Exists($script:Wd2CancellationPath)) {
        throw [OperationCanceledException]::new('Cancelled before changing driver settings. No driver settings were changed.')
    }
}

function Write-Wd2Message([string]$Message) {
    $script:Wd2Messages.Add($Message)
    Write-Host $Message
}

function Find-Wd2Game([string]$SpecifiedPath) {
    Assert-Wd2NotCancelled
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($SpecifiedPath) { $candidates.Add([IO.Path]::GetFullPath($SpecifiedPath)) }
    else {
        $steamRoots = @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")
        foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
            $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($entry.SteamPath) { $steamRoots += $entry.SteamPath }
            if ($entry.InstallPath) { $steamRoots += $entry.InstallPath }
        }
        foreach ($steamRoot in @($steamRoots | Where-Object { $_ } | Select-Object -Unique)) {
            Assert-Wd2NotCancelled
            $libraries = @($steamRoot)
            foreach ($libraryFile in @((Join-Path $steamRoot 'steamapps\libraryfolders.vdf'), (Join-Path $steamRoot 'config\libraryfolders.vdf'))) {
                if (Test-Path -LiteralPath $libraryFile) {
                    $vdf = Get-Content -LiteralPath $libraryFile -Raw
                    foreach ($match in [regex]::Matches($vdf, '"(?:path|\d+)"\s+"([^"\r\n]+)"')) {
                        $value = $match.Groups[1].Value.Replace('\\', '\')
                        if ([IO.Path]::IsPathRooted($value)) { $libraries += $value }
                    }
                }
            }
            foreach ($library in @($libraries | Select-Object -Unique)) {
                $manifest = Join-Path $library 'steamapps\appmanifest_447040.acf'
                if (Test-Path -LiteralPath $manifest) {
                    $match = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"installdir"\s+"([^"\r\n]+)"')
                    if ($match.Success) { $candidates.Add((Join-Path $library ('steamapps\common\' + $match.Groups[1].Value))) }
                }
            }
        }
        $epicManifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
        foreach ($manifest in @(Get-ChildItem -LiteralPath $epicManifests -Filter '*.item' -File -ErrorAction SilentlyContinue)) {
            try {
                $entry = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
                if ($entry.InstallLocation) { $candidates.Add([string]$entry.InstallLocation) }
            } catch { Write-Verbose "Skipping unreadable Epic manifest: $($manifest.FullName)" }
        }
        foreach ($registryRoot in @('HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs', 'HKLM:\SOFTWARE\Ubisoft\Launcher\Installs', 'HKCU:\SOFTWARE\Ubisoft\Launcher\Installs', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
            foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
                $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if ($entry.InstallDir) { $candidates.Add([string]$entry.InstallDir) }
                if ($entry.InstallLocation) { $candidates.Add([string]$entry.InstallLocation) }
            }
        }
        $commonRoots = @("${env:ProgramFiles(x86)}\Ubisoft\Ubisoft Game Launcher\games", "$env:ProgramFiles\Epic Games")
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.IsReady -and $drive.DriveType -eq [IO.DriveType]::Fixed) {
                foreach ($suffix in @('Games', 'SteamLibrary\steamapps\common', 'Epic Games', 'Ubisoft Games')) { $commonRoots += Join-Path $drive.RootDirectory.FullName $suffix }
            }
        }
        foreach ($commonRoot in $commonRoots) {
            Assert-Wd2NotCancelled
            foreach ($folder in @(Get-ChildItem -LiteralPath $commonRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($folder.Name -match '(?i)^watch[ _-]*dogs[ _-]*2$') { $candidates.Add($folder.FullName) }
            }
        }
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            if ([IO.Path]::GetFileName($candidate) -ieq 'WatchDogs2.exe') { return [IO.Path]::GetFullPath($candidate) }
        } else {
            foreach ($relative in @('bin\WatchDogs2.exe', 'bin_plus\WatchDogs2.exe', 'WatchDogs2.exe')) {
                $exe = Join-Path $candidate $relative
                if (Test-Path -LiteralPath $exe -PathType Leaf) { return [IO.Path]::GetFullPath($exe) }
            }
        }
    }
    throw 'Watch Dogs 2 was not found in the Steam, Epic, or Ubisoft install records/common folders. Run again with -GamePath followed by its install folder or WatchDogs2.exe path.'
}

function Assert-Wd2Hash([string]$Path, [string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "Checksum verification failed: $Path. No driver settings were changed."
    }
}

function Get-Wd2Tool([string]$Root, [string]$ExistingTool) {
    Assert-Wd2NotCancelled
    Write-Wd2Progress 20 'Preparing the verified NVIDIA profile tool.'
    if ($ExistingTool) { $exe = [IO.Path]::GetFullPath($ExistingTool) }
    else {
        $toolDirectory = Join-Path $Root 'Tools\3.0.2.1'
        $exe = Join-Path $toolDirectory 'nvidiaProfileInspector.exe'
        if (-not (Test-Path -LiteralPath $exe)) {
            New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null
            $archive = Join-Path $toolDirectory 'nvidiaProfileInspector-3.0.2.1.zip'
            $oldTls = [Net.ServicePointManager]::SecurityProtocol
            try {
                [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
                Write-Wd2Progress 20 'Downloading NVIDIA Profile Inspector 3.0.2.1 from its official project.'
                Write-Wd2Message 'Downloading NVIDIA Profile Inspector 3.0.2.1 from its official project...'
                Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Orbmu2k/nvidiaProfileInspector/releases/download/v3.0.2.1/nvidiaProfileInspector.zip' -OutFile $archive
            } finally { [Net.ServicePointManager]::SecurityProtocol = $oldTls }
            Assert-Wd2NotCancelled
            Write-Wd2Progress 30 'Verifying the downloaded archive checksum.'
            Assert-Wd2Hash $archive $script:Wd2ZipHash
            Expand-Archive -LiteralPath $archive -DestinationPath $toolDirectory -Force
        }
    }
    Write-Wd2Progress 35 'Verifying the profile tool and reference checksums.'
    Assert-Wd2Hash $exe $script:Wd2ExeHash
    Assert-Wd2Hash (Join-Path (Split-Path -Parent $exe) 'Reference.xml') $script:Wd2ReferenceHash
    return $exe
}

function Get-Wd2States([xml]$Profile) {
    $profiles = @($Profile.ArrayOfProfile.Profile)
    if ($profiles.Count -ne 1 -or $profiles[0].ProfileName -ne $script:Wd2ProfileName -or @($profiles[0].Executeables.string) -notcontains 'watchdogs2.exe') {
        throw 'The NVIDIA Watch Dogs 2 profile was not found. Install an NVIDIA driver with this game profile first.'
    }
    foreach ($target in $script:Wd2Targets) {
        $found = @($profiles[0].SelectNodes('Settings/ProfileSetting') | Where-Object { $_.SettingID -eq [string]$target.Id })
        if ($found.Count -gt 1) { throw 'Duplicate target setting in exported profile.' }
        if ($found.Count -and $found[0].ValueType -ne 'Dword') { throw 'Expected a DWORD game-profile setting.' }
        [pscustomobject]@{ Id = $target.Id; Present = [bool]$found.Count; Value = $(if ($found.Count) { [string]$found[0].SettingValue } else { $null }) }
    }
}

function Test-Wd2States($Actual, $Expected) {
    foreach ($target in $script:Wd2Targets) {
        $a = @($Actual | Where-Object { [uint32]$_.Id -eq $target.Id })
        $e = @($Expected | Where-Object { [uint32]$_.Id -eq $target.Id })
        if ($a.Count -ne 1 -or $e.Count -ne 1 -or [bool]$a[0].Present -ne [bool]$e[0].Present) { return $false }
        if ($e[0].Present -and [string]$a[0].Value -ne [string]$e[0].Value) { return $false }
    }
    return $true
}

function Set-Wd2States($Service, $Current, $Desired) {
    foreach ($target in $script:Wd2Targets) {
        $prior = @($Current | Where-Object { [uint32]$_.Id -eq $target.Id })
        $next = @($Desired | Where-Object { [uint32]$_.Id -eq $target.Id })
        if ($prior.Count -ne 1 -or $next.Count -ne 1) { throw 'Invalid setting-state backup.' }
        if ($next[0].Present) {
            if (-not $prior[0].Present -or [string]$prior[0].Value -ne [string]$next[0].Value) {
                $Service.SetDwordValueToProfile($script:Wd2ProfileName, $target.Id, [uint32]$next[0].Value)
            }
        } elseif ($prior[0].Present) {
            $uiModifiedMarker = $false
            $Service.DeleteValue($script:Wd2ProfileName, $target.Id, [ref]$uiModifiedMarker)
            # NPI can suppress a delete error. The caller must verify a fresh export.
        }
    }
}

function Export-Wd2Profile($Service, [string]$Path) {
    $names = New-Object 'System.Collections.Generic.List[string]'
    $names.Add($script:Wd2ProfileName)
    $Service.ExportProfiles($names, $Path, $false)
    return [xml](Get-Content -LiteralPath $Path -Raw)
}

function Get-Wd2UntouchedProfile([xml]$Profile) {
    $copy = [xml]$Profile.OuterXml
    foreach ($node in @($copy.SelectNodes('/ArrayOfProfile/Profile/Settings/ProfileSetting'))) {
        if ([uint32]$node.SettingID -in @($script:Wd2Targets.Id)) { $node.ParentNode.RemoveChild($node) | Out-Null }
    }
    foreach ($settingsNode in @($copy.SelectNodes('/ArrayOfProfile/Profile/Settings'))) { if (-not $settingsNode.HasChildNodes) { $settingsNode.IsEmpty = $true } }
    return $copy.OuterXml
}

function Assert-Wd2OriginalState($State) {
    if ($State.Schema -ne 1 -or $State.ProfileName -ne $script:Wd2ProfileName -or $State.ComputerName -ne $env:COMPUTERNAME -or @($State.Original).Count -ne 2) { throw 'The undo-state file is invalid or belongs to another computer.' }
    foreach ($target in $script:Wd2Targets) {
        $entry = @($State.Original | Where-Object { $_.Id -eq $target.Id })
        $value = [uint32]0
        if ($entry.Count -ne 1 -or $entry[0].Present -isnot [bool] -or ($entry[0].Present -and -not [uint32]::TryParse([string]$entry[0].Value, [ref]$value))) { throw 'The undo-state file contains an invalid flag value.' }
    }
}

function Save-Wd2State($State, [string]$Path) {
    $tempPath = "$Path.new"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-Wd2HelperCommand([string]$ScriptPath, [string]$Root) {
    # Encode literal PowerShell arguments; paths containing spaces or apostrophes are safe.
    $command = "& '" + $ScriptPath.Replace("'", "''") + "' -Action '" + $Action + "' -StateDirectory '" + $Root.Replace("'", "''") + "'"
    if ($ToolPath) { $command += " -ToolPath '" + ([IO.Path]::GetFullPath($ToolPath)).Replace("'", "''") + "'" }
    if ($GamePath) { $command += " -GamePath '" + ([IO.Path]::GetFullPath($GamePath)).Replace("'", "''") + "'" }
    if ($script:Wd2ProgressPath) { $command += " -ProgressFile '" + $script:Wd2ProgressPath.Replace("'", "''") + "'" }
    if ($script:Wd2CancellationPath) { $command += " -CancellationFile '" + $script:Wd2CancellationPath.Replace("'", "''") + "'" }
    # Preserve cooperative cancellation instead of collapsing every nonzero exit to one.
    $command += '; if ($?) { exit 0 } elseif ($LASTEXITCODE -eq 2) { exit 2 } else { exit 1 }'
    return $command
}

function Invoke-Wd2Fix {
    $ErrorActionPreference = 'Stop'
    Assert-Wd2NotCancelled
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Environment]::OSVersion.Version.Major -lt 10 -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'This script requires 64-bit Windows 10 or Windows 11.'
    }
    $root = [IO.Path]::GetFullPath($StateDirectory)
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $needsAdmin = $Action -ne 'Status' -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $needsWindowsPowerShell = $PSVersionTable.PSEdition -eq 'Core' -or [IntPtr]::Size -ne 8
    if ($needsAdmin -or $needsWindowsPowerShell) {
        $command = Get-Wd2HelperCommand $PSCommandPath $root
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $windowsDirectory = if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' }
        $hostExe = Join-Path $env:SystemRoot "$windowsDirectory\WindowsPowerShell\v1.0\powershell.exe"
        $launch = @{ FilePath = $hostExe; ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded); Wait = $true; PassThru = $true; WindowStyle = 'Hidden' }
        if ($needsAdmin) { $launch.Verb = 'RunAs'; Write-Wd2Message 'Approve the Windows administrator prompt to change the game profile.' }
        $child = Start-Process @launch
        $resultFile = Join-Path $root 'LastRun.log'
        if (Test-Path -LiteralPath $resultFile) { foreach ($line in Get-Content -LiteralPath $resultFile) { Write-Wd2Message $line } }
        if ($child.ExitCode -eq 2) { throw [OperationCanceledException]::new('Cancelled before changing driver settings. No driver settings were changed.') }
        if ($child.ExitCode -ne 0) { throw "The Windows PowerShell helper failed (exit $($child.ExitCode)). Check $root for snapshots and logs." }
        return
    }
    Write-Wd2Progress 5 'Checking Windows, administrator access, and required components.'
    $framework = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
    if (-not $framework -or $framework.Release -lt 528040) { throw 'Install Microsoft .NET Framework 4.8, then run this script again.' }
    Assert-Wd2NotCancelled
    Write-Wd2Progress 10 'Finding Watch Dogs 2 in Steam, Epic, and Ubisoft install records.'
    try { $gameExe = Find-Wd2Game $GamePath; Write-Wd2Message "Found Watch Dogs 2: $gameExe" }
    catch { if ($Action -eq 'Apply' -or $_.Exception -is [OperationCanceledException]) { throw }; Write-Wd2Message 'Game install not found; the NVIDIA profile can still be checked or restored.' }
    if (Get-Process -Name nvidiaProfileInspector, nvcplui -ErrorAction SilentlyContinue) { throw 'Close NVIDIA Profile Inspector and NVIDIA Control Panel before running this script.' }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $lock = $null
    $bootstrap = $null
    $scopeType = $null
    try {
        $lock = [IO.File]::Open((Join-Path $root 'operation.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $exe = Get-Wd2Tool $root $ToolPath
        Assert-Wd2NotCancelled
        Write-Wd2Progress 40 'Opening the NVIDIA game-profile service.'
        Add-Type -AssemblyName PresentationFramework
        $assembly = [Reflection.Assembly]::LoadFrom($exe)
        $scopeType = $assembly.GetType('nvidiaProfileInspector.Common.DrsSessionScope', $true)
        $scopeType.GetField('HoldSession').SetValue($null, $false)
        $bootstrap = [Activator]::CreateInstance($assembly.GetType('nvidiaProfileInspector.AppBootstrapper', $true))
        $assembly.GetType('nvidiaProfileInspector.App', $true).GetField('_bootstrapper', [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $bootstrap)
        $bootstrap.Initialize()
        $exporter = $bootstrap.Resolve($assembly.GetType('nvidiaProfileInspector.Common.DrsImportService', $true))
        $settings = $bootstrap.Resolve($assembly.GetType('nvidiaProfileInspector.Common.DrsSettingsService', $true))
        $inspectionPath = Join-Path $root 'Status.latest.nip'
        Assert-Wd2NotCancelled
        Write-Wd2Progress 45 'Reading the current Watch Dogs 2 driver settings.'
        $currentProfile = Export-Wd2Profile $exporter $inspectionPath
        $current = @(Get-Wd2States $currentProfile)
        $statePath = Join-Path $root 'OriginalState.json'
        Assert-Wd2NotCancelled
        if ($Action -eq 'Status') {
            foreach ($target in $script:Wd2Targets) {
                $actual = @($current | Where-Object { $_.Id -eq $target.Id })[0]
                $value = if ($actual.Present) { '0x{0:X8}' -f [uint32]$actual.Value } else { '(driver default; no user override)' }
                Write-Wd2Message ('0x{0:X8}: {1}' -f $target.Id, $value)
            }
            Write-Wd2Message ('Workaround applied: ' + (Test-Wd2States $current $script:Wd2Targets))
            Write-Wd2Message ('Undo backup available: ' + (Test-Path -LiteralPath $statePath))
            return
        }
        Write-Wd2Progress 55 'Checking the original-settings backup.'
        $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } else { $null }
        if ($state) {
            Assert-Wd2OriginalState $state
        }
        if ($Action -eq 'Apply' -and (Test-Wd2States $current $script:Wd2Targets)) {
            Write-Wd2Message 'The workaround is already applied. No driver settings were changed.'
            if (-not $state) { Write-Wd2Message 'No original backup was created because these flags were already present. Use the backup from the original installation to undo them.' }
            return
        }
        if ($Action -eq 'Restore' -and -not $state) { throw 'No original-state backup exists. Refusing to guess the previous settings.' }
        $desired = if ($Action -eq 'Restore') { @($state.Original) } else { $script:Wd2Targets }
        if (Test-Wd2States $current $desired) { Write-Wd2Message 'The original flag values are already restored. No changes were needed.'; return }
        if (Get-Process -Name WatchDogs2, watchdogs2_rt64, watchdogs2_r64, watchdogs_rt64_dx12 -ErrorAction SilentlyContinue) { throw 'Close Watch Dogs 2 before applying or restoring the workaround. The script will not close it for you.' }
        Assert-Wd2NotCancelled
        Write-Wd2Progress 60 'Saving original game and customized-profile snapshots.'
        $runDirectory = Join-Path $root ('Backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        Copy-Item -LiteralPath $inspectionPath -Destination (Join-Path $runDirectory 'Game.before.nip')
        $exporter.ExportAllCustomizedProfiles((Join-Path $runDirectory 'AllCustomized.before.nip'))
        if (-not $state) {
            $state = [pscustomobject]@{ Schema = 1; ProfileName = $script:Wd2ProfileName; ComputerName = $env:COMPUTERNAME; CreatedAt = (Get-Date).ToString('o'); Original = $current; OriginalSnapshot = (Join-Path $runDirectory 'Game.before.nip'); LastAction = 'BackedUp' }
            Save-Wd2State $state $statePath
        }
        Write-Wd2Progress 65 'Original settings and rollback snapshots are saved.'
        # Last cancellation checkpoint. After writes start, finish or roll back safely.
        Assert-Wd2NotCancelled
        try {
            Write-Wd2Progress 75 ('Writing the two game-profile settings for ' + $Action.ToLowerInvariant() + '.')
            Set-Wd2States $settings $current $desired
            Write-Wd2Progress 85 'Reading back the saved settings and checking unrelated settings.'
            $afterProfile = Export-Wd2Profile $exporter (Join-Path $runDirectory 'Game.after.nip')
            if (-not (Test-Wd2States @(Get-Wd2States $afterProfile) $desired)) { throw 'Driver read-back did not match the requested flag values.' }
            if ((Get-Wd2UntouchedProfile $currentProfile) -ne (Get-Wd2UntouchedProfile $afterProfile)) { throw 'Another game-profile setting changed during this operation. Inspect the snapshots.' }
            $exporter.ExportAllCustomizedProfiles((Join-Path $runDirectory 'AllCustomized.after.nip'))
            Write-Wd2Progress 95 'Saving verified results and backup metadata.'
            $state.LastAction = $Action
            Save-Wd2State $state $statePath
            "$Action verified at $((Get-Date).ToString('o'))" | Set-Content -LiteralPath (Join-Path $runDirectory 'Result.txt') -Encoding UTF8
            Write-Wd2Message "$Action completed and verified. Start Watch Dogs 2 to check the shadows."
            Write-Wd2Message "Backup and snapshots: $runDirectory"
        } catch {
            $operationError = $_
            try {
                try { Write-Wd2Progress $script:Wd2ProgressPercent 'The operation failed; restoring the pre-operation flag values.' }
                catch { Write-Verbose 'Progress reporting failed; rollback still proceeds.' }
                $failedProfile = Export-Wd2Profile $exporter (Join-Path $runDirectory 'Game.failed.nip')
                Set-Wd2States $settings @(Get-Wd2States $failedProfile) $current
                $rollbackProfile = Export-Wd2Profile $exporter (Join-Path $runDirectory 'Game.rollback.nip')
                if (-not (Test-Wd2States @(Get-Wd2States $rollbackProfile) $current)) { throw 'Rollback read-back failed.' }
                Write-Warning 'The operation failed; its two flag values were returned to their pre-operation state.'
            } catch { Write-Warning "Automatic rollback could not be verified: $($_.Exception.Message). Keep the snapshots in $runDirectory." }
            $operationError | Out-String | Set-Content -LiteralPath (Join-Path $runDirectory 'Error.txt') -Encoding UTF8
            throw $operationError
        }
    } finally {
        if ($scopeType) { $scopeType.GetMethod('DestroyGlobalSession').Invoke($null, @()) | Out-Null }
        if ($bootstrap) { $bootstrap.Dispose() }
        if ($lock) { $lock.Dispose() }
    }
}

function Invoke-Wd2Script {
    $ErrorActionPreference = 'Stop'
    $scriptExit = 0
    $script:Wd2Messages.Clear()
    try {
        Set-Wd2ProgressDestination $ProgressFile
        Write-Wd2Progress 0 'Checking requirements before starting.' -Reset
        Set-Wd2CancellationDestination $CancellationFile
        Assert-Wd2NotCancelled
        Invoke-Wd2Fix | Out-Host
        $message = switch ($Action) {
            'Apply' { 'The shadow flicker workaround is applied and verified.' }
            'Restore' { 'The original game-profile settings are restored and verified.' }
            'Status' { 'The game-profile status has been checked.' }
        }
        Write-Wd2Progress 100 $message 'Succeeded'
    } catch {
        $failure = $_
        $cancelled = $failure.Exception -is [OperationCanceledException]
        $scriptExit = if ($cancelled) { 2 } else { 1 }
        $terminalState = if ($cancelled) { 'Cancelled' } else { 'Failed' }
        try { Write-Wd2Progress $script:Wd2ProgressPercent $failure.Exception.Message $terminalState }
        catch { Write-Warning ('Could not save progress: ' + $_.Exception.Message) }
        $prefix = if ($cancelled) { 'CANCELLED: ' } else { 'ERROR: ' }
        Write-Wd2Message ($prefix + $failure.Exception.Message)
        if (-not $cancelled) { Write-Error $failure -ErrorAction Continue }
    }
    try {
        New-Item -ItemType Directory -Path $StateDirectory -Force -ErrorAction Stop | Out-Null
        $script:Wd2Messages | Set-Content -LiteralPath (Join-Path $StateDirectory 'LastRun.log') -Encoding UTF8 -ErrorAction Stop
    } catch { Write-Warning 'Could not save LastRun.log. The result is shown above.' }
    return $scriptExit
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Wd2Script)
}

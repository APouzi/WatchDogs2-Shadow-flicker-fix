# No driver settings are changed. Uses fixtures and a mock settings service.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'WatchDogs2-FlickerFix.ps1')
$script:Checks = 0
function Assert([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:Checks++; Write-Output "PASS: $Name" }
function Profile([string]$Settings) { return [xml]('<ArrayOfProfile><Profile><ProfileName>Watch Dogs 2</ProfileName><Executeables><string>watchdogs2.exe</string></Executeables><Settings>' + $Settings + '</Settings></Profile></ArrayOfProfile>') }
function Setting([uint32]$Id, [uint32]$Value) { return "<ProfileSetting><SettingID>$Id</SettingID><SettingValue>$Value</SettingValue><ValueType>Dword</ValueType></ProfileSetting>" }
function MockStates($Service) { foreach ($target in $script:Wd2Targets) { [pscustomobject]@{Id=$target.Id;Present=$Service.Values.ContainsKey($target.Id);Value=$(if($Service.Values.ContainsKey($target.Id)){[string]$Service.Values[$target.Id]}else{$null})} } }
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public class MockWd2Settings {
    public Dictionary<uint,uint> Values = new Dictionary<uint,uint>();
    public int Calls;
    public uint FailOnceOn;
    public void SetDwordValueToProfile(string profile, uint id, uint value) {
        Calls++;
        if (id == FailOnceOn) { FailOnceOn = 0; throw new Exception("Simulated driver write failure"); }
        Values[id] = value;
    }
    public void DeleteValue(string profile, uint id, out bool ignored) { Calls++; Values.Remove(id); ignored=false; }
}
'@
$empty = Profile ''
$original = @(Get-Wd2States $empty)
Assert (-not $original[0].Present -and -not $original[1].Present) 'Absent original overrides are captured'
$applied = Profile ((Setting 10810129 2729785185) + (Setting 16545312 1))
$targetStates = @(Get-Wd2States $applied)
Assert (Test-Wd2States $targetStates $script:Wd2Targets) 'Target DWORDs are parsed without signed overflow'
Assert (-not (Test-Wd2States $original $script:Wd2Targets)) 'Missing flags are not mistaken for applied flags'
Assert ((Get-Wd2UntouchedProfile $empty) -eq (Get-Wd2UntouchedProfile $applied)) 'Empty Settings XML normalizes after adding/removing flags'
$unrelated = Setting 12345 456
$before = Profile $unrelated
$after = Profile ($unrelated + (Setting 10810129 2729785185) + (Setting 16545312 1))
Assert ((Get-Wd2UntouchedProfile $before) -eq (Get-Wd2UntouchedProfile $after)) 'Unrelated settings and executable assignments are preserved'
$changed = Profile ((Setting 12345 789) + (Setting 10810129 2729785185) + (Setting 16545312 1))
Assert ((Get-Wd2UntouchedProfile $before) -ne (Get-Wd2UntouchedProfile $changed)) 'An unrelated concurrent setting change is detected'
$service = New-Object MockWd2Settings
$service.Values[[uint32]12345] = [uint32]456
Set-Wd2States $service $original $script:Wd2Targets
Assert ((Test-Wd2States @(MockStates $service) $script:Wd2Targets) -and $service.Values[[uint32]12345] -eq 456) 'Apply sets only the two requested flags'
$calls = $service.Calls
Set-Wd2States $service @(MockStates $service) $script:Wd2Targets
Assert ($service.Calls -eq $calls) 'Repeated Apply performs no writes'
Set-Wd2States $service @(MockStates $service) $original
Assert ($service.Values.Count -eq 1 -and $service.Values[[uint32]12345] -eq 456) 'Undo deletes only newly introduced overrides'
$mixed = @(Get-Wd2States (Profile (Setting 10810129 777)))
Set-Wd2States $service @(MockStates $service) $mixed
Set-Wd2States $service @(MockStates $service) $script:Wd2Targets
Set-Wd2States $service @(MockStates $service) $mixed
Assert ($service.Values[[uint32]10810129] -eq 777 -and -not $service.Values.ContainsKey([uint32]16545312) -and $service.Values[[uint32]12345] -eq 456) 'Undo restores an original explicit value and preserves unrelated settings'
Set-Wd2States $service @(MockStates $service) $original
$service.FailOnceOn = 16545312
$failed = $false
try { Set-Wd2States $service @(MockStates $service) $script:Wd2Targets } catch { $failed = $true }
Assert ($failed -and $service.Values.ContainsKey([uint32]10810129)) 'A partial driver failure surfaces to the caller'
Set-Wd2States $service @(MockStates $service) $original
Assert ($service.Values.Count -eq 1 -and $service.Values[[uint32]12345] -eq 456) 'Partial writes can roll back to the original flag state'
$invalid = [pscustomobject]@{Schema=1;ProfileName='Watch Dogs 2';ComputerName=$env:COMPUTERNAME;Original=@([pscustomobject]@{Id=10810129;Present='false';Value=$null},$original[1])}
$rejected = $false
try { Assert-Wd2OriginalState $invalid } catch { $rejected = $true }
Assert $rejected 'Malformed Boolean backup values are rejected'
$invalid.Original = @([pscustomobject]@{Id=10810129;Present=$true;Value='4294967296'},$original[1])
$rejected = $false
try { Assert-Wd2OriginalState $invalid } catch { $rejected = $true }
Assert $rejected 'Out-of-range backup DWORDs are rejected'
$invalid.Original = $original
Assert-Wd2OriginalState $invalid
Assert $true 'A valid original-state backup is accepted'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('Wd2-Fixture Game With Spaces-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'bin') -Force | Out-Null
$fixtureExe = Join-Path $fixtureRoot 'bin\WatchDogs2.exe'
Set-Content -LiteralPath $fixtureExe -Value ''
Assert ((Find-Wd2Game $fixtureRoot) -eq $fixtureExe) 'An explicit game installation root is supported'
Assert ((Find-Wd2Game (Split-Path -Parent $fixtureExe)) -eq $fixtureExe) 'An explicit bin folder is supported'
Assert ((Find-Wd2Game $fixtureExe) -eq $fixtureExe) 'An explicit executable path is supported'
$rejected = $false
try { Assert-Wd2Hash $fixtureExe ('0' * 64) } catch { $rejected = $true }
Assert $rejected 'Checksum mismatch is rejected before tool loading'
$missing = [xml]'<ArrayOfProfile><Profile><ProfileName>Other game</ProfileName><Executeables/><Settings/></Profile></ArrayOfProfile>'
$rejected = $false
try { Get-Wd2States $missing | Out-Null } catch { $rejected = $true }
Assert $rejected 'A missing or incorrect NVIDIA game profile is rejected'
Remove-Item -LiteralPath $fixtureExe
Remove-Item -LiteralPath (Split-Path -Parent $fixtureExe)
Remove-Item -LiteralPath $fixtureRoot
Write-Output "All $script:Checks checks passed. No NVIDIA profile mutations were performed."

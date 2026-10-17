#requires -Version 5.1
# Render and fixture checks only: never starts the backend or mutates a driver.
[CmdletBinding()]
param([string]$Executable)
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    $hostPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments=@('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if($Executable){$arguments+=@('-Executable',$Executable)}
    & $hostPath @arguments
    exit $LASTEXITCODE
}
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
if(-not $Executable){$Executable=Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\Alexandres-WatchDogs2-Shadow-Flicker-Setup.exe'}
$assembly=[Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($Executable))
$resultType=$assembly.GetType('WatchDogs2FlickerFix.InstallerResult',$true)
$formType=$assembly.GetType('WatchDogs2FlickerFix.SetupForm',$true)
$script:checks=0
function Assert([bool]$Condition,[string]$Name){if(-not $Condition){throw "FAIL: $Name"};$script:checks++;Write-Output "PASS: $Name"}
function Field($Form,[string]$Name){return $formType.GetField($Name,[Reflection.BindingFlags]'Instance,NonPublic').GetValue($Form)}
function SetField($Form,[string]$Name,$Value){$formType.GetField($Name,[Reflection.BindingFlags]'Instance,NonPublic').SetValue($Form,$Value)}
function Call($Form,[string]$Name){$formType.GetMethod($Name,[Reflection.BindingFlags]'Instance,NonPublic').Invoke($Form,@())|Out-Null}
Assert ($resultType::Classify(0,$false,'Succeeded') -eq 'Succeeded') 'Success requires a successful exit and terminal verification'
Assert ($resultType::Classify(0,$false,'Running') -eq 'Failed') 'An exit without terminal verification is not success'
Assert ($resultType::Classify(1,$false,'Succeeded') -eq 'Failed') 'A failing exit overrides a stale success report'
Assert ($resultType::Classify(0,$true,'Succeeded') -eq 'Failed') 'A launcher exception overrides a success report'
Assert ($resultType::Classify(2,$false,'Cancelled') -eq 'Cancelled') 'Cooperative cancellation is distinguished from failure'
$security=$formType.GetMethod('AdminOnlySecurity',[Reflection.BindingFlags]'Static,NonPublic').Invoke($null,@())
$owner=$security.GetOwner([Security.Principal.SecurityIdentifier])
Assert ($owner.IsWellKnown([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid)) 'Staged scripts are owned by Administrators'
Assert $security.AreAccessRulesProtected 'Staging ACLs do not inherit user-write permissions'
$rules=@($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
Assert ($rules.Count -eq 2 -and @($rules|Where-Object {-not($_.IdentityReference.IsWellKnown([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid) -or $_.IdentityReference.IsWellKnown([Security.Principal.WellKnownSidType]::LocalSystemSid))}).Count -eq 0) 'Only Administrators and SYSTEM can modify staged scripts'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('wd2-ui-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
$progressFile=Join-Path $fixture 'progress.json'
$cancelFile=Join-Path $fixture 'cancellation.json'
$form=[Activator]::CreateInstance($formType,$true)
try{
    $form.ShowInTaskbar=$false
    $form.Opacity=0
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Assert (Field $form 'apply').Checked 'Apply is selected by default'
    Assert ((Field $form 'next').Text -eq 'Continue') 'Welcome provides Continue'
    Assert ((Field $form 'cancel').Enabled) 'Welcome provides Cancel'
    $form.Size=New-Object Drawing.Size(900,650)
    [Windows.Forms.Application]::DoEvents()
    foreach($buttonName in @('next','cancel')){
        $button=Field $form $buttonName
        $point=$button.PointToScreen([Drawing.Point]::Empty)
        $clientPoint=$form.PointToClient($point)
        Assert ($clientPoint.X -ge 0 -and $clientPoint.Y -ge 0 -and ($clientPoint.X+$button.Width) -le $form.ClientSize.Width -and ($clientPoint.Y+$button.Height) -le $form.ClientSize.Height) "$buttonName remains reachable in a compact window"
    }
    SetField $form 'progressPath' ([string]$progressFile)
    SetField $form 'cancellationPath' ([string]$cancelFile)
    SetField $form 'running' $true
    [IO.File]::WriteAllText($progressFile,'{"Percent":55,"Message":"Backing up originals","State":"Running"}')
    Call $form 'ReadProgress'
    Assert ((Field $form 'progress').Value -eq 55) 'Progress displays the actual backend percentage'
    Assert ((Field $form 'message').Text -eq 'Backing up originals') 'Progress displays the actual backend phase'
    Assert (Field $form 'cancel').Enabled 'Cancellation is available before driver writes'
    Assert ((Field $form 'progress').AccessibilityObject.Value -eq '55%') 'Progress value is exposed to accessibility clients'
    [IO.File]::WriteAllText($progressFile,'{"Percent":75,"Message":"Saving flags","State":"Running"}')
    Call $form 'ReadProgress'
    Assert (-not (Field $form 'cancel').Enabled) 'Cancel is disabled during profile writes and verification'
    [IO.File]::WriteAllText($progressFile,'{"Percent":55,"Message":"Backing up originals","State":"Running"}')
    Call $form 'ReadProgress'
    Call $form 'RequestCancel'
    Assert (Test-Path -LiteralPath $cancelFile) 'Cancel sends a cooperative marker instead of killing a process'
    Assert (-not (Field $form 'cancel').Enabled) 'Repeated cancellation is disabled while waiting'
}finally{
    SetField $form 'running' $false
    $form.Close()
    $form.Dispose()
    foreach($file in @($progressFile,$cancelFile)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
    Remove-Item -LiteralPath $fixture
}
Write-Output "All $script:checks installer UI checks passed. No backend or driver operation was started."

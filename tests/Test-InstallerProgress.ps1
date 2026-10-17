# Fixture-only checks. The real operation is replaced before any entry-point call.
# No NVIDIA APIs, download, elevation, or game processes are used.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'WatchDogs2-FlickerFix.ps1')
$script:Checks = 0
function Assert([bool]$Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:Checks++; Write-Output "PASS: $Name" }
function Read-Progress { return ([IO.File]::ReadAllText($ProgressFile) | ConvertFrom-Json) }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("Wd2 Progress Fixture O'Brien-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
$ProgressFile = Join-Path $fixtureRoot 'progress.json'
$CancellationFile = Join-Path $fixtureRoot 'cancellation.json'
$StateDirectory = Join-Path $fixtureRoot 'state'
$realOperation = ${function:Invoke-Wd2Fix}
try {
    Set-Wd2ProgressDestination $ProgressFile
    Write-Wd2Progress 0 'Checking requirements.' -Reset
    $progress = Read-Progress
    Assert ($progress.Percent -eq 0 -and $progress.State -eq 'Running') 'Initial progress is a real running phase at zero'
    Write-Wd2Progress 35 'Verified "tool" checksum and cloud: ☁'
    $progress = Read-Progress
    Assert ($progress.Percent -eq 35 -and $progress.Message -eq 'Verified "tool" checksum and cloud: ☁') 'JSON preserves quoted Unicode status text and integer percent'
    $bytes = [IO.File]::ReadAllBytes($ProgressFile)
    Assert (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Progress JSON uses UTF-8 without a byte-order mark'
    Assert (@(Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.tmp').Count -eq 0) 'Atomic updates leave no temporary report behind'
    Write-Wd2Progress 20 'Parent reports helper failure.' 'Failed'
    $progress = Read-Progress
    Assert ($progress.Percent -eq 35 -and $progress.State -eq 'Failed') 'A helper failure preserves the last real phase'
    Set-Wd2ProgressDestination $ProgressFile
    Write-Wd2Progress 0 'Fresh operation.' -Reset
    Assert ((Read-Progress).Percent -eq 0) 'A new operation resets a previous terminal report'
    foreach ($invalid in @('relative.json', 'C:relative.json', '\rooted-without-drive.json', '\\server\share\progress.json', (Join-Path $fixtureRoot 'progress.txt'), (Join-Path $fixtureRoot 'missing\progress.json'))) {
        $rejected = $false
        try { Set-Wd2ProgressDestination $invalid } catch { $rejected = $true }
        Assert $rejected ("Unsafe or unavailable progress path is rejected: " + $invalid)
    }
    Set-Wd2ProgressDestination $ProgressFile
    $rejected = $false
    try { Set-Wd2CancellationDestination $ProgressFile } catch { $rejected = $true }
    Assert $rejected 'Cancellation cannot overwrite the progress channel'
    Set-Wd2CancellationDestination $CancellationFile
    Assert-Wd2NotCancelled
    Assert $true 'No cancellation marker lets a safe checkpoint continue'
    $ToolPath = Join-Path $fixtureRoot 'tool.exe'
    $GamePath = Join-Path $fixtureRoot 'game; literal.exe'
    $scriptPath = Join-Path $fixtureRoot "script'; literal.ps1"
    $command = Get-Wd2HelperCommand $scriptPath $StateDirectory
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$parseErrors)
    $elements = @($ast.EndBlock.Statements[0].PipelineElements[0].CommandElements)
    $literalValues = @($elements | Where-Object { $_ -is [Management.Automation.Language.StringConstantExpressionAst] } | ForEach-Object { $_.Value })
    Assert (@($parseErrors).Count -eq 0 -and $elements.Count -eq 13 -and $literalValues[0] -eq $scriptPath) 'Runtime helper keeps apostrophes and semicolons inside literal arguments'
    Assert ($literalValues -contains $ProgressFile -and $literalValues -contains $CancellationFile -and $literalValues -contains $StateDirectory -and $literalValues -contains $ToolPath -and $literalValues -contains $GamePath) 'Runtime helper propagates state, tool, game, progress, and cancellation paths intact'
    $ToolPath = $null
    $GamePath = $null
    $helperHost = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $stubHeader = 'param([string]$Action, [string]$StateDirectory, [string]$ToolPath, [string]$GamePath, [string]$ProgressFile, [string]$CancellationFile)'
    try {
        [IO.File]::WriteAllText($scriptPath, $stubHeader + '; exit 2')
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        & $helperHost -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        Assert ($LASTEXITCODE -eq 2) 'An actual helper process preserves cancellation exit code two'
        [IO.File]::WriteAllText($scriptPath, $stubHeader + '; throw [InvalidOperationException]::new("Fixture managed failure.")')
        $expectedFailurePreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $helperHost -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>$null
            $failedHelperExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $expectedFailurePreference }
        Assert ($failedHelperExit -eq 1) 'An actual helper managed failure cannot become a success exit'
        [IO.File]::WriteAllText($scriptPath, $stubHeader + '; exit 0')
        & $helperHost -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
        Assert ($LASTEXITCODE -eq 0) 'An actual successful helper returns exit zero'
    } finally {
        if ([IO.File]::Exists($scriptPath)) { [IO.File]::Delete($scriptPath) }
    }
    [IO.File]::WriteAllText($CancellationFile, '{}')
    $rejected = $false
    try { Assert-Wd2NotCancelled } catch { $rejected = $_.Exception -is [OperationCanceledException] }
    Assert $rejected 'A cancellation marker raises a typed cancellation exception'
    [IO.File]::Delete($CancellationFile)
    $script:OperationCalls = 0
    function Invoke-Wd2Fix { $script:OperationCalls++; Write-Wd2Progress 45 'Fixture driver inspection.'; throw [InvalidOperationException]::new('Simulated inspection failure.') }
    $exitCode = Invoke-Wd2Script 2>$null
    $progress = Read-Progress
    Assert ($exitCode -eq 1 -and $progress.State -eq 'Failed' -and $progress.Percent -eq 45 -and $progress.Message -eq 'Simulated inspection failure.') 'Runtime failure has nonzero exit, exact phase, and terminal failure JSON'
    Assert ((Get-Content -LiteralPath (Join-Path $StateDirectory 'LastRun.log') -Raw) -match 'Simulated inspection failure') 'Failure details are also saved to the normal run log'
    function Invoke-Wd2Fix { $script:OperationCalls++; throw [InvalidOperationException]::new('Simulated early validation failure.') }
    $exitCode = Invoke-Wd2Script 2>$null
    $progress = Read-Progress
    Assert ($exitCode -eq 1 -and $progress.State -eq 'Failed' -and $progress.Percent -eq 0) 'Early validation failure reports zero percent instead of claiming completion'
    $beforeCancel = $script:OperationCalls
    [IO.File]::WriteAllText($CancellationFile, '{}')
    $exitCode = Invoke-Wd2Script
    $progress = Read-Progress
    Assert ($exitCode -eq 2 -and $progress.State -eq 'Cancelled' -and $progress.Percent -eq 0 -and $script:OperationCalls -eq $beforeCancel) 'Pre-start Cancel returns exit two without invoking the operation'
    [IO.File]::Delete($CancellationFile)
    function Invoke-Wd2Fix { Write-Wd2Progress 60 'Fixture backup.'; [IO.File]::WriteAllText($CancellationFile, '{}'); Assert-Wd2NotCancelled; throw 'Checkpoint incorrectly continued.' }
    $exitCode = Invoke-Wd2Script
    $progress = Read-Progress
    Assert ($exitCode -eq 2 -and $progress.State -eq 'Cancelled' -and $progress.Percent -eq 60) 'Cancel during preparation preserves its real phase'
    [IO.File]::Delete($CancellationFile)
    foreach ($Action in @('Apply', 'Restore', 'Status')) {
        function Invoke-Wd2Fix { Write-Wd2Progress 85 'Fixture verified read-back.' }
        $exitCode = Invoke-Wd2Script
        $progress = Read-Progress
        Assert ($exitCode -eq 0 -and $progress.State -eq 'Succeeded' -and $progress.Percent -eq 100) ("Successful " + $Action + ' reports verified completion')
    }
    function Invoke-Wd2Fix { Write-Wd2Progress 75 'Fixture mutation started.'; [IO.File]::WriteAllText($CancellationFile, '{}'); Write-Wd2Progress 95 'Fixture results safely saved.' }
    $exitCode = Invoke-Wd2Script
    $progress = Read-Progress
    Assert ($exitCode -eq 0 -and $progress.State -eq 'Succeeded' -and $progress.Percent -eq 100) 'Late cancellation does not interrupt an operation already in its safe completion phase'
    [IO.File]::Delete($CancellationFile)
    $ProgressFile = Join-Path $fixtureRoot 'missing\progress.json'
    $beforeBadChannel = $script:OperationCalls
    function Invoke-Wd2Fix { $script:OperationCalls++ }
    $exitCode = Invoke-Wd2Script 2>$null
    Assert ($exitCode -eq 1 -and $script:OperationCalls -eq $beforeBadChannel) 'An unavailable progress channel stops before invoking driver work'
    $blockedChannel = Join-Path $fixtureRoot 'blocked.json'
    [IO.Directory]::CreateDirectory($blockedChannel) | Out-Null
    try {
        $ProgressFile = $blockedChannel
        $exitCode = Invoke-Wd2Script 2>$null 3>$null
        Assert ($exitCode -eq 1 -and $script:OperationCalls -eq $beforeBadChannel) 'An atomic progress write failure cannot continue into driver work'
    } finally { [IO.Directory]::Delete($blockedChannel) }
    $ProgressFile = $null
    $CancellationFile = $null
    $exitCode = Invoke-Wd2Script
    Assert ($exitCode -eq 0) 'Standalone script behavior remains supported without installer files'
} finally {
    Set-Item -Path Function:Invoke-Wd2Fix -Value $realOperation
    # Delete only explicitly created files and their now-empty fixture directories.
    foreach ($path in @((Join-Path $fixtureRoot 'progress.json'), (Join-Path $fixtureRoot 'cancellation.json'), (Join-Path $StateDirectory 'LastRun.log'))) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    if ([IO.Directory]::Exists($StateDirectory)) { [IO.Directory]::Delete($StateDirectory) }
    [IO.Directory]::Delete($fixtureRoot)
}
Write-Output "All $script:Checks installer progress checks passed. No NVIDIA profile mutations were performed."

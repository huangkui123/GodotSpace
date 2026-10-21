$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'pico_helper.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Import only functions, never the live device watcher or its launch/stop actions.
foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$Adb = Join-Path $PSHOME 'powershell.exe'
$DeviceSerial = ''
$expected = '采集与投屏启动指令已提交，等待 PC 收到画面'
$payload = @{ state='started'; message=$expected } | ConvertTo-Json -Compress
$bytes64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
$child = "`$bytes=[Convert]::FromBase64String('$bytes64'); [Console]::OpenStandardOutput().Write(`$bytes,0,`$bytes.Length)"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
$actual = Invoke-Adb @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
if (($actual | ConvertFrom-Json).message -cne $expected) { throw 'UTF-8 stdout was corrupted' }
$child = "`$bytes=[Convert]::FromBase64String('$bytes64'); [Console]::OpenStandardError().Write(`$bytes,0,`$bytes.Length); exit 1"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
$caught = $false
try { $null = Invoke-Adb @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) } catch {
    $caught = $true
    if (-not $_.Exception.Message.Contains($expected)) { throw 'UTF-8 stderr was corrupted' }
    if ($_.Exception -isnot [IO.IOException]) { throw 'Transport failure must be distinguishable from configuration failure' }
}
if (-not $caught) { throw 'ADB nonzero exit must be reported' }
$null = Invoke-Adb @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) 15000 @(0, 1)
$Status = Join-Path $env:TEMP "pico-status-test-$PID.json"
$StatusGeneration = 4
try {
    Write-Status 'started' $expected
    $result = Get-Content -LiteralPath $Status -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.message -cne $expected -or $result.generation -ne 4) { throw 'Status generation/encoding roundtrip failed' }
} finally {
    Remove-Item -LiteralPath $Status -Force -ErrorAction SilentlyContinue
}
# Run the actual watcher body with a fake device and parent clock. A transient
# status read, missing Android process and permission wait must not reopen it.
$TaskFolder = Join-Path $env:TEMP "pico-watcher-test-$PID"
$null = New-Item -ItemType Directory -Path $TaskFolder -Force
$Config = Join-Path $TaskFolder 'helper.json'
$Status = Join-Path $TaskFolder 'status.json'
$Action = 'Start'
$Package = 'com.picospatialanchor.helper'
$script:fixtureOptions = @{ session_id=('a' * 32); generation=1; parent_pid=$PID; capture=$true; cast=$false }
$script:fixtureOptions | ConvertTo-Json | Set-Content -LiteralPath $Config -Encoding UTF8
$script:polls = 0
$script:launches = 0
$script:stops = 0
$script:parentClock = 0
$script:parentFixture = [PSCustomObject]@{ HasExited=$false }
$script:parentFixture | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
    param($Milliseconds)
    $script:parentClock++
    if ($script:parentClock -eq 3) {
        $script:fixtureOptions.generation = 2
        $script:fixtureOptions | ConvertTo-Json | Set-Content -LiteralPath $Config -Encoding UTF8
        (Get-Item -LiteralPath $Config).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(1)
    }
    return $script:parentClock -ge 5
}
function Get-Process { param($Id, $ErrorAction) return $script:parentFixture }
function Find-Adb { param($Configured) return 'fake-adb' }
function Select-Device { param($Requested) return 'fake-pico' }
function Send-Launch { param($Options) $script:launches++ }
function Send-Stop { param($Session) $script:stops++ }
function Start-UsbTransport { param($Options) }
function Start-UsbCast { param($Options) }
function Stop-UsbTransport { }
function Publish-UsbCast { param($Options, $State) }
function Invoke-Adb {
    param($AdbArguments, $Timeout, $AllowedExitCodes)
    if ($AdbArguments[1] -eq 'cat') {
        $script:polls++
        if ($script:polls -eq 1) { throw [IO.IOException]::new('status not ready') }
        return (@{ session_id=$script:fixtureOptions.session_id; state=$(if ($script:polls -eq 5) { 'permission' } else { 'started' }); message=$expected } | ConvertTo-Json)
    }
    if ($AdbArguments[1] -eq 'pidof') {
        if ($script:polls -eq 2) { return '' }
        return '123'
    }
    throw 'Unexpected mock ADB call'
}
try {
    $main = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[-1]
    . ([ScriptBlock]::Create($main.Extent.Text))
    if ($script:launches -ne 2) { throw "Expected initial launch and one new generation, got $script:launches" }
    if ($script:polls -ne 5 -or $script:stops -ne 1) { throw 'Watcher did not poll or clean up correctly' }
    $result = Get-Content -LiteralPath $Status -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.generation -ne 2 -or $result.state -ne 'stopped') { throw 'Watcher did not acknowledge the current generation' }
} finally {
    foreach ($path in @($Config, $Status)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $TaskFolder -ErrorAction SilentlyContinue
}
Write-Output 'PICO helper self-test passed: UTF-8 stdout/stderr, exit codes, watcher recovery, generations, cleanup'

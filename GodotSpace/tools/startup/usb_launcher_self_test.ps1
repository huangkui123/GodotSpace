$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'pico_helper.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([ScriptBlock]::Create($function.Extent.Text))
}
. (Join-Path $PSScriptRoot 'usb_transport.ps1')
$TaskFolder = Join-Path $env:TEMP "usb-launcher-test-$PID"
$null = New-Item -ItemType Directory -Path $TaskFolder -Force
$Package = 'com.picospatialanchor.helper'
$Component = "$Package/.ManagedLaunchActivity"
$script:Calls = @()
$script:ReverseListing = ''
$script:Payload = $null
function Invoke-Adb {
    param($AdbArguments, $Timeout, $AllowedExitCodes)
    $script:Calls += ,$AdbArguments
    $command = $AdbArguments -join ' '
    if ($command -eq 'devices') { return "List of devices attached`nUSB123`tdevice`n192.168.1.5:5555`tdevice" }
    if ($command -eq '-d get-serialno' -or $command -eq '-s USB123 shell getprop ro.serialno') { return 'USB123' }
    if ($command -match '^shell cmd package resolve-activity') { return $Component }
    if ($AdbArguments[0] -eq 'push') {
        $script:Payload = Get-Content -LiteralPath $AdbArguments[1] -Raw -Encoding UTF8 | ConvertFrom-Json
        return 'success'
    }
    if ($command -eq 'reverse --list') { return $script:ReverseListing }
    if ($command -match '^reverse --no-rebind|^reverse --remove|^shell mkdir|^shell am start') { return '' }
    throw "Unexpected ADB operation: $command"
}
try {
    if ((Select-Device '') -ne 'USB123') { throw 'Default selection must ignore wireless devices' }
    if ((Select-Device 'USB123') -ne 'USB123') { throw 'Explicit USB serial must work' }
    $rejected = $false
    try { $null = Select-Device '192.168.1.5:5555' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Wireless device must not silently replace USB' }
    Send-Launch @{ session_id=('a' * 32); capture=$true; cast=$true; server_ip='192.168.1.2' }
    if ($script:Payload.capture_host -ne '127.0.0.1' -or $script:Payload.server_host -ne '127.0.0.1' -or $script:Payload.cast -ne $false) {
        throw 'USB camera must use reverse destinations and must not start Wi-Fi Cast SDK'
    }
    $previous = $script:Calls.Count
    Send-Launch @{ capture=$false; cast=$true }
    if ($script:Calls.Count -ne $previous) { throw 'Cast-only does not need camera APK or its permissions' }
    $script:UsbState = @{ Reverse=@() }
    $script:ReverseListing = 'UsbFfs tcp:8789 tcp:8789'
    Add-UsbReverse 8789 8789
    if ($script:UsbState.Reverse.Count -ne 0) { throw 'Borrowed mappings must not become owned' }
    $rejected = $false
    try { Add-UsbReverse 8789 40000 } catch { $rejected = $true }
    if (-not $rejected) { throw 'Conflicting mappings must not be overwritten' }
    $script:ReverseListing = ''
    Add-UsbReverse 8787 40001
    if ($script:UsbState.Reverse.Count -ne 1) { throw 'New reverse mapping must have an owner' }
    $script:ReverseListing = "UsbFfs tcp:8787 tcp:40001`nUsbFfs tcp:8789 tcp:8789"
    Stop-UsbTransport
    $removed = @($script:Calls | Where-Object { $_[0] -eq 'reverse' -and $_[1] -eq '--remove' })
    if ($removed.Count -ne 1 -or $removed[0][2] -ne 'tcp:8787') { throw 'Cleanup must remove only owned mappings' }
    $script:UsbState = @{ Reverse=@(@{Remote='tcp:8787'; Local='tcp:40001'}) }
    $script:ReverseListing = 'UsbFfs tcp:8787 tcp:40002'
    $previous = $script:Calls.Count
    Stop-UsbTransport
    if (@($script:Calls | Select-Object -Skip $previous | Where-Object { $_[1] -eq '--remove' }).Count) { throw 'Cleanup must preserve mappings replaced by another owner' }
} finally {
    Remove-Item -LiteralPath $TaskFolder -ErrorAction SilentlyContinue
}
Write-Output 'USB launcher tests passed: device selection, loopback camera payload, cast-only, mapping conflicts and ownership cleanup'

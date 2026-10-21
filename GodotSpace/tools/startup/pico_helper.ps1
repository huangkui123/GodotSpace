param(
    [ValidateSet('Prepare','Start','Stop')][string]$Action = 'Start',
    [Parameter(Mandatory=$true)][string]$Config,
    [Parameter(Mandatory=$true)][string]$Status
)
$ErrorActionPreference = 'Stop'
$Package = 'com.picospatialanchor.helper'
$Component = "$Package/.ManagedLaunchActivity"
$TaskFolder = Split-Path -Parent $Config
$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$DeviceSerial = ''
$Adb = ''
$StatusGeneration = 0
. (Join-Path $PSScriptRoot 'usb_transport.ps1')

function Write-Status([string]$State, [string]$Message) {
    $value = @{ state=$State; message=$Message; generation=$StatusGeneration }
    $temporary = "$Status.$PID.tmp"
    $value | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Status -Force
}

function Quote-NativeArgument([string]$Value) {
    # CommandLineToArgvW quoting, including trailing backslashes and quotes.
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-Adb([string[]]$AdbArguments, [int]$Timeout = 15000, [int[]]$AllowedExitCodes = @(0)) {
    $all = @()
    if ($DeviceSerial) { $all += @('-s', $DeviceSerial) }
    $all += $AdbArguments
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Adb
    $info.Arguments = ($all | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Android emits UTF-8 even when Windows PowerShell uses a legacy code page.
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = [System.Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($Timeout)) {
        $process.Kill() # Only the exact adb client started above, never adb server.
        $process.Dispose()
        throw [TimeoutException]::new('ADB 操作超时，请检查 USB / 无线调试连接')
    }
    $output = $stdout.Result.Trim()
    $errorText = $stderr.Result.Trim()
    $code = $process.ExitCode
    $process.Dispose()
    if ($code -notin $AllowedExitCodes) { throw [IO.IOException]::new("ADB 调用失败：$errorText") }
    return $output
}

function Find-Adb([string]$Configured) {
    $candidates = @($Configured)
    $command = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    foreach ($sdk in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, (Join-Path $env:LOCALAPPDATA 'Android/Sdk'))) {
        if ($sdk) { $candidates += Join-Path $sdk 'platform-tools/adb.exe' }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw '未找到 ADB。请在设备设置填写 Android SDK/platform-tools/adb.exe 路径'
}

function Select-Device([string]$Requested) {
    if ($Requested -match ':|^adb-|^emulator-') { throw '默认使用 USB；请清空无线 ADB 地址，或填写 USB 设备序列号' }
    $listing = Invoke-Adb @('devices')
    $devices = @($listing -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\s*$' } |
        ForEach-Object { ($_ -split '\s+')[0] })
    if ($Requested) {
        if ($Requested -notin $devices) { throw '指定的 PICO 未连接或未授权，请检查头显内 USB 调试授权' }
        $hardwareSerial = Invoke-Adb @('-s', $Requested, 'shell', 'getprop', 'ro.serialno')
        if ($hardwareSerial -ne $Requested) { throw '所选设备不是 USB 连接，请填写 PICO USB 序列号' }
        return $Requested
    }
    try { return (Invoke-Adb @('-d', 'get-serialno')) }
    catch { throw '未找到唯一的 USB 设备。请连接数据线并授权；多设备时填写 PICO USB 序列号' }
}

function Start-Streaming([string]$Configured) {
    $candidates = @($Configured,
        (Join-Path $env:LOCALAPPDATA 'Programs/BusinessStreaming/BusinessStreaming.exe'),
        (Join-Path $env:ProgramFiles 'PICO Connect/Business Streaming/Business Streaming.exe'),
        (Join-Path $env:ProgramFiles 'BusinessStreaming/BusinessStreaming.exe'))
    if (-not $Configured) {
        Get-Process -Name 'Business Streaming','BusinessStreaming' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Path) { $candidates += $_.Path }
        }
    }
    if (-not $Configured) {
        foreach ($key in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -match 'Business.?Streaming'
            } | ForEach-Object {
                if ($_.InstallLocation) { $candidates += Join-Path $_.InstallLocation 'BusinessStreaming.exe' }
            }
        }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $name = [IO.Path]::GetFileNameWithoutExtension($candidate)
            if (-not (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $candidate -WindowStyle Hidden | Out-Null
            }
            break
        }
    }
    # Ask Android for the vendor's actual launch component; never guess an activity.
    foreach ($streamPackage in @('com.picoxr.bstreamassistant', 'com.picoxr.bstreamassistant2')) {
        $activity = Invoke-Adb @('shell', 'cmd', 'package', 'resolve-activity', '--brief', $streamPackage)
        $componentName = @($activity -split "`r?`n" | Where-Object { $_ -match '^[a-zA-Z0-9._]+/[a-zA-Z0-9._]+$' })
        if ($componentName.Count -eq 1) {
            $null = Invoke-Adb @('shell', 'am', 'start', '-n', $componentName[0])
            return
        }
    }
    throw '未找到头显 Business Streaming 入口，请确认已安装 2.2.0；Godot 仍可等待已有串流连接'
}

function Send-Stop([string]$Session) {
    $null = Invoke-Adb @('shell', 'am', 'start', '-n', $Component,
        '-a', "$Package.MANAGED_STOP", '--es', 'session_id', $Session)
}

function Send-Launch($Options) {
    if (-not [bool]$Options.capture) { return }
    $session = [string]$Options.session_id
    if ($session -notmatch '^[a-f0-9]{32}$') { throw '启动会话编号无效' }
    $activity = Invoke-Adb @('shell', 'cmd', 'package', 'resolve-activity', '--brief', '-n', $Component)
    if ($activity -notmatch 'ManagedLaunchActivity') {
        $apk = Join-Path $ProjectRoot 'companion_app/pico_spatial_anchor_helper/app/build/outputs/apk/debug/app-debug.apk'
        if (-not (Test-Path -LiteralPath $apk)) { throw '头显 helper 需要更新。请先构建 companion app，再点击重试采集 / 投屏' }
        $installed = Invoke-Adb @('install', '-r', $apk) 120000
        if ($installed -notmatch 'Success') { throw '更新 helper 失败，请检查应用签名和设备空间' }
    }
    # Camera PSA2 goes through adb reverse; the PC relay handles a remote
    # Server. Full composite video belongs to scrcpy, not PICO's Wi-Fi Cast SDK.
    $payload = @{ version=1; session_id=$session; capture_host='127.0.0.1'; server_host='127.0.0.1';
        capture=$true; cast=$false; cast_token='' }
    $transfer = Join-Path $TaskFolder "transfer-$session.json"
    $remoteDir = "/sdcard/Android/data/$Package/files"
    $remoteFile = "$remoteDir/launch-$session.json"
    try {
        [IO.File]::WriteAllText($transfer, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        $null = Invoke-Adb @('shell', 'mkdir', '-p', $remoteDir)
        $null = Invoke-Adb @('push', $transfer, $remoteFile)
        $result = Invoke-Adb @('shell', 'am', 'start', '-n', $Component, '--es', 'session_id', $session)
        if ($result -match 'Error:|Exception') { throw '头显拒绝启动 helper，请检查应用版本与权限' }
    } finally {
        if (Test-Path -LiteralPath $transfer) { Remove-Item -LiteralPath $transfer -Force }
    }
}

try {
    $options = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $StatusGeneration = [int]$options.generation
    $Adb = Find-Adb ([string]$options.adb_path)
    $DeviceSerial = Select-Device ([string]$options.device_serial)
    if ($Action -eq 'Prepare') {
        @{ device_serial=$DeviceSerial } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TaskFolder 'device.json') -Encoding UTF8
        Start-Streaming ([string]$options.streaming_path)
        Write-Status 'prepared' '已请求连接 PICO 串流；首次请在 Business Streaming 设置绑定电脑和自动连接'
    } elseif ($Action -eq 'Stop') {
        if ([bool]$options.capture) { Send-Stop ([string]$options.session_id) }
        Write-Status 'stopped' '已请求停止本次采集与投屏'
    } else {
        $parentProcess = Get-Process -Id ([int]$options.parent_pid) -ErrorAction Stop
        $lastWrite = [DateTime]::MinValue
        $launchFailed = $false
        while (-not $parentProcess.HasExited -and -not (Test-Path -LiteralPath (Join-Path $TaskFolder 'stop'))) {
            try {
                $modified = (Get-Item -LiteralPath $Config).LastWriteTimeUtc
                if ($modified -ne $lastWrite) {
                    $options = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
                    $StatusGeneration = [int]$options.generation
                    $lastWrite = $modified
                    Write-Status 'launching' '正在准备头显 helper，请稍候'
                    try {
                        Start-UsbTransport $options
                        Send-Launch $options
                        Start-UsbCast $options
                        $launchFailed = $false
                        Write-Status 'starting' 'helper 启动指令已发送；若首次使用，请在头显完成授权'
                    } catch {
                        $launchFailed = $true
                        if ($_.Exception -is [IO.IOException] -or $_.Exception -is [TimeoutException]) {
                            Write-Status 'waiting_device' $_.Exception.Message
                        } else {
                            Write-Status 'failed' $_.Exception.Message
                        }
                    }
                }
                if (-not $launchFailed -and [bool]$options.capture) {
                    $raw = Invoke-Adb @('shell', 'cat', "/sdcard/Android/data/$Package/files/managed-status.json")
                    $remote = $raw | ConvertFrom-Json
                    if ($remote.session_id -eq $options.session_id) {
                        Write-Status ([string]$remote.state) ([string]$remote.message)
                        if ($remote.state -eq 'started') {
                            # pidof exits 1 if absent. Let Godot's bounded stream
                            # watchdog recover, instead of reopening an activity every poll.
                            $processId = Invoke-Adb @('shell', 'pidof', $Package) 15000 @(0, 1)
                            if (-not $processId) { Write-Status 'worker_missing' '头显 helper 已退出，等待自动恢复' }
                        }
                    }
                }
                if (-not $launchFailed) {
                    Publish-UsbCast $options
                    if ([bool]$options.cast -and $script:UsbState.Bridge.Error) {
                        Write-Status 'worker_missing' ('USB 投屏已断开：' + $script:UsbState.Bridge.Error)
                    } elseif (-not [bool]$options.capture) {
                        Write-Status 'started' 'USB 投屏已启动，等待头显画面'
                    }
                }
            } catch {
                Write-Status 'waiting_device' $_.Exception.Message
                # A missing/partially written status file is not a launch failure.
                # Only a new Godot generation requests another launch.
            }
            if ($parentProcess.WaitForExit(3000)) { break }
        }
        try { Publish-UsbCast $options 'stopped' } catch { }
        Stop-UsbTransport
        if ([bool]$options.capture) { Send-Stop ([string]$options.session_id) }
        Write-Status 'stopped' '本次 XR 已退出，已停止采集与投屏'
    }
} catch {
    Write-Status 'failed' $_.Exception.Message
    exit 1
} finally {
    Stop-UsbTransport
}

# Dot-sourced by pico_helper.ps1. All device operations use its selected USB
# serial; mappings and encoder processes belong to this watcher only.
$script:UsbState = $null
$script:ScrcpyVersion = '5.0.1'
$script:ScrcpyHash = '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536'

function Get-ScrcpyServer {
    $server = Join-Path $PSScriptRoot '.runtime/scrcpy-server-5.0.1'
    if ($env:GODOTSPACE_SCRCPY_SERVER) { $server = $env:GODOTSPACE_SCRCPY_SERVER }
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
        if ($env:GODOTSPACE_SCRCPY_SERVER) { throw 'GODOTSPACE_SCRCPY_SERVER 指定的文件不存在' }
        Write-Status 'launching' '首次使用：正在下载 USB 投屏组件（scrcpy 5.0.1）'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $server) -Force
        $download = "$server.$PID.download"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/Genymobile/scrcpy/releases/download/v$script:ScrcpyVersion/scrcpy-server-v$script:ScrcpyVersion" -OutFile $download -TimeoutSec 60
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $script:ScrcpyHash) {
                throw 'USB 投屏组件校验失败，请重新下载官方 scrcpy 5.0.1 server'
            }
            Move-Item -LiteralPath $download -Destination $server -Force
        } finally { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force } }
    }
    if ((Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash.ToLowerInvariant() -ne $script:ScrcpyHash) {
        throw 'USB 投屏组件版本或 SHA-256 不匹配，需要官方 scrcpy 5.0.1 server'
    }
    return $server
}

function Add-UsbReverse([int]$RemotePort, [int]$LocalPort) {
    $existing = Invoke-Adb @('reverse', '--list')
    $remote = "tcp:$RemotePort"
    $local = "tcp:$LocalPort"
    $matching = @($existing -split "`r?`n" | Where-Object { ($_ -split '\s+')[1] -eq $remote })
    if ($matching.Count) {
        if (($matching[0] -split '\s+')[2] -eq $local) { return } # Borrow, never remove.
        throw "USB 端口 $RemotePort 已被其他转发占用；请结束旧采集会话后重试"
    }
    $null = Invoke-Adb @('reverse', '--no-rebind', $remote, $local)
    $script:UsbState.Reverse += @{ Remote=$remote; Local=$local }
}

function Stop-UsbTransport {
    $state = $script:UsbState
    $script:UsbState = $null
    if (-not $state) { return }
    if ($state.Bridge) { $state.Bridge.Dispose() }
    if ($state.Relay) { $state.Relay.Dispose() }
    # Closing the video socket terminates the matching Android encoder. Kill
    # only this adb shell client if it has not reaped itself yet.
    if ($state.Process) {
        if (-not $state.Process.WaitForExit(1500)) { $state.Process.Kill() }
        $state.Process.Dispose()
    }
    foreach ($mapping in $state.Reverse) {
        try {
            $listing = Invoke-Adb @('reverse', '--list') 2000
            if (@($listing -split "`r?`n" | Where-Object {
                $parts = $_ -split '\s+'
                $parts.Count -ge 3 -and $parts[1] -eq $mapping.Remote -and $parts[2] -eq $mapping.Local
            }).Count) { $null = Invoke-Adb @('reverse', '--remove', $mapping.Remote) 2000 }
        } catch { } # A disconnected USB transport has already lost its reverse mappings.
    }
    if ($state.ForwardPort) {
        try {
            $listing = Invoke-Adb @('forward', '--list') 2000
            if (@($listing -split "`r?`n" | Where-Object {
                $parts = $_ -split '\s+'
                $parts.Count -ge 3 -and $parts[0] -eq $DeviceSerial -and $parts[1] -eq "tcp:$($state.ForwardPort)" -and $parts[2] -eq "localabstract:$($state.Socket)"
            }).Count) { $null = Invoke-Adb @('forward', '--remove', "tcp:$($state.ForwardPort)") 2000 }
        } catch { }
    }
    if ($state.RemoteJar) {
        try { $null = Invoke-Adb @('shell', 'rm', '-f', $state.RemoteJar) 2000 } catch { }
    }
}

function Start-UsbTransport($Options) {
    if ([string]$Options.session_id -notmatch '^[a-f0-9]{32}$') { throw 'USB 启动会话编号无效' }
    if ([bool]$Options.cast -and [string]$Options.cast_token -notmatch '^[a-f0-9]{48}$') { throw 'USB 投屏会话凭据无效' }
    Stop-UsbTransport
    if (-not ('GodotSpace.Usb.CastBridge' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'usb_transport.cs')
    }
    $script:UsbState = @{ Reverse=@(); Relay=$null; Bridge=$null; Process=$null; ForwardPort=0; RemoteJar=''; Socket=''; Url='' }
    if ([bool]$Options.capture) {
        # Both helper destinations stay loopback on Android. The second one
        # relays to the Server PC, whether it is this PC or a wired LAN peer.
        $script:UsbState.Relay = New-Object GodotSpace.Usb.CameraRelay([string]$Options.server_ip, 8787)
        Add-UsbReverse 8787 $script:UsbState.Relay.Port
        Add-UsbReverse 8789 8789
    }
}

function Start-UsbCast($Options) {
    if (-not [bool]$Options.cast) { return }
    $server = Get-ScrcpyServer
    $id = '0' + ([string]$Options.session_id).Substring(0, 7)
    $script:UsbState.Socket = "scrcpy_$id"
    $script:UsbState.RemoteJar = "/data/local/tmp/godotspace-scrcpy-$($Options.session_id).jar"
    $null = Invoke-Adb @('push', $server, $script:UsbState.RemoteJar)
    $port = Invoke-Adb @('forward', 'tcp:0', "localabstract:$($script:UsbState.Socket)")
    $script:UsbState.ForwardPort = [int]$port
    $size = Invoke-Adb @('shell', 'wm', 'size')
    # Respect Android's active override if present, otherwise use physical size.
    if ($size -notmatch 'Override size:\s*(\d+)x(\d+)' -and $size -notmatch 'Physical size:\s*(\d+)x(\d+)') { throw '无法读取 PICO 显示尺寸' }
    $width = [int]$Matches[1]; $height = [int]$Matches[2]
    if ($width -ne 2 * $height) { throw "当前显示尺寸 ${width}x${height} 不是 PICO 双目布局，无法自动裁切单眼投屏" }
    $crop = "${height}:${height}:0:0"
    $arguments = @('-s', $DeviceSerial, 'shell', "CLASSPATH=$($script:UsbState.RemoteJar)",
        'app_process', '/', 'com.genymobile.scrcpy.Server', $script:ScrcpyVersion,
        "scid=$id", 'tunnel_forward=true', 'audio=false', 'control=false', 'power_on=false',
        'video_codec=h264', 'max_size=1280', 'max_fps=30', 'video_bit_rate=6000000',
        'video_codec_options=i-frame-interval=1', "crop=$crop", 'send_device_meta=false',
        'send_stream_meta=false', 'send_dummy_byte=false', 'send_frame_meta=true')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Adb
    $info.Arguments = ($arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $script:UsbState.Process = [Diagnostics.Process]::Start($info)
    $script:UsbState.Output = $script:UsbState.Process.StandardOutput.ReadToEndAsync()
    $script:UsbState.Errors = $script:UsbState.Process.StandardError.ReadToEndAsync()
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ($script:UsbState.Process.HasExited) { throw '头显 USB 投屏编码器启动失败，请确认 PICO 系统版本支持 scrcpy 5.0.1' }
        $sockets = Invoke-Adb @('shell', 'cat', '/proc/net/unix')
        if ($sockets.Contains('@' + $script:UsbState.Socket)) { $ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { throw [TimeoutException]::new('等待 USB 投屏编码器超时') }
    $remoteServer = [string]$Options.server_ip -notin @('127.0.0.1', 'localhost', '::1')
    $address = '127.0.0.1'
    if ($remoteServer) {
        $route = New-Object Net.Sockets.UdpClient
        try { $route.Connect([string]$Options.server_ip, 42069); $address = $route.Client.LocalEndPoint.Address.ToString() }
        finally { $route.Dispose() }
    }
    # Viewers receive only a separate media token, never the Server's control
    # credential. A Ground viewer must not gain permission to publish sessions.
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $tokenBytes = New-Object byte[] 24
    try { $random.GetBytes($tokenBytes) } finally { $random.Dispose() }
    $mediaToken = ([BitConverter]::ToString($tokenBytes)).Replace('-', '').ToLowerInvariant()
    $script:UsbState.Bridge = New-Object GodotSpace.Usb.CastBridge($script:UsbState.ForwardPort, $mediaToken, $remoteServer)
    $script:UsbState.Url = "http://${address}:$($script:UsbState.Bridge.Port)/$mediaToken/video.ts"
}

function Publish-UsbCast($Options, [string]$State = 'live') {
    if (-not [bool]$Options.cast) { return }
    if ($State -eq 'live' -and (-not $script:UsbState -or -not $script:UsbState.Bridge.IsLive)) { return }
    $payload = @{ type='pico_cast_session'; version=1; state=$State; authorization=[string]$Options.cast_token;
        transport='usb'; stream_url=$(if ($State -eq 'live') { $script:UsbState.Url } else { '' }); device_name='PICO USB'; eye='left' }
    $client = New-Object Net.Sockets.TcpClient
    try {
        if (-not $client.ConnectAsync([string]$Options.server_ip, 8788).Wait(2000)) { throw [TimeoutException]::new('等待 Server 投屏控制连接') }
        $client.SendTimeout = 2000
        $bytes = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress) + "`n")
        $client.GetStream().Write($bytes, 0, $bytes.Length)
    } finally { $client.Dispose() }
}

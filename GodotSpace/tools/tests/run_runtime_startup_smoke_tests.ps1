param(
    [string]$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$GamePort = 42069
$PeerScene = 'res://Assets/ARSpace/Scenes/Tests/RuntimeStartupSmokePeer.tscn'
$Processes = @()
$TemporaryFiles = @()

function New-SmokeProcess {
    param(
        [string]$Name,
        [string[]]$Arguments
    )

    $StdOutPath = [System.IO.Path]::GetTempFileName()
    $StdErrPath = [System.IO.Path]::GetTempFileName()
    $script:TemporaryFiles += $StdOutPath
    $script:TemporaryFiles += $StdErrPath
    $Process = Start-Process -FilePath $Godot `
        -ArgumentList $Arguments `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput $StdOutPath `
        -RedirectStandardError $StdErrPath
    # Retain the native handle so ExitCode remains observable after a fast exit.
    $null = $Process.Handle
    $Record = [pscustomobject]@{
        Name = $Name
        Process = $Process
        StdOutPath = $StdOutPath
        StdErrPath = $StdErrPath
    }
    $script:Processes += $Record
    return $Record
}

function Wait-SmokeProcesses {
    param(
        [object[]]$Records,
        [int]$Timeout
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $Deadline) {
        $AllExited = $true
        foreach ($Record in $Records) {
            if (-not $Record.Process.HasExited) {
                $AllExited = $false
                break
            }
        }
        if ($AllExited) {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    $RunningNames = @(
        $Records |
            Where-Object { -not $_.Process.HasExited } |
            ForEach-Object { $_.Name }
    )
    throw "Runtime startup smoke process timeout: $($RunningNames -join ', ')"
}

function Wait-SmokeLogToken {
    param(
        [object]$Record,
        [string]$Token,
        [int]$Timeout
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds($Timeout)
    while ([DateTime]::UtcNow -lt $Deadline) {
        $StdOut = Get-Content -LiteralPath $Record.StdOutPath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrEmpty($StdOut) -and $StdOut.Contains($Token)) {
            return
        }
        if ($Record.Process.HasExited) {
            $StdErr = Get-Content -LiteralPath $Record.StdErrPath -Raw -ErrorAction SilentlyContinue
            throw "Runtime startup smoke process $($Record.Name) exited before emitting $Token.`n$StdOut`n$StdErr"
        }
        Start-Sleep -Milliseconds 100
    }

    throw "Runtime startup smoke process $($Record.Name) timed out before emitting $Token."
}

function Assert-SmokeProcess {
    param(
        [object]$Record,
        [string]$PassToken
    )

    $Record.Process.WaitForExit()
    $Record.Process.Refresh()
    $StdOut = Get-Content -LiteralPath $Record.StdOutPath -Raw -ErrorAction SilentlyContinue
    $StdErr = Get-Content -LiteralPath $Record.StdErrPath -Raw -ErrorAction SilentlyContinue
    Write-Host "[$($Record.Name)]"
    if (-not [string]::IsNullOrWhiteSpace($StdOut)) {
        Write-Host $StdOut.TrimEnd()
    }
    if (-not [string]::IsNullOrWhiteSpace($StdErr)) {
        Write-Host $StdErr.TrimEnd()
    }
    $ExitCode = $Record.Process.ExitCode
    if ($null -eq $ExitCode) {
        throw "Runtime startup smoke process $($Record.Name) did not expose an exit code."
    }
    if ([int]$ExitCode -ne 0) {
        throw "Runtime startup smoke process $($Record.Name) failed with exit code $ExitCode."
    }
    $PassCount = [regex]::Matches($StdOut, [regex]::Escape($PassToken)).Count
    if ($PassCount -ne 1) {
        throw "Runtime startup smoke process $($Record.Name) emitted $PassToken $PassCount times; expected exactly once."
    }
    $CombinedOutput = "$StdOut`n$StdErr"
    $FailurePatterns = @(
        'SCRIPT ERROR:',
        'Parse Error:',
        'Failed to load script',
        'RUNTIME_STARTUP_SMOKE_[A-Z_]+:'
    )
    foreach ($Pattern in $FailurePatterns) {
        if ($CombinedOutput -match $Pattern) {
            throw "Runtime startup smoke process $($Record.Name) emitted a failure pattern: $Pattern"
        }
    }
    $OutputWithoutKnownHeadlessNoise = $CombinedOutput `
        -replace [regex]::Escape('ERROR: SubViewport is not a child of a SubViewportContainer. get_screen_transform doesn''t return the actual screen position.'), '' `
        -replace [regex]::Escape('ERROR: Parameter "material" is null.'), '' `
        -replace [regex]::Escape('ERROR: Parameter "m" is null.'), ''
    if ($Record.Name -eq 'shutdown_client') {
        # This custom engine renders push_warning() as an ERROR-prefixed line.
        $OutputWithoutKnownHeadlessNoise = $OutputWithoutKnownHeadlessNoise `
            -replace [regex]::Escape('ERROR: Ground Server disconnected. Returning to the start menu.'), ''
    }
    if ($OutputWithoutKnownHeadlessNoise.Contains('ERROR:')) {
        throw "Runtime startup smoke process $($Record.Name) emitted an unexpected Godot error."
    }
}

function Assert-GamePortAvailable {
    $Probe = $null
    try {
        $Probe = [System.Net.Sockets.UdpClient]::new($GamePort)
    }
    catch [System.Net.Sockets.SocketException] {
        throw "Runtime startup smoke requires UDP port $GamePort, but it is already in use."
    }
    finally {
        if ($null -ne $Probe) {
            $Probe.Dispose()
        }
    }
}

try {
    if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
        throw "Godot executable was not found: $Godot"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Project 'project.godot') -PathType Leaf)) {
        throw "Godot project was not found: $Project"
    }

    Assert-GamePortAvailable
    $QuotedProject = '"' + $Project.Replace('"', '\"') + '"'

    $Server = New-SmokeProcess -Name 'pc_server' -Arguments @(
        '--headless',
        '--path', $QuotedProject,
        $PeerScene,
        '--',
        '--runtime-startup-smoke-role=server',
        '--voice-role=server'
    )
    Wait-SmokeLogToken -Record $Server -Token 'RUNTIME_STARTUP_SMOKE_SERVER READY' -Timeout $TimeoutSeconds

    $TestClient = New-SmokeProcess -Name 'test_client' -Arguments @(
        '--headless',
        '--path', $QuotedProject,
        $PeerScene,
        '--',
        '--runtime-startup-smoke-role=test_client',
        '--testmode',
        '--voice-role=client',
        '--server-ip=127.0.0.1'
    )
    Wait-SmokeProcesses -Records @($Server, $TestClient) -Timeout $TimeoutSeconds
    Assert-SmokeProcess -Record $Server -PassToken 'RUNTIME_STARTUP_SMOKE_SERVER PASS'
    Assert-SmokeProcess -Record $TestClient -PassToken 'RUNTIME_STARTUP_SMOKE_TEST_CLIENT PASS'

    $XrConfig = New-SmokeProcess -Name 'xr_client_config' -Arguments @(
        '--headless',
        '--path', $QuotedProject,
        $PeerScene,
        '--',
        '--runtime-startup-smoke-role=xr_config',
        '--xr-mode', 'on',
        '--xr-client',
        '--voice-role=client'
    )
    Wait-SmokeProcesses -Records @($XrConfig) -Timeout $TimeoutSeconds
    Assert-SmokeProcess -Record $XrConfig -PassToken 'RUNTIME_STARTUP_SMOKE_XR_CONFIG PASS'

    Assert-GamePortAvailable
    $ShutdownServer = New-SmokeProcess -Name 'shutdown_server' -Arguments @(
        '--headless',
        '--path', $QuotedProject,
        $PeerScene,
        '--',
        '--runtime-startup-smoke-role=shutdown_server',
        '--voice-role=server'
    )
    Wait-SmokeLogToken `
        -Record $ShutdownServer `
        -Token 'RUNTIME_STARTUP_SMOKE_SHUTDOWN_SERVER READY' `
        -Timeout $TimeoutSeconds

    $ShutdownClient = New-SmokeProcess -Name 'shutdown_client' -Arguments @(
        '--headless',
        '--path', $QuotedProject,
        $PeerScene,
        '--',
        '--runtime-startup-smoke-role=shutdown_client',
        '--testmode',
        '--voice-role=client',
        '--server-ip=127.0.0.1'
    )
    Wait-SmokeProcesses -Records @($ShutdownServer, $ShutdownClient) -Timeout $TimeoutSeconds
    Assert-SmokeProcess `
        -Record $ShutdownServer `
        -PassToken 'RUNTIME_STARTUP_SMOKE_SHUTDOWN_SERVER PASS'
    Assert-SmokeProcess `
        -Record $ShutdownClient `
        -PassToken 'RUNTIME_STARTUP_SMOKE_SHUTDOWN_CLIENT PASS'

    Write-Host 'All runtime startup smoke tests passed.'
}
finally {
    foreach ($Record in $Processes) {
        if ($null -ne $Record.Process -and -not $Record.Process.HasExited) {
            Stop-Process -Id $Record.Process.Id -Force -ErrorAction SilentlyContinue
            $Record.Process.WaitForExit(5000) | Out-Null
        }
        if ($null -ne $Record.Process) {
            $Record.Process.Dispose()
        }
    }
    foreach ($TemporaryFile in $TemporaryFiles) {
        if (Test-Path -LiteralPath $TemporaryFile) {
            Remove-Item -LiteralPath $TemporaryFile -Force -ErrorAction SilentlyContinue
        }
    }
}

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
    if ($null -ne $ExitCode -and [int]$ExitCode -ne 0) {
        throw "Runtime startup smoke process $($Record.Name) failed with exit code $ExitCode."
    }
    if (-not $StdOut.Contains($PassToken)) {
        throw "Runtime startup smoke process $($Record.Name) did not emit $PassToken."
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
    Start-Sleep -Milliseconds 750
    if ($Server.Process.HasExited) {
        Assert-SmokeProcess -Record $Server -PassToken 'RUNTIME_STARTUP_SMOKE_SERVER PASS'
    }

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

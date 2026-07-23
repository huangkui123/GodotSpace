param(
    [string]$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$PeerScene = 'res://Assets/ARSpace/Scenes/Tests/CollaborationMultiprocessPeer.tscn'
$Jobs = @()

if ($Port -eq 0) {
    foreach ($Candidate in 43280..43299) {
        $Probe = $null
        try {
            $Probe = [System.Net.Sockets.UdpClient]::new($Candidate)
            $Port = $Candidate
            break
        }
        catch [System.Net.Sockets.SocketException] {
            continue
        }
        finally {
            if ($null -ne $Probe) {
                $Probe.Dispose()
            }
        }
    }
}
if ($Port -lt 43200 -or $Port -gt 43299) {
    throw "Collaboration multiprocess test requires an available UDP port in the 432xx range. Selected: $Port"
}
Write-Host "Using collaboration test port $Port"

function Start-CollaborationPeer {
    param([string]$Role, [string]$VoiceRole)
    return Start-Job -ScriptBlock {
        param($GodotPath, $ProjectPath, $ScenePath, $PeerRole, $PeerVoiceRole, $PeerPort)
        $ModeArgument = switch ($PeerRole) {
            'server' { '--testmode' }
            'ground_client' { '--ground-vr-client' }
            'sky_client' { '--testmode' }
            'sky_candidate' { '--testmode' }
            default { throw "Unknown collaboration peer role: $PeerRole" }
        }
        $Lines = & $GodotPath --headless --path $ProjectPath $ScenePath -- `
            "--collab-process-role=$PeerRole" `
            "--collab-process-port=$PeerPort" `
            $ModeArgument `
            "--voice-role=$PeerVoiceRole" 2>&1
        [pscustomobject]@{
            Role = $PeerRole
            ExitCode = $LASTEXITCODE
            Output = ($Lines -join [Environment]::NewLine)
        }
    } -ArgumentList $Godot, $Project, $PeerScene, $Role, $VoiceRole, $Port
}

try {
    $Jobs += Start-CollaborationPeer -Role 'server' -VoiceRole 'server'
    Start-Sleep -Milliseconds 750
    $Jobs += Start-CollaborationPeer -Role 'ground_client' -VoiceRole 'client'
    Start-Sleep -Milliseconds 1250
    $Jobs += Start-CollaborationPeer -Role 'sky_client' -VoiceRole 'client'
    Start-Sleep -Milliseconds 750
    $Jobs += Start-CollaborationPeer -Role 'sky_candidate' -VoiceRole 'client'

    $null = Wait-Job -Job $Jobs -Timeout 120
    $Results = @()
    foreach ($Job in $Jobs) {
        if ($Job.State -ne 'Completed') {
            throw "Collaboration peer job did not complete: $($Job.Id) state=$($Job.State)"
        }
        $Results += Receive-Job -Job $Job
    }

    $FailedRoles = @()
    foreach ($Result in $Results) {
		Write-Host "[$($Result.Role)]"
		Write-Host $Result.Output
		if ([int]$Result.ExitCode -ne 0) {
			$FailedRoles += "$($Result.Role)($($Result.ExitCode))"
		}
		$ExpectedSentinel = "COLLABORATION_MULTIPROCESS_$($Result.Role.ToUpper()) PASS"
		if (-not $Result.Output.Contains($ExpectedSentinel)) {
			$FailedRoles += "$($Result.Role)(missing PASS sentinel)"
		}
		if ($Result.Output.Contains('previously freed')) {
			$FailedRoles += "$($Result.Role)(stale XR Tools reference)"
		}
	}
	if ($FailedRoles.Count -gt 0) {
		throw "Collaboration multiprocess peers failed: $($FailedRoles -join ', ')"
	}
    Write-Host 'All collaboration multiprocess peers passed.'
}
finally {
    foreach ($Job in $Jobs) {
        if ($Job.State -eq 'Running') {
            Stop-Job -Job $Job
        }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

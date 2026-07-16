param(
    [string]$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$Port = 43195
)

$ErrorActionPreference = 'Stop'
$PeerScene = 'res://Assets/ARSpace/Scenes/Tests/CollaborationMultiprocessPeer.tscn'
$Jobs = @()

function Start-CollaborationPeer {
    param([string]$Role, [string]$VoiceRole)
    return Start-Job -ScriptBlock {
        param($GodotPath, $ProjectPath, $ScenePath, $PeerRole, $PeerVoiceRole, $PeerPort)
        $Lines = & $GodotPath --headless --path $ProjectPath $ScenePath -- `
            "--collab-process-role=$PeerRole" `
            "--collab-process-port=$PeerPort" `
            '--testmode' `
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
    $Jobs += Start-CollaborationPeer -Role 'first_client' -VoiceRole 'client'
    Start-Sleep -Milliseconds 1250
    $Jobs += Start-CollaborationPeer -Role 'late_client' -VoiceRole 'client'

    $null = Wait-Job -Job $Jobs -Timeout 45
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

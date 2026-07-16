param(
    [string]$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$PeerScene = 'res://Assets/ARSpace/Scenes/Tests/CollaborationMultiprocessPeer.tscn'
function Get-CollaborationPort {
	param([int]$RequestedPort, [int]$StartPort = 43280, [int[]]$ExcludedPorts = @())
	if ($RequestedPort -ne 0) {
		return $RequestedPort
	}
    foreach ($Candidate in $StartPort..43299) {
		if ($Candidate -in $ExcludedPorts) {
			continue
		}
        $Probe = $null
        try {
            $Probe = [System.Net.Sockets.UdpClient]::new($Candidate)
			return $Candidate
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
	return 0
}

function Wait-ControlMarker {
	param([string]$ControlDirectory, [string]$MarkerName, [int]$TimeoutSeconds = 12)
	$MarkerPath = Join-Path $ControlDirectory $MarkerName
	$Deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	while ([DateTime]::UtcNow -lt $Deadline) {
		if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
			return
		}
		Start-Sleep -Milliseconds 50
	}
	throw "Timed out waiting for collaboration control marker: $MarkerName"
}

function Start-CollaborationPeer {
	param(
		[string]$Role,
		[string]$VoiceRole,
		[string]$Scenario,
		[int]$ScenarioPort,
		[string]$ControlDirectory
	)
    return Start-Job -ScriptBlock {
		param($GodotPath, $ProjectPath, $ScenePath, $PeerRole, $PeerVoiceRole, $PeerScenario, $PeerPort, $PeerControlDirectory)
        $ModeArgument = switch ($PeerRole) {
            'server' { '--testmode' }
            'ground_client' { '--ground-vr-client' }
			'competing_ground_client' { '--ground-vr-client' }
            'astronaut_client' { '--testmode' }
            default { throw "Unknown collaboration peer role: $PeerRole" }
        }
        $Lines = & $GodotPath --headless --path $ProjectPath $ScenePath -- `
            "--collab-process-role=$PeerRole" `
			"--collab-process-port=$PeerPort" `
			"--collab-process-scenario=$PeerScenario" `
			"--collab-control-dir=$PeerControlDirectory" `
            $ModeArgument `
            "--voice-role=$PeerVoiceRole" 2>&1
        [pscustomobject]@{
            Role = $PeerRole
            ExitCode = $LASTEXITCODE
            Output = ($Lines -join [Environment]::NewLine)
        }
	} -ArgumentList $Godot, $Project, $PeerScene, $Role, $VoiceRole, $Scenario, $ScenarioPort, $ControlDirectory
}

function Invoke-CollaborationScenario {
	param([string]$Scenario, [string[]]$Roles, [int]$ScenarioPort)
	$Jobs = @()
	$ControlDirectory = Join-Path ([IO.Path]::GetTempPath()) ("godotspace-collaboration-{0}" -f [Guid]::NewGuid().ToString('N'))
	$null = New-Item -ItemType Directory -Path $ControlDirectory
	try {
		Write-Host "Running collaboration scenario '$Scenario' on port $ScenarioPort"
		$Jobs += Start-CollaborationPeer -Role $Roles[0] -VoiceRole 'server' -Scenario $Scenario `
			-ScenarioPort $ScenarioPort -ControlDirectory $ControlDirectory
		Wait-ControlMarker -ControlDirectory $ControlDirectory -MarkerName 'server.ready'

		$Jobs += Start-CollaborationPeer -Role $Roles[1] -VoiceRole 'client' -Scenario $Scenario `
			-ScenarioPort $ScenarioPort -ControlDirectory $ControlDirectory
		Wait-ControlMarker -ControlDirectory $ControlDirectory -MarkerName 'first_client.ready'

		$Jobs += Start-CollaborationPeer -Role $Roles[2] -VoiceRole 'client' -Scenario $Scenario `
			-ScenarioPort $ScenarioPort -ControlDirectory $ControlDirectory

		$null = Wait-Job -Job $Jobs -Timeout 60
		$Results = @()
		foreach ($Job in $Jobs) {
			if ($Job.State -ne 'Completed') {
				throw "Collaboration peer job did not complete: $($Job.Id) state=$($Job.State)"
			}
			$Results += Receive-Job -Job $Job
		}

		$FailedRoles = @()
		foreach ($Result in $Results) {
			Write-Host "[$Scenario/$($Result.Role)]"
			Write-Host $Result.Output
			if ([int]$Result.ExitCode -ne 0) {
				$FailedRoles += "$($Result.Role)($($Result.ExitCode))"
			}
			$ExpectedPass = "COLLABORATION_MULTIPROCESS_$($Result.Role.ToUpperInvariant()) PASS"
			$PassCount = [regex]::Matches($Result.Output, [regex]::Escape($ExpectedPass)).Count
			if ($PassCount -ne 1) {
				$FailedRoles += "$($Result.Role)(PASS token count $PassCount)"
			}
			$OutputWithoutKnownHeadlessNoise = $Result.Output.Replace('ERROR: Parameter "m" is null.', '')
			if ($OutputWithoutKnownHeadlessNoise.Contains('ERROR:')) {
				$FailedRoles += "$($Result.Role)(unexpected Godot error)"
			}
			if ($Result.Output.Contains('previously freed')) {
				$FailedRoles += "$($Result.Role)(stale XR Tools reference)"
			}
		}
		if ($FailedRoles.Count -gt 0) {
			throw "Collaboration scenario '$Scenario' failed: $($FailedRoles -join ', ')"
		}
	}
	finally {
		foreach ($Job in $Jobs) {
			if ($Job.State -eq 'Running') {
				Stop-Job -Job $Job
			}
			Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
		}
		$ResolvedControlDirectory = [IO.Path]::GetFullPath($ControlDirectory)
		$ResolvedTempDirectory = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
		if (-not $ResolvedControlDirectory.StartsWith($ResolvedTempDirectory, [StringComparison]::OrdinalIgnoreCase)) {
			throw "Refusing to remove control directory outside the system temp directory: $ResolvedControlDirectory"
		}
		if (Test-Path -LiteralPath $ResolvedControlDirectory) {
			Remove-Item -LiteralPath $ResolvedControlDirectory -Recurse -Force
		}
	}
}

$ScenarioDefinitions = @(
	@{ Name = 'baseline'; Roles = @('server', 'ground_client', 'astronaut_client') },
	@{ Name = 'astronaut_first'; Roles = @('server', 'astronaut_client', 'ground_client') },
	@{ Name = 'ground_contention'; Roles = @('server', 'ground_client', 'competing_ground_client') }
)

$AllocatedPorts = @()
for ($ScenarioIndex = 0; $ScenarioIndex -lt $ScenarioDefinitions.Count; $ScenarioIndex++) {
	$Definition = $ScenarioDefinitions[$ScenarioIndex]
	$RequestedPort = if ($Port -eq 0) { 0 } else { $Port + $ScenarioIndex }
	$ScenarioPort = Get-CollaborationPort -RequestedPort $RequestedPort `
		-StartPort (43280 + $ScenarioIndex) -ExcludedPorts $AllocatedPorts
	if ($ScenarioPort -lt 43200 -or $ScenarioPort -gt 43299) {
		throw "Collaboration scenario requires an available UDP port in the 432xx range. Selected: $ScenarioPort"
	}
	$AllocatedPorts += $ScenarioPort
	Invoke-CollaborationScenario -Scenario $Definition.Name -Roles $Definition.Roles -ScenarioPort $ScenarioPort
	Start-Sleep -Milliseconds 250
}

Write-Host 'All collaboration multiprocess scenarios passed.'

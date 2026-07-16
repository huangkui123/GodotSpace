param(
    [string]$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

$ScriptTests = @(
    'res://Assets/ARSpace/Scripts/runtime_profile_self_test.gd',
    'res://Assets/ARSpace/Scripts/shared_space_alignment_self_test.gd',
    'res://Assets/ARSpace/Scripts/SpatialCalibration/shared_space_contract_self_test.gd',
    'res://Assets/ARSpace/Scripts/SpatialCalibration/spatial_calibration_state_network_self_test.gd',
    'res://Assets/ARSpace/Scripts/runtime_mode_integration_self_test.gd',
    'res://Assets/ARSpace/Scripts/Network/network_startup_recovery_self_test.gd',
    'res://Assets/ARSpace/Scripts/Network/collaboration_state_self_test.gd',
    'res://Assets/ARSpace/Scripts/Network/collaboration_state_network_self_test.gd',
    'res://Assets/ARSpace/Scripts/Network/peer_role_registry_self_test.gd',
    'res://Assets/ARSpace/Scripts/Network/peer_role_network_self_test.gd',
    'res://Assets/ARSpace/Scripts/Network/voice_dictation_self_test.gd',
	'res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_state_self_test.gd',
	'res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_self_test.gd',
	'res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_adapter_self_test.gd',
	'res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_registry_network_self_test.gd',
	'res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_migration_self_test.gd',
    'res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_self_test.gd',
    'res://Assets/ARSpace/Scripts/VirtualAnnotation/virtual_annotation_network_self_test.gd',
    'res://Assets/ARSpace/Scripts/collaboration_feature_self_test.gd'
)

$SceneTests = @(
    'res://Assets/ARSpace/Scenes/Tests/PlayerPresenceSelfTest.tscn',
    'res://Assets/ARSpace/Scenes/Tests/PlayerNetworkSelfTest.tscn'
)

foreach ($Test in $ScriptTests) {
    Write-Host "Running $Test"
    & $Godot --headless --path $Project --script $Test
    if ($LASTEXITCODE -ne 0) {
        throw "Godot self-test failed: $Test"
    }
}

foreach ($Test in $SceneTests) {
    Write-Host "Running $Test"
    & $Godot --headless --path $Project $Test --quit-after 1800
    if ($LASTEXITCODE -ne 0) {
        throw "Godot scene self-test failed: $Test"
    }
}

$MultiprocessTest = Join-Path $PSScriptRoot 'run_collaboration_multiprocess_self_test.ps1'
Write-Host 'Running collaboration multiprocess server/client/reconnect test'
& $MultiprocessTest -Godot $Godot -Project $Project
if ($LASTEXITCODE -ne 0) {
    throw 'Godot collaboration multiprocess self-test failed'
}

Write-Host 'All collaboration self-tests passed.'

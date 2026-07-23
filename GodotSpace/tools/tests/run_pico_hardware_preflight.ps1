param(
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-File {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [long]$MinimumBytes = 1
    )

    $Path = Join-Path $Project $RelativePath
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required PICO preflight file is missing: $RelativePath"
    }
    if ((Get-Item -LiteralPath $Path).Length -lt $MinimumBytes) {
        throw "Required PICO preflight file is unexpectedly small: $RelativePath"
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not $Text.Contains($Expected)) {
        throw "$Context is missing '$Expected'."
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $Project 'project.godot') -PathType Leaf)) {
    throw "Godot project.godot was not found under: $Project"
}

$VendorFiles = @(
    'addons\godotopenxrvendors\plugin.gdextension',
    'addons\godotopenxrvendors\pico\LICENSE',
    'addons\godotopenxrvendors\.bin\android\debug\godotopenxr-pico-debug.aar',
    'addons\godotopenxrvendors\.bin\android\release\godotopenxr-pico-release.aar',
    'addons\godotopenxrvendors\.bin\android\template_debug\arm64\libgodotopenxrvendors.so',
    'addons\godotopenxrvendors\.bin\android\template_release\arm64\libgodotopenxrvendors.so',
    'addons\godotopenxrvendors\.bin\windows\template_debug\x86_64\libgodotopenxrvendors.dll',
    'addons\godotopenxrvendors\.bin\windows\template_release\x86_64\libgodotopenxrvendors.dll'
)
foreach ($RelativePath in $VendorFiles) {
    Assert-File -RelativePath $RelativePath -MinimumBytes 128
}

$VendorDescriptor = Get-Content -Raw -LiteralPath (Join-Path $Project 'addons\godotopenxrvendors\plugin.gdextension')
Assert-Contains $VendorDescriptor 'compatibility_minimum = "4.4"' 'Godot OpenXR Vendors descriptor'
Assert-Contains $VendorDescriptor 'android_aar_plugin = true' 'Godot OpenXR Vendors descriptor'

$TemporaryVendorLibraries = @(
    Get-ChildItem -LiteralPath (Join-Path $Project 'addons\godotopenxrvendors') -Recurse -File |
        Where-Object { $_.Name.StartsWith('~') }
)
if ($TemporaryVendorLibraries.Count -gt 0) {
    throw "Temporary OpenXR vendor libraries must not be packaged: $($TemporaryVendorLibraries.FullName -join ', ')"
}

$ExportConfig = Get-Content -Raw -LiteralPath (Join-Path $Project 'export_presets.cfg')
$PresetMatch = [regex]::Match($ExportConfig, '(?s)\[preset\.0\](.*?)(?=\[preset\.1\])')
if (-not $PresetMatch.Success) {
    throw 'Android PICO export preset must remain preset 0.'
}
$PicoPreset = $PresetMatch.Value
$PresetRequirements = @(
    'name="Android PICO"',
    'platform="Android"',
    'runnable=true',
    'export_path="Dabao/GodotSpace-PICO.apk"',
    'gradle_build/use_gradle_build=true',
    'architectures/arm64-v8a=true',
    'xr_features/xr_mode=1',
    'xr_features/enable_pico_plugin=true',
    'permissions/internet=true',
    'permissions/record_audio=true',
    'package/unique_name="com.yaoling.godotspace"'
)
foreach ($Requirement in $PresetRequirements) {
    Assert-Contains $PicoPreset $Requirement 'Android PICO export preset'
}

$ActionMap = Get-Content -Raw -LiteralPath (Join-Path $Project 'openxr_action_map.tres')
$PicoBindings = @(
    '/interaction_profiles/bytedance/pico4_controller',
    '/user/hand/left/input/aim/pose',
    '/user/hand/right/input/aim/pose',
    '/user/hand/left/input/grip/pose',
    '/user/hand/right/input/grip/pose',
    '/user/hand/left/input/x/click',
    '/user/hand/left/input/y/click',
    '/user/hand/right/input/a/click',
    '/user/hand/right/input/b/click',
    '/user/hand/left/input/trigger/value',
    '/user/hand/right/input/squeeze/value',
    '/user/hand/left/input/thumbstick',
    '/user/hand/right/output/haptic'
)
foreach ($Binding in $PicoBindings) {
    Assert-Contains $ActionMap $Binding 'PICO 4 OpenXR action map'
}

$PlayerXrScene = Get-Content -Raw -LiteralPath (Join-Path $Project 'Assets\ARSpace\Scenes\Player_XR.tscn')
Assert-Contains $PlayerXrScene 'name="HeadGazePointer"' 'PICO XR player scene'
Assert-Contains $PlayerXrScene 'follow_active_controller = false' 'PICO head-gaze pointer anchoring'
$XrInputRouter = Get-Content -Raw -LiteralPath (Join-Path $Project 'Assets\ARSpace\Characters\Astronaut\xr_input_router.gd')
Assert-Contains $XrInputRouter '_requested_input_mode' 'PICO tracking fallback recovery'
Assert-Contains $XrInputRouter 'SELECT_PRESS_THRESHOLD: float = 0.65' 'PICO analog trigger press threshold'
Assert-Contains $XrInputRouter 'SELECT_RELEASE_THRESHOLD: float = 0.45' 'PICO analog trigger release threshold'

$ProjectConfig = Get-Content -Raw -LiteralPath (Join-Path $Project 'project.godot')
Assert-Contains $ProjectConfig 'openxr/extensions/hand_tracking=true' 'Godot OpenXR hand-tracking settings'

$RuntimeProfile = Get-Content -Raw -LiteralPath (Join-Path $Project 'Assets\ARSpace\Scripts\runtime_profile.gd')
if ($RuntimeProfile.Contains('Ground VR Client is not supported on Android')) {
    throw 'Android Ground VR Client is still explicitly rejected.'
}
Assert-Contains $RuntimeProfile 'profile.selection_locked = has_explicit_selection' 'Runtime role-selection contract'
Assert-Contains $RuntimeProfile 'profile.validation_error = "Ground Server is not supported on Android"' 'Android server rejection contract'
$StartMenuSource = Get-Content -Raw -LiteralPath (Join-Path $Project 'Assets\ARSpace\Scenes\startmenu_ui.gd')
Assert-Contains $StartMenuSource 'if not OS.has_feature("android"):' 'Android StartMenu role filtering'

$FfmpegDescriptor = Get-Content -Raw -LiteralPath (Join-Path $Project 'addons\ffmpeg\ffmpeg.gdextension')
if ($FfmpegDescriptor -match '(?im)^android\.' -or $FfmpegDescriptor.Contains('res://addons/ffmpeg/android/')) {
    throw 'FFmpeg declares Android libraries that are not shipped in this repository.'
}
$VideoFallbackScripts = @(
    'Assets\ARSpace\Scripts\MovieCanvas\MovieInfoItem.gd',
    'Assets\ARSpace\Scripts\MovieCanvas\MovieListItem.gd',
    'Assets\ARSpace\Scripts\WorkListCanvas\WorkListInfoItem.gd'
)
foreach ($RelativePath in $VideoFallbackScripts) {
    $Source = Get-Content -Raw -LiteralPath (Join-Path $Project $RelativePath)
    Assert-Contains $Source 'ClassDB.class_exists("FFmpegVideoStream")' "Android video fallback in $RelativePath"
}

Write-Host 'PICO_HARDWARE_PREFLIGHT PASS'

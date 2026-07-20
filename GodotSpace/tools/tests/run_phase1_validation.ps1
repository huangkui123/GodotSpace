param(
    [string]$Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe',
    [string]$Project = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [switch]$SkipImport,
    [switch]$SkipRuntimeSmoke,
    [switch]$SkipLlm
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot console executable was not found: $Godot"
}
if (-not (Test-Path -LiteralPath (Join-Path $Project 'project.godot') -PathType Leaf)) {
    throw "Godot project.godot was not found under: $Project"
}

function Invoke-GodotScriptTest {
    param([Parameter(Mandatory = $true)][string]$ResourcePath)

    Write-Host "Running $ResourcePath"
    & $Godot --headless --path $Project --script $ResourcePath
    if ($LASTEXITCODE -ne 0) {
        throw "Godot self-test failed: $ResourcePath"
    }
}

if (-not $SkipImport) {
    $ImportLog = Join-Path ([IO.Path]::GetTempPath()) 'GodotSpace-headless-import.log'
    Write-Host "Running headless import; log: $ImportLog"
    $PreviousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell wraps native stderr lines as non-terminating
        # ErrorRecord objects. Keep them in the baseline log without letting
        # ErrorActionPreference=Stop abort before the native exit code is read.
        $ErrorActionPreference = 'Continue'
        $ImportLines = & $Godot --headless --path $Project --import 2>&1
        $ImportExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    $ImportText = $ImportLines -join [Environment]::NewLine
    [IO.File]::WriteAllText($ImportLog, $ImportText, [Text.UTF8Encoding]::new($false))
    $ImportLines | ForEach-Object { Write-Host $_ }
    if ($ImportExitCode -ne 0) {
        throw "Godot headless import failed with exit code $ImportExitCode. See $ImportLog"
    }

    $CriticalPatterns = @(
        'SCRIPT ERROR: Parse Error',
        'Compile Error:',
        'Failed to load script',
        'Failed loading resource',
        'Cannot open file.*res://',
        'Error loading image: ''res://',
        'Error importing ''res://',
        '(?:GDExtension.*(?:failed|could not|cannot|can''t|error)|(?:failed|could not|cannot|can''t|error).*GDExtension)',
        'Error loading extension:',
        '(?:autoload|Autoload).*(?:failed|invalid)'
    )
    foreach ($Pattern in $CriticalPatterns) {
        if ($ImportText -match $Pattern) {
            throw "Headless import matched critical pattern '$Pattern'. See $ImportLog"
        }
    }

    # These paths are embedded references in legacy, non-phase-1 source
    # models. Keep the list exact so a new missing file cannot silently join
    # the historical import baseline.
    $KnownMissingResourcePaths = @(
        'res://Scene_Main/ori/SM_Tri.mtl',
        'res://Assets/ChatRes/Models/YuanGongNan/images/nan_Color.1002.tif',
        'res://Assets/ChatRes/Models/YuanGongNan/images/yifu_Color.1002.tif',
        'res://Assets/ChatRes/Models/YuanGongNan/images/nan_Color.1001.tif',
        'res://Assets/Visual Design Cafe/Nature Shaders Demo/Art/Ferns/Source Assets/RnD_Fern_Albedo.png',
        'res://Assets/Visual Design Cafe/Nature Shaders Demo/Art/Ferns/Source Assets/RnD_Fern_Opp.png',
        'res://Assets/Resource/Model/FBX/Generic/Mala.psd'
    )
    $MissingPathPattern = [regex]"(?:Can't open file from path|Couldn't open MTL file) '(?<path>res://[^']+)'"
    foreach ($Match in $MissingPathPattern.Matches($ImportText)) {
        $MissingPath = $Match.Groups['path'].Value
        if ($MissingPath -notin $KnownMissingResourcePaths) {
            throw "Headless import found a new missing resource: $MissingPath. See $ImportLog"
        }
    }
    Write-Host 'Headless import completed without critical parse/resource/autoload/GDExtension errors.'
}

$PicoPreflightRunner = Join-Path $PSScriptRoot 'run_pico_hardware_preflight.ps1'
if (-not (Test-Path -LiteralPath $PicoPreflightRunner -PathType Leaf)) {
    throw "PICO hardware preflight runner is missing: $PicoPreflightRunner"
}
Write-Host 'Running PICO hardware-package preflight checks'
& $PicoPreflightRunner -Project $Project
if ($LASTEXITCODE -ne 0) {
    throw 'PICO hardware preflight checks failed.'
}

$CollaborationRunner = Join-Path $PSScriptRoot 'run_collaboration_self_tests.ps1'
Write-Host 'Running collaboration, player, role and VirtualAnnotation tests'
& $CollaborationRunner -Godot $Godot -Project $Project
if ($LASTEXITCODE -ne 0) {
    throw 'Collaboration self-test suite failed.'
}

Invoke-GodotScriptTest 'res://Assets/ARSpace/Scripts/WorkListCanvas/work_list_baseline_self_test.gd'

if (-not $SkipLlm) {
    $LlmTests = @(
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_self_test.gd',
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_task_ui_self_test.gd',
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_menu_entry_self_test.gd',
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_queue_self_test.gd',
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_http_self_test.gd',
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_voice_panel_self_test.gd',
        'res://Assets/ARSpace/Scripts/AI/llm_assistant_feature_audit_self_test.gd'
    )
    foreach ($Test in $LlmTests) {
        Invoke-GodotScriptTest $Test
    }
}

if (-not $SkipRuntimeSmoke) {
    $RuntimeSmokeRunner = Join-Path $PSScriptRoot 'run_runtime_startup_smoke_tests.ps1'
    if (-not (Test-Path -LiteralPath $RuntimeSmokeRunner -PathType Leaf)) {
        throw "Runtime startup smoke runner is missing: $RuntimeSmokeRunner"
    }
    Write-Host 'Running PC Server, testmode Client and XR configuration startup smoke tests'
    & $RuntimeSmokeRunner -Godot $Godot -Project $Project
    if ($LASTEXITCODE -ne 0) {
        throw 'Runtime startup smoke tests failed.'
    }
}

Write-Host 'PHASE1_VALIDATION PASS'

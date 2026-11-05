param([string]$Godot = $env:GODOTSPACE_GODOT)
$ErrorActionPreference = 'Stop'
if (-not $Godot) {
    $engineName = 'godot.windows.editor.x86_64.llvm.console.exe'
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) "godot_modding\bin\$engineName"),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "godot_modding\bin\$engineName"),
        "D:\godot_modding\bin\$engineName"
    )
    $Godot = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $Godot -or -not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw 'Godot executable not found. Set GODOTSPACE_GODOT or pass -Godot <path>.'
}
$project = Join-Path $PSScriptRoot 'GodotSpace'
if (-not (Test-Path -LiteralPath (Join-Path $project 'project.godot') -PathType Leaf)) {
    throw "Godot project not found: $project"
}
$logs = Join-Path $env:LOCALAPPDATA 'GodotSpace/startup'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$log = Join-Path $logs ('controller-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
# Start-Process needs quoted native arguments on Windows, including space paths.
Start-Process -FilePath $Godot -ArgumentList @('--path', ('"' + $project + '"'), '--log-file', ('"' + $log + '"')) -WindowStyle Hidden | Out-Null

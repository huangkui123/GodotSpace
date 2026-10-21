param([string]$Godot = $env:GODOTSPACE_GODOT)
$ErrorActionPreference = 'Stop'
if (-not $Godot) { $Godot = 'D:\godot_modding\bin\godot.windows.editor.x86_64.llvm.console.exe' }
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw 'Godot executable not found. Set GODOTSPACE_GODOT or pass -Godot <path>.'
}
$project = Join-Path $PSScriptRoot 'GodotSpace'
$logs = Join-Path $env:LOCALAPPDATA 'GodotSpace/startup'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$log = Join-Path $logs ('controller-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
# Start-Process needs quoted native arguments on Windows, including space paths.
Start-Process -FilePath $Godot -ArgumentList @('--path', ('"' + $project + '"'), '--log-file', ('"' + $log + '"')) -WindowStyle Hidden | Out-Null

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$WslProjectRoot = (& wsl.exe -d Ubuntu-20.04 -- wslpath -a -u $ProjectRoot.Replace('\', '/') | Select-Object -First 1).Trim()
if (-not $WslProjectRoot) {
  throw "Could not translate the project root to a WSL path: $ProjectRoot"
}
$Stdout = Join-Path $ProjectRoot "logs\local_asr.out"
$Stderr = Join-Path $ProjectRoot "logs\local_asr.err"

New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot "logs") | Out-Null

Start-Process `
  -FilePath "wsl.exe" `
  -ArgumentList @(
    "-d", "Ubuntu-20.04",
    "--cd", $WslProjectRoot,
    "--",
    "bash", "scripts/start_local_asr.sh"
  ) `
  -WorkingDirectory $ProjectRoot `
  -RedirectStandardOutput $Stdout `
  -RedirectStandardError $Stderr `
  -WindowStyle Hidden `
  -PassThru

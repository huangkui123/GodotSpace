$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Stdout = Join-Path $ProjectRoot "logs\agent_gateway.out"
$Stderr = Join-Path $ProjectRoot "logs\agent_gateway.err"

New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot "logs") | Out-Null

Start-Process `
  -FilePath "wsl.exe" `
  -ArgumentList @(
    "-d", "Ubuntu-20.04",
    "--cd", "/mnt/c/Users/94580/Desktop/cxy/Model",
    "--",
    "bash", "scripts/start_agent_gateway.sh"
  ) `
  -WorkingDirectory $ProjectRoot `
  -RedirectStandardOutput $Stdout `
  -RedirectStandardError $Stderr `
  -WindowStyle Hidden `
  -PassThru

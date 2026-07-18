$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Stdout = Join-Path $ProjectRoot "logs\web_demo.out"
$Stderr = Join-Path $ProjectRoot "logs\web_demo.err"

New-Item -ItemType Directory -Force -Path (Join-Path $ProjectRoot "logs") | Out-Null

Start-Process `
  -FilePath "wsl.exe" `
  -ArgumentList @(
    "-d", "Ubuntu-20.04",
    "--cd", "/mnt/c/Users/94580/Desktop/cxy/Model",
    "--",
    "bash", "scripts/start_web_demo.sh"
  ) `
  -WorkingDirectory $ProjectRoot `
  -RedirectStandardOutput $Stdout `
  -RedirectStandardError $Stderr `
  -WindowStyle Hidden `
  -PassThru


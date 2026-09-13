param([ValidateSet('install', 'start', 'stop', 'status', 'test')][string]$Action = 'status')
$ErrorActionPreference = 'Stop'
$ttsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ttsWslRoot = (& wsl.exe -d Ubuntu-20.04 -- wslpath -a -u $ttsRoot.Replace('\', '/') | Select-Object -First 1).Trim()
if (-not $ttsWslRoot) { throw 'Unable to resolve the WSL repository path.' }
if ($Action -eq 'install') {
    & wsl.exe -d Ubuntu-20.04 --cd $ttsWslRoot -- bash scripts/bootstrap_local_tts.sh
} elseif ($Action -eq 'test') {
    & wsl.exe -d Ubuntu-20.04 --cd $ttsWslRoot -- .venv-tts/bin/python scripts/smoke_local_tts.py
} else {
    & wsl.exe -d Ubuntu-20.04 --cd $ttsWslRoot -- .venv-tts/bin/python scripts/local_tts.py $Action
}
if ($LASTEXITCODE -ne 0) { throw "Local TTS $Action failed (exit $LASTEXITCODE)." }

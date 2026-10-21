param(
    [ValidateSet('start', 'stop', 'status')][string]$Action = 'status',
    [ValidateSet('cpu', 'cuda')][string]$Device = 'cpu',
    [string]$Distro = 'Ubuntu-20.04'
)
$ErrorActionPreference = 'Stop'
$TtsBackend = Split-Path -Parent $PSScriptRoot
$TtsPathResult = & wsl.exe -d $Distro --exec wslpath -u $TtsBackend.Replace('\', '/')
if ($LASTEXITCODE -ne 0 -or -not $TtsPathResult) {
    throw 'Cannot resolve this checkout inside the selected WSL distribution.'
}
$TtsLinuxPath = $TtsPathResult.Trim()
if (-not $TtsLinuxPath.StartsWith('/')) { throw 'Expected an absolute WSL path.' }
$TtsEnvironment = if ($Device -eq 'cuda') { '.venv-tts-gpu' } else { '.venv-tts' }
& wsl.exe -d $Distro --cd $TtsLinuxPath --exec env "LOCAL_TTS_DEVICE=$Device" "$TtsLinuxPath/$TtsEnvironment/bin/python" -B "$TtsLinuxPath/scripts/local_tts.py" $Action
exit $LASTEXITCODE

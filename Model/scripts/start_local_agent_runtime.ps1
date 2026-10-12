param(
    [Parameter(Mandatory=$true)][string]$Config,
    [Parameter(Mandatory=$true)][string]$Status,
    [ValidateSet('server','client','server_voice')][string]$Role = 'server',
    [ValidateSet('local','remote')][string]$Mode = 'local'
)
$ErrorActionPreference = 'Stop'
try {
    $runtimeConfig = Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json
    $distro = [string]$runtimeConfig.wsl_distro
    if ([string]::IsNullOrWhiteSpace($distro)) { throw 'Missing wsl_distro in runtime.json' }
    $repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
    function Convert-RuntimePath([string]$value) {
        $converted = & wsl.exe -d $distro -- wslpath -u $value
        if ($LASTEXITCODE -ne 0) { throw 'WSL path conversion failed' }
        return ([string]$converted).Trim()
    }
    $linuxRepo = Convert-RuntimePath $repo
    $linuxConfig = Convert-RuntimePath $Config
    $linuxStatus = Convert-RuntimePath $Status
    & wsl.exe -d $distro -- python3 "$linuxRepo/Model/scripts/local_agent_runtime.py" --repo $linuxRepo --config $linuxConfig --status $linuxStatus --role $Role --mode $Mode --require-windows-check
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $result = Get-Content -LiteralPath $Status -Raw | ConvertFrom-Json
    if ($result.state -ne 'verifying') { throw 'Runtime did not report services ready for host verification' }
    foreach ($check in $result.health_checks) {
        $actual = Invoke-RestMethod -Uri $check.url -TimeoutSec 5
        foreach ($expected in $check.expected.PSObject.Properties) {
            if ($actual.($expected.Name) -cne $expected.Value) {
                throw "Windows localhost service mismatch: $($expected.Name)"
            }
        }
    }
    $result.state = 'ready'
    $result.message = 'Local Agent services ready (WSL and Windows verified)'
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$Status.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$Status.tmp" -Destination $Status -Force
} catch {
    @{state='failed'; message=$_.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath $Status -Encoding UTF8
    exit 1
}

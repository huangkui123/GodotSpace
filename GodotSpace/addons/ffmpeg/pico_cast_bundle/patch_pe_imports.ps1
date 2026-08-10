[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $FfmpegBin,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $DebugWrapper,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ReleaseWrapper,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'
$latin1 = [System.Text.Encoding]::Latin1

$nameMap = [ordered]@{
    'avcodec-60.dll' = 'pxcodec-60.dll'
    'avformat-60.dll' = 'pxformat-60.dll'
    'avutil-58.dll' = 'pxutil-58.dll'
    'swresample-4.dll' = 'pxresample-4.dll'
    'swscale-7.dll' = 'pxscale-7.dll'
}

foreach ($entry in $nameMap.GetEnumerator()) {
    if ($entry.Key.Length -ne $entry.Value.Length) {
        throw "PE import replacement must preserve length: $($entry.Key)"
    }
}

function Copy-PatchedBinary {
    param(
        [string] $Source,
        [string] $Destination,
        [string[]] $Imports
    )

    $bytes = [System.IO.File]::ReadAllBytes($Source)
    $text = $latin1.GetString($bytes)
    foreach ($importName in $Imports) {
        $replacement = $nameMap[$importName]
        if ([string]::IsNullOrEmpty($replacement)) {
            throw "Unknown isolated import: $importName"
        }
        if (-not $text.Contains($importName)) {
            throw "$Source does not import $importName"
        }
        $text = $text.Replace($importName, $replacement)
    }
    $patchedBytes = $latin1.GetBytes($text)
    if ($patchedBytes.Length -ne $bytes.Length) {
        throw "PE patch changed file length: $Source"
    }
    [System.IO.File]::WriteAllBytes($Destination, $patchedBytes)
}

[System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

Copy-PatchedBinary `
    -Source (Join-Path $FfmpegBin 'avcodec-60.dll') `
    -Destination (Join-Path $OutputDir 'pxcodec-60.dll') `
    -Imports @('avutil-58.dll', 'swresample-4.dll')
Copy-PatchedBinary `
    -Source (Join-Path $FfmpegBin 'avformat-60.dll') `
    -Destination (Join-Path $OutputDir 'pxformat-60.dll') `
    -Imports @('avcodec-60.dll', 'avutil-58.dll')
Copy-Item `
    -LiteralPath (Join-Path $FfmpegBin 'avutil-58.dll') `
    -Destination (Join-Path $OutputDir 'pxutil-58.dll') `
    -Force
Copy-PatchedBinary `
    -Source (Join-Path $FfmpegBin 'swresample-4.dll') `
    -Destination (Join-Path $OutputDir 'pxresample-4.dll') `
    -Imports @('avutil-58.dll')
Copy-PatchedBinary `
    -Source (Join-Path $FfmpegBin 'swscale-7.dll') `
    -Destination (Join-Path $OutputDir 'pxscale-7.dll') `
    -Imports @('avutil-58.dll')

$wrapperImports = @(
    'avcodec-60.dll',
    'avformat-60.dll',
    'avutil-58.dll',
    'swresample-4.dll',
    'swscale-7.dll'
)
Copy-PatchedBinary `
    -Source $DebugWrapper `
    -Destination (Join-Path $OutputDir 'libgdffmpeg.windows.template_debug.x86_64.dll') `
    -Imports $wrapperImports
Copy-PatchedBinary `
    -Source $ReleaseWrapper `
    -Destination (Join-Path $OutputDir 'libgdffmpeg.windows.template_release.x86_64.dll') `
    -Imports $wrapperImports

Get-ChildItem -LiteralPath $OutputDir -Filter '*.dll' |
    Sort-Object Name |
    Select-Object Name, Length

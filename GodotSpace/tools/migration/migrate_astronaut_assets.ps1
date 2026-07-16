param(
	[Parameter(Mandatory = $true)]
	[string]$UnityModelRoot,

	[string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,

	[string]$Python = 'python',

	[ValidateRange(64, 4096)]
	[int]$MaxTextureSize = 1024
)

$ErrorActionPreference = 'Stop'

$SourceModel = Join-Path $UnityModelRoot 'china_rig.fbx'
$DestinationRoot = Join-Path $ProjectRoot 'Assets\ARSpace\Characters\Astronaut\Source'
$DestinationTextures = $DestinationRoot
$ResizeScript = Join-Path $PSScriptRoot 'resize_astronaut_textures.py'
$PatchFbxScript = Join-Path $PSScriptRoot 'patch_astronaut_fbx.py'

$TextureNames = @(
	'A.PNG',
	'BaseColor.1002.png',
	'DETAIL_DETAIL_AO.png',
	'DETAIL_DETAIL_BaseColor.png',
	'DETAIL_DETAIL_Height.png',
	'DETAIL_DETAIL_Metallic.png',
	'DETAIL_DETAIL_Normal.png',
	'DETAIL_DETAIL_Roughness.png',
	'GLOVES_GLOVES_AO.png',
	'GLOVES_GLOVES_BaseColor.png',
	'GLOVES_GLOVES_Height.png',
	'GLOVES_GLOVES_Metallic.png',
	'GLOVES_GLOVES_Normal.png',
	'GLOVES_GLOVES_Roughness.png',
	'Height.1002.png',
	'HELMET_HELMET_AO.png',
	'HELMET_HELMET_BaseColor.png',
	'HELMET_HELMET_Height.png',
	'HELMET_HELMET_Metallic.png',
	'HELMET_HELMET_Normal.png',
	'HELMET_HELMET_Roughness.png',
	'LOGO_C.png',
	'LOGO_D.jpg',
	'Metallic.1002.png',
	'Normal.1002.png',
	'PANT_PANT_AO.png',
	'PANT_PANT_BaseColor.png',
	'PANT_PANT_Height.png',
	'PANT_PANT_Metallic.png',
	'PANT_PANT_Normal.png',
	'PANT_PANT_Roughness.png',
	'Roughness.1002.png',
	'STRIP_STRIP_AO.png',
	'STRIP_STRIP_BaseColor.png',
	'STRIP_STRIP_Height.png',
	'STRIP_STRIP_Metallic.png',
	'STRIP_STRIP_Normal.png',
	'STRIP_STRIP_Roughness.png',
	'TORSO_TORSO_AO.png',
	'TORSO_TORSO_BaseColor.png',
	'TORSO_TORSO_Height.png',
	'TORSO_TORSO_Metallic.png',
	'TORSO_TORSO_Normal.png',
	'TORSO_TORSO_Roughness.png'
)

if (-not (Test-Path -LiteralPath $SourceModel -PathType Leaf)) {
	throw "Astronaut FBX not found: $SourceModel"
}

New-Item -ItemType Directory -Force -Path $DestinationTextures | Out-Null
$DestinationModel = Join-Path $DestinationRoot 'china_rig.fbx'
Copy-Item -LiteralPath $SourceModel -Destination $DestinationModel -Force
& $Python $PatchFbxScript $DestinationModel
if ($LASTEXITCODE -ne 0) {
	throw 'Unable to patch FBX UDIM texture aliases.'
}

foreach ($TextureName in $TextureNames) {
	$SourceTexture = Join-Path (Join-Path $UnityModelRoot 'Textures') $TextureName
	$DestinationTexture = Join-Path $DestinationTextures $TextureName
	if (-not (Test-Path -LiteralPath $SourceTexture -PathType Leaf)) {
		throw "Required astronaut texture not found: $SourceTexture"
	}
	& $Python $ResizeScript $SourceTexture $DestinationTexture --max-size $MaxTextureSize
	if ($LASTEXITCODE -ne 0) {
		throw "Texture conversion failed: $TextureName"
	}
}

$UdimAliases = @{
	'BaseColor.1002.png' = 'BaseColor.1002xx.png'
	'Roughness.1002.png' = 'Roughness.1002xx.png'
	'Normal.1002.png' = 'Normal.1002xx.png'
	'Metallic.1002.png' = 'Metallic.1002xx.png'
}
foreach ($SourceName in $UdimAliases.Keys) {
	Copy-Item `
		-LiteralPath (Join-Path $DestinationTextures $SourceName) `
		-Destination (Join-Path $DestinationTextures $UdimAliases[$SourceName]) `
		-Force
}

Write-Output "Astronaut source assets migrated to $DestinationRoot"

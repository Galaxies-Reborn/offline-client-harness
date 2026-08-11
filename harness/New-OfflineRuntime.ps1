<#
.SYNOPSIS
    Builds a self-contained, serverless SWG client runtime directory.

.DESCRIPTION
    Assembles a directory the offline client can run from with no login server, no central
    server, no game server and no Oracle database:

      1. Mirrors the game data (.tre stack, .toc files, loose override directories) out of an
         existing client installation. Files are hardlinked by default, so a mirror of an 8 GB
         install costs almost no disk.
      2. Copies the freshly built x64 client binaries over the top.
      3. Writes offline.cfg and appends a .include for it to the runtime's own client.cfg.

    The asset source is never written to. Every file this script rewrites is unlinked first, so
    a hardlinked mirror can never propagate an edit back into the source installation.

    Game assets are NOT redistributed with this repository. You supply your own client
    installation as -AssetSource.

.PARAMETER AssetSource
    An existing SWG client installation containing client.cfg and the root .tre stack.

.PARAMETER Destination
    Directory to create the offline runtime in. Created if absent.

.PARAMETER Configuration
    Which build configuration's binaries to stage. Only Release links SwgClient in this tree.

.PARAMETER Scene
    Terrain file to boot directly into, as a tree-file path. Empty string means do not auto-boot;
    the client then starts at the normal login screen.

.PARAMETER Avatar
    Player object template to build the local avatar from.

.PARAMETER StartLocation
    World X, Y, Z to start at. Y is ignored unless -NoSnapToTerrain is given, because the client
    drops the player onto the heightmap once the terrain is loaded.

.PARAMETER NoSnapToTerrain
    Keep the configured Y verbatim instead of snapping to terrain height. Use for interiors and
    for space scenes, where the heightmap is not the floor.

.PARAMETER AssetLinkMode
    Hardlink (default) or Copy. Hardlink requires the destination to be on the same volume as the
    asset source; the script falls back to copying per-file if a link cannot be made.

.PARAMETER SkipBinaries
    Mirror assets and write configuration, but do not stage built binaries. Useful when you want
    to point Stage-X64Client.ps1 at the runtime yourself.

.EXAMPLE
    .\harness\New-OfflineRuntime.ps1 -AssetSource E:\SWG\_client -Destination E:\SWG\_offline

.EXAMPLE
    .\harness\New-OfflineRuntime.ps1 -AssetSource E:\SWG\_client -Destination E:\SWG\_offline `
        -Scene terrain/naboo.trn -StartLocation -5000,0,4000
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$AssetSource,

    [Parameter(Mandatory)]
    [string]$Destination,

    [ValidateSet("Release", "Optimized", "Debug")]
    [string]$Configuration = "Release",

    [string]$Scene = "terrain/tatooine.trn",

    [string]$Avatar = "object/creature/player/shared_human_male.iff",

    [ValidateCount(3, 3)]
    [float[]]$StartLocation = @(3528.0, 0.0, -4804.0),

    [switch]$NoSnapToTerrain,

    [string]$PlayerName = "Offline",

    [ValidateSet("Hardlink", "Copy")]
    [string]$AssetLinkMode = "Hardlink",

    [switch]$SkipBinaries,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path

# ----------------------------------------------------------------------------------------------
# Validate the asset source

if (-not (Test-Path -LiteralPath $AssetSource -PathType Container)) {
    throw "AssetSource does not exist: $AssetSource"
}

$sourceRoot = (Resolve-Path -LiteralPath $AssetSource).Path

if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot "client.cfg") -PathType Leaf)) {
    throw "AssetSource does not look like a client installation, client.cfg is missing: $sourceRoot"
}

$sourceTreCount = @(Get-ChildItem -LiteralPath $sourceRoot -Filter "*.tre" -File).Count
if ($sourceTreCount -eq 0) {
    throw "AssetSource contains no root .tre files: $sourceRoot"
}

# ----------------------------------------------------------------------------------------------
# Prepare the destination

if (Test-Path -LiteralPath $Destination) {
    $existing = @(Get-ChildItem -LiteralPath $Destination -Force)
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "Destination is not empty. Re-run with -Force to refresh it in place: $Destination"
    }
}
else {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

$runtimeRoot = (Resolve-Path -LiteralPath $Destination).Path

if ($runtimeRoot -eq $sourceRoot) {
    throw "Destination and AssetSource are the same directory. The offline runtime must be separate so the source installation stays untouched."
}

if (-not $PSCmdlet.ShouldProcess($runtimeRoot, "build offline client runtime from $sourceRoot")) {
    return
}

# ----------------------------------------------------------------------------------------------
# Mirror game assets
#
# Excluded: build and run droppings that either do not belong to a fresh runtime or would make
# the mirror confusing to read. Nothing here is needed to launch.

# compiled_shader is deliberately NOT excluded. Blobs there are keyed by a hash of the exact
# compiler input, so a carried-over cache cannot be stale -- a changed program hashes differently,
# finds no file and compiles. Mirroring it is a large first-run saving.
$excludedDirectories = @(
    "logs",
    "screenshots",
    "profiles",
    ".x64-backups",
    ".git"
)

$excludedExtensions = @(".pdb", ".log", ".bak", ".ilk", ".exp")

# Files this script rewrites. They are copied rather than linked, and are unlinked before every
# write, so an edit here can never reach back into the asset source through a hardlink.
$mutableFiles = @("client.cfg", "offline.cfg")

$sourceVolume = [IO.Path]::GetPathRoot($sourceRoot)
$destVolume = [IO.Path]::GetPathRoot($runtimeRoot)
$canHardlink = ($AssetLinkMode -eq "Hardlink") -and ($sourceVolume -eq $destVolume)

if ($AssetLinkMode -eq "Hardlink" -and -not $canHardlink) {
    Write-Warning "AssetSource ($sourceVolume) and Destination ($destVolume) are on different volumes. Falling back to copying, which needs the full size of the installation on disk."
}

Write-Host "Mirroring assets from $sourceRoot"

$linked = 0
$copied = 0
$skipped = 0

Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | ForEach-Object {
    $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $firstSegment = ($relative -split [regex]::Escape([IO.Path]::DirectorySeparatorChar))[0]

    if ($excludedDirectories -contains $firstSegment) { $script:skipped++; return }
    if ($excludedExtensions -contains $_.Extension.ToLowerInvariant()) { $script:skipped++; return }
    if ($_.Name -like "*.cfg.*") { $script:skipped++; return }   # options.cfg.dx9-backup and friends

    $target = Join-Path $runtimeRoot $relative
    $targetDirectory = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Remove-Item -LiteralPath $target -Force
    }

    $mustCopy = $mutableFiles -contains $_.Name

    if ($canHardlink -and -not $mustCopy) {
        try {
            New-Item -ItemType HardLink -Path $target -Target $_.FullName -ErrorAction Stop | Out-Null
            $script:linked++
            return
        }
        catch {
            # Fall through to a copy. Hardlinks fail on some filesystems and across mount points
            # even when the drive letters match, and a slower mirror beats a failed one.
        }
    }

    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    $script:copied++
}

Write-Host ("Mirrored {0:N0} hardlinked, {1:N0} copied, {2:N0} skipped" -f $linked, $copied, $skipped)

foreach ($directory in @("logs", "screenshots", "profiles")) {
    $path = Join-Path $runtimeRoot $directory
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

# ----------------------------------------------------------------------------------------------
# Stage the built client

if (-not $SkipBinaries) {
    $stageScript = Join-Path $repoRoot "scripts\Stage-X64Client.ps1"
    if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
        throw "Cannot find the staging script: $stageScript"
    }

    Write-Host "Staging $Configuration|x64 client binaries"
    & $stageScript -ClientRoot $runtimeRoot -Configuration $Configuration -NoBackup
}

# ----------------------------------------------------------------------------------------------
# Write offline.cfg
#
# .cfg files must be written without a byte order mark. The client's config parser does not skip
# one, and a BOM makes the first section header unreadable, which fails before any logging exists.

$snapToTerrain = if ($NoSnapToTerrain) { 0 } else { 1 }
$sceneLine = if ([string]::IsNullOrWhiteSpace($Scene)) {
    "#	groundScene=          # unset: start at the login screen instead of booting a scene"
}
else {
    "	groundScene=$Scene"
}

$offlineCfg = @"
# offline.cfg -- generated by harness/New-OfflineRuntime.ps1
#
# Included last from client.cfg. The client's 3-argument config accessors return the LAST value
# entered for a key, so everything here wins over user.cfg and options.cfg.
#
# Regenerate with New-OfflineRuntime.ps1, or hand-edit; nothing reads this file but the client.

[SwgClient]
	allowMultipleInstances=true

[Station]
	# Unlock every expansion's content locally. Nothing validates this without a server.
	gameFeatures=65535
	subscriptionFeatures=0x01

[ClientGame]
	# Setting groundScene is the whole opt-in for offline mode. With it set, Game::install builds a
	# single player GroundScene directly and never activates the splash or the login screen, so no
	# connection is attempted to anything.
$sceneLine
	avatarSelection=$Avatar
	playerName=$PlayerName

	singlePlayerStartLocationX=$($StartLocation[0])
	singlePlayerStartLocationY=$($StartLocation[1])
	singlePlayerStartLocationZ=$($StartLocation[2])

	# Snap the avatar onto the heightmap once terrain has loaded. Turn off for interiors and space.
	singlePlayerSnapToTerrain=$snapToTerrain

	# Belt and braces: with groundScene set none of this is reached, but if you clear groundScene
	# to get the login screen back, these keep the client from dialling out on its own.
	autoConnectToLoginServer=false
	autoConnectToCentralServer=false
	autoConnectToGameServer=false
	launcherAvatarName=

	skipIntro=1
	skipSplash=1
	disableCutScenes=1

	# Show the login screen's dev button in a PRODUCTION build, which transitions to the /SceneSel
	# page for interactive scene picking. Only useful with groundScene cleared, and only if your
	# .tre stack actually carries that page.
	offlineSceneSelectButton=0

	# Suppress the client's static object layer to get bare terrain. Off by default: for most
	# client work you want the shipped world drawn.
	# disableWorldSnapshot=1
"@

$offlineCfgPath = Join-Path $runtimeRoot "offline.cfg"
if (Test-Path -LiteralPath $offlineCfgPath -PathType Leaf) {
    Remove-Item -LiteralPath $offlineCfgPath -Force
}

$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($offlineCfgPath, ($offlineCfg -replace "`r?`n", "`r`n") + "`r`n", $utf8NoBom)

# ----------------------------------------------------------------------------------------------
# Chain offline.cfg from the runtime's own client.cfg
#
# The runtime copy, never the asset source's. client.cfg is in $mutableFiles so it was copied, not
# linked, and it is unlinked before this write regardless.

$clientCfgPath = Join-Path $runtimeRoot "client.cfg"
$clientCfgText = [IO.File]::ReadAllText($clientCfgPath)

if ($clientCfgText -notmatch '(?m)^\s*\.include\s+"offline\.cfg"') {
    $clientCfgText = $clientCfgText.TrimEnd() + "`r`n`r`n" +
        "# Offline harness. Must stay last: the client's config accessors take the last value" + "`r`n" +
        "# entered for a key, so this is what lets offline.cfg override user.cfg and options.cfg." + "`r`n" +
        '.include "offline.cfg"' + "`r`n"

    Remove-Item -LiteralPath $clientCfgPath -Force
    [IO.File]::WriteAllText($clientCfgPath, $clientCfgText, $utf8NoBom)
    Write-Host "Chained offline.cfg from client.cfg"
}
else {
    Write-Host "client.cfg already includes offline.cfg"
}

# ----------------------------------------------------------------------------------------------

$manifest = [ordered]@{
    formatVersion  = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
    assetSource    = $sourceRoot
    runtimeRoot    = $runtimeRoot
    configuration  = $Configuration
    assetLinkMode  = if ($canHardlink) { "Hardlink" } else { "Copy" }
    rootTreCount   = $sourceTreCount
    scene          = $Scene
    avatar         = $Avatar
    startLocation  = $StartLocation
    snapToTerrain  = [bool]$snapToTerrain
    sourceCommit   = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceBranch   = (& git -C $repoRoot branch --show-current).Trim()
}

[IO.File]::WriteAllText(
    (Join-Path $runtimeRoot "offline-harness-manifest.json"),
    ($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
    $utf8NoBom)

Write-Host ""
Write-Host "Offline runtime ready: $runtimeRoot"
if ([string]::IsNullOrWhiteSpace($Scene)) {
    Write-Host "No scene configured. The client will start at the login screen."
}
else {
    Write-Host "Boots directly into $Scene as $Avatar. No server is contacted."
}
Write-Host "Launch it with: .\harness\Start-OfflineClient.ps1 -RuntimeRoot `"$runtimeRoot`""

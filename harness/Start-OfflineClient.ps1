<#
.SYNOPSIS
    Launches the offline client out of a runtime directory built by New-OfflineRuntime.ps1.

.DESCRIPTION
    Starts the client with its working directory set to the runtime root, which is required: the
    graphics backend is loaded as a CWD-relative .\glNN_x.dll, so launching from anywhere else
    fails to find a renderer.

    Optionally retargets the scene, avatar or start location first by rewriting offline.cfg, so
    you can jump between planets without regenerating the runtime.

.PARAMETER RuntimeRoot
    The offline runtime directory. Defaults to the one recorded by the last New-OfflineRuntime run
    if -RuntimeRoot is omitted and exactly one is remembered.

.PARAMETER Scene
    Retarget the boot scene before launching, as a tree-file path such as terrain/naboo.trn.
    Pass an empty string to clear it and start at the login screen instead.

.PARAMETER Avatar
    Retarget the player object template before launching.

.PARAMETER StartLocation
    Retarget world X, Y, Z before launching.

.PARAMETER Configuration
    Which client binary to launch. Only Release links SwgClient in this tree.

.PARAMETER TailLog
    Follow logs\warning.log until the client exits. Everything the client reports lands there;
    DEBUG_* logging compiles out of PRODUCTION builds, so warning.log is the whole record.

.PARAMETER Wait
    Block until the client exits instead of returning immediately.

.EXAMPLE
    .\harness\Start-OfflineClient.ps1 -RuntimeRoot E:\SWG\_offline

.EXAMPLE
    .\harness\Start-OfflineClient.ps1 -RuntimeRoot E:\SWG\_offline -Scene terrain/dathomir.trn -TailLog
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RuntimeRoot,

    [string]$Scene,

    [string]$Avatar,

    [ValidateCount(3, 3)]
    [float[]]$StartLocation,

    [ValidateSet("Release", "Optimized", "Debug")]
    [string]$Configuration = "Release",

    [switch]$TailLog,

    [switch]$Wait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
    throw "RuntimeRoot does not exist: $RuntimeRoot"
}

$runtimeRootPath = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$offlineCfgPath = Join-Path $runtimeRootPath "offline.cfg"

if (-not (Test-Path -LiteralPath $offlineCfgPath -PathType Leaf)) {
    throw "This is not an offline runtime, offline.cfg is missing. Build one with New-OfflineRuntime.ps1: $runtimeRootPath"
}

# ----------------------------------------------------------------------------------------------
# Retarget offline.cfg in place if asked
#
# Rewriting rather than appending, because the client takes the LAST value entered for a key and a
# file that accumulated three groundScene lines would be unreadable even though it would work.

$rewrites = [ordered]@{}
if ($PSBoundParameters.ContainsKey("Scene")) { $rewrites["groundScene"] = $Scene }
if ($PSBoundParameters.ContainsKey("Avatar")) { $rewrites["avatarSelection"] = $Avatar }
if ($PSBoundParameters.ContainsKey("StartLocation")) {
    $rewrites["singlePlayerStartLocationX"] = $StartLocation[0]
    $rewrites["singlePlayerStartLocationY"] = $StartLocation[1]
    $rewrites["singlePlayerStartLocationZ"] = $StartLocation[2]
}

if ($rewrites.Count -gt 0) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]][IO.File]::ReadAllLines($offlineCfgPath))

    foreach ($key in $rewrites.Keys) {
        $value = $rewrites[$key]
        $pattern = '^\s*#?\s*' + [regex]::Escape($key) + '\s*='
        $replacement = if ([string]::IsNullOrWhiteSpace([string]$value)) {
            "#	$key="
        }
        else {
            "	$key=$value"
        }

        $matched = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) {
                $lines[$i] = $replacement
                $matched = $true
            }
        }

        if (-not $matched) {
            throw "offline.cfg has no $key line to retarget. Regenerate it with New-OfflineRuntime.ps1."
        }

        Write-Host "offline.cfg: $key = $value"
    }

    # Unlink before writing. The runtime may be a hardlinked mirror of a real installation, and an
    # in-place write through a link would edit the source.
    $text = ($lines -join "`r`n") + "`r`n"
    Remove-Item -LiteralPath $offlineCfgPath -Force
    [IO.File]::WriteAllText($offlineCfgPath, $text, [Text.UTF8Encoding]::new($false))
}

# ----------------------------------------------------------------------------------------------
# Find the client
#
# By directory, and by suffix, never by a hardcoded product name. These executables get renamed
# per server, and several unrelated SWG clients commonly coexist on one machine.

$suffix = @{
    Release   = "r"
    Optimized = "o"
    Debug     = "d"
}[$Configuration]

$candidates = @(
    Get-ChildItem -LiteralPath $runtimeRootPath -Filter "*_$suffix.exe" -File |
        Where-Object { $_.Name -notlike "*Setup*" }
)

if ($candidates.Count -eq 0) {
    throw "No *_$suffix.exe client found in $runtimeRootPath. Stage the build with scripts\Stage-X64Client.ps1."
}
if ($candidates.Count -gt 1) {
    throw ("Ambiguous client executable in {0}: {1}" -f $runtimeRootPath, (($candidates.Name) -join ", "))
}

$clientPath = $candidates[0].FullName

$backend = Join-Path $runtimeRootPath "gl11_$suffix.dll"
if (-not (Test-Path -LiteralPath $backend -PathType Leaf)) {
    Write-Warning "The DX11 backend gl11_$suffix.dll is not present. The client will use whichever renderer options.cfg rasterMajor selects."
}

$logPath = Join-Path $runtimeRootPath "logs\warning.log"
$logStartLength = if (Test-Path -LiteralPath $logPath -PathType Leaf) { (Get-Item -LiteralPath $logPath).Length } else { 0 }

Write-Host "Launching $clientPath"
Write-Host "Working directory: $runtimeRootPath"

$process = Start-Process -FilePath $clientPath -WorkingDirectory $runtimeRootPath -PassThru

Write-Host "Started PID $($process.Id)"

if ($TailLog) {
    Write-Host "Following $logPath (Ctrl+C to stop following; the client keeps running)"
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { continue }

        $length = (Get-Item -LiteralPath $logPath).Length
        if ($length -gt $logStartLength) {
            $stream = [IO.FileStream]::new($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $stream.Position = $logStartLength
                $reader = [IO.StreamReader]::new($stream)
                Write-Host $reader.ReadToEnd().TrimEnd()
            }
            finally {
                $stream.Dispose()
            }
            $logStartLength = $length
        }
    }
    Write-Host "Client exited with code $($process.ExitCode)"
}
elseif ($Wait) {
    $process.WaitForExit()
    Write-Host "Client exited with code $($process.ExitCode)"
}
else {
    Write-Host "Log: $logPath"
    Write-Host "Close it cleanly with: (Get-Process -Id $($process.Id)).CloseMainWindow()"
}

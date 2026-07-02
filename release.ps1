#Requires -Version 5.1
<#
Release automation for Melcosoft.Releases.
Run this script from anywhere; it locates paths relative to its own location
(Melcosoft.Releases) and the repo root (its parent).
#>

$ErrorActionPreference = "Stop"

$ReleasesRepo = $PSScriptRoot
$RepoRoot     = Resolve-Path (Join-Path $PSScriptRoot "..")
$LatestFiles  = Join-Path $ReleasesRepo "latest_files"
$LatestJsonPath   = Join-Path $ReleasesRepo "latest.json"
$ReleaseManifestPath = Join-Path $LatestFiles "release_manifest.json"
$FileManifestPath    = Join-Path $LatestFiles "file_manifest.json"

# ---------- helpers ----------

function Write-Section($text) {
    Write-Host ""
    Write-Host "== $text ==" -ForegroundColor Cyan
}

function Write-Warn2($text) {
    Write-Host $text -ForegroundColor Yellow
}

function Write-Ok($text) {
    Write-Host $text -ForegroundColor Green
}

function Confirm-Step($message) {
    $resp = Read-Host "$message (y/N)"
    return $resp -match '^(y|yes)$'
}

function Read-MultilineInput($prompt) {
    Write-Host $prompt -ForegroundColor Cyan
    Write-Host "(Paste/type the text; finish with a line containing only: END)" -ForegroundColor DarkGray
    $lines = @()
    while ($true) {
        $line = Read-Host
        if ($line -eq "END") { break }
        $lines += $line
    }
    return ($lines -join "`n")
}

function ConvertTo-JsonUtf8($InputObject, [int]$Depth = 10) {
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    # ConvertTo-Json escapes non-ASCII (e.g. Cyrillic release notes) as \uXXXX by default
    # in Windows PowerShell 5.1; unescape them so the file stays human-readable like the
    # existing files in this repo.
    return [System.Text.RegularExpressions.Regex]::Replace(
        $json,
        '\\u(?<val>[0-9a-fA-F]{4})',
        { param($m) [string][char]([convert]::ToInt32($m.Groups['val'].Value, 16)) }
    )
}

function Save-JsonFile([string]$Path, $Object) {
    $json = ConvertTo-JsonUtf8 -InputObject $Object -Depth 10
    # Backend (Python) and the Updater (C#) both parse these files expecting plain UTF-8
    # with no BOM; Set-Content -Encoding UTF8 would add one and can break json.load() there.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-JsonFile([string]$Path) {
    # Get-Content -Raw with no explicit encoding misreads these BOM-less UTF-8 files (mangles
    # Cyrillic release notes) on this host - read the bytes directly as UTF-8 instead.
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $text | ConvertFrom-Json
}

function Assert-PathExists([string]$Path, [string]$Description) {
    if (-not (Test-Path $Path)) {
        throw "$Description not found: $Path"
    }
}

function Copy-DirMirror([string]$Source, [string]$Dest) {
    Assert-PathExists $Source "Source directory"
    if (Test-Path $Dest) {
        Remove-Item -Path $Dest -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Dest -Recurse -Force
}

# ---------- start ----------

try {
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    Write-Warn2 "Could not set console encoding to UTF-8 - typed/pasted Cyrillic may come out corrupted. Verify release_notes before confirming step 18."
}

Write-Section "Melcosoft release script"
Write-Host "Releases repo: $ReleasesRepo"
Write-Host "Repo root:     $RepoRoot"

$currentBranch = git -C $ReleasesRepo branch --show-current
Write-Host "Current branch: $currentBranch"
if ($currentBranch -ne "main") {
    if (-not (Confirm-Step "Not on 'main' (currently '$currentBranch'). Continue anyway?")) {
        Write-Host "Aborted."
        exit 1
    }
}

$latest = Get-JsonFile $LatestJsonPath
$releaseManifest = Get-JsonFile $ReleaseManifestPath

# ---------- 1-2: ask for release_notes / version ----------

Write-Section "Step 1-2: release notes and version"
Write-Host "Current release_manifest.json release_notes:" -ForegroundColor DarkGray
Write-Host $releaseManifest.release_notes -ForegroundColor DarkGray
$releaseNotes = Read-MultilineInput "Enter new release_notes:"

Write-Host "Current release_manifest.json version: $($releaseManifest.version)" -ForegroundColor DarkGray
$version = Read-Host "Enter new version"
$version = $version.Trim()
if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Version cannot be empty."
}

# ---------- 3-4: write into latest.json ----------

Write-Section "Step 3-4: updating latest.json"
$latest.release_notes  = $releaseNotes
$latest.latest_version = $version
Write-Ok "latest_version -> $version"

# ---------- also write into release_manifest.json (asked for in step 1-2) ----------

$releaseManifest.release_notes = $releaseNotes
$releaseManifest.version = $version

# ---------- 5: min_supported_version ----------

Write-Section "Step 5: min_supported_version"
Write-Host "Current min_supported_version: $($latest.min_supported_version)" -ForegroundColor DarkGray
if (Confirm-Step "Update min_supported_version?") {
    $newMin = Read-Host "Enter new min_supported_version"
    $latest.min_supported_version = $newMin.Trim()
    Write-Ok "min_supported_version -> $($latest.min_supported_version)"
} else {
    Write-Host "Keeping min_supported_version as-is."
}

# ---------- 6: download_endpoint ----------

$latest.download_endpoint = "$version/package.zip"
Write-Ok "download_endpoint -> $($latest.download_endpoint)"

# ---------- 7: backend ----------

Write-Section "Step 7: backend"
if (Confirm-Step "Update backend?") {
    $backendDist = Join-Path $RepoRoot "Melcosoft.Backend\dist\MelcosoftBackend"
    $backendInternal = Join-Path $backendDist "_internal"
    $backendExe = Join-Path $backendDist "MelcosoftBackend.exe"
    $backendVersionFile = Join-Path $backendDist "_internal.version"
    $destBackend = Join-Path $LatestFiles "backend"

    Assert-PathExists $backendInternal "Backend _internal folder"
    Assert-PathExists $backendExe "MelcosoftBackend.exe"
    Assert-PathExists $backendVersionFile "_internal.version"

    New-Item -ItemType Directory -Path $destBackend -Force | Out-Null

    $destInternalZip = Join-Path $destBackend "_internal.zip"
    if (Test-Path $destInternalZip) { Remove-Item $destInternalZip -Force }
    Write-Host "Zipping _internal..."
    Compress-Archive -Path (Join-Path $backendInternal "*") -DestinationPath $destInternalZip -Force

    Copy-Item $backendVersionFile (Join-Path $destBackend "_internal.version") -Force
    Copy-Item $backendExe (Join-Path $destBackend "MelcosoftBackend.exe") -Force

    Write-Ok "Backend updated."
} else {
    Write-Host "Skipping backend."
}

# ---------- 8: updater ----------

Write-Section "Step 8: updater"
if (Confirm-Step "Update updater?") {
    $updaterExe = Join-Path $RepoRoot "Melcosoft.Updater\Melcosoft.Updater\bin\Release\net8.0-windows\win-x64\publish\Melcosoft.Updater.exe"
    $destUpdater = Join-Path $LatestFiles "updater"

    Assert-PathExists $updaterExe "Melcosoft.Updater.exe (publish output)"
    New-Item -ItemType Directory -Path $destUpdater -Force | Out-Null
    Copy-Item $updaterExe (Join-Path $destUpdater "Melcosoft.Updater.exe") -Force

    Write-Ok "Updater updated."
} else {
    Write-Host "Skipping updater."
}

# ---------- 9: service ----------

Write-Section "Step 9: service"
if (Confirm-Step "Update service?") {
    $serviceExe = Join-Path $RepoRoot "Melcosoft.Service\bin\Release\net8.0-windows\win-x64\publish\MelcosoftService.exe"
    $destService = Join-Path $LatestFiles "service"

    Assert-PathExists $serviceExe "MelcosoftService.exe (publish output)"
    New-Item -ItemType Directory -Path $destService -Force | Out-Null
    Copy-Item $serviceExe (Join-Path $destService "MelcosoftService.exe") -Force

    Write-Ok "Service updated."
} else {
    Write-Host "Skipping service."
}

# ---------- 10: extension ----------

Write-Section "Step 10: extension"
if (Confirm-Step "Update extension?") {
    $extRoot = Join-Path $RepoRoot "Melcosoft.Extension"
    $extDll = Join-Path $extRoot "bin\x86\Release\net48\Melcosoft.dll"
    $extYaml = Join-Path $extRoot "extension.yaml"
    $extResources = Join-Path $extRoot "Resources"
    $extLocalization = Join-Path $extRoot "Localization"
    $destExt = Join-Path $LatestFiles "roaming_playnite\Extensions\Melcosoft"

    Assert-PathExists $extDll "Melcosoft.dll (build output)"
    Assert-PathExists $extYaml "extension.yaml"
    Assert-PathExists $extResources "Extension Resources folder"
    Assert-PathExists $extLocalization "Extension Localization folder"

    New-Item -ItemType Directory -Path $destExt -Force | Out-Null
    Copy-Item $extDll (Join-Path $destExt "Melcosoft.dll") -Force
    Copy-Item $extYaml (Join-Path $destExt "extension.yaml") -Force
    Copy-DirMirror $extResources (Join-Path $destExt "Resources")
    Copy-DirMirror $extLocalization (Join-Path $destExt "Localization")

    Write-Ok "Extension updated."
} else {
    Write-Host "Skipping extension."
}

# ---------- 11: launcher ----------

Write-Section "Step 11: launcher"
if (Confirm-Step "Update launcher?") {
    $playniteDll = Join-Path $RepoRoot "Melcosoft.Launcher\source\Playnite\bin\x86\Release\Playnite.dll"
    $desktopExe = Join-Path $RepoRoot "Melcosoft.Launcher\source\Playnite.DesktopApp\bin\x86\Release\Playnite.DesktopApp.exe"
    $fullscreenExe = Join-Path $RepoRoot "Melcosoft.Launcher\source\Playnite.FullscreenApp\bin\x86\Release\Playnite.FullscreenApp.exe"
    $launcherLocalization = Join-Path $RepoRoot "Melcosoft.Launcher\source\Playnite\bin\x86\Release\Localization"
    $destLauncher = Join-Path $LatestFiles "launcher"

    Assert-PathExists $playniteDll "Playnite.dll"
    Assert-PathExists $desktopExe "Playnite.DesktopApp.exe"
    Assert-PathExists $fullscreenExe "Playnite.FullscreenApp.exe"
    Assert-PathExists $launcherLocalization "Playnite Localization folder"

    New-Item -ItemType Directory -Path $destLauncher -Force | Out-Null
    Copy-Item $playniteDll (Join-Path $destLauncher "Playnite.dll") -Force
    Copy-Item $desktopExe (Join-Path $destLauncher "Playnite.DesktopApp.exe") -Force
    Copy-Item $fullscreenExe (Join-Path $destLauncher "Playnite.FullscreenApp.exe") -Force
    Copy-DirMirror $launcherLocalization (Join-Path $destLauncher "Localization")

    Write-Ok "Launcher files updated."
    Write-Warn2 "Themes were NOT touched by this script - update latest_files\launcher\Themes manually if needed."
} else {
    Write-Host "Skipping launcher."
}

# ---------- 12: config ----------

Write-Section "Step 12: config"
if (Confirm-Step "Should config be changed for this release?") {
    Write-Warn2 "Update latest_files\config\config.json manually - this script does not touch it."
    Read-Host "Press Enter once you're done (or have decided not to change it)"
}

# ---------- 13: file_manifest.json ----------

Write-Section "Step 13: file_manifest.json"
if (Confirm-Step "Should file_manifest.json be changed for this release?") {
    Write-Warn2 "Update $FileManifestPath manually now."
    while (-not (Confirm-Step "Type y once file_manifest.json is updated and ready")) {
        Write-Host "Waiting..."
    }
}

# ---------- save release_manifest.json and latest.json so far ----------

Save-JsonFile -Path $ReleaseManifestPath -Object $releaseManifest
Save-JsonFile -Path $LatestJsonPath -Object $latest
Write-Ok "release_manifest.json and latest.json saved."

# ---------- 14: zip latest_files ----------

Write-Section "Step 14: packaging"
$tempZip = Join-Path $ReleasesRepo "package.zip"
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }

Write-Host "Zipping latest_files -> package.zip ..."
Compress-Archive -Path (Join-Path $LatestFiles "*") -DestinationPath $tempZip -CompressionLevel Optimal
Write-Ok "package.zip created."

# ---------- 15: move into version folder ----------

Write-Section "Step 15: placing package"
$versionDir = Join-Path $ReleasesRepo $version
$finalZipPath = Join-Path $versionDir "package.zip"

$committedVersions = git -C $ReleasesRepo log --pretty=format: --name-only -- "$version/" | Where-Object { $_ } | Select-Object -Unique
if ($committedVersions) {
    Write-Warn2 "Version folder '$version' already exists in git history. Version folders are supposed to be immutable."
    if (-not (Confirm-Step "Overwrite anyway?")) {
        Write-Host "Aborted."
        exit 1
    }
}

New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
Move-Item -Path $tempZip -Destination $finalZipPath -Force
Write-Ok "package.zip -> $finalZipPath"

# ---------- 16: hash ----------

Write-Section "Step 16-17: SHA256"
$hashOutput = certutil -hashfile $finalZipPath SHA256
$hashLine = ($hashOutput | Select-Object -Index 1) -replace '\s', ''
$hashLine = $hashLine.ToLower()

if ($hashLine -notmatch '^[0-9a-f]{64}$') {
    throw "Could not parse SHA256 from certutil output:`n$hashOutput"
}

Write-Host "SHA256: $hashLine"

# ---------- 17: write sha256 into latest.json ----------

$latest.sha256 = $hashLine
Save-JsonFile -Path $LatestJsonPath -Object $latest
Write-Ok "latest.json sha256 updated."

# ---------- 18: final confirmation ----------

Write-Section "Step 18: review before publishing"
Write-Host "Version:            $version"
Write-Host "min_supported:      $($latest.min_supported_version)"
Write-Host "download_endpoint:  $($latest.download_endpoint)"
Write-Host "sha256:             $($latest.sha256)"
Write-Host "mandatory:          $($latest.mandatory)"
Write-Host "release_notes:"
Write-Host $latest.release_notes
Write-Host ""

if (-not (Confirm-Step "Everything looks good - commit and push?")) {
    Write-Host "Stopping before commit/push. Working tree changes are left in place for review."
    exit 0
}

# ---------- 19-23: commit and push (Releases, then Launcher, then root -
# in that order so the root repo's submodule pointers land on commits that
# already exist on their remotes) ----------

function Invoke-GitCommitPush([string]$RepoPath, [string]$Label, [string]$Message) {
    Write-Section "$Label - git add / commit / push"

    git -C $RepoPath add .
    if ($LASTEXITCODE -ne 0) { throw "git add failed in $RepoPath." }

    $pending = git -C $RepoPath status --porcelain --cached
    if ([string]::IsNullOrWhiteSpace($pending)) {
        Write-Host "Nothing to commit in $RepoPath, skipping commit/push."
        return
    }

    git -C $RepoPath commit -m $Message
    if ($LASTEXITCODE -ne 0) { throw "git commit failed in $RepoPath." }

    git -C $RepoPath push
    if ($LASTEXITCODE -ne 0) { throw "git push failed in $RepoPath. Commit succeeded locally - push manually once resolved." }

    Write-Ok "$Label pushed."
}

$releaseMessage = "Release $version"

# 19-21: Melcosoft.Releases
Invoke-GitCommitPush -RepoPath $ReleasesRepo -Label "Step 19-21: Melcosoft.Releases" -Message $releaseMessage

# 22: Melcosoft.Launcher
$launcherRepo = Join-Path $RepoRoot "Melcosoft.Launcher"
Invoke-GitCommitPush -RepoPath $launcherRepo -Label "Step 22: Melcosoft.Launcher" -Message $releaseMessage

# 23: root repo (also records the updated submodule pointers for the two above)
Invoke-GitCommitPush -RepoPath $RepoRoot -Label "Step 23: root repo" -Message $releaseMessage

Write-Ok "Release $version published."

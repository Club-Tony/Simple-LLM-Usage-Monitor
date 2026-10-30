# Builds the Simple LLM Usage Monitor release into dist\ in the tool folder (gitignored):
#   LLMUsageMonitor-Setup-v<ver>.bat   the one-click installer: the ZIP below, embedded as Base64
#   LLMUsageMonitor-v<ver>.zip         the same files plus Install.bat, for people who read first
#   release.json                       version, source commit, file hashes, runtime pins, network facts
#   SHA256SUMS.txt                     hashes of the BAT and the ZIP
# The tool folder is this script's parent's parent: the public repo's root, or a host repo's copy
# of it. Every path below is relative to it, so the build never reads outside it.
# The version comes from package.json. Text files are LF-normalised (.bat files get
# CRLF), so two builds of the same source are byte-identical. A tracked or new file in the
# tool folder that is neither shipped nor excluded below stops the build, so nothing ships by
# accident. Uncommitted changes in the tool folder stop it too, unless -AllowDirty
# (local test builds; release.json still records the commit and the dirty state).
# ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
[CmdletBinding()]
param(
    [string]$OutputRoot = '',
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$InstallerDir = $PSScriptRoot
$MonitorDir = Split-Path -Path $InstallerDir -Parent
if (-not $OutputRoot) { $OutputRoot = Join-Path -Path $MonitorDir -ChildPath 'dist' }

$ProductId = 'LLMUsageMonitor'
$ProductName = 'Simple LLM Usage Monitor'
# sqlite3.exe 3.47.2, byte-identical to sqlite.org's sqlite-tools-win-x64-3470200.zip (README, Setup).
$SqliteSha256 = '5e33fe030fb7c3bbe2bca1f70f21a406716961aefdfb1bc030d7c65b7db055e9'

# Installed flat into the install folder (paths relative to the tool folder).
$AppFiles = @(
    'Usage_Monitor.ahk', 'Usage_Monitor_GUI.ahk', 'Get-LLMUsageSnapshot.ps1', 'Protect-CacheValue.ps1',
    'usage-scraper.mjs', 'token-cache.mjs', 'debug-redaction.mjs',
    'claude-account-label.mjs', 'sqlite-tool.mjs', 'firefox-cookie-db.mjs', 'usage-classification.mjs',
    'cli-credentials.mjs', 'provider-settings.mjs', 'addon-provider.mjs', 'sqlite3.exe',
    'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.md', 'SECURITY.md'
)
# Installed into setup\ (paths relative to the tool folder).
$SetupFiles = @('installer\Setup-LLMUsageMonitor.ps1', 'installer\runtime-pins.json', 'installer\Resolve-AHK-Runtime.ps1')
# Part of the build but not shipped as files (paths relative to the tool folder, / separators).
$BuildOnly = @('installer/Install.bat', 'installer/BundleStub.cmd.txt', 'installer/BundleExtractor.ps1', 'installer/Build-UsageMonitorRelease.ps1')
# Never shipped: tests, the npm manifest and the git files.
$ExcludedPatterns = @('*.test.mjs', 'Test-*.ps1', 'installer/Test-*.ps1', 'package.json', 'package-lock.json', '.gitignore', '.gitattributes')

function Get-Sha256Hex([byte[]]$Bytes) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function Get-FileSha256Hex([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

$Latin1 = [Text.Encoding]::GetEncoding(28591)   # maps every byte to one char and back
function Test-BinaryFile([string]$Path) { return ([IO.Path]::GetExtension($Path) -eq '.exe') }

# File bytes with CRLF turned into LF (or every line ending into CRLF for .bat and the stub).
function Read-NormalizedBytes([string]$Path, [bool]$Crlf = $false) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if (Test-BinaryFile $Path) { return ,$bytes }
    $text = $Latin1.GetString($bytes).Replace("`r`n", "`n")
    if ($Crlf) { $text = $text.Replace("`n", "`r`n") }
    return ,$Latin1.GetBytes($text)
}

function Write-Bytes([string]$Path, [byte[]]$Bytes) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-LfJson([string]$Path, $Value) {
    $json = ($Value | ConvertTo-Json -Depth 8).Replace("`r`n", "`n") + "`n"
    Write-Bytes $Path ([Text.Encoding]::UTF8.GetBytes($json))
}

function Assert-Ascii([string]$Label, [byte[]]$Bytes) {
    foreach ($b in $Bytes) { if ($b -gt 127) { throw "$Label contains a non-ASCII byte." } }
}

function Invoke-Git([string[]]$GitArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $MonitorDir @GitArgs 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    $lines = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_ })
    return @{ Code = $code; Lines = $lines }
}

# The commit a release was built from, and whether the shipped sources differ from it.
function Get-SourceProvenance {
    $result = [ordered]@{ Commit = 'unknown'; Dirty = $true; Problems = New-Object System.Collections.Generic.List[string] }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        $result.Problems.Add('git is not available, so the source commit cannot be recorded')
        return $result
    }
    $head = Invoke-Git @('rev-parse', '--verify', 'HEAD')
    if ($head.Code -eq 0 -and $head.Lines.Count -eq 1 -and $head.Lines[0] -match '^[0-9a-f]{40}$') { $result.Commit = $head.Lines[0] }
    else { $result.Problems.Add('the source commit is unknown') }
    $status = Invoke-Git @('status', '--porcelain', '--', '.')
    if ($status.Code -ne 0) { $result.Problems.Add('the working tree state is unknown') }
    elseif ($status.Lines.Count -gt 0) {
        $shown = @($status.Lines | Select-Object -First 5 | ForEach-Object { $_.Trim() }) -join ', '
        if ($status.Lines.Count -gt 5) { $shown += ', ...' }
        $result.Problems.Add("the tool folder has $($status.Lines.Count) uncommitted change(s): $shown")
    } else { $result.Dirty = $false }
    return $result
}

# Every tracked or new (not ignored) file in the tool folder must be shipped, build-only or excluded.
function Assert-EveryFileClassified {
    # Run from the tool folder, ls-files prints paths relative to it.
    $listing = Invoke-Git @('ls-files', '--cached', '--others', '--exclude-standard', '--', '.')
    if ($listing.Code -ne 0) { throw 'git ls-files failed.' }
    $unlisted = New-Object System.Collections.Generic.List[string]
    foreach ($line in $listing.Lines) {
        $relative = $line
        if (-not (Test-Path -LiteralPath (Join-Path -Path $MonitorDir -ChildPath $relative) -PathType Leaf)) { continue }   # deleted in the working tree
        if ($AppFiles -contains $relative) { continue }
        if ($BuildOnly -contains $relative) { continue }
        if ($relative.Replace('/', '\') -in @($SetupFiles)) { continue }
        $excluded = $false
        foreach ($pattern in $ExcludedPatterns) { if ($relative -like $pattern) { $excluded = $true; break } }
        if (-not $excluded) { $unlisted.Add($relative) }
    }
    if ($unlisted.Count -gt 0) {
        throw ("These files in the tool folder are neither shipped nor excluded in Build-UsageMonitorRelease.ps1: " + ($unlisted -join ', '))
    }
}

# The shipped text must not name the person or the profile folder that built it.
function Assert-NoBuilderTraces([string]$Root) {
    $needles = @()
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) { $needles += $env:USERNAME }
    if ($env:USERPROFILE) { $needles += $env:USERPROFILE; $needles += $env:USERPROFILE.Replace('\', '/') }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File)) {
        if (Test-BinaryFile $file.FullName) { continue }
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($needle in $needles) {
            if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "$($file.FullName.Substring($Root.Length + 1)) contains the builder's user name or profile path."
            }
        }
    }
}

function Read-AhkPin {
    $resolver = Join-Path -Path $InstallerDir -ChildPath 'Resolve-AHK-Runtime.ps1'
    return (& {
        . $resolver
        @{ Version = [string]$AhkV1Version; Urls = @($AhkV1ZipUrls); ZipSha256 = ([string]$AhkV1ZipSha256).ToLowerInvariant() }
    })
}

# Entries sorted by ordinal name, every timestamp 1980-01-01, so the same files give the same bytes.
function New-DeterministicZip([string]$PackageRoot, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    $base = Split-Path -Path $PackageRoot -Parent
    $names = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File | ForEach-Object { $_.FullName.Substring($base.Length + 1).Replace('\', '/') })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Delete($Destination) }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
    try {
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($name in $names) {
                $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = New-Object DateTimeOffset(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $bytes = [IO.File]::ReadAllBytes((Join-Path -Path $base -ChildPath $name.Replace('/', '\')))
                $out = $entry.Open()
                try { $out.Write($bytes, 0, $bytes.Length) } finally { $out.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function New-SelfExtractingBat([string]$ZipPath, [string]$Destination) {
    $zipBytes = [IO.File]::ReadAllBytes($ZipPath)
    $stub = $Latin1.GetString((Read-NormalizedBytes (Join-Path -Path $InstallerDir -ChildPath 'BundleStub.cmd.txt') $true))
    if (-not $stub.Contains('__PAYLOAD_SHA256__')) { throw 'BundleStub.cmd.txt has no __PAYLOAD_SHA256__ placeholder.' }
    $stub = $stub.Replace('__PAYLOAD_SHA256__', (Get-Sha256Hex $zipBytes))
    $extractor = $Latin1.GetString((Read-NormalizedBytes (Join-Path -Path $InstallerDir -ChildPath 'BundleExtractor.ps1') $true))
    # The stub cuts the extractor out between the last two marker lines, so the extractor itself
    # must contain neither marker.
    if ($extractor.Contains('#===EXTRACTOR===') -or $extractor.Contains('#===PAYLOAD===')) { throw 'BundleExtractor.ps1 must not contain a marker line.' }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($stub.TrimEnd("`r", "`n")).Append("`r`n")
    [void]$builder.Append("#===EXTRACTOR===`r`n")
    [void]$builder.Append($extractor.TrimEnd("`r", "`n")).Append("`r`n")
    [void]$builder.Append("#===PAYLOAD===`r`n")
    [void]$builder.Append([Convert]::ToBase64String($zipBytes)).Append("`r`n")
    $bytes = [Text.Encoding]::ASCII.GetBytes($builder.ToString())
    Assert-Ascii 'The setup BAT' ($Latin1.GetBytes($builder.ToString()))
    Write-Bytes $Destination $bytes
}

# --- Build --------------------------------------------------------------------------------------
$packageJson = Get-Content -LiteralPath (Join-Path -Path $MonitorDir -ChildPath 'package.json') -Raw | ConvertFrom-Json
$version = [string]$packageJson.version
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "package.json has an unexpected version: $version" }

$provenance = Get-SourceProvenance
if ($provenance.Problems.Count -gt 0) {
    $reasons = $provenance.Problems -join '; '
    if (-not $AllowDirty) { throw "Refusing to build a release: $reasons. Commit first, or pass -AllowDirty for a local test build." }
    Write-Warning "-AllowDirty: $reasons. release.json records sourceCommit=$($provenance.Commit), sourceDirty=$($provenance.Dirty.ToString().ToLowerInvariant())."
}
Assert-EveryFileClassified

$sqlitePath = Join-Path -Path $MonitorDir -ChildPath 'sqlite3.exe'
if ((Get-FileSha256Hex $sqlitePath) -ne $SqliteSha256) { throw 'sqlite3.exe does not match its recorded SHA-256.' }

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).ProviderPath
$work = Join-Path -Path $OutputRoot -ChildPath '.release-work'
if (Test-Path -LiteralPath $work) { [IO.Directory]::Delete($work, $true) }
$packageName = "$ProductId-v$version"
$packageRoot = Join-Path -Path $work -ChildPath $packageName
New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

$installed = New-Object System.Collections.Generic.List[string]   # paths relative to the package root
foreach ($relative in $AppFiles) {
    Write-Bytes (Join-Path -Path $packageRoot -ChildPath $relative) (Read-NormalizedBytes (Join-Path -Path $MonitorDir -ChildPath $relative))
    $installed.Add($relative)
}
foreach ($relative in $SetupFiles) {
    $leaf = Split-Path -Path $relative -Leaf
    $bytes = Read-NormalizedBytes (Join-Path -Path $MonitorDir -ChildPath $relative)
    if ($leaf -like '*.ps1') { Assert-Ascii $leaf $bytes }
    Write-Bytes (Join-Path -Path $packageRoot -ChildPath "setup\$leaf") $bytes
    $installed.Add("setup\$leaf")
}
Write-Bytes (Join-Path -Path $packageRoot -ChildPath 'Install.bat') (Read-NormalizedBytes (Join-Path -Path $InstallerDir -ChildPath 'Install.bat') $true)

$ahkPin = Read-AhkPin
$nodePin = (Get-Content -LiteralPath (Join-Path -Path $InstallerDir -ChildPath 'runtime-pins.json') -Raw | ConvertFrom-Json).node

$installText = @"
$ProductName $version

Install: double-click Install.bat in this extracted folder. The one-file
$ProductId-Setup-v$version.bat from the same release does the same thing.

Setup installs for your Windows account only, with no administrator rights, into
%LOCALAPPDATA%\Programs\$ProductId. It downloads AutoHotkey v$($ahkPin.Version) (www.autohotkey.com)
and Node.js $($nodePin.version) (nodejs.org), each checked against a SHA-256 pinned in setup\, and
adds a Start Menu shortcut and an entry in Settings > Apps. Starting with Windows is optional.
PATH is not changed.

Uninstall: Settings > Apps > Installed apps > $ProductName, or run the installer again.

This release is not code-signed, so Windows may warn about an unknown publisher. Download it
only from the project's release page and compare its SHA-256 with that page's SHA256SUMS.txt.

The app sends no telemetry. README.md ("Privacy and data") lists everything it reads, writes
and connects to.
"@
Write-Bytes (Join-Path -Path $packageRoot -ChildPath 'README-INSTALL.txt') $Latin1.GetBytes($installText.Replace("`r`n", "`n").Replace("`n", "`r`n"))

$fileRecords = @(foreach ($relative in $installed) {
    [ordered]@{ path = $relative; sha256 = (Get-FileSha256Hex (Join-Path -Path $packageRoot -ChildPath $relative)) }
})
$release = [ordered]@{
    schemaVersion = 1
    product       = $ProductId
    name          = $ProductName
    version       = $version
    sourceCommit  = $provenance.Commit
    sourceDirty   = [bool]$provenance.Dirty
    files         = $fileRecords
    runtimes      = [ordered]@{
        autohotkey = [ordered]@{ version = $ahkPin.Version; zipSha256 = $ahkPin.ZipSha256; urls = $ahkPin.Urls; keeps = @('AutoHotkeyU64.exe', 'license.txt') }
        node       = [ordered]@{ version = [string]$nodePin.version; zipSha256 = [string]$nodePin.zipSha256; url = ("{0}/{1}/node-{1}-win-x64.zip" -f $nodePin.distBaseUrl, $nodePin.version); keeps = @('node.exe', 'LICENSE') }
    }
    install       = [ordered]@{ scope = 'per-user'; admin = $false; program = "%LOCALAPPDATA%\Programs\$ProductId"; data = "%LOCALAPPDATA%\$ProductId"; pathChanged = $false }
    network       = [ordered]@{ telemetry = $false; updateCheck = 'none'; setupHosts = @('www.autohotkey.com', 'github.com (AutoHotkey fallback)', 'nodejs.org') }
}
Write-LfJson (Join-Path -Path $packageRoot -ChildPath 'release.json') $release
$installed.Add('release.json')

$manifestFiles = @(foreach ($relative in $installed) {
    $path = Join-Path -Path $packageRoot -ChildPath $relative
    [ordered]@{ path = $relative; size = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileSha256Hex $path) }
})
Write-LfJson (Join-Path -Path $packageRoot -ChildPath 'setup\payload-manifest.json') ([ordered]@{ product = $ProductId; version = $version; files = $manifestFiles })

Assert-NoBuilderTraces $packageRoot

$zipPath = Join-Path -Path $OutputRoot -ChildPath "$packageName.zip"
New-DeterministicZip $packageRoot $zipPath
$batPath = Join-Path -Path $OutputRoot -ChildPath "$ProductId-Setup-v$version.bat"
New-SelfExtractingBat $zipPath $batPath
Copy-Item -LiteralPath (Join-Path -Path $packageRoot -ChildPath 'release.json') -Destination (Join-Path -Path $OutputRoot -ChildPath 'release.json') -Force
$sumLines = @(foreach ($path in @($batPath, $zipPath)) { "$(Get-FileSha256Hex $path)  $(Split-Path -Path $path -Leaf)" })
Write-Bytes (Join-Path -Path $OutputRoot -ChildPath 'SHA256SUMS.txt') ([Text.Encoding]::ASCII.GetBytes(($sumLines -join "`n") + "`n"))
[IO.Directory]::Delete($work, $true)

foreach ($path in @($batPath, $zipPath, (Join-Path -Path $OutputRoot -ChildPath 'release.json'), (Join-Path -Path $OutputRoot -ChildPath 'SHA256SUMS.txt'))) {
    $item = Get-Item -LiteralPath $path
    Write-Output ('{0}  {1,10:N0} bytes  {2}' -f (Get-FileSha256Hex $path), $item.Length, $item.Name)
}

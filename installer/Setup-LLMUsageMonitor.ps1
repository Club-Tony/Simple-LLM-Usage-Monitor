# Simple LLM Usage Monitor setup: install, reinstall and uninstall for the current Windows user.
# No administrator rights, no PATH change. It runs from a release package (the self-contained BAT
# or the ZIP's Install.bat), where the app files sit beside this script's setup\ folder and
# setup\payload-manifest.json lists every one of them, or from an installed copy's setup\ folder
# (the Settings > Apps uninstall).
#
#   -Action Interactive   first run installs; on an installed PC: [1] Reinstall [2] Uninstall [3] Close
#   -Action Install | Reinstall | Uninstall | Status
#
# What it owns: the install folder (%LOCALAPPDATA%\Programs\LLMUsageMonitor, removed whole), the two
# shortcuts named "LLM Usage Monitor.lnk" when they point into that folder, one per-user Settings >
# Apps key, and in the data folder (%LOCALAPPDATA%\LLMUsageMonitor) only the files the app itself
# writes. Anything else is left where it is and listed.
#
# ASCII only: Windows PowerShell 5.1 reads BOM-less files as ANSI.
[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'Install', 'Reinstall', 'Uninstall', 'Status')]
    [string]$Action = 'Interactive',
    [string]$InstallRoot = '',
    [Alias('DataDir')][string]$DataFolder = '',
    [string]$StartMenuDir = '',
    [string]$StartupDir = '',
    # Test only: write the Settings > Apps entry to this JSON file instead of the registry.
    [string]$RegistrationFile = '',
    # A folder to look in for the pinned runtime zips when a download fails (the BAT's own folder).
    [string]$LocalPackageDir = '',
    # Test only: serve every download from <mirror>\<host>\<path>, and read the pins from a file.
    [string]$OfflineMirror = '',
    [string]$RuntimePinsFile = '',
    [switch]$NonInteractive,
    [switch]$Startup,
    [switch]$NoStartup,
    [switch]$KeepData,
    [switch]$KeepSettings,
    [switch]$NoLaunch,
    [switch]$FromAppsEntry,
    [switch]$LoadOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Names shared with the app: the data folder name is usageMonitorAppDirName in Usage_Monitor_GUI.ahk
# and the shortcut name is usageMonitorStandaloneLinkName in Usage_Monitor.ahk (a test checks both).
$script:ProductId = 'LLMUsageMonitor'
$script:ProductName = 'Simple LLM Usage Monitor'
$script:LinkName = 'LLM Usage Monitor.lnk'
$script:Publisher = 'Tony'
$script:AppsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LLMUsageMonitor'
$script:SetupDir = $PSScriptRoot
$script:PayloadRoot = Split-Path -Path $PSScriptRoot -Parent
$script:ExitCode = 0
$script:TestMode = ($env:LLMUSAGE_SETUP_TEST -eq '1')
$script:PowerShellExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:MaxDownloadBytes = 200MB
$script:MissingRuntimes = New-Object System.Collections.Generic.List[string]
$script:Leftovers = New-Object System.Collections.Generic.List[string]
$script:MirrorRoot = ''
$script:UsingTestPins = $false
$script:Pins = $null
$script:Manifest = $null
$script:Release = $null

# --- Console ------------------------------------------------------------------------------------
# Named console colours only: they vanish cleanly when the output is redirected. Every line keeps a
# text prefix, so nothing depends on colour.
function Write-Step([string]$Text) { Write-Host "-> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "[OK] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "     $Text" -ForegroundColor DarkGray }
function Write-Warn([string]$Text) { Write-Host "[!] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "[X] $Text" -ForegroundColor Red }

function Read-Line {
    if ([Console]::IsInputRedirected) {
        $line = [Console]::In.ReadLine()
    } else {
        $line = Read-Host
    }
    if ($null -eq $line) { return '' }
    return ([string]$line).Trim().TrimStart([char]0xFEFF)
}

# Every prompt sits on its own line after a blank one.
function Read-Choice([string]$Prompt) {
    Write-Host ''
    Write-Host "$Prompt " -NoNewline
    return (Read-Line)
}

function Test-Yes([string]$Answer) { return ($Answer -match '^(?i)y(es)?$') }

function Stop-Setup([int]$Code, [string]$Message) {
    $script:ExitCode = $Code
    throw $Message
}

function Format-MB([double]$Bytes) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }

# --- Paths and ownership ------------------------------------------------------------------------
function Get-FullPath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-SamePath([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals((Get-FullPath $A), (Get-FullPath $B), [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathUnder([string]$Path, [string]$Root) {
    if (-not $Path -or -not $Root) { return $false }
    return $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-DefaultLocations {
    if (-not $env:LOCALAPPDATA) { Stop-Setup 1 'LOCALAPPDATA is not set, so there is no per-user folder to install into.' }
    return @{
        Root      = Join-Path -Path $env:LOCALAPPDATA -ChildPath ('Programs\' + $script:ProductId)
        Data      = Join-Path -Path $env:LOCALAPPDATA -ChildPath $script:ProductId
        StartMenu = [Environment]::GetFolderPath('Programs')
        Startup   = [Environment]::GetFolderPath('Startup')
    }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-InstallState([string]$Dir) {
    if (-not $Dir) { return $null }
    $file = Join-Path -Path $Dir -ChildPath 'install-state.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    try { $state = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { return $null }
    if ((Get-Prop $state 'product') -ne $script:ProductId) { return $null }
    return $state
}

# A folder this installer made: the expected leaf name and a state file naming this product.
function Test-OwnedTree([string]$Dir, [string]$LeafName) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    if ((Split-Path -Path $Dir.TrimEnd('\') -Leaf) -ne $LeafName) { return $false }
    return ($null -ne (Read-InstallState $Dir))
}

function Test-OwnedRoot([string]$Root) { return (Test-OwnedTree $Root $script:ProductId) }

function Assert-SafeRoot([string]$Root) {
    if ((Split-Path -Path $Root -Leaf) -ne $script:ProductId) {
        Stop-Setup 1 "The install folder must be named $($script:ProductId): $Root"
    }
    if ([string]::IsNullOrEmpty((Split-Path -Path $Root -Parent))) { Stop-Setup 1 "Refusing to install at a drive root: $Root" }
}

function Test-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

# Deletes one owned file or folder tree, retrying briefly (antivirus scans hold files open).
# Never follows or deletes through a reparse point. Returns $true when it is gone.
function Remove-OwnedItem([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (Test-ReparsePoint $Path) {
        $script:Leftovers.Add("$Path (a link; left alone)")
        return $false
    }
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path -PathType Container) {
                [IO.Directory]::Delete($Path, $true)
            } else {
                [IO.File]::Delete($Path)
            }
            return $true
        } catch {
            if ($attempt -eq 10) {
                $script:Leftovers.Add("$Path (could not delete: $($_.Exception.Message))")
                return $false
            }
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}

function Move-WithRetry([string]$From, [string]$To) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            [IO.Directory]::Move($From, $To)
            return
        } catch {
            if ($attempt -eq 10) { throw "Could not move $From to $To ($($_.Exception.Message)). Close any window or program using it and run setup again." }
            Start-Sleep -Milliseconds 300
        }
    }
}

# --- Configuration ------------------------------------------------------------------------------
function Resolve-SetupConfig {
    $defaults = Get-DefaultLocations
    # Install folder: the argument, then the installed copy this script runs from, then the
    # Settings > Apps entry, then the default.
    if ($InstallRoot) {
        $root = Get-FullPath $InstallRoot
    } elseif (Test-OwnedRoot $script:PayloadRoot) {
        $root = Get-FullPath $script:PayloadRoot
    } else {
        $root = Get-FullPath $defaults.Root
        $entry = Read-AppsEntry
        $location = [string](Get-Prop $entry 'InstallLocation')
        if ($location -and (Test-OwnedRoot $location)) { $root = Get-FullPath $location }
    }
    Assert-SafeRoot $root
    $state = Read-InstallState $root
    $data = if ($DataFolder) { $DataFolder } elseif (Get-Prop $state 'dataFolder') { [string](Get-Prop $state 'dataFolder') } else { $defaults.Data }
    $startMenu = if ($StartMenuDir) { $StartMenuDir } else { $defaults.StartMenu }
    $startupDir = if ($StartupDir) { $StartupDir } else { $defaults.Startup }
    return @{
        Root          = $root
        Data          = Get-FullPath $data
        StartMenuLink = Join-Path -Path (Get-FullPath $startMenu) -ChildPath $script:LinkName
        StartupLink   = Join-Path -Path (Get-FullPath $startupDir) -ChildPath $script:LinkName
        State         = $state
        Defaults      = $defaults
    }
}

# The installer tests set LLMUSAGE_SETUP_TEST=1. Then every location must be given and must not be
# one of the real ones, and nothing may be launched, so a test can never touch this user's setup.
function Assert-TestFence {
    if (-not $script:TestMode) {
        if ($OfflineMirror -or $RuntimePinsFile -or $RegistrationFile) {
            Stop-Setup 1 'The -OfflineMirror, -RuntimePinsFile and -RegistrationFile options are for the installer tests only.'
        }
        return
    }
    $given = @{ InstallRoot = $InstallRoot; DataDir = $DataFolder; StartMenuDir = $StartMenuDir; StartupDir = $StartupDir; RegistrationFile = $RegistrationFile }
    foreach ($name in $given.Keys) {
        if (-not $given[$name]) { Stop-Setup 1 "Test mode needs -$name." }
    }
    if (-not $NoLaunch) { Stop-Setup 1 'Test mode needs -NoLaunch.' }
    $defaults = Get-DefaultLocations
    $pairs = @(@($InstallRoot, $defaults.Root), @($DataFolder, $defaults.Data), @($StartMenuDir, $defaults.StartMenu), @($StartupDir, $defaults.Startup))
    foreach ($pair in $pairs) {
        if ((Test-SamePath $pair[0] $pair[1]) -or (Test-PathUnder (Get-FullPath $pair[0]) $defaults.StartMenu) -or (Test-PathUnder (Get-FullPath $pair[0]) $defaults.Startup)) {
            Stop-Setup 1 "Test mode refuses a real location: $($pair[0])"
        }
    }
    if ($OfflineMirror) { $script:MirrorRoot = Get-FullPath $OfflineMirror }
}

function Read-JsonFile([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Value) {
    $json = $Value | ConvertTo-Json -Depth 8
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path -Parent) | Out-Null
    $temp = $Path + '.tmp'
    [IO.File]::WriteAllText($temp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

# The release package's manifest: every file setup copies into the install folder, with its size
# and SHA-256. Paths are relative and may not climb out of the package.
function Read-PayloadManifest {
    $file = Join-Path -Path $script:SetupDir -ChildPath 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Stop-Setup 1 'payload-manifest.json is missing. Run setup from a release package (the setup BAT or the extracted ZIP).'
    }
    $manifest = Read-JsonFile $file
    if ((Get-Prop $manifest 'product') -ne $script:ProductId) { Stop-Setup 1 'payload-manifest.json is for another product.' }
    foreach ($entry in @($manifest.files)) {
        $path = [string]$entry.path
        if (-not $path -or [IO.Path]::IsPathRooted($path) -or $path -match '(^|\\)\.\.(\\|$)' -or $path.Contains('/')) {
            Stop-Setup 1 "payload-manifest.json lists an unsafe path: $path"
        }
    }
    return $manifest
}

function Read-ReleaseInfo {
    $file = Join-Path -Path $script:PayloadRoot -ChildPath 'release.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Setup 1 'release.json is missing from the release package.' }
    return (Read-JsonFile $file)
}

# --- Helpers reused from the app ----------------------------------------------------------------
# The bridge (Get-LLMUsageSnapshot.ps1) holds the verified Node.js zip download and the resolver
# (Resolve-AHK-Runtime.ps1) the pinned AutoHotkey one. Both are dot-sourced inside this function,
# so their param() blocks and top-level variables stay in this function's scope and cannot reset
# setup's own parameters; only the functions setup calls are copied to script scope.
function Import-SetupHelpers {
    $bridge = Join-Path -Path $script:PayloadRoot -ChildPath 'Get-LLMUsageSnapshot.ps1'
    $resolver = Join-Path -Path $script:SetupDir -ChildPath 'Resolve-AHK-Runtime.ps1'
    foreach ($file in @($bridge, $resolver)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Setup 1 "The release package is missing $file" }
    }
    . $bridge
    . $resolver
    $ErrorActionPreference = 'Stop'
    foreach ($name in @('Get-VerifiedNodeZip', 'Save-PortableAhkV1Zip')) {
        $body = (Get-Item -LiteralPath "function:$name").ScriptBlock
        Set-Item -Path "function:script:$name" -Value $body
    }
    # Save-PortableAhkV1Zip names the version in its first message.
    $script:AhkV1Version = [string]$AhkV1Version
    return @{
        Version   = [string]$AhkV1Version
        Urls      = @($AhkV1ZipUrls)
        ZipSha256 = ([string]$AhkV1ZipSha256).ToLowerInvariant()
    }
}

# Both helpers download through these two names; setup points them at its own downloader.
function Invoke-NodeDownload { param([string]$Uri, [string]$OutFile) Invoke-SetupDownload -Uri $Uri -OutFile $OutFile }
function Invoke-AhkDownload { param([string]$Uri, [string]$OutFile) Invoke-SetupDownload -Uri $Uri -OutFile $OutFile }

function Read-RuntimePins($AhkFromResolver) {
    $file = Join-Path -Path $script:SetupDir -ChildPath 'runtime-pins.json'
    if ($RuntimePinsFile) {
        if (-not $script:TestMode -or -not $OfflineMirror) { Stop-Setup 1 '-RuntimePinsFile needs test mode and -OfflineMirror.' }
        $file = $RuntimePinsFile
        $script:UsingTestPins = $true
    }
    $raw = Read-JsonFile $file
    $node = Get-Prop $raw 'node'
    $ahk = Get-Prop $raw 'autohotkey'
    $nodeVersion = [string](Get-Prop $node 'version')
    $pins = @{
        Node = @{
            Version     = $nodeVersion
            DistBaseUrl = ([string](Get-Prop $node 'distBaseUrl')).TrimEnd('/')
            ZipSha256   = ([string](Get-Prop $node 'zipSha256')).ToLowerInvariant()
            ZipBytes    = [double](Get-Prop $node 'zipBytes')
            ZipName     = "node-$nodeVersion-win-x64.zip"
            EntryRoot   = "node-$nodeVersion-win-x64"
        }
        Ahk = @{
            Version   = $AhkFromResolver.Version
            Urls      = $AhkFromResolver.Urls
            ZipSha256 = $AhkFromResolver.ZipSha256
            ZipBytes  = [double](Get-Prop $ahk 'zipBytes')
            ZipName   = "AutoHotkey_$($AhkFromResolver.Version).zip"
        }
    }
    # A test pins file may also replace the AutoHotkey pin and its sources.
    if ($script:UsingTestPins) {
        if (Get-Prop $ahk 'zipSha256') { $pins.Ahk.ZipSha256 = ([string](Get-Prop $ahk 'zipSha256')).ToLowerInvariant() }
        if (Get-Prop $ahk 'urls') { $pins.Ahk.Urls = @(Get-Prop $ahk 'urls') }
    }
    if ($pins.Node.Version -notmatch '^v\d+\.\d+\.\d+$' -or $pins.Node.ZipSha256 -notmatch '^[0-9a-f]{64}$' -or $pins.Ahk.ZipSha256 -notmatch '^[0-9a-f]{64}$') {
        Stop-Setup 1 'The runtime pins are malformed.'
    }
    return $pins
}

# --- Downloads ----------------------------------------------------------------------------------
# One GET, written straight to OutFile, with a progress line every few seconds so a slow link never
# looks like a hang. Throws on any HTTP error or on a body over the size cap.
function Invoke-SetupDownload {
    param([string]$Uri, [string]$OutFile)
    if ($script:MirrorRoot) {
        $parsed = [Uri]$Uri
        $local = Join-Path -Path $script:MirrorRoot -ChildPath ($parsed.Host + ($parsed.AbsolutePath -replace '/', '\'))
        Add-Content -LiteralPath (Join-Path -Path $script:MirrorRoot -ChildPath 'requests.log') -Value $Uri -Encoding ASCII
        if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { throw "404 Not Found: $Uri" }
        Copy-Item -LiteralPath $local -Destination $OutFile -Force
        return
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent = "LLMUsageMonitor-Setup/$(Get-Prop $script:Release 'version')"
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 60000
    $response = $request.GetResponse()
    try {
        $total = $response.ContentLength
        if ($total -gt $script:MaxDownloadBytes) { throw "The server offered $(Format-MB $total), more than expected." }
        $in = $response.GetResponseStream()
        $out = [IO.File]::Create($OutFile)
        try {
            $buffer = New-Object byte[] 65536
            $done = [long]0
            $lastReport = [DateTime]::UtcNow
            while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $out.Write($buffer, 0, $read)
                $done += $read
                if ($done -gt $script:MaxDownloadBytes) { throw 'The download is larger than expected.' }
                if (([DateTime]::UtcNow - $lastReport).TotalSeconds -ge 3) {
                    if ($total -gt 0) { Write-Note ("{0} of {1}" -f (Format-MB $done), (Format-MB $total)) }
                    else { Write-Note ("{0} so far" -f (Format-MB $done)) }
                    $lastReport = [DateTime]::UtcNow
                }
            }
        } finally {
            $out.Dispose()
            $in.Dispose()
        }
    } finally {
        $response.Dispose()
    }
}

# A pinned zip the user saved beside the installer: used only when its SHA-256 matches the pin.
function Find-LocalPackage([string]$ZipName, [string]$Sha256) {
    if (-not $LocalPackageDir) { return $null }
    $candidate = Join-Path -Path $LocalPackageDir -ChildPath $ZipName
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    if ((Get-FileSha256 $candidate) -ne $Sha256) {
        Write-Warn "$candidate does not match the pinned SHA-256, so it was not used."
        return $null
    }
    Write-Ok "Using the saved $ZipName beside the installer (SHA-256 matches the pin)."
    return $candidate
}

# Copies named entries out of a zip to exact destinations; nothing else in the zip is written.
function Expand-ZipMembers([string]$ZipPath, $Map) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($name in @($Map.Keys)) {
            $entry = $zip.GetEntry($name)
            if (-not $entry) { throw "$name is missing from $(Split-Path -Path $ZipPath -Leaf)." }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Map[$name], $true)
        }
    } finally {
        $zip.Dispose()
    }
}

# --- Runtimes -----------------------------------------------------------------------------------
# A runtime record's files as Name (relative path) / Value (SHA-256) pairs, whether the record was
# just built (a dictionary) or read back from install-state.json (an object).
function Get-RecordFilePairs($Record) {
    $files = Get-Prop $Record 'files'
    if ($null -eq $files) { return @() }
    if ($files -is [System.Collections.IDictionary]) {
        return @($files.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = [string]$files[$_] } })
    }
    return @($files.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Value = [string]$_.Value } })
}

# A runtime from the install being replaced is copied over only when the state file says it came
# from the same pinned zip and every file still has the hash recorded at install time.
function Copy-ReusableRuntime([string]$Name, $Pin, [string]$OldRoot, $OldState, [string]$StagingRoot) {
    if (-not $OldRoot -or -not $OldState) { return $null }
    $record = Get-Prop (Get-Prop $OldState 'runtimes') $Name
    if (-not $record) { return $null }
    if ((Get-Prop $record 'version') -ne $Pin.Version -or (Get-Prop $record 'zipSha256') -ne $Pin.ZipSha256) { return $null }
    $pairs = @(Get-RecordFilePairs $record)
    if ($pairs.Count -eq 0) { return $null }
    foreach ($pair in $pairs) {
        $source = Join-Path -Path $OldRoot -ChildPath $pair.Name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $null }
        if ((Get-FileSha256 $source) -ne [string]$pair.Value) { return $null }
    }
    foreach ($pair in $pairs) {
        Copy-Item -LiteralPath (Join-Path -Path $OldRoot -ChildPath $pair.Name) -Destination (Join-Path -Path $StagingRoot -ChildPath $pair.Name)
    }
    return $record
}

function New-RuntimeRecord($Pin, [string]$StagingRoot, [string[]]$RelativeFiles) {
    $files = [ordered]@{}
    foreach ($relative in $RelativeFiles) { $files[$relative] = Get-FileSha256 (Join-Path -Path $StagingRoot -ChildPath $relative) }
    return [ordered]@{ version = $Pin.Version; zipSha256 = $Pin.ZipSha256; files = $files }
}

function Get-AhkRuntime([string]$StagingRoot, [string]$WorkDir, [string]$OldRoot, $OldState) {
    $pin = $script:Pins.Ahk
    $reused = Copy-ReusableRuntime 'autohotkey' $pin $OldRoot $OldState $StagingRoot
    if ($reused) { Write-Ok "AutoHotkey v$($pin.Version) is already installed and unchanged."; return $reused }
    $zip = Join-Path -Path $WorkDir -ChildPath $pin.ZipName
    Write-Step "Downloading AutoHotkey v$($pin.Version) ($(Format-MB $pin.ZipBytes))"
    try {
        Save-PortableAhkV1Zip -ZipPath $zip -Urls $pin.Urls -ExpectedSha256 $pin.ZipSha256
        Write-Ok 'AutoHotkey zip matches its pinned SHA-256.'
    } catch {
        Write-Warn $_.Exception.Message
        $zip = Find-LocalPackage $pin.ZipName $pin.ZipSha256
        if (-not $zip) {
            $script:MissingRuntimes.Add("AutoHotkey v$($pin.Version): $(@($pin.Urls)[0])")
            return $null
        }
    }
    $map = [ordered]@{
        'AutoHotkeyU64.exe' = Join-Path -Path $StagingRoot -ChildPath 'runtime\AutoHotkeyU64.exe'
        'license.txt'       = Join-Path -Path $StagingRoot -ChildPath 'runtime\AutoHotkey-license.txt'
    }
    Expand-ZipMembers $zip $map
    return (New-RuntimeRecord $pin $StagingRoot @('runtime\AutoHotkeyU64.exe', 'runtime\AutoHotkey-license.txt'))
}

function Get-NodeRuntime([string]$StagingRoot, [string]$WorkDir, [string]$OldRoot, $OldState) {
    $pin = $script:Pins.Node
    $reused = Copy-ReusableRuntime 'node' $pin $OldRoot $OldState $StagingRoot
    if ($reused) { Write-Ok "Node.js $($pin.Version) is already installed and unchanged."; return $reused }
    Write-Step "Downloading Node.js $($pin.Version) ($(Format-MB $pin.ZipBytes)) from nodejs.org"
    Write-Note 'Checked against the pinned SHA-256 and the release''s SHASUMS256.txt. This can take a minute.'
    $zip = $null
    try {
        $verified = Get-VerifiedNodeZip -WorkDir $WorkDir -DistBaseUrl $pin.DistBaseUrl -Version $pin.Version -ExpectedSha256 $pin.ZipSha256
        $zip = $verified.ZipPath
        Write-Ok 'Node.js zip matches its pinned SHA-256 and SHASUMS256.txt.'
    } catch {
        Write-Warn $_.Exception.Message
        $zip = Find-LocalPackage $pin.ZipName $pin.ZipSha256
        if (-not $zip) {
            $script:MissingRuntimes.Add("Node.js $($pin.Version): $($pin.DistBaseUrl)/$($pin.Version)/$($pin.ZipName)")
            return $null
        }
    }
    $map = [ordered]@{
        "$($pin.EntryRoot)/node.exe" = Join-Path -Path $StagingRoot -ChildPath 'runtime\node.exe'
        "$($pin.EntryRoot)/LICENSE"  = Join-Path -Path $StagingRoot -ChildPath 'runtime\Node-LICENSE.txt'
    }
    Expand-ZipMembers $zip $map
    return (New-RuntimeRecord $pin $StagingRoot @('runtime\node.exe', 'runtime\Node-LICENSE.txt'))
}

# The real runtimes must also start and report the pinned version (skipped for test fixtures).
function Test-RuntimeHealth([string]$Root) {
    if ($script:UsingTestPins) { return }
    $nodeExe = Join-Path -Path $Root -ChildPath 'runtime\node.exe'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $reported = (& $nodeExe --version 2>&1 | Select-Object -First 1) } finally { $ErrorActionPreference = $previous }
    if ([string]$reported -ne $script:Pins.Node.Version) { Stop-Setup 1 "node.exe did not start as expected (it reported '$reported')." }
    $ahkExe = Join-Path -Path $Root -ChildPath 'runtime\AutoHotkeyU64.exe'
    $fileVersion = [string](Get-Item -LiteralPath $ahkExe).VersionInfo.FileVersion
    if (-not $fileVersion.StartsWith($script:Pins.Ahk.Version)) { Stop-Setup 1 "AutoHotkeyU64.exe reports version '$fileVersion', not $($script:Pins.Ahk.Version)." }
}

# Every manifest file in Root must have the manifest's size and SHA-256.
function Test-TreeAgainstManifest([string]$Root) {
    foreach ($entry in @($script:Manifest.files)) {
        $path = Join-Path -Path $Root -ChildPath ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Setup 1 "Setup file missing after copy: $($entry.path)" }
        if ((Get-FileSha256 $path) -ne ([string]$entry.sha256).ToLowerInvariant()) {
            Stop-Setup 1 "Setup file $($entry.path) does not match the release manifest. Download the installer again."
        }
    }
}

function Test-RuntimeRecords([string]$Root, $Runtimes) {
    foreach ($name in @('autohotkey', 'node')) {
        $pairs = @(Get-RecordFilePairs $Runtimes[$name])
        if ($pairs.Count -eq 0) { Stop-Setup 1 "No files were recorded for the $name runtime." }
        foreach ($pair in $pairs) {
            $path = Join-Path -Path $Root -ChildPath $pair.Name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileSha256 $path) -ne $pair.Value) {
                Stop-Setup 1 "Runtime file $($pair.Name) did not arrive intact."
            }
        }
    }
}

# --- Staging and the swap -----------------------------------------------------------------------
# Leftovers of an interrupted run: owned .staging-/.failed- folders are removed, and a .previous
# folder is put back when the install folder itself is missing (a reinstall stopped mid-swap).
function Repair-InterruptedRun([string]$Root) {
    $parent = Split-Path -Path $Root -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    $previous = $Root + '.previous'
    $previousOwned = Test-OwnedTree $previous ($script:ProductId + '.previous')
    if (-not (Test-Path -LiteralPath $Root) -and $previousOwned) {
        Move-WithRetry $previous $Root
        Write-Warn "Put back the previous install after an interrupted run: $Root"
    } elseif ($previousOwned) {
        [void](Remove-OwnedItem $previous)
    }
    $pattern = '^' + [regex]::Escape($script:ProductId) + '\.(staging|failed)-[0-9a-f]{32}$'
    foreach ($dir in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($dir.Name -match $pattern) { [void](Remove-OwnedItem $dir.FullName) }
    }
}

function New-StagedInstall($Config, [string]$OldRoot, $OldState) {
    $parent = Split-Path -Path $Config.Root -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $staging = Join-Path -Path $parent -ChildPath ($script:ProductId + '.staging-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        Write-Step 'Copying the program files'
        foreach ($entry in @($script:Manifest.files)) {
            $source = Join-Path -Path $script:PayloadRoot -ChildPath ([string]$entry.path)
            $target = Join-Path -Path $staging -ChildPath ([string]$entry.path)
            New-Item -ItemType Directory -Force -Path (Split-Path -Path $target -Parent) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
        }
        Copy-Item -LiteralPath (Join-Path -Path $script:SetupDir -ChildPath 'payload-manifest.json') -Destination (Join-Path -Path $staging -ChildPath 'setup\payload-manifest.json')
        Test-TreeAgainstManifest $staging

        New-Item -ItemType Directory -Force -Path (Join-Path -Path $staging -ChildPath 'runtime') | Out-Null
        $work = Join-Path -Path $staging -ChildPath '.download'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $ahk = Get-AhkRuntime $staging $work $OldRoot $OldState
        $node = Get-NodeRuntime $staging $work $OldRoot $OldState
        [void](Remove-OwnedItem $work)
        if ($script:MissingRuntimes.Count -gt 0) {
            Write-Host ''
            foreach ($line in $script:MissingRuntimes) {
                $parts = $line.Split(@(': '), 2, [StringSplitOptions]::None)
                Write-Fail "Download $($parts[0]):"
                Write-Host "      $($parts[1])"
            }
            $where = if ($LocalPackageDir) { $LocalPackageDir } else { 'the folder this installer is in' }
            Write-Note "Save each file next to this installer ($where), then run the installer again."
            Stop-Setup 2 'A runtime could not be downloaded.'
        }
        $runtimes = [ordered]@{ autohotkey = $ahk; node = $node }
        Test-RuntimeRecords $staging $runtimes

        # Files copied out of a ZIP that Windows marked as downloaded keep that mark; the release
        # has been verified by this point, so clear it on the staged copies only.
        Get-ChildItem -LiteralPath $staging -Recurse -File -Force | Unblock-File -ErrorAction SilentlyContinue
        Test-RuntimeHealth $staging
        return @{ Path = $staging; Runtimes = $runtimes }
    } catch {
        [void](Remove-OwnedItem $staging)
        throw
    }
}

function New-StateRecord($Config, $Runtimes, [string]$Status, [string]$StartupLink) {
    return [ordered]@{
        product       = $script:ProductId
        schema        = 1
        status        = $Status
        version       = [string](Get-Prop $script:Release 'version')
        sourceCommit  = [string](Get-Prop $script:Release 'sourceCommit')
        installRoot   = $Config.Root
        dataFolder    = $Config.Data
        startMenuLink = $Config.StartMenuLink
        startupLink   = $StartupLink
        appsEntry     = if ($RegistrationFile) { 'file' } else { 'registry' }
        runtimes      = $Runtimes
        updated       = [DateTime]::UtcNow.ToString('o')
    }
}

# Moves the staged folder into place. With an install already there, it goes aside to
# <root>.previous first and comes back if the second move fails.
function Switch-InstallRoot([string]$Staging, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) {
        Move-WithRetry $Staging $Root
        return $false
    }
    if (-not (Test-OwnedRoot $Root)) { Stop-Setup 1 "$Root exists but was not created by this installer; nothing was changed." }
    $previous = $Root + '.previous'
    if (Test-Path -LiteralPath $previous) {
        if (-not (Test-OwnedTree $previous ($script:ProductId + '.previous'))) { Stop-Setup 1 "$previous is in the way and was not created by this installer." }
        if (-not (Remove-OwnedItem $previous)) { Stop-Setup 1 "Could not clear $previous." }
    }
    Move-WithRetry $Root $previous
    try {
        if ($script:TestMode -and $env:LLMUSAGE_SETUP_FAULT -eq 'after-move-aside') { throw 'Injected test fault after moving the install aside.' }
        Move-WithRetry $Staging $Root
    } catch {
        Move-WithRetry $previous $Root
        throw
    }
    return $true
}

# --- Processes ----------------------------------------------------------------------------------
# WMI can be denied or broken (Windows Sandbox answers Win32_Process with "Access is denied", which
# used to stop every uninstall). Then Get-Process stands in: executable paths only, no parents and no
# command lines, so only a process whose program file is inside the install folder can match (the
# app's AutoHotkey and node.exe; a bridge PowerShell is missed and may leave a file to retry).
function Get-ProcessSnapshot {
    try {
        $wmi = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    } catch {
        Write-Note ('Windows did not list processes through WMI (' + $_.Exception.Message.Trim() + '); using the basic process list.')
        return @(Get-Process | ForEach-Object {
            $exe = ''
            try { $exe = [string]$_.Path } catch { $exe = '' }
            [pscustomobject]@{ ProcessId = [int]$_.Id; ParentProcessId = 0; ExecutablePath = $exe; CommandLine = '' }
        })
    }
    return @($wmi | ForEach-Object {
        [pscustomobject]@{
            ProcessId       = [int]$_.ProcessId
            ParentProcessId = [int]$_.ParentProcessId
            ExecutablePath  = [string]$_.ExecutablePath
            CommandLine     = [string]$_.CommandLine
        }
    })
}

# The installed app's processes: an executable inside the install folder (AutoHotkey, node.exe) or
# a command line naming a file inside it (the bridge and its PowerShell helpers). Never matched by
# process name, and never setup itself or the windows that started it.
function Select-OwnedProcesses($Processes, [string]$Root, [int]$SelfPid) {
    $byId = @{}
    foreach ($p in @($Processes)) { $byId[[int]$p.ProcessId] = $p }
    $excluded = @{}
    $current = $SelfPid
    for ($depth = 0; $depth -lt 32 -and $current -gt 0 -and -not $excluded.ContainsKey($current); $depth++) {
        $excluded[$current] = $true
        if (-not $byId.ContainsKey($current)) { break }
        $current = [int]$byId[$current].ParentProcessId
    }
    $needle = $Root.TrimEnd('\') + '\'
    return @($Processes | Where-Object {
        $id = [int]$_.ProcessId
        $exe = [string]$_.ExecutablePath
        $cmd = [string]$_.CommandLine
        (-not $excluded.ContainsKey($id)) -and (
            ($exe -and $exe.StartsWith($needle, [StringComparison]::OrdinalIgnoreCase)) -or
            ($cmd -and $cmd.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0))
    })
}

# A second check, separate from Select-OwnedProcesses, made right before a process is stopped:
# its executable is inside the install folder or its command line names a file inside it. A fault
# in the filter alone then still cannot reach any other program.
function Test-ProcessInsideRoot($Process, [string]$Root) {
    $needle = $Root.TrimEnd('\') + '\'
    $exe = [string]$Process.ExecutablePath
    $cmd = [string]$Process.CommandLine
    return ((Test-PathUnder $exe $Root) -or ($cmd -and $cmd.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0))
}

# Stops the installed app and waits up to 10 seconds. Returns the processes still running.
# In test mode nothing is ever stopped: a matching process is reported and returned as still
# running, so a broken build of this script under test cannot stop a real program.
function Stop-OwnedProcesses([string]$Root) {
    $owned = @(Select-OwnedProcesses (Get-ProcessSnapshot) $Root $PID | Where-Object { Test-ProcessInsideRoot $_ $Root })
    if ($owned.Count -eq 0) { return @() }
    if ($script:TestMode) {
        Write-Warn "Test mode: not closing $($owned.Count) running process(es) of the app."
        return $owned
    }
    Write-Step "Closing $($script:ProductName) ($($owned.Count) process$(if ($owned.Count -ne 1) { 'es' }))"
    $ordered = @($owned | Sort-Object { if ([string]$_.ExecutablePath -match 'AutoHotkey') { 0 } else { 1 } })
    foreach ($p in $ordered) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $alive = @($owned | Where-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        if ($alive.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $alive
}

# --- Shortcuts ----------------------------------------------------------------------------------
function Get-ShortcutTarget([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    return [string]$shell.CreateShortcut($Path).TargetPath
}

# Ours when it points into the install folder; any other "LLM Usage Monitor.lnk" is left alone.
function Test-OwnedShortcut([string]$Path, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Test-PathUnder (Get-ShortcutTarget $Path) $Root)
}

# The same fields the tray's "Start with Windows" item writes, so the tray's tick agrees with it.
function Set-AppShortcut([string]$Path, [string]$Root, [string]$ExtraArgs) {
    if ((Test-Path -LiteralPath $Path) -and -not (Test-OwnedShortcut $Path $Root)) {
        Write-Warn "Left $Path alone: it opens something else ($(Get-ShortcutTarget $Path))."
        return $false
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path -Parent) | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = Join-Path -Path $Root -ChildPath 'runtime\AutoHotkeyU64.exe'
    $arguments = '"' + (Join-Path -Path $Root -ChildPath 'Usage_Monitor.ahk') + '"'
    if ($ExtraArgs) { $arguments += ' ' + $ExtraArgs }
    $link.Arguments = $arguments
    $link.WorkingDirectory = $Root
    $link.Description = $script:ProductName
    $link.Save()
    return $true
}

function Remove-OwnedShortcut([string]$Path, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (Test-OwnedShortcut $Path $Root) {
        [void](Remove-OwnedItem $Path)
    } else {
        $script:Leftovers.Add("$Path (opens something else; left alone)")
    }
}

# --- Settings > Apps entry ----------------------------------------------------------------------
function Get-AppsEntryValues([string]$Root, [string]$Version, [long]$SizeKB) {
    $setupScript = Join-Path -Path $Root -ChildPath 'setup\Setup-LLMUsageMonitor.ps1'
    $command = '"' + $script:PowerShellExe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $setupScript + '" -Action Uninstall -FromAppsEntry'
    return [ordered]@{
        DisplayName          = $script:ProductName
        DisplayVersion       = $Version
        Publisher            = $script:Publisher
        InstallLocation      = $Root
        DisplayIcon          = (Join-Path -Path $Root -ChildPath 'runtime\AutoHotkeyU64.exe') + ',0'
        UninstallString      = $command
        QuietUninstallString = $command + ' -NonInteractive'
        NoModify             = 1
        NoRepair             = 1
        EstimatedSize        = $SizeKB
        InstallDate          = (Get-Date).ToString('yyyyMMdd')
    }
}

function Read-AppsEntry {
    if ($RegistrationFile) {
        if (-not (Test-Path -LiteralPath $RegistrationFile -PathType Leaf)) { return $null }
        return (Read-JsonFile $RegistrationFile)
    }
    if (-not (Test-Path -LiteralPath $script:AppsKey)) { return $null }
    return (Get-ItemProperty -LiteralPath $script:AppsKey)
}

function Write-AppsEntry([string]$Root) {
    $bytes = (Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
    $values = Get-AppsEntryValues $Root ([string](Get-Prop $script:Release 'version')) ([long][Math]::Ceiling($bytes / 1KB))
    if ($RegistrationFile) {
        Write-JsonFile $RegistrationFile $values
        return
    }
    if (-not (Test-Path -LiteralPath $script:AppsKey)) { New-Item -Path $script:AppsKey -Force | Out-Null }
    foreach ($name in @($values.Keys)) {
        $type = if ($values[$name] -is [int] -or $values[$name] -is [long]) { 'DWord' } else { 'String' }
        New-ItemProperty -LiteralPath $script:AppsKey -Name $name -Value $values[$name] -PropertyType $type -Force | Out-Null
    }
}

# Removed only while it still names this install folder.
function Remove-AppsEntry([string]$Root) {
    $entry = Read-AppsEntry
    if (-not $entry) { return }
    if (-not (Test-SamePath ([string](Get-Prop $entry 'InstallLocation')) $Root)) { return }
    if ($RegistrationFile) { [void](Remove-OwnedItem $RegistrationFile) }
    else { Remove-Item -LiteralPath $script:AppsKey -Recurse -Force }
}

# --- Data folder --------------------------------------------------------------------------------
# Exactly the names the app writes in its data folder (Usage_Monitor_GUI.ahk, the bridge,
# usage-scraper.mjs and token-cache.mjs). Anything else there belongs to someone else.
function Test-OwnedDataName([string]$Name, [bool]$IsDirectory, [bool]$KeepSettingsFile) {
    if ($IsDirectory) {
        return ($Name -eq 'tmp' -or $Name -eq 'node' -or
            $Name -match '^node\.previous-\d{14}-[0-9a-f]{8}$' -or $Name -match '^node-download-[0-9a-f]{32}$')
    }
    if ($Name -eq 'settings.ini') { return (-not $KeepSettingsFile) }
    return ($Name -eq 'snapshot.log' -or
        $Name -eq 'llm-usage-discovery-cache.json' -or $Name -match '^llm-usage-discovery-cache\.json\.\d+\.tmp$' -or
        $Name -eq 'llm-usage-token-cache.dpapi' -or $Name -match '^llm-usage-token-cache\.dpapi\.\d+\.tmp$')
}

function Remove-OwnedDataItems([string]$Data, [bool]$KeepSettingsFile) {
    if (-not (Test-Path -LiteralPath $Data -PathType Container)) { return $true }
    $ok = $true
    foreach ($item in @(Get-ChildItem -LiteralPath $Data -Force)) {
        if (Test-OwnedDataName $item.Name $item.PSIsContainer $KeepSettingsFile) {
            if (-not (Remove-OwnedItem $item.FullName)) { $ok = $false }
        } elseif (-not ($KeepSettingsFile -and $item.Name -eq 'settings.ini')) {
            $script:Leftovers.Add("$($item.FullName) (not created by $($script:ProductName); left alone)")
        }
    }
    if (@(Get-ChildItem -LiteralPath $Data -Force).Count -eq 0) { [void](Remove-OwnedItem $Data) }
    return $ok
}

# --- Launch -------------------------------------------------------------------------------------
function Start-InstalledApp([string]$Root, [string]$Data, [bool]$StartupMode, $Defaults) {
    $exe = Join-Path -Path $Root -ChildPath 'runtime\AutoHotkeyU64.exe'
    $argLine = '"' + (Join-Path -Path $Root -ChildPath 'Usage_Monitor.ahk') + '"'
    if ($StartupMode) { $argLine += ' /startup' }
    # The app gets a clean environment: none of the installer's own variables, and a data folder
    # override only when setup was given a non-default one.
    $names = @('LLMUSAGE_SELF', 'LLMUSAGE_EXTRACTOR', 'LLMUSAGE_PS', 'LLMUSAGE_EXIT', 'LLMUSAGE_BUNDLE_NOLAUNCH', 'LLM_USAGE_MONITOR_DATA_DIR')
    $saved = @{}
    foreach ($name in $names) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    try {
        if (-not (Test-SamePath $Data $Defaults.Data)) { [Environment]::SetEnvironmentVariable('LLM_USAGE_MONITOR_DATA_DIR', $Data, 'Process') }
        Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $Root | Out-Null
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

# --- Checks before installing -------------------------------------------------------------------
function Assert-Preflight([string]$Root) {
    if (-not [Environment]::Is64BitOperatingSystem) { Stop-Setup 1 "$($script:ProductName) needs 64-bit Windows." }
    if ([Environment]::OSVersion.Version.Major -lt 10) { Stop-Setup 1 "$($script:ProductName) needs Windows 10 or 11." }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Stop-Setup 1 'PowerShell is restricted on this PC (Constrained Language Mode), so setup cannot run here.'
    }
    $drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($Root))
    if ($drive.AvailableFreeSpace -lt 300MB) { Stop-Setup 1 "Setup needs about 300 MB free on $($drive.Name); $(Format-MB $drive.AvailableFreeSpace) is free." }
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Warn 'Setup is running as administrator. It installs for the account running it; run it without "Run as administrator" to install for yourself.'
    }
}

function Show-FirstRunSummary($Config) {
    Write-Host ''
    Write-Host "$($script:ProductName) $(Get-Prop $script:Release 'version') setup" -ForegroundColor Cyan
    Write-Host '  Installs for your Windows account only. No administrator rights; PATH is not changed.'
    Write-Host "  Program:    $($Config.Root)"
    Write-Host "  Your data:  $($Config.Data) (created when the app first runs)"
    Write-Host '  Downloads, each checked against a pinned SHA-256:'
    Write-Host ("    AutoHotkey v{0}  {1}  www.autohotkey.com (github.com if that fails)" -f $script:Pins.Ahk.Version, (Format-MB $script:Pins.Ahk.ZipBytes))
    Write-Host ("    Node.js {0}  {1}  nodejs.org" -f $script:Pins.Node.Version, (Format-MB $script:Pins.Node.ZipBytes))
    Write-Host '  Adds a Start Menu shortcut and an entry in Settings > Apps.'
}

# --- Actions ------------------------------------------------------------------------------------
function Invoke-Install {
    $config = Resolve-SetupConfig
    Repair-InterruptedRun $config.Root
    $config = Resolve-SetupConfig
    if ($config.State) { Invoke-Reinstall; return }
    if (Test-Path -LiteralPath $config.Root) { Stop-Setup 1 "$($config.Root) exists but was not created by this installer; nothing was changed." }
    Assert-Preflight $config.Root
    $script:Pins = Read-RuntimePins (Import-SetupHelpers)
    if (-not $NonInteractive) {
        Show-FirstRunSummary $config
        if ((Read-Choice 'Press Enter to install, or type N to cancel:') -match '^(?i)n(o)?$') {
            Write-Note 'Cancelled. Nothing was changed.'
            return
        }
    }
    Write-Host ''
    $staged = New-StagedInstall $config '' $null
    Write-JsonFile (Join-Path -Path $staged.Path -ChildPath 'install-state.json') (New-StateRecord $config $staged.Runtimes 'staged' '')
    [void](Switch-InstallRoot $staged.Path $config.Root)
    Write-Ok "Installed to $($config.Root)"

    [void](Set-AppShortcut $config.StartMenuLink $config.Root '')
    Write-AppsEntry $config.Root
    $wantStartup = $false
    if ($Startup) { $wantStartup = $true }
    elseif (-not $NoStartup -and -not $NonInteractive) {
        $wantStartup = Test-Yes (Read-Choice "Start $($script:ProductName) when you sign in to Windows? [y/N]:")
    }
    $startupLink = ''
    if ($wantStartup -and (Set-AppShortcut $config.StartupLink $config.Root '/startup')) { $startupLink = $config.StartupLink }
    Write-JsonFile (Join-Path -Path $config.Root -ChildPath 'install-state.json') (New-StateRecord $config $staged.Runtimes 'installed' $startupLink)

    Write-Host ''
    Write-Ok "$($script:ProductName) $(Get-Prop $script:Release 'version') is installed."
    Write-Note 'Open it from the Start Menu or with its hotkey (Alt+Y unless you change it in Settings).'
    Write-Note 'Its tray icon has Settings, Start with Windows and Exit.'
    Write-Note 'To uninstall: Settings > Apps > Installed apps, or run this installer again.'
    if ($startupLink) { Write-Note 'It will start when you sign in to Windows.' }
    if (-not $NoLaunch) { Start-InstalledApp $config.Root $config.Data $false $config.Defaults }
}

function Invoke-Reinstall {
    $config = Resolve-SetupConfig
    Repair-InterruptedRun $config.Root
    $config = Resolve-SetupConfig
    if (-not $config.State) { Invoke-Install; return }
    Assert-Preflight $config.Root
    $script:Pins = Read-RuntimePins (Import-SetupHelpers)
    Write-Step "Reinstalling $($script:ProductName) $(Get-Prop $script:Release 'version') in $($config.Root)"
    $staged = New-StagedInstall $config $config.Root $config.State
    try {
        $survivors = @(Stop-OwnedProcesses $config.Root)
        if ($survivors.Count -gt 0) { Stop-Setup 1 "$($script:ProductName) is still running (process $($survivors[0].ProcessId)). Exit it from its tray icon and run setup again." }
        Write-JsonFile (Join-Path -Path $staged.Path -ChildPath 'install-state.json') (New-StateRecord $config $staged.Runtimes 'staged' ([string](Get-Prop $config.State 'startupLink')))
        [void](Switch-InstallRoot $staged.Path $config.Root)
    } catch {
        [void](Remove-OwnedItem $staged.Path)
        throw
    }
    $previous = $config.Root + '.previous'
    try {
        Test-TreeAgainstManifest $config.Root
        Test-RuntimeRecords $config.Root $staged.Runtimes
    } catch {
        # The swapped-in copy is not intact: put the previous one back.
        $failed = Join-Path -Path (Split-Path -Path $config.Root -Parent) -ChildPath ($script:ProductId + '.failed-' + [guid]::NewGuid().ToString('N'))
        Move-WithRetry $config.Root $failed
        Move-WithRetry $previous $config.Root
        [void](Remove-OwnedItem $failed)
        throw
    }
    if (Test-Path -LiteralPath $previous) { [void](Remove-OwnedItem $previous) }

    [void](Set-AppShortcut $config.StartMenuLink $config.Root '')
    Write-AppsEntry $config.Root
    # The Startup choice is kept as found: an existing shortcut into this install stays.
    $startupLink = ''
    if ($NoStartup) {
        Remove-OwnedShortcut $config.StartupLink $config.Root
    } elseif ($Startup -or (Test-OwnedShortcut $config.StartupLink $config.Root)) {
        if (Set-AppShortcut $config.StartupLink $config.Root '/startup') { $startupLink = $config.StartupLink }
    }
    Write-JsonFile (Join-Path -Path $config.Root -ChildPath 'install-state.json') (New-StateRecord $config $staged.Runtimes 'installed' $startupLink)
    Write-Ok "$($script:ProductName) $(Get-Prop $script:Release 'version') is reinstalled. Your settings were not touched."
    # /startup brings the popup back only if it was open.
    if (-not $NoLaunch) { Start-InstalledApp $config.Root $config.Data $true $config.Defaults }
}

function Invoke-Uninstall {
    $config = Resolve-SetupConfig
    $root = $config.Root
    if (-not $config.State) {
        if (Test-Path -LiteralPath $root) { Stop-Setup 1 "$root was not created by this installer, so it was left alone." }
        Write-Note "$($script:ProductName) is not installed at $root. Nothing to remove."
        return
    }
    if (-not $NonInteractive -and -not $FromAppsEntry) {
        if (-not (Test-Yes (Read-Choice "Uninstall $($script:ProductName) from $($root)? [y/N]:"))) {
            Write-Note 'Nothing was changed.'
            return
        }
    }
    $keepSettingsFile = [bool]$KeepSettings
    if (-not $KeepData -and -not $KeepSettings -and -not $NonInteractive) {
        $keepSettingsFile = Test-Yes (Read-Choice 'Keep your settings for a later reinstall? [y/N]:')
    }

    # Nothing of this process may sit inside the folder being deleted.
    Set-Location -LiteralPath $env:SystemRoot
    [Environment]::CurrentDirectory = $env:SystemRoot

    $survivors = @(Stop-OwnedProcesses $root)
    if ($survivors.Count -gt 0) {
        Stop-Setup 1 "$($script:ProductName) is still running (process $($survivors[0].ProcessId)). Exit it from its tray icon and run setup again; nothing was removed."
    }

    Write-Step "Removing $($script:ProductName)"
    $recordedStartup = [string](Get-Prop $config.State 'startupLink')
    $recordedStartMenu = [string](Get-Prop $config.State 'startMenuLink')
    $links = @($config.StartMenuLink, $config.StartupLink, $recordedStartup, $recordedStartMenu) | Where-Object { $_ } | Select-Object -Unique
    foreach ($link in $links) { Remove-OwnedShortcut $link $root }

    # Everything but setup\ and the state file first, so a failure leaves a copy that can retry.
    $ok = $true
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Force)) {
        if ($item.Name -eq 'setup' -or $item.Name -eq 'install-state.json') { continue }
        if (-not (Remove-OwnedItem $item.FullName)) { $ok = $false }
    }
    if (-not $KeepData) {
        if (-not (Remove-OwnedDataItems $config.Data $keepSettingsFile)) { $ok = $false }
    }
    if ($ok) {
        # The running script is in setup\: PowerShell read it whole at start and holds no lock on it.
        if (Remove-OwnedItem $root) { Remove-AppsEntry $root } else { $ok = $false }
    }

    Write-Host ''
    if ($script:Leftovers.Count -gt 0) {
        Write-Note 'Left in place:'
        foreach ($line in $script:Leftovers) { Write-Note "  $line" }
    }
    if (-not $ok) {
        $script:ExitCode = 3
        Write-Warn 'Some files could not be removed. Close anything using them and run the uninstall again.'
        return
    }
    Write-Ok "$($script:ProductName) is uninstalled."
    if ($KeepData) { Write-Note "Your data folder was kept: $($config.Data)" }
    elseif ($keepSettingsFile) { Write-Note "Your settings were kept: $(Join-Path -Path $config.Data -ChildPath 'settings.ini')" }
    Write-Note 'Your CLI logins and browser profiles were never changed by this app.'
}

function Invoke-Status {
    $config = Resolve-SetupConfig
    if (-not $config.State) {
        Write-Host "$($script:ProductName) is not installed at $($config.Root)."
        return
    }
    $state = $config.State
    Write-Host "$($script:ProductName) $(Get-Prop $state 'version') ($(Get-Prop $state 'status'))"
    Write-Host "  Program:     $($config.Root)"
    Write-Host "  Data:        $($config.Data)"
    $startupLink = [string](Get-Prop $state 'startupLink')
    Write-Host ("  Start Menu:  {0}" -f $(if (Test-OwnedShortcut $config.StartMenuLink $config.Root) { $config.StartMenuLink } else { '(none)' }))
    Write-Host ("  Startup:     {0}" -f $(if ($startupLink -and (Test-OwnedShortcut $startupLink $config.Root)) { $startupLink } else { 'off' }))
    Write-Host ("  Apps entry:  {0}" -f $(if (Read-AppsEntry) { 'yes' } else { 'no' }))
    $runtimes = Get-Prop $state 'runtimes'
    foreach ($name in @('autohotkey', 'node')) {
        $record = Get-Prop $runtimes $name
        if ($record) { Write-Host ("  {0,-11}  {1}" -f ($name + ':'), (Get-Prop $record 'version')) }
    }
}

function Invoke-Interactive {
    $config = Resolve-SetupConfig
    if (-not $config.State) { Invoke-Install; return }
    Write-Host ''
    Write-Host "$($script:ProductName) $(Get-Prop $config.State 'version') is installed in $($config.Root)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "[1] Reinstall  (puts back the program files and re-checks AutoHotkey and Node.js; keeps your settings)"
    Write-Host '[2] Uninstall'
    Write-Host '[3] Close'
    switch (Read-Choice 'Selection:') {
        '1' { Invoke-Reinstall }
        '2' { Invoke-Uninstall }
        default { Write-Note 'Closed. Nothing was changed.' }
    }
}

# --- Main ---------------------------------------------------------------------------------------
if ($LoadOnly) { return }

try { $Host.UI.RawUI.WindowTitle = "$($script:ProductName) Setup" } catch {}
try {
    Assert-TestFence
    if ($Action -ne 'Uninstall' -and $Action -ne 'Status') {
        $script:Manifest = Read-PayloadManifest
        $script:Release = Read-ReleaseInfo
    } else {
        $script:Release = @{ version = '' }
    }
    switch ($Action) {
        'Interactive' { Invoke-Interactive }
        'Install' { Invoke-Install }
        'Reinstall' { Invoke-Reinstall }
        'Uninstall' { Invoke-Uninstall }
        'Status' { Invoke-Status }
    }
} catch {
    if ($script:ExitCode -eq 0) { $script:ExitCode = 1 }
    Write-Host ''
    Write-Fail ('Setup stopped: ' + $_.Exception.Message)
}
if ($FromAppsEntry -and -not $NonInteractive) {
    Write-Host ''
    Write-Host 'Press Enter to exit.'
    [void](Read-Line)
}
exit $script:ExitCode

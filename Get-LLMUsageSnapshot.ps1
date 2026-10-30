[CmdletBinding()]
param(
    [ValidateSet('Snapshot', 'Bootstrap', 'Install')]
    [string]$Mode = 'Snapshot',
    [string]$OutFile,
    [string]$StatusFile,
    [string]$ClaudeProfile,
    # Per-user data folder chosen by the GUI. The log and the scraper's caches go here, so the
    # install folder can stay read-only and holds no account details. Empty = old behaviour.
    [string]$DataDir,
    # The Settings window's per-provider choices, e.g. "codex=auto,claude=cli,grok=off,addon=on"
    # (passed on to the scraper as --providers). Empty = every provider as before; a value that
    # cannot be read turns every provider off.
    [string]$Providers,
    # The add-on module a host script named (addon-provider.mjs), passed on as --addonModule. Only
    # the GUI sets it, from the host's usageMonitorHostAddonModule; nothing else names it. It must
    # be an absolute drive path to an existing .mjs file. Empty = no add-on column.
    [string]$AddonModule
)

$ErrorActionPreference = 'Stop'

$DiagnosticLogDir = if (-not [string]::IsNullOrWhiteSpace($DataDir)) { $DataDir } else { Split-Path -Path $PSCommandPath -Parent }
$DiagnosticLogPath = Join-Path -Path $DiagnosticLogDir -ChildPath 'snapshot.log'
$DiagnosticLogMaxEntries = 50

function Write-DiagnosticLog {
    param(
        [string]$Mode = '',
        [int]$ExitCode = 0,
        [string]$Status = 'unknown',
        [string]$ErrorMessage = '',
        [string]$NodePath = '',
        [string]$OutFile = '',
        [System.Collections.IDictionary]$Snapshot = $null,
        $NodeOutput = $null
    )
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $sep = '=' * 80
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add($sep)
        $lines.Add("[$stamp] Mode=$Mode ExitCode=$ExitCode Status=$Status")
        if ($NodePath) { $lines.Add("  Node: $NodePath") }
        if ($OutFile)  { $lines.Add("  OutFile: $OutFile") }
        if ($script:ProvidersLogText) { $lines.Add("  Providers: $script:ProvidersLogText") }
        if ($script:AddonLogText) { $lines.Add("  Add-on: $script:AddonLogText") }
        if ($Snapshot) {
            $keysToLog = @(
                'codex_status', 'codex_source', 'codex_line_1', 'codex_line_2',
                'claude_status', 'claude_source', 'claude_line_1', 'claude_line_2', 'claude_line_3',
                'claude_account_label', 'claude_profile', 'claude_profile_switch_available',
                'grok_status', 'grok_source', 'grok_line_1',
                'addon_status', 'addon_source',
                'error_code'
            )
            $hasAny = $false
            foreach ($key in $keysToLog) {
                if ($Snapshot.Contains($key) -and -not [string]::IsNullOrWhiteSpace([string]$Snapshot[$key])) {
                    if (-not $hasAny) {
                        $lines.Add('  Snapshot:')
                        $hasAny = $true
                    }
                    $val = ([string]$Snapshot[$key] -replace "`r|`n", ' ').Trim()
                    $lines.Add("    $key=$val")
                }
            }
        }
        if ($ErrorMessage) { $lines.Add("  Error: $ErrorMessage") }
        if ($NodeOutput) {
            $nodeLines = @($NodeOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 10)
            if ($nodeLines.Count -gt 0) {
                $lines.Add('  Node output (first 10 lines):')
                foreach ($l in $nodeLines) {
                    $lines.Add("    " + ($l.Trim()))
                }
            }
        }

        Add-Content -LiteralPath $DiagnosticLogPath -Value $lines -Encoding UTF8

        # Rotate: keep last N entries when the file grows
        $info = Get-Item -LiteralPath $DiagnosticLogPath -ErrorAction SilentlyContinue
        if ($info -and $info.Length -gt 16KB) {
            $content = @(Get-Content -LiteralPath $DiagnosticLogPath -ErrorAction SilentlyContinue)
            $starts = @()
            for ($i = 0; $i -lt $content.Count; $i++) {
                if ($content[$i] -eq $sep) { $starts += $i }
            }
            if ($starts.Count -gt $DiagnosticLogMaxEntries) {
                $keepFrom = $starts[$starts.Count - $DiagnosticLogMaxEntries]
                $trimmed = $content[$keepFrom..($content.Count - 1)]
                Set-Content -LiteralPath $DiagnosticLogPath -Value $trimmed -Encoding UTF8
            }
        }
    }
    catch {
        # Diagnostic logging must never break the main flow.
    }
}

# Cleans the -Providers value: lower case, whitespace turned into commas (a comma list can arrive
# split into words), at most 200 characters of name=choice pairs. Returns '' for an empty value
# and the all-off value for one that cannot be read, so a garbled setting never makes requests
# the user switched off. The scraper checks the value again.
$ProvidersAllOff = 'codex=off,claude=off,grok=off,addon=off'
function ConvertTo-ProvidersArg {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $clean = ($Value.Trim().ToLowerInvariant() -replace '\s+', ',')
    if ($clean.Length -gt 200 -or $clean -notmatch '^[a-z]+=[a-z]+(,[a-z]+=[a-z]+)*$') {
        return $ProvidersAllOff
    }
    return $clean
}

# Provider names set to off in a cleaned -Providers value.
function Get-ProvidersOff {
    param([string]$ProvidersArg)
    $off = @()
    if ([string]::IsNullOrWhiteSpace($ProvidersArg)) { return $off }
    foreach ($pair in $ProvidersArg.Split(',')) {
        $parts = $pair.Split('=')
        if ($parts.Count -eq 2 -and $parts[1] -eq 'off' -and @('codex', 'claude', 'grok', 'addon') -contains $parts[0]) {
            $off += $parts[0]
        }
    }
    return $off
}

# Checks the -AddonModule value the same way addon-provider.mjs does: an absolute drive path (no
# UNC share, no relative path, no '..') to an existing .mjs file, at most 260 characters, with no
# quotes. Returns '' for an empty value, the path when it passes, and the word 'rejected'
# otherwise, which the scraper turns into an add-on error row. The path is never logged.
$AddonModuleRejected = 'rejected'
function ConvertTo-AddonModuleArg {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value.Length -gt 260 -or $Value -notmatch '^[A-Za-z]:\\[^"<>|?*\x00-\x1f]+\.mjs$') { return $AddonModuleRejected }
    if (@($Value.Split('\') | Where-Object { $_ -eq '..' }).Count -gt 0) { return $AddonModuleRejected }
    if (-not (Test-Path -LiteralPath $Value -PathType Leaf)) { return $AddonModuleRejected }
    return $Value
}

# The snapshot written when the scraper cannot run (Node missing, a crash). A provider switched off
# in Settings still shows as off there. The add-on keys appear only when a host named a module.
function New-DefaultSnapshot {
    param(
        [string]$ProvidersArg = $script:ProvidersArg,
        [string]$AddonModuleArg = $script:AddonModuleArg
    )
    $snapshot = New-BaseSnapshot
    if ($AddonModuleArg) {
        $snapshot.addon_status = 'error'
        $snapshot.addon_source = ''
        $snapshot.addon_label = ''
        $snapshot.addon_line_1 = 'Add-on: unavailable'
        $snapshot.addon_line_2 = ''
    }
    foreach ($name in (Get-ProvidersOff -ProvidersArg $ProvidersArg)) {
        if ($name -eq 'addon' -and -not $AddonModuleArg) { continue }
        $snapshot["${name}_status"] = 'off'
        switch ($name) {
            'grok'   { $snapshot.grok_line_1 = 'Weekly: Off'; $snapshot.grok_line_2 = '' }
            'addon'  { $snapshot.addon_line_1 = 'Off'; $snapshot.addon_line_2 = '' }
            default  { $snapshot["${name}_line_1"] = 'Daily: Off'; $snapshot["${name}_line_2"] = 'Weekly: Off' }
        }
    }
    return $snapshot
}

function New-BaseSnapshot {
    $nowLocal = Get-Date
    return [ordered]@{
        fetched_at_utc   = $nowLocal.ToUniversalTime().ToString('o')
        fetched_at_local = $nowLocal.ToString('yyyy-MM-dd HH:mm:ss')
        overall_status   = 'error'
        codex_status     = 'error'
        codex_source     = ''
        codex_line_1     = 'Daily: unavailable'
        codex_line_2     = 'Weekly: unavailable'
        claude_status    = 'error'
        claude_source    = ''
        claude_account_label = ''
        claude_profile   = ''
        claude_profile_choices = ''
        claude_next_profile = ''
        claude_profile_switch_available = '0'
        claude_line_1    = 'Daily: unavailable'
        claude_line_2    = 'Weekly: unavailable'
        claude_line_3    = ''
        grok_status      = 'error'
        grok_source      = ''
        grok_line_1      = 'Weekly: unavailable'
        grok_line_2      = ''
        error            = ''
        error_code       = ''
    }
}

function Write-KeyValueFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Data
    )

    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $lines = foreach ($key in $Data.Keys) {
        $value = [string]$Data[$key]
        $cleanValue = ($value -replace "`r|`n", ' ').Trim()
        "$key=$cleanValue"
    }

    Set-Content -Path $Path -Value $lines -Encoding UTF8
}

function Read-KeyValueFile {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }

    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $splitIndex = $line.IndexOf('=')
        if ($splitIndex -lt 1) {
            continue
        }

        $key = $line.Substring(0, $splitIndex)
        $value = $line.Substring($splitIndex + 1)
        $map[$key] = $value
    }

    return $map
}

function Write-FailureSnapshot {
    param(
        [string]$Message,
        [string]$OutPath,
        [string]$StatusPath,
        [string]$ErrorCode = ''
    )

    $snapshot = New-DefaultSnapshot
    $snapshot.error = $Message
    $snapshot.error_code = $ErrorCode
    Write-KeyValueFile -Path $OutPath -Data $snapshot
    Set-Content -Path $StatusPath -Value 'error' -Encoding UTF8
}

# --- Node.js lookup and install ------------------------------------------------------------
# Nothing here edits PATH: the bridge runs node by its full path. Lookup order: the installer's
# pinned copy (runtime\node.exe beside these scripts), this app's own copy in the data folder
# (<data folder>\node, where the zip fallback installs), node on PATH, then the usual per-user and
# machine-wide install folders. The default data folder name must stay in step with
# usageMonitorAppDirName in Usage_Monitor_GUI.ahk.
$EffectiveDataDir = if (-not [string]::IsNullOrWhiteSpace($DataDir)) { $DataDir }
    elseif ($env:LOCALAPPDATA) { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'LLMUsageMonitor' }
    else { '' }
# Set at the top level, where $PSScriptRoot is this file's folder even when dot-sourced.
$BundledNodeExe = Join-Path -Path $PSScriptRoot -ChildPath 'runtime\node.exe'

function Get-NodeHome {
    param([string]$BaseDir = $EffectiveDataDir)
    if ([string]::IsNullOrWhiteSpace($BaseDir)) { return '' }
    return (Join-Path -Path $BaseDir -ChildPath 'node')
}

function Find-NodeInWingetPackages {
    $packagesDir = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages"
    if (-not (Test-Path $packagesDir)) { return $null }
    $nodeExe = Get-ChildItem -Path $packagesDir -Directory -Filter 'OpenJS.NodeJS*' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter 'node.exe' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if ($nodeExe) { return $nodeExe.FullName }
    return $null
}

# Full path of the node.exe to use, or $null. BundledExe (the installer's copy) is checked first,
# then NodeHome, this app's own copy in the data folder.
function Resolve-NodeExe {
    param(
        [string]$NodeHome = (Get-NodeHome),
        [string]$BundledExe = $BundledNodeExe
    )
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($BundledExe) { $candidates.Add($BundledExe) }
    if ($NodeHome) { $candidates.Add((Join-Path -Path $NodeHome -ChildPath 'node.exe')) }
    $onPath = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $candidates.Add($onPath.Source) }
    foreach ($dir in @("$env:LOCALAPPDATA\Programs\nodejs", "$env:APPDATA\nvm\current", "$env:ProgramFiles\nodejs", "${env:ProgramFiles(x86)}\nodejs")) {
        if ($dir -match '^[A-Za-z]:\\') { $candidates.Add((Join-Path -Path $dir -ChildPath 'node.exe')) }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    # winget's package folder, where a per-user winget install can land instead of Programs\nodejs.
    return (Find-NodeInWingetPackages)
}

# The zip fallback's only network call; a test replaces it with a local copy, and the installer
# with its own copy that reports progress.
function Invoke-NodeDownload {
    param([string]$Uri, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Windows PowerShell's progress bar slows a large download many times over.
    $ProgressPreference = 'SilentlyContinue'
    # Throws on a non-2xx response, which the caller treats as a failed install.
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
}

# Downloads a Node.js win-x64 zip into WorkDir (which must exist; the caller removes it) and checks
# it against that release's SHASUMS256.txt before returning. Without -Version it takes the newest
# LTS listed in index.json. With -Version it fetches that release only, never index.json, and with
# -ExpectedSha256 (the installer's pin) the published sum and the zip must both equal the pin too.
# Returns @{ Version; ZipPath; Sha256 }. Throws, naming the step, on any download or check failure.
function Get-VerifiedNodeZip {
    param(
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [string]$DistBaseUrl = 'https://nodejs.org/dist',
        [string]$Version = '',
        [string]$ExpectedSha256 = ''
    )
    $pin = $ExpectedSha256.Trim().ToLowerInvariant()
    if ($pin -and $pin -notmatch '^[0-9a-f]{64}$') { throw 'The pinned Node.js SHA-256 is not a 64-character hex value.' }
    $ver = $Version.Trim()
    if (-not $ver) {
        $indexFile = Join-Path -Path $WorkDir -ChildPath 'index.json'
        Invoke-NodeDownload -Uri "$DistBaseUrl/index.json" -OutFile $indexFile
        $index = Get-Content -LiteralPath $indexFile -Raw | ConvertFrom-Json
        $lts = @($index | Where-Object { $_.lts }) | Select-Object -First 1
        if (-not $lts) { throw 'index.json lists no LTS release.' }
        $ver = [string]$lts.version
    }
    # The version goes into URLs and folder names: accept only the plain vX.Y.Z form.
    if ($ver -notmatch '^v\d+\.\d+\.\d+$') { throw "Unexpected Node.js version text: $ver" }
    $zipName = "node-$ver-win-x64.zip"

    $sumsFile = Join-Path -Path $WorkDir -ChildPath 'SHASUMS256.txt'
    Invoke-NodeDownload -Uri "$DistBaseUrl/$ver/SHASUMS256.txt" -OutFile $sumsFile
    $expected = ''
    foreach ($line in (Get-Content -LiteralPath $sumsFile)) {
        if ($line -match ('^([0-9a-fA-F]{64})\s+' + [regex]::Escape($zipName) + '\s*$')) {
            $expected = $Matches[1].ToLowerInvariant()
            break
        }
    }
    if (-not $expected) { throw "SHASUMS256.txt for $ver has no line for $zipName." }
    if ($pin -and $expected -ne $pin) { throw "SHASUMS256.txt for $ver does not match the pinned SHA-256." }

    $zipPath = Join-Path -Path $WorkDir -ChildPath $zipName
    Invoke-NodeDownload -Uri "$DistBaseUrl/$ver/$zipName" -OutFile $zipPath
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "$zipName failed its SHA-256 check (expected $expected, got $actual)." }
    return @{ Version = $ver; ZipPath = $zipPath; Sha256 = $actual }
}

# Latest LTS zip from nodejs.org, checked against that release's SHASUMS256.txt before anything
# is unpacked, installed into NodeHome (this app's data folder). An existing NodeHome is renamed
# aside, never deleted, and nothing outside NodeHome's parent folder is touched. The download
# folder is removed on every path. Returns the node.exe path, or '' on any failure.
function Install-NodeFromZip {
    param(
        [Parameter(Mandatory = $true)][string]$NodeHome,
        [string]$DistBaseUrl = 'https://nodejs.org/dist'
    )
    $parent = Split-Path -Path $NodeHome -Parent
    $work = Join-Path -Path $parent -ChildPath ('node-download-' + [Guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $work | Out-Null

        $verified = Get-VerifiedNodeZip -WorkDir $work -DistBaseUrl $DistBaseUrl
        $ver = $verified.Version
        $zipPath = $verified.ZipPath

        # .NET refuses zip entries that would land outside the destination folder.
        $extractDir = Join-Path -Path $work -ChildPath 'x'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
        $inner = Join-Path -Path $extractDir -ChildPath "node-$ver-win-x64"
        if (-not (Test-Path -LiteralPath (Join-Path -Path $inner -ChildPath 'node.exe') -PathType Leaf)) { return '' }

        if (Test-Path -LiteralPath $NodeHome) {
            $aside = '{0}.previous-{1}-{2}' -f $NodeHome, (Get-Date -Format 'yyyyMMddHHmmss'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
            Move-Item -LiteralPath $NodeHome -Destination $aside
        }
        Move-Item -LiteralPath $inner -Destination $NodeHome
        $nodeExe = Join-Path -Path $NodeHome -ChildPath 'node.exe'
        if (Test-Path -LiteralPath $nodeExe -PathType Leaf) { return $nodeExe }
        return ''
    }
    catch {
        return ''
    }
    finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Install mode. Returns the node.exe path, or ''. In order: a Node that is already installed;
# winget, per-user, which accepts the winget source and package agreements on the user's behalf
# (the GUI's install prompt says so before this runs); the verified zip into <data folder>\node.
function Install-NodeUser {
    $existing = Resolve-NodeExe
    if ($existing) { return $existing }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        try {
            & $winget.Source install OpenJS.NodeJS.LTS `
                --scope user `
                --accept-source-agreements `
                --accept-package-agreements `
                --silent 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $afterWinget = Resolve-NodeExe
                if ($afterWinget) { return $afterWinget }
            }
        }
        catch {
            # A winget failure (including stderr output under ErrorAction Stop) falls through to the zip.
        }
    }

    $nodeHome = Get-NodeHome
    if (-not $nodeHome) { return '' }
    return (Install-NodeFromZip -NodeHome $nodeHome)
}

# Dot-sourcing this file (the Node install test does) loads the functions without running a mode.
if ($MyInvocation.InvocationName -eq '.') { return }

$script:ProvidersArg = ConvertTo-ProvidersArg -Value $Providers
$script:ProvidersLogText = $script:ProvidersArg
if ($script:ProvidersArg -eq $ProvidersAllOff -and ($Providers.Trim().ToLowerInvariant() -replace '\s+', ',') -ne $ProvidersAllOff) {
    $script:ProvidersLogText = 'invalid value, all off'
}
$script:AddonModuleArg = ConvertTo-AddonModuleArg -Value $AddonModule
$script:AddonLogText = if (-not $script:AddonModuleArg) { '' } elseif ($script:AddonModuleArg -eq $AddonModuleRejected) { 'rejected' } else { 'set' }

$scriptDir = Split-Path -Path $PSCommandPath -Parent
$nodeScript = Join-Path -Path $scriptDir -ChildPath 'usage-scraper.mjs'
$modeLower = $Mode.ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $OutFile = Join-Path -Path $env:TEMP -ChildPath ("llm-usage-out-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
}
if ([string]::IsNullOrWhiteSpace($StatusFile)) {
    $StatusFile = Join-Path -Path $env:TEMP -ChildPath ("llm-usage-status-{0}.txt" -f [Guid]::NewGuid().ToString('N'))
}
if ($modeLower -eq 'bootstrap') {
    $modeLower = 'snapshot'
}

if ($modeLower -eq 'install') {
    try {
        $installedNode = Install-NodeUser
        if ($installedNode) {
            $snapshot = New-DefaultSnapshot
            $snapshot.overall_status = 'ok'
            $snapshot.error = ''
            $snapshot.error_code = ''
            Write-KeyValueFile -Path $OutFile -Data $snapshot
            Set-Content -Path $StatusFile -Value 'ok' -Encoding UTF8
            Write-DiagnosticLog -Mode 'Install' -ExitCode 0 -Status 'ok' -NodePath $installedNode -OutFile $OutFile
            exit 0
        } else {
            $msg = 'Node.js installation failed. Please install Node 18+ manually from https://nodejs.org'
            Write-FailureSnapshot -Message $msg -OutPath $OutFile -StatusPath $StatusFile -ErrorCode 'node_install_failed'
            Write-DiagnosticLog -Mode 'Install' -ExitCode 1 -Status 'error' -ErrorMessage $msg -OutFile $OutFile
            exit 1
        }
    }
    catch {
        $msg = "Node install error: {0}" -f $_.Exception.Message
        Write-FailureSnapshot -Message $msg -OutPath $OutFile -StatusPath $StatusFile -ErrorCode 'node_install_failed'
        Write-DiagnosticLog -Mode 'Install' -ExitCode 1 -Status 'error' -ErrorMessage $msg -OutFile $OutFile
        exit 1
    }
}

$nodeOutput = $null
$nodeExe = $null

try {
    if (-not (Test-Path -LiteralPath $nodeScript)) {
        $msg = "Missing node script: $nodeScript"
        Write-FailureSnapshot -Message $msg -OutPath $OutFile -StatusPath $StatusFile
        Write-DiagnosticLog -Mode $Mode -ExitCode 1 -Status 'error' -ErrorMessage $msg -OutFile $OutFile
        exit 1
    }

    $nodeExe = Resolve-NodeExe
    if (-not $nodeExe) {
        $msg = 'Node.js is required. Install Node 18+ or approve installation from the usage monitor prompt.'
        Write-FailureSnapshot -Message $msg -OutPath $OutFile -StatusPath $StatusFile -ErrorCode 'node_missing'
        Write-DiagnosticLog -Mode $Mode -ExitCode 1 -Status 'error' -ErrorMessage $msg -OutFile $OutFile
        exit 1
    }

    $timeoutMs = 25000
    $nodeArgs = @($nodeScript, '--mode', 'snapshot', '--outFile', $OutFile, '--timeoutMs', $timeoutMs)
    if (-not [string]::IsNullOrWhiteSpace($ClaudeProfile)) {
        $nodeArgs += @('--claudeProfile', $ClaudeProfile)
    }
    if (-not [string]::IsNullOrWhiteSpace($DataDir)) {
        $nodeArgs += @('--dataDir', $DataDir)
    }
    if ($script:ProvidersArg) {
        $nodeArgs += @('--providers', $script:ProvidersArg)
    }
    if ($script:AddonModuleArg) {
        $nodeArgs += @('--addonModule', $script:AddonModuleArg)
    }
    $nodeOutput = & $nodeExe @nodeArgs 2>&1
    $nodeExitCode = $LASTEXITCODE

    if (-not (Test-Path -LiteralPath $OutFile)) {
        $message = 'Scraper did not produce an output file.'
        if ($nodeOutput) {
            $nodeSummary = ($nodeOutput | ForEach-Object { [string]$_ } | Select-Object -First 3) -join ' | '
            $nodeSummary = ($nodeSummary -replace "`r|`n", ' ').Trim()
            if (-not [string]::IsNullOrWhiteSpace($nodeSummary)) {
                $message = "$message Node output: $nodeSummary"
            }
        }

        Write-FailureSnapshot -Message $message -OutPath $OutFile -StatusPath $StatusFile
        Write-DiagnosticLog -Mode $Mode -ExitCode $nodeExitCode -Status 'error' -ErrorMessage $message -NodePath $nodeExe -OutFile $OutFile -NodeOutput $nodeOutput
        exit 1
    }

    $snapshot = Read-KeyValueFile -Path $OutFile
    $status = $snapshot['overall_status']
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = if ($nodeExitCode -eq 0) { 'ok' } else { 'error' }
    }

    Set-Content -Path $StatusFile -Value $status -Encoding UTF8

    $snapshotError = [string]$snapshot['error']
    $logNodeOutput = if ($status -ne 'ok') { $nodeOutput } else { $null }
    Write-DiagnosticLog -Mode $Mode -ExitCode $nodeExitCode -Status $status -ErrorMessage $snapshotError -NodePath $nodeExe -OutFile $OutFile -Snapshot $snapshot -NodeOutput $logNodeOutput

    if ($nodeExitCode -ne 0 -and $status -eq 'error') {
        exit 1
    }

    exit 0
}
catch {
    $msg = "Snapshot runner error: {0}" -f $_.Exception.Message
    Write-FailureSnapshot -Message $msg -OutPath $OutFile -StatusPath $StatusFile
    $nodePathForLog = if ($nodeExe) { $nodeExe } else { '' }
    Write-DiagnosticLog -Mode $Mode -ExitCode 1 -Status 'error' -ErrorMessage $msg -NodePath $nodePathForLog -OutFile $OutFile -NodeOutput $nodeOutput
    exit 1
}

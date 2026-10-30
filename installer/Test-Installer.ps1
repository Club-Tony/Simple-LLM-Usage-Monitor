# Offline tests of the one-click installer. ASCII only.
# Builds the release twice into scratch, then runs the BAT carrier, the ZIP's Install.bat and
# Setup-LLMUsageMonitor.ps1 against fixture runtimes served from a fake mirror. Every setup run has
# LLMUSAGE_SETUP_TEST=1 and scratch locations, so nothing here writes the registry, the real Start
# Menu or Startup folders, or the real install and data folders (checked before and after).
# Prints one line per check; exit code = failed checks. Run by installer.test.mjs, which also points
# TEMP and TMP at scratch. -SetupOverride swaps a (deliberately broken) setup script into the built
# package, for calibration runs.
param(
    [Parameter(Mandatory = $true)][string]$Scratch,
    [string]$SetupOverride = ''
)
$ErrorActionPreference = 'Stop'

$InstallerDir = $PSScriptRoot
$MonitorDir = Split-Path -Path $InstallerDir -Parent
$Scratch = (Resolve-Path -LiteralPath $Scratch).ProviderPath
$PowerShell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Cmd = Join-Path -Path $env:SystemRoot -ChildPath 'System32\cmd.exe'
$env:LLMUSAGE_SETUP_TEST = '1'
Remove-Item -LiteralPath 'Env:LLMUSAGE_BUNDLE_NOLAUNCH' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'Env:LLMUSAGE_SETUP_FAULT' -ErrorAction SilentlyContinue

$script:failures = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Output "ok   $Name" }
    else {
        $script:failures++
        Write-Output "FAIL $Name"
        if ($Detail) { Write-Output ('     ' + ($Detail.Trim() -replace "`r?`n", "`n     ")) }
    }
}

function Get-Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-TextSha([string]$Text) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}
function Get-TreeHash([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return 'absent' }
    $lines = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Dir.Length) + ' ' + (Get-Sha $_.FullName) } | Sort-Object)
    return (Get-TextSha ($lines -join "`n"))
}

# Runs a program with redirected output and the given text on stdin (then closed).
function Invoke-Captured([string]$FilePath, [string]$ArgumentLine, [string]$StdIn = '', [hashtable]$ExtraEnv = @{}) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($key in $ExtraEnv.Keys) {
        if ($psi.EnvironmentVariables.ContainsKey($key)) { $psi.EnvironmentVariables.Remove($key) }
        if ($null -ne $ExtraEnv[$key]) { $psi.EnvironmentVariables.Add($key, [string]$ExtraEnv[$key]) }
    }
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($StdIn) { $p.StandardInput.Write($StdIn) }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(180000)) { try { $p.Kill() } catch {}; return @{ Code = -1; Out = 'TIMEOUT' } }
    $p.WaitForExit()
    return @{ Code = $p.ExitCode; Out = ($outTask.Result + $errTask.Result) }
}

function Join-Args([string[]]$Items) {
    return (($Items | ForEach-Object { if ($_ -match '\s' -or $_ -eq '') { '"' + $_ + '"' } else { $_ } }) -join ' ')
}

function Invoke-Setup([string]$Script, [string[]]$SetupArgs, [string]$StdIn = '', [hashtable]$ExtraEnv = @{}) {
    $line = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + (Join-Args $SetupArgs)
    return (Invoke-Captured $PowerShell $line $StdIn $ExtraEnv)
}

function Invoke-Bat([string]$Bat, [string[]]$BatArgs, [hashtable]$ExtraEnv = @{}) {
    $line = '/d /s /c ""' + $Bat + '" ' + (Join-Args $BatArgs) + '"'
    return (Invoke-Captured $Cmd $line '' $ExtraEnv)
}

function Get-Shortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    return @{ Target = [string]$link.TargetPath; Arguments = [string]$link.Arguments; WorkingDirectory = [string]$link.WorkingDirectory }
}

function New-Shortcut([string]$Path, [string]$Target) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path -Parent) | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($Path)
    $link.TargetPath = $Target
    $link.Save()
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-FixtureZip([string]$Path, $Entries) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path -Parent) | Out-Null
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($name in @($Entries.Keys)) {
                $writer = New-Object IO.StreamWriter($zip.CreateEntry($name).Open())
                try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $stream.Dispose() }
}

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path -Parent) | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}

# --- Real-profile guard: read-only, compared at the end ----------------------------------------
function Get-RealProfileState {
    $programs = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs'
    return @(
        ('startmenu=' + (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'LLM Usage Monitor.lnk'))),
        ('startup=' + (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Startup')) 'LLM Usage Monitor.lnk'))),
        ('appskey=' + (Test-Path -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LLMUsageMonitor')),
        ('programs=' + ((@(Get-ChildItem -LiteralPath $programs -Filter 'LLMUsageMonitor*' -Force -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join ',')),
        ('data=' + ((@(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'LLMUsageMonitor') -Force -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name }) -join ','))
    ) -join '; '
}
$realBefore = Get-RealProfileState

# --- 1. Source checks ---------------------------------------------------------------------------
$setupSource = Join-Path -Path $InstallerDir -ChildPath 'Setup-LLMUsageMonitor.ps1'
$psFiles = @(Get-ChildItem -LiteralPath $InstallerDir -Filter '*.ps1' | ForEach-Object { $_.FullName }) + @((Join-Path $MonitorDir 'Get-LLMUsageSnapshot.ps1'))
foreach ($file in $psFiles) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $leaf = Split-Path -Path $file -Leaf
    Check "source: $leaf parses" (@($errors).Count -eq 0) (@($errors) -join "`n")
    Check "source: $leaf is ASCII" (@([IO.File]::ReadAllBytes($file) | Where-Object { $_ -gt 127 }).Count -eq 0)
}
$shipped = @{
    'Setup-LLMUsageMonitor.ps1' = [IO.File]::ReadAllText($setupSource)
    'BundleExtractor.ps1'       = [IO.File]::ReadAllText((Join-Path $InstallerDir 'BundleExtractor.ps1'))
    'BundleStub.cmd.txt'        = [IO.File]::ReadAllText((Join-Path $InstallerDir 'BundleStub.cmd.txt'))
    'Install.bat'               = [IO.File]::ReadAllText((Join-Path $InstallerDir 'Install.bat'))
}
$banned = @('Invoke-Expression', '\biex\b', 'EncodedCommand', 'WindowStyle\s+Hidden', 'Stop-Process\s+-Name', 'taskkill', 'HKLM:',
    "SetEnvironmentVariable\(\s*'Path'", "'(User|Machine)'\s*\)", 'MpPreference', 'Ahk2Exe', 'RunAs', 'Start-Transcript',
    '\.claude', '\.codex', '\.grok', 'Mozilla', 'Firefox', '\bagy\b')
foreach ($name in $shipped.Keys) {
    $hits = @($banned | Where-Object { $shipped[$name] -match $_ })
    Check "source: $name has none of the banned tokens" ($hits.Count -eq 0) ($hits -join ', ')
}
$setupText = $shipped['Setup-LLMUsageMonitor.ps1']
$llmNames = @([regex]::Matches($setupText, 'llm-usage-[a-z-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
Check 'source: setup names only the app''s own llm-usage- data files' ((@($llmNames | Where-Object { $_ -notin @('llm-usage-discovery-cache', 'llm-usage-token-cache') }).Count -eq 0)) ($llmNames -join ', ')
Check 'source: setup has exactly one registry key' (([regex]::Matches($setupText, 'HKCU:')).Count -eq 1 -and ([regex]::Matches($setupText, 'CurrentVersion\\Uninstall')).Count -eq 1)
$guiText = [IO.File]::ReadAllText((Join-Path $MonitorDir 'Usage_Monitor_GUI.ahk'))
$hostText = [IO.File]::ReadAllText((Join-Path $MonitorDir 'Usage_Monitor.ahk'))
$guiDir = [regex]::Match($guiText, 'usageMonitorAppDirName\s*:=\s*"([^"]+)"').Groups[1].Value
$hostLink = [regex]::Match($hostText, 'usageMonitorStandaloneLinkName\s*:=\s*"([^"]+)"').Groups[1].Value
$setupId = [regex]::Match($setupText, "\`$script:ProductId\s*=\s*'([^']+)'").Groups[1].Value
$setupLink = [regex]::Match($setupText, "\`$script:LinkName\s*=\s*'([^']+)'").Groups[1].Value
Check 'drift: setup''s folder name equals the GUI''s data folder name' ($guiDir -and $guiDir -eq $setupId) "$guiDir vs $setupId"
Check 'drift: setup''s shortcut name equals the tray''s' ($hostLink -and $hostLink -eq $setupLink) "$hostLink vs $setupLink"

# --- 2. Build -----------------------------------------------------------------------------------
$builder = Join-Path -Path $InstallerDir -ChildPath 'Build-UsageMonitorRelease.ps1'
$buildA = Join-Path $Scratch 'build-a'
$buildB = Join-Path $Scratch 'build-b'
$resultA = Invoke-Captured $PowerShell ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $builder + '" -OutputRoot "' + $buildA + '" -AllowDirty')
$resultB = Invoke-Captured $PowerShell ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $builder + '" -OutputRoot "' + $buildB + '" -AllowDirty')
Check 'build: both builds succeed' ($resultA.Code -eq 0 -and $resultB.Code -eq 0) ($resultA.Out + $resultB.Out)
if ($resultA.Code -ne 0) { Write-Output 'Build failed; stopping.'; exit ($script:failures + 1) }
$version = [string](Get-Content -LiteralPath (Join-Path $MonitorDir 'package.json') -Raw | ConvertFrom-Json).version
$batName = "LLMUsageMonitor-Setup-v$version.bat"
$zipName = "LLMUsageMonitor-v$version.zip"
foreach ($leaf in @($batName, $zipName, 'release.json', 'SHA256SUMS.txt')) {
    Check "build: $leaf is byte-identical across two builds" ((Get-Sha (Join-Path $buildA $leaf)) -eq (Get-Sha (Join-Path $buildB $leaf)))
}
$zipFile = [IO.Compression.ZipFile]::OpenRead((Join-Path $buildA $zipName))
try { $entries = @($zipFile.Entries | ForEach-Object { $_.FullName }) } finally { $zipFile.Dispose() }
$top = "LLMUsageMonitor-v$version/"
$expectedEntries = @('Get-LLMUsageSnapshot.ps1', 'Install.bat', 'LICENSE', 'Protect-CacheValue.ps1', 'README-INSTALL.txt', 'README.md',
    'SECURITY.md', 'addon-provider.mjs', 'THIRD-PARTY-NOTICES.md', 'Usage_Monitor.ahk', 'Usage_Monitor_GUI.ahk', 'claude-account-label.mjs',
    'cli-credentials.mjs', 'debug-redaction.mjs', 'firefox-cookie-db.mjs', 'provider-settings.mjs', 'release.json', 'setup/Resolve-AHK-Runtime.ps1',
    'setup/Setup-LLMUsageMonitor.ps1', 'setup/payload-manifest.json', 'setup/runtime-pins.json', 'sqlite-tool.mjs', 'sqlite3.exe', 'token-cache.mjs',
    'usage-classification.mjs', 'usage-scraper.mjs') | ForEach-Object { $top + $_ }
Check 'build: the ZIP holds exactly the expected files' ((($entries | Sort-Object) -join '|') -eq (($expectedEntries | Sort-Object) -join '|')) (Compare-Object $expectedEntries $entries | Out-String)
$release = Get-Content -LiteralPath (Join-Path $buildA 'release.json') -Raw | ConvertFrom-Json
$head = (& git -C $MonitorDir rev-parse HEAD).Trim()
Check 'build: release.json version and commit match package.json and HEAD' ($release.version -eq $version -and $release.sourceCommit -eq $head)
$resolverText = [IO.File]::ReadAllText((Join-Path $InstallerDir 'Resolve-AHK-Runtime.ps1'))
$resolverSha = [regex]::Match($resolverText, 'AhkV1ZipSha256\s*=\s*"([0-9A-Fa-f]{64})"').Groups[1].Value.ToLowerInvariant()
Check 'drift: release.json carries the resolver''s AutoHotkey pin' ($resolverSha -and $release.runtimes.autohotkey.zipSha256 -eq $resolverSha)
$batBytes = [IO.File]::ReadAllBytes((Join-Path $buildA $batName))
$batText = [Text.Encoding]::ASCII.GetString($batBytes)
Check 'build: the BAT is ASCII' (@($batBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
Check 'build: the BAT uses CRLF line endings only' (-not ($batText -match '[^\r]\n'))
Check 'build: the BAT sets its title and ends with the Enter pause' ($batText.Contains('title Simple LLM Usage Monitor Setup') -and $batText.Contains('echo Press Enter to exit.'))
$sums = @(Get-Content -LiteralPath (Join-Path $buildA 'SHA256SUMS.txt'))
Check 'build: SHA256SUMS.txt matches the BAT and the ZIP' (($sums -contains "$(Get-Sha (Join-Path $buildA $batName))  $batName") -and ($sums -contains "$(Get-Sha (Join-Path $buildA $zipName))  $zipName"))

# The package every setup run below uses: the built ZIP, extracted.
$pkgRoot = Join-Path $Scratch 'pkg'
[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $buildA $zipName), $pkgRoot)
$payload = Join-Path $pkgRoot "LLMUsageMonitor-v$version"
$setup = Join-Path $payload 'setup\Setup-LLMUsageMonitor.ps1'
if ($SetupOverride) {
    Copy-Item -LiteralPath $SetupOverride -Destination $setup -Force
    $manifestPath = Join-Path $payload 'setup\payload-manifest.json'
    $manifestJson = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($entry in $manifestJson.files) {
        if ($entry.path -eq 'setup\Setup-LLMUsageMonitor.ps1') { $entry.sha256 = Get-Sha $setup; $entry.size = (Get-Item -LiteralPath $setup).Length }
    }
    [IO.File]::WriteAllText($manifestPath, ($manifestJson | ConvertTo-Json -Depth 6))
    Write-Output "(calibration: setup replaced by $SetupOverride)"
}

# --- 3. Fixture runtimes and the fake mirror ----------------------------------------------------
$mirror = Join-Path $Scratch 'mirror'
$ahkVersion = [regex]::Match($resolverText, 'AhkV1Version\s*=\s*"([^"]+)"').Groups[1].Value
$ahkZipName = "AutoHotkey_$ahkVersion.zip"
$ahkPrimary = Join-Path $mirror "ahk-primary.invalid\$ahkZipName"
$ahkFallback = Join-Path $mirror "ahk-fallback.invalid\$ahkZipName"
New-FixtureZip $ahkPrimary ([ordered]@{ 'AutoHotkeyU64.exe' = 'fixture autohotkey'; 'license.txt' = 'fixture autohotkey licence'; 'AutoHotkeyA32.exe' = 'not kept'; 'Compiler/Ahk2Exe.exe' = 'never extracted' })
Copy-Item -LiteralPath $ahkPrimary -Destination (New-Item -ItemType Directory -Force -Path (Split-Path $ahkFallback -Parent)).FullName
$ahkSha = Get-Sha $ahkPrimary
$nodeVersion = 'v90.1.2'
$nodeRelDir = Join-Path $mirror "node.invalid\dist\$nodeVersion"
$nodeZip = Join-Path $nodeRelDir "node-$nodeVersion-win-x64.zip"
New-FixtureZip $nodeZip ([ordered]@{ "node-$nodeVersion-win-x64/node.exe" = 'fixture node'; "node-$nodeVersion-win-x64/LICENSE" = 'fixture node licence'; "node-$nodeVersion-win-x64/npm" = 'not kept' })
$nodeSha = Get-Sha $nodeZip
Write-Text (Join-Path $nodeRelDir 'SHASUMS256.txt') ((('0' * 64) + "  node-$nodeVersion-x64.msi`n") + "$nodeSha  node-$nodeVersion-win-x64.zip`n")
$pins = Join-Path $Scratch 'pins.json'
Write-Text $pins (@{
    node       = @{ version = $nodeVersion; distBaseUrl = 'https://node.invalid/dist'; zipSha256 = $nodeSha; zipBytes = 1000 }
    autohotkey = @{ zipBytes = 1000; zipSha256 = $ahkSha; urls = @("https://ahk-primary.invalid/$ahkZipName", "https://ahk-fallback.invalid/$ahkZipName") }
} | ConvertTo-Json -Depth 4)
$requestsLog = Join-Path $mirror 'requests.log'
function Get-Requests { if (Test-Path -LiteralPath $requestsLog) { return @(Get-Content -LiteralPath $requestsLog) } else { return @() } }
function Clear-Requests { if (Test-Path -LiteralPath $requestsLog) { Remove-Item -LiteralPath $requestsLog -Force } }

function New-Locations([string]$Name) {
    $base = Join-Path $Scratch $Name
    return @{
        Base = $base; Root = Join-Path $base 'Programs\LLMUsageMonitor'; Data = Join-Path $base 'data'
        StartMenu = Join-Path $base 'startmenu'; Startup = Join-Path $base 'startup'; Reg = Join-Path $base 'apps-entry.json'
    }
}
function Get-LocArgs($L) {
    return @('-InstallRoot', $L.Root, '-DataDir', $L.Data, '-StartMenuDir', $L.StartMenu, '-StartupDir', $L.Startup,
        '-RegistrationFile', $L.Reg, '-OfflineMirror', $mirror, '-RuntimePinsFile', $pins, '-NoLaunch')
}
function Get-SiblingNames($L) { return @(Get-ChildItem -LiteralPath (Split-Path $L.Root -Parent) -Force | ForEach-Object { $_.Name }) }

# --- 4. Carrier: the self-contained BAT and the ZIP's Install.bat -------------------------------
$carrier = Join-Path $Scratch 'carrier'
New-Item -ItemType Directory -Force -Path $carrier | Out-Null
$bat = Join-Path $carrier $batName
Copy-Item -LiteralPath (Join-Path $buildA $batName) -Destination $bat
function Get-TempLeftovers { return @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Force -Filter 'LLMUsageMonitor-*' -ErrorAction SilentlyContinue) }
$r = Invoke-Bat $bat @() @{ LLMUSAGE_BUNDLE_NOLAUNCH = '1' }
Check 'carrier: the BAT verifies and unpacks its ZIP (no-launch hook)' ($r.Code -eq 0 -and $r.Out.Contains('Release verified')) $r.Out
Check 'carrier: nothing is left in TEMP' ((Get-TempLeftovers).Count -eq 0) ((Get-TempLeftovers | ForEach-Object Name) -join ', ')

$lines = $batText -split "`r`n"
$payloadLine = [Array]::IndexOf($lines, '#===PAYLOAD===') + 1
function Write-BatVariant([string]$Name, [string[]]$VariantLines) {
    $path = Join-Path $carrier $Name
    [IO.File]::WriteAllText($path, ($VariantLines -join "`r`n"), [Text.Encoding]::ASCII)
    return $path
}
$tampered = $lines.Clone()
$chars = $tampered[$payloadLine].ToCharArray()
$mid = [int]($chars.Length / 2)
$chars[$mid] = if ($chars[$mid] -eq 'A') { 'B' } else { 'A' }
$tampered[$payloadLine] = New-Object string (, $chars)
$r = Invoke-Bat (Write-BatVariant 'tampered.bat' $tampered) @() @{ LLMUSAGE_BUNDLE_NOLAUNCH = '1' }
Check 'carrier: one changed Base64 character is refused with exit 9' ($r.Code -eq 9 -and $r.Out.Contains('failed its SHA-256 check')) $r.Out
Check 'carrier: the refused BAT unpacked nothing' ((Get-TempLeftovers).Count -eq 0)
$cut = $lines.Clone()
$cut[$payloadLine] = $cut[$payloadLine].Substring(0, $cut[$payloadLine].Length - 200)
$r = Invoke-Bat (Write-BatVariant 'short-payload.bat' $cut) @() @{ LLMUSAGE_BUNDLE_NOLAUNCH = '1' }
Check 'carrier: a truncated payload is refused with exit 9' ($r.Code -eq 9) $r.Out
$r = Invoke-Bat (Write-BatVariant 'no-payload.bat' $lines[0..($payloadLine - 2)]) @() @{ LLMUSAGE_BUNDLE_NOLAUNCH = '1' }
Check 'carrier: a BAT cut before its payload is refused with exit 9' ($r.Code -eq 9 -and $r.Out.Contains('incomplete or damaged')) $r.Out
$extractorLine = [Array]::IndexOf($lines, '#===EXTRACTOR===')
$r = Invoke-Bat (Write-BatVariant 'cut-extractor.bat' $lines[0..($extractorLine + 20)]) @() @{ LLMUSAGE_BUNDLE_NOLAUNCH = '1' }
Check 'carrier: a BAT cut inside the extractor is refused with exit 9' ($r.Code -eq 9) $r.Out
$r = Invoke-Bat (Write-BatVariant 'cut-stub.bat' $lines[0..8]) @() @{ LLMUSAGE_BUNDLE_NOLAUNCH = '1' }
Check 'carrier: a BAT cut inside its stub never reaches setup' (-not $r.Out.Contains('Release verified') -and (Get-TempLeftovers).Count -eq 0) $r.Out

$statusLoc = New-Locations 'status'
$r = Invoke-Bat $bat (@('-Action', 'Status') + (Get-LocArgs $statusLoc))
Check 'carrier: the BAT hands its arguments to setup and passes exit 0 back' ($r.Code -eq 0 -and $r.Out.Contains('is not installed at')) $r.Out
$r = Invoke-Bat $bat @('-Action', 'Bogus')
Check 'carrier: the BAT passes setup''s failure code back' ($r.Code -ne 0 -and $r.Code -ne 9) "code=$($r.Code)`n$($r.Out)"
Check 'carrier: the hand-off left nothing in TEMP' ((Get-TempLeftovers).Count -eq 0)
$installBat = Join-Path $payload 'Install.bat'
$r = Invoke-Bat $installBat (@('-Action', 'Status') + (Get-LocArgs $statusLoc))
Check 'Install.bat: runs setup from its folder and passes exit 0 back' ($r.Code -eq 0 -and $r.Out.Contains('is not installed at')) $r.Out
$r = Invoke-Bat $installBat @('-Action', 'Bogus')
Check 'Install.bat: passes setup''s failure code back' ($r.Code -ne 0) $r.Out
$lonely = Join-Path $Scratch 'lonely'
New-Item -ItemType Directory -Force -Path $lonely | Out-Null
Copy-Item -LiteralPath $installBat -Destination $lonely
$r = Invoke-Bat (Join-Path $lonely 'Install.bat') @('-x')
Check 'Install.bat: outside an extracted ZIP it says to extract first (exit 9)' ($r.Code -eq 9 -and $r.Out.Contains('Extract the whole ZIP first')) $r.Out

# --- 5. Test fence ------------------------------------------------------------------------------
$fenceLoc = New-Locations 'fence'
$noReg = @(Get-LocArgs $fenceLoc | Where-Object { $_ -ne '-RegistrationFile' -and $_ -ne $fenceLoc.Reg })
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive') + $noReg)
Check 'fence: test mode refuses a run without every scratch location' ($r.Code -eq 1 -and $r.Out.Contains('Test mode needs') -and -not (Test-Path -LiteralPath $fenceLoc.Root)) $r.Out
$realRoot = Join-Path $env:LOCALAPPDATA 'Programs\LLMUsageMonitor'
$fenceArgs = @(Get-LocArgs $fenceLoc)
$fenceArgs[1] = $realRoot
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive') + $fenceArgs)
Check 'fence: test mode refuses the real install folder' ($r.Code -eq 1 -and $r.Out.Contains('refuses a real location')) $r.Out
$r = Invoke-Setup $setup @('-Action', 'Status', '-OfflineMirror', $mirror) '' @{ LLMUSAGE_SETUP_TEST = $null }
Check 'fence: the test-only options are refused outside test mode' ($r.Code -eq 1 -and $r.Out.Contains('for the installer tests only')) $r.Out

# --- 6. Fresh install ---------------------------------------------------------------------------
$L1 = New-Locations 'life1'
Clear-Requests
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive') + (Get-LocArgs $L1))
Check 'install: a fresh non-interactive install succeeds' ($r.Code -eq 0 -and $r.Out.Contains('is installed.')) $r.Out
$manifest = Get-Content -LiteralPath (Join-Path $L1.Root 'setup\payload-manifest.json') -Raw | ConvertFrom-Json
$bad = @($manifest.files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $L1.Root $_.path)) -or (Get-Sha (Join-Path $L1.Root $_.path)) -ne $_.sha256 })
Check 'install: every manifest file is in place with its hash' ($manifest.files.Count -ge 20 -and $bad.Count -eq 0) (($bad | ForEach-Object path) -join ', ')
$runtimeFiles = @(Get-ChildItem -LiteralPath (Join-Path $L1.Root 'runtime') -Force | ForEach-Object { $_.Name } | Sort-Object)
$keptFiles = @('AutoHotkeyU64.exe', 'AutoHotkey-license.txt', 'node.exe', 'Node-LICENSE.txt') | Sort-Object
Check 'install: runtime\ holds exactly the four kept files' (($runtimeFiles -join '|') -ceq ($keptFiles -join '|')) ($runtimeFiles -join ', ')
Check 'install: the runtimes are the fixture files' (([IO.File]::ReadAllText((Join-Path $L1.Root 'runtime\node.exe')) -eq 'fixture node') -and ([IO.File]::ReadAllText((Join-Path $L1.Root 'runtime\AutoHotkeyU64.exe')) -eq 'fixture autohotkey'))
Check 'install: nothing else from the zips (no Compiler, no npm)' (@(Get-ChildItem -LiteralPath $L1.Root -Recurse -Force | Where-Object { $_.Name -in @('Compiler', 'Ahk2Exe.exe', 'npm', 'AutoHotkeyA32.exe') }).Count -eq 0)
$state = Get-Content -LiteralPath (Join-Path $L1.Root 'install-state.json') -Raw | ConvertFrom-Json
Check 'install: the state file says installed, with both runtimes recorded' ($state.status -eq 'installed' -and $state.version -eq $version -and $state.runtimes.node.version -eq $nodeVersion -and $state.runtimes.autohotkey.zipSha256 -eq $ahkSha)
$menuLink = Join-Path $L1.StartMenu 'LLM Usage Monitor.lnk'
$link = if (Test-Path -LiteralPath $menuLink) { Get-Shortcut $menuLink } else { @{ Target = ''; Arguments = ''; WorkingDirectory = '' } }
Check 'install: the Start Menu shortcut opens the installed app with its own AutoHotkey' ($link.Target -eq (Join-Path $L1.Root 'runtime\AutoHotkeyU64.exe') -and $link.Arguments -eq ('"' + (Join-Path $L1.Root 'Usage_Monitor.ahk') + '"') -and $link.WorkingDirectory -eq $L1.Root) ($link | Out-String)
Check 'install: no Startup shortcut unless asked' (-not (Test-Path -LiteralPath (Join-Path $L1.Startup 'LLM Usage Monitor.lnk')))
$entry = if (Test-Path -LiteralPath $L1.Reg) { Get-Content -LiteralPath $L1.Reg -Raw | ConvertFrom-Json } else { $null }
$expectedUninstall = '-File "' + (Join-Path $L1.Root 'setup\Setup-LLMUsageMonitor.ps1') + '" -Action Uninstall -FromAppsEntry'
Check 'install: the Settings > Apps entry names this install and its uninstaller' ($entry -and $entry.DisplayName -eq 'Simple LLM Usage Monitor' -and $entry.InstallLocation -eq $L1.Root -and $entry.UninstallString.EndsWith($expectedUninstall) -and $entry.QuietUninstallString.EndsWith($expectedUninstall + ' -NonInteractive') -and $entry.NoModify -eq 1 -and $entry.EstimatedSize -gt 0) ($entry | Out-String)
$requests = Get-Requests
Check 'install: AutoHotkey from its first source, then SHASUMS256 and the zip for Node, never index.json' ((@($requests) -join '|') -eq ("https://ahk-primary.invalid/$ahkZipName|https://node.invalid/dist/$nodeVersion/SHASUMS256.txt|https://node.invalid/dist/$nodeVersion/node-$nodeVersion-win-x64.zip")) ($requests -join "`n")
Check 'install: no staging, download or previous folder is left' ((Get-SiblingNames $L1) -join '|' -eq 'LLMUsageMonitor' -and -not (Test-Path -LiteralPath (Join-Path $L1.Root '.download')))
Check 'install: the data folder is left for the app to create' (-not (Test-Path -LiteralPath $L1.Data))

# --- 7. Interactive runs ------------------------------------------------------------------------
$L2 = New-Locations 'life2'
$r = Invoke-Setup $setup (@('-Action', 'Interactive') + (Get-LocArgs $L2)) "`n`n"
Check 'interactive: a first run installs with no menu' ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $L2.Root 'install-state.json')) -and -not $r.Out.Contains('[1] Reinstall')) $r.Out
Check 'interactive: each prompt follows a blank line' (($r.Out -match '(\r?\n){2}Press Enter to install') -and ($r.Out -match '(\r?\n){2}Start Simple LLM Usage Monitor when you sign in')) $r.Out
Check 'interactive: Enter at the Startup question means No' (-not (Test-Path -LiteralPath (Join-Path $L2.Startup 'LLM Usage Monitor.lnk')))
$before = Get-TreeHash $L2.Root
$r = Invoke-Setup $setup (@('-Action', 'Interactive') + (Get-LocArgs $L2)) "3`n"
Check 'interactive: an installed PC gets [1] Reinstall [2] Uninstall [3] Close' ($r.Out.Contains('[1] Reinstall') -and $r.Out.Contains('[2] Uninstall') -and $r.Out.Contains('[3] Close') -and ($r.Out -match '(\r?\n){2}Selection:')) $r.Out
Check 'interactive: 3 closes and changes nothing' ($r.Code -eq 0 -and (Get-TreeHash $L2.Root) -eq $before)
$r = Invoke-Setup $setup (@('-Action', 'Interactive') + (Get-LocArgs $L2)) "x`n"
Check 'interactive: an unknown answer closes and changes nothing' ($r.Code -eq 0 -and (Get-TreeHash $L2.Root) -eq $before) $r.Out
Write-Text (Join-Path $L2.Data 'settings.ini') "[Settings]`r`nhotkey=^#!u`r`n"
$settingsHash = Get-Sha (Join-Path $L2.Data 'settings.ini')
Clear-Requests
$r = Invoke-Setup $setup (@('-Action', 'Interactive') + (Get-LocArgs $L2)) "1`n"
Check 'reinstall: 1 reinstalls' ($r.Code -eq 0 -and $r.Out.Contains('is reinstalled')) $r.Out
Check 'reinstall: unchanged runtimes are reused, nothing downloaded' ((Get-Requests).Count -eq 0) ((Get-Requests) -join "`n")
Check 'reinstall: settings.ini is untouched' ((Get-Sha (Join-Path $L2.Data 'settings.ini')) -eq $settingsHash)
Check 'reinstall: still one Start Menu shortcut and no extra folders' (@(Get-ChildItem -LiteralPath $L2.StartMenu).Count -eq 1 -and ((Get-SiblingNames $L2) -join '|') -eq 'LLMUsageMonitor')

# --- 8. Startup shortcut ------------------------------------------------------------------------
$L3 = New-Locations 'life3'
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive', '-Startup') + (Get-LocArgs $L3))
$startupLink = Join-Path $L3.Startup 'LLM Usage Monitor.lnk'
$link = if (Test-Path -LiteralPath $startupLink) { Get-Shortcut $startupLink } else { @{ Target = ''; Arguments = ''; WorkingDirectory = '' } }
Check 'startup: -Startup writes the tray''s Startup shortcut' ($r.Code -eq 0 -and $link.Target -eq (Join-Path $L3.Root 'runtime\AutoHotkeyU64.exe') -and $link.Arguments -eq ('"' + (Join-Path $L3.Root 'Usage_Monitor.ahk') + '" /startup') -and $link.WorkingDirectory -eq $L3.Root) ($r.Out + ($link | Out-String))
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive') + (Get-LocArgs $L3))
Check 'startup: a reinstall keeps the Startup shortcut' ($r.Code -eq 0 -and (Test-Path -LiteralPath $startupLink)) $r.Out

# --- 9. Runtime repair and failures -------------------------------------------------------------
$nodeInstalled = Join-Path $L1.Root 'runtime\node.exe'
[IO.File]::WriteAllText($nodeInstalled, 'corrupted')
Clear-Requests
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive') + (Get-LocArgs $L1))
Check 'repair: a changed node.exe is downloaded again' ($r.Code -eq 0 -and [IO.File]::ReadAllText($nodeInstalled) -eq 'fixture node' -and (Get-Requests).Count -eq 2) ($r.Out + ((Get-Requests) -join "`n"))
[IO.File]::WriteAllText($nodeInstalled, 'corrupted')
$goodNodeZip = [IO.File]::ReadAllBytes($nodeZip)
[IO.File]::AppendAllText($nodeZip, 'x')
$before = Get-TreeHash $L1.Root
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive') + (Get-LocArgs $L1))
Check 'repair: a zip that fails its check stops setup with exit 2 and the download link' ($r.Code -eq 2 -and $r.Out.Contains("node-$nodeVersion-win-x64.zip") -and $r.Out.Contains('Save each file next to this installer')) $r.Out
Check 'repair: the failed run left the install exactly as it was' ((Get-TreeHash $L1.Root) -eq $before -and ((Get-SiblingNames $L1) -join '|') -eq 'LLMUsageMonitor')
[IO.File]::WriteAllBytes($nodeZip, $goodNodeZip)
$ahkInstalled = Join-Path $L1.Root 'runtime\AutoHotkeyU64.exe'
[IO.File]::WriteAllText($ahkInstalled, 'corrupted')
$primaryBytes = [IO.File]::ReadAllBytes($ahkPrimary)
Remove-Item -LiteralPath $ahkPrimary
Clear-Requests
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive') + (Get-LocArgs $L1))
$requests = @(Get-Requests)
Check 'repair: AutoHotkey falls back to its second source' ($r.Code -eq 0 -and $requests.Count -ge 2 -and $requests[0] -like '*ahk-primary*' -and $requests[1] -like '*ahk-fallback*' -and [IO.File]::ReadAllText($ahkInstalled) -eq 'fixture autohotkey') ($r.Out + ($requests -join "`n"))
[IO.File]::WriteAllText($ahkInstalled, 'corrupted')
$fallbackBytes = [IO.File]::ReadAllBytes($ahkFallback)
Remove-Item -LiteralPath $ahkFallback
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive') + (Get-LocArgs $L1))
Check 'repair: with both sources down setup exits 2 and names the download' ($r.Code -eq 2 -and $r.Out.Contains("ahk-primary.invalid/$ahkZipName")) $r.Out
$localPkg = Join-Path $Scratch 'localpkg'
New-Item -ItemType Directory -Force -Path $localPkg | Out-Null
[IO.File]::WriteAllBytes((Join-Path $localPkg $ahkZipName), $primaryBytes)
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive', '-LocalPackageDir', $localPkg) + (Get-LocArgs $L1))
Check 'repair: a pinned zip saved beside the installer is used' ($r.Code -eq 0 -and $r.Out.Contains('Using the saved') -and [IO.File]::ReadAllText($ahkInstalled) -eq 'fixture autohotkey') $r.Out
[IO.File]::WriteAllBytes($ahkPrimary, $primaryBytes)
[IO.File]::WriteAllBytes($ahkFallback, $fallbackBytes)
$before = Get-TreeHash $L1.Root
$r = Invoke-Setup $setup (@('-Action', 'Reinstall', '-NonInteractive') + (Get-LocArgs $L1)) '' @{ LLMUSAGE_SETUP_FAULT = 'after-move-aside' }
Check 'swap: a failure after moving the install aside puts it back' ($r.Code -eq 1 -and (Get-TreeHash $L1.Root) -eq $before -and ((Get-SiblingNames $L1) -join '|') -eq 'LLMUsageMonitor') ($r.Out + ((Get-SiblingNames $L1) -join ', '))

$L4 = New-Locations 'life4'
Write-Text (Join-Path $L4.Root 'mine.txt') 'not the installer''s'
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive') + (Get-LocArgs $L4))
Check 'ownership: a folder without a state file is refused and left alone' ($r.Code -eq 1 -and $r.Out.Contains('was not created by this installer') -and (@(Get-ChildItem -LiteralPath $L4.Root).Count -eq 1)) $r.Out

$L5 = New-Locations 'life5'
$foreign = Join-Path $L5.Startup 'LLM Usage Monitor.lnk'
New-Shortcut $foreign (Join-Path $env:SystemRoot 'notepad.exe')
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive', '-Startup') + (Get-LocArgs $L5))
Check 'ownership: a Startup shortcut that opens something else is left alone' ($r.Code -eq 0 -and $r.Out.Contains('alone') -and (Get-Shortcut $foreign).Target -like '*notepad.exe') $r.Out

# --- 10. Unit checks of the process filter and the data-file rules ------------------------------
# In a child process: dot-sourcing setup sets its own script-scope variables (such as $script:Pins),
# which in this script would overwrite this test's variables of the same name.
$unitProbe = Join-Path $Scratch 'unit-probe.ps1'
Write-Text $unitProbe (@'
param([string]$Setup)
$ErrorActionPreference = 'Stop'
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Output "ok   $Name" } else { Write-Output "FAIL $Name"; if ($Detail) { Write-Output "     $Detail" } }
}
. $Setup -LoadOnly
'@ + "`r`n" + @'
    $root = 'C:\Fake\Programs\LLMUsageMonitor'
    $procs = @(
        [pscustomobject]@{ ProcessId = 100; ParentProcessId = 90; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = "powershell -File `"$root\setup\Setup-LLMUsageMonitor.ps1`"" }
        [pscustomobject]@{ ProcessId = 90; ParentProcessId = 1; ExecutablePath = 'C:\Windows\System32\cmd.exe'; CommandLine = "cmd /c `"$root\setup\x.cmd`"" }
        [pscustomobject]@{ ProcessId = 200; ParentProcessId = 1; ExecutablePath = "$root\runtime\AutoHotkeyU64.exe"; CommandLine = "`"$root\runtime\AutoHotkeyU64.exe`" `"$root\Usage_Monitor.ahk`"" }
        [pscustomobject]@{ ProcessId = 201; ParentProcessId = 200; ExecutablePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; CommandLine = "powershell -File `"$root\Get-LLMUsageSnapshot.ps1`" -Mode Snapshot" }
        [pscustomobject]@{ ProcessId = 202; ParentProcessId = 201; ExecutablePath = "$root\runtime\node.exe"; CommandLine = 'node usage-scraper.mjs' }
        [pscustomobject]@{ ProcessId = 300; ParentProcessId = 1; ExecutablePath = 'C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe'; CommandLine = '"C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe" "C:\Scripts\My-Hotkeys.ahk"' }
        [pscustomobject]@{ ProcessId = 301; ParentProcessId = 1; ExecutablePath = 'C:\Fake\Programs\LLMUsageMonitor2\runtime\AutoHotkeyU64.exe'; CommandLine = '' }
        [pscustomobject]@{ ProcessId = 302; ParentProcessId = 1; ExecutablePath = 'C:\FAKE\PROGRAMS\LLMUSAGEMONITOR\RUNTIME\NODE.EXE'; CommandLine = '' }
        [pscustomobject]@{ ProcessId = 303; ParentProcessId = 1; ExecutablePath = ''; CommandLine = '' }
    )
    $selected = @(Select-OwnedProcesses $procs $root 100 | ForEach-Object { $_.ProcessId } | Sort-Object)
    Check 'processes: only the app''s own (exe or command line inside the folder, any case)' (($selected -join ',') -eq '200,201,202,302') ($selected -join ',')
    $keep = @('playwright-profile', 'unknown.txt', 'node.previous-x', 'llm-usage-other.json', 'tmp2')
    $own = @('settings.ini', 'snapshot.log', 'llm-usage-token-cache.dpapi', 'llm-usage-token-cache.dpapi.123.tmp', 'llm-usage-discovery-cache.json', 'llm-usage-discovery-cache.json.45.tmp')
    $ownDirs = @('tmp', 'node', 'node.previous-20261027120000-abcdef12', ('node-download-' + ('a' * 32)))
    $okNames = (@($own | Where-Object { -not (Test-OwnedDataName $_ $false $false) }).Count -eq 0) -and (@($ownDirs | Where-Object { -not (Test-OwnedDataName $_ $true $false) }).Count -eq 0)
    $okOthers = (@($keep | Where-Object { (Test-OwnedDataName $_ $false $false) -or (Test-OwnedDataName $_ $true $false) }).Count -eq 0) -and -not (Test-OwnedDataName 'settings.ini' $false $true)
    Check 'data: the owned names are exactly the app''s own' ($okNames -and $okOthers)
    $values = Get-AppsEntryValues $root '9.9.9' 1234
    Check 'apps entry: per-user uninstall command and no repair or modify' ($values.UninstallString -like '*powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "*' -and $values.NoModify -eq 1 -and $values.NoRepair -eq 1 -and $values.EstimatedSize -eq 1234)
    $inside = @($procs | Where-Object { Test-ProcessInsideRoot $_ $root } | ForEach-Object { $_.ProcessId } | Sort-Object)
    Check 'processes: the second check passes only processes inside the install folder' (($inside -join ',') -eq '90,100,200,201,202,302') ($inside -join ',')

    # WMI denied (as in Windows Sandbox): the snapshot falls back to Get-Process, executable paths only.
    # Read-only: nothing is stopped here.
    function Get-CimInstance { throw (New-Object System.UnauthorizedAccessException 'Access is denied.') }
    $fallback = @(Get-ProcessSnapshot)
    Remove-Item -LiteralPath function:Get-CimInstance
    $me = @($fallback | Where-Object { $_.ProcessId -eq $PID })
    $withCmd = @($fallback | Where-Object { $_.CommandLine -or $_.ParentProcessId })
    Check 'processes: with WMI denied the snapshot falls back to executable paths only' ($fallback.Count -gt 5 -and $me.Count -eq 1 -and $me[0].ExecutablePath -like '*\powershell.exe' -and $withCmd.Count -eq 0) ("count=$($fallback.Count) self=$($me.Count) withCmd=$($withCmd.Count)")

    # Both guards against a real (harmless) process this probe starts itself: the fake process list
    # gives it an executable path, so no other program is ever a candidate.
    $dummy = Start-Process -FilePath "$env:SystemRoot\System32\PING.EXE" -ArgumentList '-n 60 127.0.0.1' -WindowStyle Minimized -PassThru
    try {
        $script:FakeSnapshot = @([pscustomobject]@{ ProcessId = $dummy.Id; ParentProcessId = 1; ExecutablePath = "$root\runtime\AutoHotkeyU64.exe"; CommandLine = '' })
        function Get-ProcessSnapshot { return $script:FakeSnapshot }
        $script:TestMode = $true
        $survivors = @(Stop-OwnedProcesses $root)
        Check 'processes: test mode never stops a process, even a matching one' ($survivors.Count -eq 1 -and -not $dummy.HasExited)
        # A filter that matches by name (the planted calibration bug) and a process outside the
        # folder: with test mode off, the second check alone must still refuse it.
        $script:TestMode = $false
        $script:FakeSnapshot = @([pscustomobject]@{ ProcessId = $dummy.Id; ParentProcessId = 1; ExecutablePath = 'C:\Program Files\AutoHotkey\AutoHotkeyU64.exe'; CommandLine = '' })
        function Select-OwnedProcesses($Processes, [string]$Root, [int]$SelfPid) { return @($Processes | Where-Object { $_.ExecutablePath -match 'AutoHotkey' }) }
        $survivors = @(Stop-OwnedProcesses $root)
        Start-Sleep -Milliseconds 300
        Check 'processes: a by-name filter still cannot stop a program outside the folder' ($survivors.Count -eq 0 -and -not $dummy.HasExited)
    } finally {
        if (-not $dummy.HasExited) { $dummy.Kill() }
    }
'@)
$r = Invoke-Captured $PowerShell ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $unitProbe + '" -Setup "' + $setup + '"')
$unitLines = @($r.Out -split "`r?`n" | Where-Object { $_ })
foreach ($line in $unitLines) {
    Write-Output $line
    if ($line.StartsWith('FAIL')) { $script:failures++ }
}
Check 'unit: the probe ran all of its checks' (@($unitLines | Where-Object { $_ -match '^(ok  |FAIL) ' }).Count -eq 7) $r.Out

# Dot-sourcing the bridge and the resolver must not reset setup's own parameters.
$probe = Join-Path $Scratch 'import-probe.ps1'
Write-Text $probe (". '$setup' -LoadOnly -DataDir 'C:\keep\me'`r`n`$null = Import-SetupHelpers`r`n'{0}|{1}|{2}|{3}' -f `$DataFolder, (Test-Path function:Get-VerifiedNodeZip), (Test-Path function:Save-PortableAhkV1Zip), `$script:AhkV1Version`r`n")
$r = Invoke-Captured $PowerShell ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $probe + '"')
Check 'import: the helpers load without resetting setup''s parameters' ($r.Out.Trim() -eq "C:\keep\me|True|True|$ahkVersion") $r.Out

# --- 11. Uninstall ------------------------------------------------------------------------------
function New-DataFixture([string]$Data) {
    foreach ($name in @('settings.ini', 'snapshot.log', 'tmp\llm-usage-out-1.txt', 'llm-usage-token-cache.dpapi', 'llm-usage-token-cache.dpapi.123.tmp',
            'llm-usage-discovery-cache.json', 'llm-usage-discovery-cache.json.45.tmp', 'node\node.exe', 'node.previous-20261027120000-abcdef12\x.txt',
            ('node-download-' + ('b' * 32) + '\y.txt'), 'unknown.txt', 'playwright-profile\x.txt')) {
        Write-Text (Join-Path $Data $name) 'x'
    }
}
New-DataFixture $L3.Data
$installedSetup = Join-Path $L3.Root 'setup\Setup-LLMUsageMonitor.ps1'
$r = Invoke-Setup $installedSetup (@('-Action', 'Uninstall', '-FromAppsEntry', '-NonInteractive') + (Get-LocArgs $L3))
Check 'uninstall: run from the installed copy, it removes the whole install folder, itself included' ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $L3.Root) -and $r.Out.Contains('is uninstalled')) $r.Out
Check 'uninstall: both shortcuts and the Apps entry are gone' (-not (Test-Path -LiteralPath (Join-Path $L3.StartMenu 'LLM Usage Monitor.lnk')) -and -not (Test-Path -LiteralPath $startupLink) -and -not (Test-Path -LiteralPath $L3.Reg))
$left = @(Get-ChildItem -LiteralPath $L3.Data -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
Check 'uninstall: only files the app did not create stay in the data folder' (($left -join '|') -eq 'playwright-profile|unknown.txt') ($left -join ', ')
Check 'uninstall: what stayed is listed by full path' ($r.Out.Contains((Join-Path $L3.Data 'playwright-profile')) -and $r.Out.Contains((Join-Path $L3.Data 'unknown.txt'))) $r.Out

New-DataFixture $L1.Data
$r = Invoke-Setup $setup (@('-Action', 'Uninstall', '-NonInteractive', '-KeepSettings') + (Get-LocArgs $L1))
Check 'uninstall: -KeepSettings keeps settings.ini only' ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $L1.Data 'settings.ini')) -and -not (Test-Path -LiteralPath (Join-Path $L1.Data 'snapshot.log')) -and -not (Test-Path -LiteralPath $L1.Root)) $r.Out
New-DataFixture $L2.Data
$before = Get-TreeHash $L2.Data
$r = Invoke-Setup $setup (@('-Action', 'Uninstall', '-NonInteractive', '-KeepData') + (Get-LocArgs $L2))
Check 'uninstall: -KeepData leaves the data folder as it was' ($r.Code -eq 0 -and (Get-TreeHash $L2.Data) -eq $before -and -not (Test-Path -LiteralPath $L2.Root)) $r.Out
Write-Text (Join-Path $L5.Data 'settings.ini') 'x'
Write-Text (Join-Path $L5.Data 'tmp\llm-usage-status-1.txt') 'x'
$r = Invoke-Setup $setup (@('-Action', 'Uninstall', '-NonInteractive') + (Get-LocArgs $L5))
Check 'uninstall: a data folder holding only the app''s files is removed' ($r.Code -eq 0 -and -not (Test-Path -LiteralPath $L5.Data)) $r.Out
Check 'uninstall: the foreign Startup shortcut is still there' ((Test-Path -LiteralPath $foreign) -and (Get-Shortcut $foreign).Target -like '*notepad.exe')

$L6 = New-Locations 'life6'
$r = Invoke-Setup $setup (@('-Action', 'Install', '-NonInteractive') + (Get-LocArgs $L6))
$r = Invoke-Setup $setup (@('-Action', 'Uninstall') + (Get-LocArgs $L6)) "n`n"
Check 'uninstall: answering No changes nothing' ($r.Code -eq 0 -and (Test-Path -LiteralPath (Join-Path $L6.Root 'install-state.json'))) $r.Out
$statePath = Join-Path $L6.Root 'install-state.json'
[IO.File]::WriteAllText($statePath, ([IO.File]::ReadAllText($statePath) -replace '"LLMUsageMonitor"', '"SomethingElse"'))
$before = Get-TreeHash $L6.Root
$r = Invoke-Setup $setup (@('-Action', 'Uninstall', '-NonInteractive') + (Get-LocArgs $L6))
Check 'uninstall: a state file naming another product means hands off' ($r.Code -eq 1 -and (Get-TreeHash $L6.Root) -eq $before) $r.Out

# --- 12. The resolver's own default path is unchanged -------------------------------------------
$lad = Join-Path $Scratch 'localappdata'
New-Item -ItemType Directory -Force -Path $lad | Out-Null
$resolverProbe = Join-Path $Scratch 'resolver-probe.ps1'
Write-Text $resolverProbe (@"
`$env:LOCALAPPDATA = '$lad'
. '$(Join-Path $InstallerDir 'Resolve-AHK-Runtime.ps1')'
`$script:AhkV1ZipSha256 = '$($ahkSha.ToUpperInvariant())'
`$script:AhkV1ZipUrls = @('https://ahk-primary.invalid/$ahkZipName')
function Invoke-AhkDownload { param([string]`$Uri, [string]`$OutFile) Copy-Item -LiteralPath '$ahkPrimary' -Destination `$OutFile }
`$null = Install-PortableAhkV1
"@)
$r = Invoke-Captured $PowerShell ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $resolverProbe + '"')
$portable = Join-Path $lad 'Programs\AutoHotkey-v1'
Check 'resolver: Install-PortableAhkV1 still unpacks the whole zip into Programs\AutoHotkey-v1' ((Test-Path -LiteralPath (Join-Path $portable 'AutoHotkeyU64.exe')) -and (Test-Path -LiteralPath (Join-Path $portable 'Compiler\Ahk2Exe.exe'))) $r.Out

# --- Guard --------------------------------------------------------------------------------------
$realAfter = Get-RealProfileState
Check 'guard: the real Start Menu, Startup, Apps key, Programs and data folders are untouched' ($realAfter -eq $realBefore) "before: $realBefore`nafter:  $realAfter"
Check 'guard: nothing is left in TEMP by any setup run' ((Get-TempLeftovers).Count -eq 0) ((Get-TempLeftovers | ForEach-Object Name) -join ', ')

exit $script:failures

# The self-contained setup BAT's extractor (the builder appends it after the BAT's stub). It reads
# the Base64 ZIP after the payload marker at the end of the BAT, checks its SHA-256 against the
# value the stub passes in before writing or unpacking anything, unpacks it into a new folder in
# %TEMP%, runs setup\Setup-LLMUsageMonitor.ps1 from it with the BAT's own arguments, and deletes the
# folder afterwards. LLMUSAGE_BUNDLE_NOLAUNCH=1 stops after the unpack (used by the tests).
# Deliberately not an advanced script: arguments it does not name land in $args and go to setup.
# Exit codes: setup's own, or 9 when the BAT is damaged. ASCII only.
param(
    [string]$BundleSelfPath = '',
    [string]$BundleSha256 = ''
)
$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Simple LLM Usage Monitor Setup' } catch {}

$exitCode = 9
$launch = $false
$setupScript = ''
$workRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('LLMUsageMonitor-Setup-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Host 'Simple LLM Usage Monitor setup' -ForegroundColor Cyan
    Write-Host 'Checking the release this installer carries...' -ForegroundColor DarkGray
    if ($BundleSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'The installer has no valid checksum line.' }
    if (-not $BundleSelfPath -or -not (Test-Path -LiteralPath $BundleSelfPath -PathType Leaf)) { throw 'The installer could not find its own file.' }

    $text = [IO.File]::ReadAllText($BundleSelfPath)
    # Built in two parts so this file's own text never matches the marker.
    $marker = '#===' + 'PAYLOAD==='
    $at = $text.LastIndexOf($marker)
    if ($at -lt 0) { throw 'The release data is missing.' }
    try {
        $bytes = [Convert]::FromBase64String($text.Substring($at + $marker.Length).Trim())
    } catch {
        throw 'The release data is not readable.'
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    if ($actual -ne $BundleSha256.ToLowerInvariant()) { throw "The release data failed its SHA-256 check (expected $($BundleSha256.ToLowerInvariant()), got $actual)." }
    Write-Host "[OK] Release verified: SHA-256 $actual" -ForegroundColor Green

    New-Item -ItemType Directory -Path $workRoot | Out-Null
    $zipPath = Join-Path -Path $workRoot -ChildPath 'release.zip'
    [IO.File]::WriteAllBytes($zipPath, $bytes)
    $expandRoot = Join-Path -Path $workRoot -ChildPath 'x'
    New-Item -ItemType Directory -Path $expandRoot | Out-Null
    $expandFull = [IO.Path]::GetFullPath($expandRoot).TrimEnd('\') + '\'
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path -Path $expandRoot -ChildPath ($entry.FullName -replace '/', '\')))
            if (-not $target.StartsWith($expandFull, [StringComparison]::OrdinalIgnoreCase)) { throw "The release holds an unsafe path: $($entry.FullName)" }
            if ($entry.FullName.EndsWith('/')) { continue }
            New-Item -ItemType Directory -Force -Path (Split-Path -Path $target -Parent) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    } finally {
        $zip.Dispose()
    }
    $tops = @(Get-ChildItem -LiteralPath $expandRoot -Directory)
    if ($tops.Count -ne 1) { throw 'The release does not have the expected layout.' }
    $setupScript = Join-Path -Path $tops[0].FullName -ChildPath 'setup\Setup-LLMUsageMonitor.ps1'
    if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) { throw 'The release has no setup script.' }

    if ($env:LLMUSAGE_BUNDLE_NOLAUNCH -eq '1') {
        Write-Host '[OK] Unpacked and checked; not running setup (LLMUSAGE_BUNDLE_NOLAUNCH=1).' -ForegroundColor Green
        $exitCode = 0
    } else {
        $launch = $true
    }
} catch {
    Write-Host ''
    Write-Host ('Setup stopped safely: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Download the installer again from the release page.' -ForegroundColor Red
    $exitCode = 9
}

if ($launch) {
    $powershell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $packageDir = Split-Path -Path $BundleSelfPath -Parent
    & $powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setupScript -LocalPackageDir $packageDir @args
    $exitCode = $LASTEXITCODE
}

if (Test-Path -LiteralPath $workRoot) {
    try { [IO.Directory]::Delete($workRoot, $true) }
    catch { Write-Host "Could not remove the temporary folder $workRoot ($($_.Exception.Message))." -ForegroundColor Yellow }
}
exit $exitCode

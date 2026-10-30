# Offline test of the Node.js zip fallback in Get-LLMUsageSnapshot.ps1. ASCII only.
# Dot-sources the bridge (which then skips its mode dispatch), replaces Invoke-NodeDownload with
# a copy from a fake dist folder, and checks the install rules. It never touches the network,
# winget, PATH or the real data folder. Prints one line per check; exit code = failed checks.
# Run by node-install.test.mjs; -Bridge lets a calibration run point it at a broken copy.
param(
    [Parameter(Mandatory = $true)][string]$Scratch,
    [string]$Bridge = ''
)
$ErrorActionPreference = 'Stop'
# Resolved here, not as the parameter default: PowerShell 5.1 leaves $PSScriptRoot empty there.
if (-not $Bridge) { $Bridge = Join-Path -Path $PSScriptRoot -ChildPath 'Get-LLMUsageSnapshot.ps1' }
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$processPathBefore = $env:PATH
. $Bridge
$ErrorActionPreference = 'Stop'

$script:failures = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Output "ok   $Name" } else { $script:failures++; Write-Output "FAIL $Name" }
}

$dist = Join-Path -Path $Scratch -ChildPath 'dist'
$fakeBase = 'https://fake.invalid/dist'
$script:downloads = New-Object System.Collections.Generic.List[string]
function Invoke-NodeDownload {
    param([string]$Uri, [string]$OutFile)
    $script:downloads.Add($Uri)
    if (-not $Uri.StartsWith("$fakeBase/")) { throw "unexpected URL $Uri" }
    $local = Join-Path -Path $dist -ChildPath ($Uri.Substring($fakeBase.Length + 1) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { throw "404 $Uri" }
    Copy-Item -LiteralPath $local -Destination $OutFile
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
function Set-FakeIndex([string]$LtsVersion) {
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    $json = '[{"version":"v99.0.1","lts":false},{"version":"' + $LtsVersion + '","lts":"Fixture"}]'
    Set-Content -LiteralPath (Join-Path $dist 'index.json') -Value $json -Encoding ASCII
}
# A release folder with a zip holding node-<ver>-win-x64\node.exe and a SHASUMS256.txt for it.
function New-FakeRelease([string]$Version, [string]$NodeText) {
    $relDir = Join-Path -Path $dist -ChildPath $Version
    New-Item -ItemType Directory -Force -Path $relDir | Out-Null
    $stage = Join-Path -Path $Scratch -ChildPath ('stage-' + [Guid]::NewGuid().ToString('N'))
    $inner = Join-Path -Path $stage -ChildPath "node-$Version-win-x64"
    New-Item -ItemType Directory -Force -Path $inner | Out-Null
    Set-Content -LiteralPath (Join-Path $inner 'node.exe') -Value $NodeText -Encoding ASCII
    $zip = Join-Path -Path $relDir -ChildPath "node-$Version-win-x64.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    # Parenthesised: in PowerShell the comma binds tighter than +.
    $sums = @((('0' * 64) + "  node-$Version-x64.msi"), "$hash  node-$Version-win-x64.zip")
    Set-Content -LiteralPath (Join-Path $relDir 'SHASUMS256.txt') -Value $sums -Encoding ASCII
}
function New-DataDir([string]$Name) {
    $dir = Join-Path -Path $Scratch -ChildPath $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}
function Get-Leftovers([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Filter 'node-download-*' -Force -ErrorAction SilentlyContinue).Count
}

# 1. A good release installs into <data>\node and cleans its download folder.
Set-FakeIndex 'v98.1.2'
New-FakeRelease 'v98.1.2' 'fake node v98.1.2'
$data1 = New-DataDir 'data1'
$home1 = Join-Path $data1 'node'
$result = Install-NodeFromZip -NodeHome $home1 -DistBaseUrl $fakeBase
Check 'good zip: returns <data>\node\node.exe' ($result -eq (Join-Path $home1 'node.exe'))
Check 'good zip: node.exe content is the release file' ((Test-Path -LiteralPath $result) -and ((Get-Content -LiteralPath $result -Raw).Trim() -eq 'fake node v98.1.2'))
Check 'good zip: download folder removed' ((Get-Leftovers $data1) -eq 0)
Check 'good zip: fetched index, SHASUMS256 and zip in that order' (($script:downloads -join '|') -eq "$fakeBase/index.json|$fakeBase/v98.1.2/SHASUMS256.txt|$fakeBase/v98.1.2/node-v98.1.2-win-x64.zip")
Check 'lookup prefers the app copy in <data>\node' ((Resolve-NodeExe -NodeHome $home1) -eq (Join-Path $home1 'node.exe'))

# 2. An existing folder there is renamed aside with its contents, never deleted.
$data2 = New-DataDir 'data2'
$home2 = Join-Path $data2 'node'
New-Item -ItemType Directory -Force -Path $home2 | Out-Null
Set-Content -LiteralPath (Join-Path $home2 'keep-me.txt') -Value 'user file' -Encoding ASCII
$result = Install-NodeFromZip -NodeHome $home2 -DistBaseUrl $fakeBase
$aside = @(Get-ChildItem -LiteralPath $data2 -Directory -Filter 'node.previous-*')
Check 'existing folder: new node.exe installed' ($result -eq (Join-Path $home2 'node.exe'))
Check 'existing folder: moved aside with its file intact' (($aside.Count -eq 1) -and (Test-Path -LiteralPath (Join-Path $aside[0].FullName 'keep-me.txt')))

# 3. A zip whose SHA-256 does not match SHASUMS256.txt installs nothing.
New-FakeRelease 'v98.1.2' 'fake node v98.1.2'
$sumsPath = Join-Path $dist 'v98.1.2\SHASUMS256.txt'
(Get-Content -LiteralPath $sumsPath) -replace '^[0-9a-f]{64}(\s+node-v98\.1\.2-win-x64\.zip)$', (('f' * 64) + '$1') | Set-Content -LiteralPath $sumsPath -Encoding ASCII
$data3 = New-DataDir 'data3'
$result = Install-NodeFromZip -NodeHome (Join-Path $data3 'node') -DistBaseUrl $fakeBase
Check 'hash mismatch: returns nothing' ($result -eq '')
Check 'hash mismatch: no node folder created' (-not (Test-Path -LiteralPath (Join-Path $data3 'node')))
Check 'hash mismatch: download folder removed' ((Get-Leftovers $data3) -eq 0)

# 4. A zip with no SHASUMS256 line for it installs nothing.
Set-Content -LiteralPath $sumsPath -Value (('0' * 64) + '  node-v98.1.2-x64.msi') -Encoding ASCII
$data4 = New-DataDir 'data4'
$result = Install-NodeFromZip -NodeHome (Join-Path $data4 'node') -DistBaseUrl $fakeBase
Check 'no checksum line: installs nothing' (($result -eq '') -and -not (Test-Path -LiteralPath (Join-Path $data4 'node')))

# 5. A version string that is not plain vX.Y.Z is refused before any further download.
Set-FakeIndex 'v1.0.0/../../escape'
$script:downloads.Clear()
$data5 = New-DataDir 'data5'
$result = Install-NodeFromZip -NodeHome (Join-Path $data5 'node') -DistBaseUrl $fakeBase
Check 'odd version string: refused after index.json only' (($result -eq '') -and ($script:downloads.Count -eq 1))

# 6. A failed download (404) installs nothing and leaves nothing behind.
Set-FakeIndex 'v97.0.0'
$data6 = New-DataDir 'data6'
$result = Install-NodeFromZip -NodeHome (Join-Path $data6 'node') -DistBaseUrl $fakeBase
Check 'failed download: installs nothing, cleans up' (($result -eq '') -and ((Get-Leftovers $data6) -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $data6 'node')))

# 7a. Pinned mode (the installer's): one named release, never index.json, and the published sum and
# the zip must both equal the pin.
function Test-Throws([scriptblock]$Body) { try { & $Body | Out-Null; return $false } catch { return $true } }
New-FakeRelease 'v96.2.0' 'fake node v96.2.0'
$pinZip = Join-Path $dist 'v96.2.0\node-v96.2.0-win-x64.zip'
$pin = (Get-FileHash -LiteralPath $pinZip -Algorithm SHA256).Hash.ToLowerInvariant()
$script:downloads.Clear()
$got = Get-VerifiedNodeZip -WorkDir (New-DataDir 'pin1') -DistBaseUrl $fakeBase -Version 'v96.2.0' -ExpectedSha256 $pin
Check 'pinned: returns the verified zip' (($got.Version -eq 'v96.2.0') -and ($got.Sha256 -eq $pin) -and (Test-Path -LiteralPath $got.ZipPath))
Check 'pinned: SHASUMS256 then zip, never index.json' (($script:downloads -join '|') -eq "$fakeBase/v96.2.0/SHASUMS256.txt|$fakeBase/v96.2.0/node-v96.2.0-win-x64.zip")
$script:downloads.Clear()
Check 'pinned: a published sum that differs from the pin is refused before the zip download' ((Test-Throws { Get-VerifiedNodeZip -WorkDir (New-DataDir 'pin2') -DistBaseUrl $fakeBase -Version 'v96.2.0' -ExpectedSha256 ('a' * 64) }) -and ($script:downloads.Count -eq 1))
# The server's zip changes while its SHASUMS line and the pin still agree on the old one.
[IO.File]::AppendAllText($pinZip, 'x')
Check 'pinned: a zip that does not match is refused' (Test-Throws { Get-VerifiedNodeZip -WorkDir (New-DataDir 'pin3') -DistBaseUrl $fakeBase -Version 'v96.2.0' -ExpectedSha256 $pin })
$script:downloads.Clear()
Check 'pinned: an odd version is refused before any download' ((Test-Throws { Get-VerifiedNodeZip -WorkDir (New-DataDir 'pin4') -DistBaseUrl $fakeBase -Version 'v1.0.0/../x' }) -and ($script:downloads.Count -eq 0))
Check 'pinned: a malformed pin is refused before any download' ((Test-Throws { Get-VerifiedNodeZip -WorkDir (New-DataDir 'pin5') -DistBaseUrl $fakeBase -Version 'v96.2.0' -ExpectedSha256 'abc' }) -and ($script:downloads.Count -eq 0))

# 7b. The installer's runtime\node.exe beside the scripts wins over the data-folder copy.
$bundleRuntime = New-DataDir 'bundle\runtime'
$bundledExe = Join-Path $bundleRuntime 'node.exe'
Set-Content -LiteralPath $bundledExe -Value 'bundled node' -Encoding ASCII
Check 'lookup prefers the bundled runtime\node.exe' ((Resolve-NodeExe -NodeHome $home1 -BundledExe $bundledExe) -eq $bundledExe)
Check 'bundled lookup points at runtime\node.exe beside the bridge' ($BundledNodeExe -eq (Join-Path -Path (Split-Path -Path (Resolve-Path -LiteralPath $Bridge).ProviderPath -Parent) -ChildPath 'runtime\node.exe'))

# 7. Nothing edits PATH, and the bridge has no code that could.
Check 'user PATH unchanged' ([Environment]::GetEnvironmentVariable('Path', 'User') -eq $userPathBefore)
Check 'process PATH unchanged' ($env:PATH -eq $processPathBefore)
$bridgeText = Get-Content -LiteralPath $Bridge -Raw
Check 'bridge never calls SetEnvironmentVariable' ($bridgeText -notmatch 'SetEnvironmentVariable')
Check 'bridge never removes a Programs\nodejs folder' ($bridgeText -notmatch 'Remove-Item[^\r\n]*Programs')

exit $script:failures

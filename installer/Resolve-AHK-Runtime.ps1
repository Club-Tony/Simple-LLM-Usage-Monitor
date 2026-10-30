[CmdletBinding()]
param(
    [ValidateSet("v1", "v2")]
    [string]$Version = "v1",
    [switch]$Ensure,
    [switch]$Json,
    [switch]$ExcludeSystemCandidates,
    [switch]$NoDownload
)

$ErrorActionPreference = "Stop"

$script:AhkV1Version = "1.1.37.02"
# Both sources serve the byte-identical zip (verified 2026-06-12); the single
# pinned SHA256 below gates whichever one responds first.
$script:AhkV1ZipUrls = @(
    "https://www.autohotkey.com/download/1.1/AutoHotkey_$($script:AhkV1Version).zip",
    "https://github.com/AutoHotkey/AutoHotkey/releases/download/v$($script:AhkV1Version)/AutoHotkey_$($script:AhkV1Version).zip"
)
$script:AhkV1ZipSha256 = "6F3663F7CDD25063C8C8728F5D9B07813CED8780522FD1F124BA539E2854215F"

function Get-PortableAhkV1Root {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw "LOCALAPPDATA is not set; cannot use a per-user AutoHotkey v1 runtime."
    }
    return (Join-Path $env:LOCALAPPDATA "Programs\AutoHotkey-v1")
}

function Get-PortableAhkV1Candidates {
    $root = Get-PortableAhkV1Root
    return @(
        (Join-Path $root "AutoHotkeyU64.exe"),
        (Join-Path $root "AutoHotkey64.exe"),
        (Join-Path $root "AutoHotkey.exe"),
        (Join-Path $root "AutoHotkeyU32.exe"),
        (Join-Path $root "AutoHotkey32.exe")
    )
}

function Invoke-AhkVersionProbe {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimePath,
        [Parameter(Mandatory = $true)][ValidateSet("v1", "v2")][string]$ProbeSyntax
    )

    if (-not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)) {
        return $null
    }

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ahk-version-probe-{0}.ahk" -f ([guid]::NewGuid().ToString("N")))
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    if ($ProbeSyntax -eq "v1") {
        $probe = "#NoEnv`r`nFileAppend, %A_AhkVersion%, *`r`nExitApp`r`n"
    } else {
        $probe = "#Requires AutoHotkey v2.0`r`nFileAppend A_AhkVersion, `"*`"`r`nExitApp`r`n"
    }

    try {
        [System.IO.File]::WriteAllText($tempPath, $probe, $utf8NoBom)
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $RuntimePath
        $psi.Arguments = ('/ErrorStdOut=UTF-8 "{0}"' -f $tempPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(5000)) {
            try { $proc.Kill() } catch {}
            return $null
        }

        $stdout = $proc.StandardOutput.ReadToEnd().Trim()
        if ($proc.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($stdout)) {
            return $null
        }
        return $stdout
    } catch {
        return $null
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-AhkRuntimeVersion {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimePath,
        [Parameter(Mandatory = $true)][ValidateSet("v1", "v2")][string]$Version
    )

    $reportedVersion = $null
    try {
        $versionInfo = (Get-Item -LiteralPath $RuntimePath -ErrorAction Stop).VersionInfo
        foreach ($value in @($versionInfo.ProductVersion, $versionInfo.FileVersion)) {
            if ($value -match '^\d+\.') {
                $reportedVersion = $value.Trim()
                break
            }
        }
    } catch {}

    if ([string]::IsNullOrWhiteSpace($reportedVersion)) {
        $reportedVersion = Invoke-AhkVersionProbe -RuntimePath $RuntimePath -ProbeSyntax $Version
    }
    if ([string]::IsNullOrWhiteSpace($reportedVersion)) {
        return $false
    }
    if ($Version -eq "v1") {
        return ($reportedVersion -match "^1\.")
    }
    return ($reportedVersion -match "^2\.")
}

function Get-AhkRuntimeCandidates {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("v1", "v2")][string]$Version,
        [switch]$ExcludeSystemCandidates
    )

    $candidates = @()
    $localAppData = $env:LOCALAPPDATA
    $programFiles = ${env:ProgramFiles}

    if ($Version -eq "v1") {
        # Repo-local user-supplied portable runtime (runtime\) wins over everything,
        # so locked-down machines (MSI blocked, download blocked) stay zero-gap.
        $repoRuntimeDir = Join-Path $PSScriptRoot "runtime"
        $candidates += Join-Path $repoRuntimeDir "AutoHotkeyU64.exe"
        $candidates += Join-Path $repoRuntimeDir "AutoHotkey64.exe"
        $candidates += Join-Path $repoRuntimeDir "AutoHotkey.exe"
        $candidates += Join-Path $repoRuntimeDir "AutoHotkeyU32.exe"
        $candidates += Join-Path $repoRuntimeDir "AutoHotkey32.exe"
        $candidates += Get-PortableAhkV1Candidates
    }

    if (-not $ExcludeSystemCandidates) {
        if ($Version -eq "v2") {
            if ($localAppData) {
                $candidates += Join-Path $localAppData "Microsoft\WindowsApps\AutoHotkeyV2.exe"
                # Per-user (no-admin) install location offered by the official v2 installer
                $candidates += Join-Path $localAppData "Programs\AutoHotkey\v2\AutoHotkey64.exe"
                $candidates += Join-Path $localAppData "Programs\AutoHotkey\v2\AutoHotkey32.exe"
                $candidates += Join-Path $localAppData "Programs\AutoHotkey\v2\AutoHotkey.exe"
            }
            if ($programFiles) {
                $candidates += Join-Path $programFiles "AutoHotkey\v2\AutoHotkey64.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\v2\AutoHotkey32.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\v2\AutoHotkey.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\AutoHotkeyV2.exe"
            }
            $cmd = Get-Command AutoHotkeyV2.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd -and $cmd.Source) {
                $candidates += $cmd.Source
            }
        } else {
            if ($programFiles) {
                $candidates += Join-Path $programFiles "AutoHotkey\v1\AutoHotkey64.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\v1\AutoHotkey32.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\v1\AutoHotkey.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\v1\AutoHotkeyU64.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\v1\AutoHotkeyU32.exe"

                $ahkRoot = Join-Path $programFiles "AutoHotkey"
                $v1Dirs = Get-ChildItem -LiteralPath $ahkRoot -Directory -Filter "v1*" -ErrorAction SilentlyContinue
                foreach ($v1Dir in $v1Dirs) {
                    $candidates += Join-Path $v1Dir.FullName "AutoHotkeyU64.exe"
                    $candidates += Join-Path $v1Dir.FullName "AutoHotkeyU32.exe"
                    $candidates += Join-Path $v1Dir.FullName "AutoHotkey64.exe"
                    $candidates += Join-Path $v1Dir.FullName "AutoHotkey32.exe"
                    $candidates += Join-Path $v1Dir.FullName "AutoHotkey.exe"
                }

                $candidates += Join-Path $programFiles "AutoHotkey\AutoHotkeyU64.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\AutoHotkeyU32.exe"
                $candidates += Join-Path $programFiles "AutoHotkey\AutoHotkey.exe"
            }
            if ($localAppData) {
                $candidates += Join-Path $localAppData "Microsoft\WindowsApps\AutoHotkey.exe"
            }
            $cmd = Get-Command AutoHotkey.exe -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cmd -and $cmd.Source) {
                $candidates += $cmd.Source
            }
        }
    }

    return @(
        $candidates |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            ForEach-Object {
                try { [System.IO.Path]::GetFullPath($_) } catch { $_ }
            } |
            Select-Object -Unique
    )
}

# The AutoHotkey zip's only network call. The usage monitor's installer (which also dot-sources
# this file) and its offline tests replace it.
function Invoke-AhkDownload {
    param([string]$Uri, [string]$OutFile)
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
}

# Downloads the pinned AutoHotkey v1 zip to ZipPath, trying each source in turn, and keeps it only
# when its SHA-256 matches the pin. Throws, listing every source's error, when none gives a good zip.
function Save-PortableAhkV1Zip {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [string[]]$Urls = $script:AhkV1ZipUrls,
        [string]$ExpectedSha256 = $script:AhkV1ZipSha256
    )

    # Older Windows PowerShell hosts can default to TLS 1.0/1.1, which both
    # download sources reject. Opt into TLS 1.2 without removing newer protocols.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    Write-Host "Downloading AutoHotkey v$script:AhkV1Version portable runtime..." -ForegroundColor Cyan
    $downloadErrors = @()
    foreach ($url in $Urls) {
        Write-Host "  Source: $url"
        try {
            Invoke-AhkDownload -Uri $url -OutFile $ZipPath
        } catch {
            $downloadErrors += "{0} -> {1}" -f $url, $_.Exception.Message
            Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
            continue
        }

        $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($hash -ne $ExpectedSha256.ToUpperInvariant()) {
            $downloadErrors += "{0} -> SHA256 mismatch (expected {1}, got {2})" -f $url, $ExpectedSha256, $hash
            Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
            continue
        }

        return
    }
    throw ("AutoHotkey v1 download failed from all sources:`n  " + ($downloadErrors -join "`n  "))
}

function Install-PortableAhkV1 {
    param([switch]$NoDownload)

    if ($NoDownload) {
        return $null
    }

    $destRoot = Get-PortableAhkV1Root
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ahk-v1-download-{0}" -f ([guid]::NewGuid().ToString("N")))
    $zipPath = Join-Path $tempDir ("AutoHotkey_{0}.zip" -f $script:AhkV1Version)

    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    try {
        Save-PortableAhkV1Zip -ZipPath $zipPath

        New-Item -Path $destRoot -ItemType Directory -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $destRoot -Force
        Unblock-File -Path (Join-Path $destRoot "*") -ErrorAction SilentlyContinue
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return Resolve-AhkRuntimePath -Version "v1" -ExcludeSystemCandidates
}

function Resolve-AhkRuntimePath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("v1", "v2")][string]$Version,
        [switch]$Ensure,
        [switch]$ExcludeSystemCandidates,
        [switch]$NoDownload
    )

    foreach ($candidate in Get-AhkRuntimeCandidates -Version $Version -ExcludeSystemCandidates:$ExcludeSystemCandidates) {
        if (Test-AhkRuntimeVersion -RuntimePath $candidate -Version $Version) {
            return $candidate
        }
    }

    if ($Version -eq "v1" -and $Ensure) {
        return Install-PortableAhkV1 -NoDownload:$NoDownload
    }

    return $null
}

if ($MyInvocation.InvocationName -ne ".") {
    $resolved = Resolve-AhkRuntimePath -Version $Version -Ensure:$Ensure -ExcludeSystemCandidates:$ExcludeSystemCandidates -NoDownload:$NoDownload
    if ($Json) {
        [pscustomobject]@{
            requested_version = $Version
            found             = [bool]$resolved
            path              = if ($resolved) { $resolved } else { "" }
            portable_root     = if ($Version -eq "v1") { Get-PortableAhkV1Root } else { "" }
        } | ConvertTo-Json -Depth 3
    } elseif ($resolved) {
        Write-Output $resolved
    }

    if ($resolved) {
        exit 0
    }
    if ($Version -eq "v1") {
        Write-Error ("AutoHotkey v1 runtime not found. Options: (1) extract AutoHotkeyU64.exe from https://www.autohotkey.com/download/ahk.zip into '{0}' (no admin/MSI needed); (2) run the standard installer from https://www.autohotkey.com/download/ahk-install.exe" -f (Join-Path $PSScriptRoot "runtime"))
    } else {
        Write-Error "AutoHotkey $Version runtime not found."
    }
    exit 1
}

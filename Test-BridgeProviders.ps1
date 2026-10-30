# Offline test of the -Providers handling in Get-LLMUsageSnapshot.ps1. ASCII only.
# Dot-sources the bridge (which then skips its mode dispatch) and checks ConvertTo-ProvidersArg,
# Get-ProvidersOff, ConvertTo-AddonModuleArg and the Off rows in the failure snapshot. Touches no
# network; creates and removes one empty .mjs file in a temp folder.
# Prints one line per check; exit code = failed checks. Run by bridge-providers.test.mjs.
param([string]$Bridge = '')
$ErrorActionPreference = 'Stop'
# Resolved here, not as the parameter default: PowerShell 5.1 leaves $PSScriptRoot empty there.
if (-not $Bridge) { $Bridge = Join-Path -Path $PSScriptRoot -ChildPath 'Get-LLMUsageSnapshot.ps1' }
. $Bridge
$ErrorActionPreference = 'Stop'

$script:failures = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Output "ok   $Name" } else { $script:failures++; Write-Output "FAIL $Name" }
}

$allOff = 'codex=off,claude=off,grok=off,addon=off'
Check 'empty value passes nothing' ((ConvertTo-ProvidersArg -Value '') -eq '')
Check 'whitespace value passes nothing' ((ConvertTo-ProvidersArg -Value '   ') -eq '')
Check 'valid value passes through' ((ConvertTo-ProvidersArg -Value 'codex=auto,claude=cli,grok=off,addon=off') -eq 'codex=auto,claude=cli,grok=off,addon=off')
Check 'upper case is lowered' ((ConvertTo-ProvidersArg -Value 'CODEX=Firefox') -eq 'codex=firefox')
Check 'spaces become commas' ((ConvertTo-ProvidersArg -Value 'codex=off claude=cli') -eq 'codex=off,claude=cli')
Check 'a semicolon turns every provider off' ((ConvertTo-ProvidersArg -Value 'codex=auto;calc') -eq $allOff)
Check 'a quote turns every provider off' ((ConvertTo-ProvidersArg -Value 'codex="auto"') -eq $allOff)
Check 'a dash turns every provider off' ((ConvertTo-ProvidersArg -Value 'codex=auto,--debug') -eq $allOff)
Check 'a dangling pair turns every provider off' ((ConvertTo-ProvidersArg -Value 'codex=') -eq $allOff)
Check 'over 200 characters turns every provider off' ((ConvertTo-ProvidersArg -Value ('codex=auto,' + ('x=y,' * 60) + 'a=b')) -eq $allOff)

$off = @(Get-ProvidersOff -ProvidersArg 'codex=off,claude=cli,grok=off,addon=off,bogus=off')
Check 'off providers are listed, unknown names ignored' (($off -join ',') -eq 'codex,grok,addon')
Check 'no value means none off' (@(Get-ProvidersOff -ProvidersArg '').Count -eq 0)

$plain = New-DefaultSnapshot -ProvidersArg ''
Check 'failure snapshot has only the codex, claude and grok rows' (@($plain.Keys | Where-Object { $_ -like '*_status' -and @('overall_status', 'codex_status', 'claude_status', 'grok_status') -notcontains $_ }).Count -eq 0)
Check 'failure snapshot without choices keeps errors' ($plain.codex_status -eq 'error' -and $plain.grok_line_1 -eq 'Weekly: unavailable')

$snap = New-DefaultSnapshot -ProvidersArg 'codex=off,claude=auto,grok=off'
Check 'codex off row' ($snap.codex_status -eq 'off' -and $snap.codex_line_1 -eq 'Daily: Off' -and $snap.codex_line_2 -eq 'Weekly: Off')
Check 'claude left as error' ($snap.claude_status -eq 'error' -and $snap.claude_line_1 -eq 'Daily: unavailable')
Check 'grok off row' ($snap.grok_status -eq 'off' -and $snap.grok_line_1 -eq 'Weekly: Off' -and $snap.grok_line_2 -eq '')

$noAddon = New-DefaultSnapshot -ProvidersArg 'addon=off' -AddonModuleArg ''
Check 'failure snapshot without an add-on module has no add-on keys' (-not $noAddon.Contains('addon_status'))

$tempDir = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('usage-bridge-addon-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $module = Join-Path -Path $tempDir -ChildPath 'addon.mjs'
    Set-Content -LiteralPath $module -Value '' -Encoding ASCII
    Check 'add-on: empty value passes nothing' ((ConvertTo-AddonModuleArg -Value '') -eq '')
    Check 'add-on: an existing absolute .mjs path passes' ((ConvertTo-AddonModuleArg -Value $module) -eq $module)
    Check 'add-on: a relative path is rejected' ((ConvertTo-AddonModuleArg -Value 'addon.mjs') -eq 'rejected')
    $bs = [string][char]92
    Check 'add-on: a UNC path is rejected' ((ConvertTo-AddonModuleArg -Value ($bs + $bs + 'server' + $bs + 'share' + $bs + 'addon.mjs')) -eq 'rejected')
    Check 'add-on: a non-.mjs file is rejected' ((ConvertTo-AddonModuleArg -Value ($module.Substring(0, $module.Length - 4) + '.js')) -eq 'rejected')
    Check 'add-on: a quote is rejected' ((ConvertTo-AddonModuleArg -Value ('C:' + $bs + 'a"b' + $bs + 'addon.mjs')) -eq 'rejected')
    # sub\..\addon.mjs names a file that exists, so only the '..' rule can reject it.
    New-Item -ItemType Directory -Path (Join-Path -Path $tempDir -ChildPath 'sub') -Force | Out-Null
    Check 'add-on: a .. segment is rejected' ((ConvertTo-AddonModuleArg -Value ($tempDir + $bs + 'sub' + $bs + '..' + $bs + 'addon.mjs')) -eq 'rejected')
    Check 'add-on: a missing file is rejected' ((ConvertTo-AddonModuleArg -Value (Join-Path -Path $tempDir -ChildPath 'missing.mjs')) -eq 'rejected')
    Check 'add-on: over 260 characters is rejected' ((ConvertTo-AddonModuleArg -Value ('C:' + $bs + ('a' * 260) + '.mjs')) -eq 'rejected')
    Check 'add-on: a forward-slash path is rejected' ((ConvertTo-AddonModuleArg -Value ($module -replace '[\\]', '/')) -eq 'rejected')

    $withAddon = New-DefaultSnapshot -ProvidersArg '' -AddonModuleArg $module
    Check 'failure snapshot with an add-on module has an add-on error row' ($withAddon.addon_status -eq 'error' -and $withAddon.addon_line_1 -eq 'Add-on: unavailable')
    $addonOff = New-DefaultSnapshot -ProvidersArg 'codex=auto,addon=off' -AddonModuleArg $module
    Check 'add-on off row' ($addonOff.addon_status -eq 'off' -and $addonOff.addon_line_1 -eq 'Off' -and $addonOff.addon_line_2 -eq '')
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

exit $script:failures

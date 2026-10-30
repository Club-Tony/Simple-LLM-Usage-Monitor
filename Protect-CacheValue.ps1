# DPAPI filter for usage-scraper.mjs's token cache (see token-cache.mjs).
# Node has no Windows DPAPI binding, so the scraper pipes the cache through this script:
#   -Protect   : stdin = base64(plaintext)  -> stdout = base64(DPAPI ciphertext)
#   -Unprotect : stdin = base64(ciphertext) -> stdout = base64(plaintext)
# Both directions are base64 so the console code page can never alter a byte. Protection
# is CurrentUser scope: only the same Windows account on this machine can decrypt, and the
# fixed entropy below keeps a blob protected for any other purpose from being fed back in.
# Nothing is written to disk here - token-cache.mjs owns the file - and error messages
# never include the input.
[CmdletBinding()]
param(
    [switch]$Protect,
    [switch]$Unprotect
)

$ErrorActionPreference = 'Stop'
if ($Protect.IsPresent -eq $Unprotect.IsPresent) {
    throw 'Pass exactly one of -Protect or -Unprotect.'
}

Add-Type -AssemblyName System.Security
# v2 came with the move to the per-user data folder; a v1 blob simply reads as a cache miss.
$entropy = [Text.Encoding]::UTF8.GetBytes('llm-usage-monitor/token-cache/v2')
$scope = [Security.Cryptography.DataProtectionScope]::CurrentUser

$inputText = [Console]::In.ReadToEnd().Trim()
if (-not $inputText) {
    throw 'No base64 input on stdin.'
}
$inputBytes = [Convert]::FromBase64String($inputText)
if ($Protect) {
    $outputBytes = [Security.Cryptography.ProtectedData]::Protect($inputBytes, $entropy, $scope)
} else {
    $outputBytes = [Security.Cryptography.ProtectedData]::Unprotect($inputBytes, $entropy, $scope)
}
[Console]::Out.Write([Convert]::ToBase64String($outputBytes))

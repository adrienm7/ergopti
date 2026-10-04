# Qualification-only byte transport for officially generated public artifacts.
param([Parameter(Mandatory=$true)][ValidatePattern("^[0-9a-f]{40}$")][string]$SourceCandidate)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. ./tools/test/group7_native_generation.ps1 -SourceCandidate $SourceCandidate
foreach ($recoveryPath in @(
    "static/ergopti_plus/windows/vendor/ergopti_nav_owner.dll",
    "static/ergopti_plus/windows/vendor/ergopti_nav_owner.manifest.json",
    "tools/test/group7-native-generation-results/source-identities.log",
    "tools/test/group7-native-generation-results/terminal_release_has_one_owner.log",
    "tools/test/group7-native-generation-results/terminal_release_preserves_concurrent_overflow.log"
)) {
    $recoveryFullPath = Join-Path $repoRoot $recoveryPath
    $recoveryBytes = [System.IO.File]::ReadAllBytes($recoveryFullPath)
    $recoveryHash = (Get-FileHash -LiteralPath $recoveryFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $recoveryEncoded = [System.Convert]::ToBase64String($recoveryBytes)
    Write-Host "GROUP7_FILE_BEGIN $recoveryPath $($recoveryBytes.Length) $recoveryHash"
    $recoveryIndex = 0
    for ($recoveryOffset = 0; $recoveryOffset -lt $recoveryEncoded.Length; $recoveryOffset += 2048) {
        $recoveryLength = [Math]::Min(2048, $recoveryEncoded.Length - $recoveryOffset)
        Write-Host "GROUP7_FILE_PART $recoveryIndex $($recoveryEncoded.Substring($recoveryOffset, $recoveryLength))"
        $recoveryIndex++
    }
    Write-Host "GROUP7_FILE_END $recoveryPath $recoveryIndex"
}

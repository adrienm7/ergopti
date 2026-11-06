# vendor/keyboard_layout/add_user_keyboard_layout.ps1
<#
==============================================================================
MODULE: Ergopti Layout in the User's Language List (Windows)
DESCRIPTION:
Adds an installed system keyboard layout to the current user's language list
(Settings > Time & language > Language & region), as a user does by hand
after an installer, so the layout appears in the language bar, in Layout >
« Input sources » and in the pause and resume pickers. Runs as the user, not
elevated: an elevated process may be another account.

FEATURES & RATIONALE:
1. The layout goes under -LocaleName; that language is added when the user
	does not have it yet, with the Ergopti layout as its only one (Windows would
	otherwise add the language's default layout too).
2. Idempotent: a layout already listed is not added twice.
3. Fail fast: the outcome is written to -ResultPath as JSON ({ status,
	message }: added, already_listed or failed) and a failure exits 1.
==============================================================================
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{8}$')][string]$Klid,
	[Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{4}$')][string]$LanguageId,
	[Parameter(Mandatory = $true)][string]$LocaleName,
	[Parameter(Mandatory = $true)][string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

<#
.SYNOPSIS
Writes the outcome the driver reads.
#>
function Write-Outcome {
	param([string]$Status, [string]$Message)
	$json = [ordered]@{ status = $Status; message = $Message } | ConvertTo-Json -Compress
	[IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false))
}

try {
	$tip = "{0}:{1}" -f $LanguageId.ToUpperInvariant(), $Klid.ToUpperInvariant()
	$list = Get-WinUserLanguageList
	$language = $list | Where-Object { $_.LanguageTag -ieq $LocaleName } | Select-Object -First 1
	if (-not $language) {
		$list.Add($LocaleName)
		$language = $list | Where-Object { $_.LanguageTag -ieq $LocaleName } | Select-Object -First 1
		if (-not $language) { throw "Windows does not know the language $LocaleName." }
		$language.InputMethodTips.Clear()
	}
	if (@($language.InputMethodTips | Where-Object { $_ -ieq $tip }).Count -gt 0) {
		Write-Outcome -Status "already_listed" -Message ""
		exit 0
	}
	$language.InputMethodTips.Add($tip)
	Set-WinUserLanguageList -LanguageList $list -Force
	Write-Outcome -Status "added" -Message ""
	exit 0
} catch {
	Write-Outcome -Status "failed" -Message $_.Exception.Message
	exit 1
}

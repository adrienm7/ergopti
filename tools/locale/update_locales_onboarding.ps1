# tools/update_locales_onboarding.ps1
#
# ==============================================================================
# Refreshes the onboarding wizard strings across every locale file except
# en.json and fr.json (which already hold the canonical EN/FR copies).
#
# Why this script exists
# ----------------------
# The wizard was rewritten to add new keys (welcome.title/heading,
# magic_key.choose_freely, the gestures.register_* family) and to update the
# *content* of several existing keys (the keylogger warning, the metrics
# description, the magic-key description/hint, the gestures description).
#
# Translating every change into the 19 non-EN/FR languages by hand is not
# realistic in one pass, but leaving the stale translations would surface
# obviously-outdated wording the moment a user switches their locale. This
# script therefore mirrors the new English text into every other locale so
# users still see the new behaviour in English even when their locale lacks a
# proper translation. Translators can later layer real translations on top of
# the same keys with the regular workflow.
# ==============================================================================

$ErrorActionPreference = "Stop"

$LocalesDir = Join-Path $PSScriptRoot "..\static\locales"
$LocalesDir = (Resolve-Path $LocalesDir).Path

# en.json and fr.json hold the canonical strings - never overwrite them.
$ExcludeFiles = @("en.json", "fr.json")

# Build all values from ASCII-safe chunks then attach the unicode bits via
# [char] so the .ps1 itself can stay ASCII (PowerShell on Windows reads .ps1
# files in ANSI by default and would mangle UTF-8 byte sequences embedded
# directly in here).
$EmDash      = [char]0x2014  # 'em dash'
$UGrave      = [char]0x00F9  # 'u with grave accent'
$Bullet      = [char]0x2022  # 'bullet'
$Ellipsis    = [char]0x2026  # 'horizontal ellipsis'

# --- Existing keys whose *value* changed (must be replaced if present) ---
# The values below are the canonical English copies; non-EN/FR locales pick
# them up verbatim as a placeholder until a translator authors a proper
# rendering. The script is idempotent so subsequent runs only re-write lines
# whose content actually differs from the source-of-truth here.
$ReplacedKeys = @{
	"dialog.metrics.enable_warning"   = "WARNING: You are about to enable the keylogger.\n\nIt records your keystrokes to the millisecond. Logs are stored locally under:\n    %s\n\nPassword fields are ignored automatically (UIA filter), and key content is also dropped while you are in a private/incognito browser window. Even so, this remains a keylogger " + $EmDash + " PAUSE the script when entering sensitive data outside those contexts.\n\nEnable?"
	"onboarding.gestures.desc"             = "Do you want to enable trackpad gesture support?\n\nThis lets you trigger custom actions with trackpad gestures (swipes, taps, pinches)."
	"onboarding.gestures.register_auto"      = "Automatic configuration"
	"onboarding.gestures.register_auto_hint" = "Fills in every gesture slot in Windows Settings for you. Does not require administrator rights."
	"onboarding.gestures.register_failed"    = "Automatic configuration failed. Please use the manual method below."
	"onboarding.gestures.register_manual_hint" = "Opens a step-by-step tutorial and a one-click shortcut to the touchpad settings page so you can wire up each gesture by hand."
	"onboarding.gestures.register_section"   = "Gestures must be wired up in Windows Settings (Bluetooth & devices " + $EmDash + " Touchpad " + $EmDash + " Advanced gestures). Choose how:"
	"onboarding.gestures.register_success"   = "Gestures are now configured in Windows Settings."
	"onboarding.magic_key.desc"              = "Pick the character that triggers your hotstrings."
	"onboarding.magic_key.choose_freely"     = "You can actually pick any character " + $EmDash + " it just needs to be rare enough not to cause false positives while still staying easy to reach."
	"onboarding.metrics.desc"                = "Do you want to enable typing metrics collection?\n\nWhat ErgoptiPlus tracks for you:\n" + $Bullet + " typing speed (WPM) per session, per app and over time;\n" + $Bullet + " most-typed keys, words, n-grams and ergonomic strain;\n" + $Bullet + " hand alternation, finger load, same-finger bigrams;\n" + $Bullet + " time spent per application (RescueTime-style) with productivity scoring;\n" + $Bullet + " trends, heatmaps and detailed dashboards in the Metrics window."
}

# --- Keys to delete (they were superseded). The magic_key.hint key duplicated
#     magic_key.desc verbatim; the wizard now uses magic_key.suggestions instead. ---
$DeletedKeys = @(
	"onboarding.magic_key.hint"
)

# --- Brand-new keys ---
# Note: ``onboarding.welcome.title`` and ``onboarding.welcome.heading`` are
# deliberately NOT listed here. Those two strings render BEFORE the user picks
# a language, so they must be fully localised — they live in
# tools/translate_welcome_keys.ps1 (per-locale table) and any value listed
# here would clobber the real translation on every bulk-update run.
$NewKeys = @{
	"onboarding.gestures.open_settings"        = "Open touchpad settings"
	"onboarding.gestures.open_settings_hint"   = "Opens Settings " + $EmDash + " Bluetooth & devices " + $EmDash + " Touchpad " + $EmDash + " Advanced gestures, where you assign Ctrl + Win + Shift + F1..F10 to each gesture slot."
	"onboarding.gestures.register_manual"      = "Manual method"
	"onboarding.magic_key.option_custom"       = "Custom (type your own below)"
	"onboarding.magic_key.option_semicolon"    = "; " + $EmDash + " recommended on QWERTY"
	"onboarding.magic_key.option_star"         = ([char]0x2605) + " " + $EmDash + " recommended on Ergopti+ (dedicated key)"
	"onboarding.magic_key.option_ugrave"       = $UGrave + " " + $EmDash + " recommended on AZERTY"
	# suggestions is kept for the Hammerspoon web wizard, which renders the
	# recommended characters as a hint paragraph above the input. The AHK
	# driver switched to the four radio options above; both stay in lockstep
	# wording-wise.
	"onboarding.magic_key.suggestions"         = "Recommended characters:\n   " + $Bullet + " " + ([char]0x2605) + " " + $EmDash + " on Ergopti+ (dedicated key)\n   " + $Bullet + " " + $UGrave + " " + $EmDash + " on AZERTY\n   " + $Bullet + " ; " + $EmDash + " on QWERTY"
	# menu.gestures.manual_tutorial replaces the previous two-item flow
	# (instructions + open touchpad). The single popup carries both.
	# 📋 (U+1F4CB) is outside the BMP — build it from its UTF-16 surrogate
	# pair so PowerShell 5.1 (which cannot cast 0x1F4CB to [char]) does not
	# choke. High = 0xD83D, low = 0xDCCB.
	"menu.gestures.manual_tutorial"            = ([char]0xD83D) + ([char]0xDCCB) + " Manual setup tutorial"
}

# Build a fast escape helper for regex special characters.
function Escape-Regex([string]$s) { [Regex]::Escape($s) }

# Update the *value* of an existing key by working on a line array — avoids the
# .NET Regex.Replace MatchEvaluator subtleties around back-references and PS
# variable scoping. Source values are already JSON-escaped (single backslashes
# mean JSON \n / \\ / \"), so we emit them verbatim.
function Replace-Key([string]$text, [string]$key, [string]$value, [ref]$changed) {
	$lines  = $text -split "`n"
	$linePat = '^(\t)?"' + (Escape-Regex $key) + '":'
	$updated = $false
	for ($i = 0; $i -lt $lines.Length; $i++) {
		if ($lines[$i] -match $linePat) {
			$newLine = "`t`"$key`": `"$value`","
			if ($lines[$i] -ne $newLine) {
				$lines[$i] = $newLine
				$updated = $true
			}
			break
		}
	}
	if ($updated) {
		$changed.Value = $true
		return ($lines -join "`n")
	}
	return $text
}

# Delete a key entirely. Returns the new text (possibly unchanged).
function Delete-Key([string]$text, [string]$key, [ref]$changed) {
	$lines  = $text -split "`n"
	$linePat = '^(\t)?"' + (Escape-Regex $key) + '":'
	$kept = New-Object System.Collections.ArrayList
	$removed = $false
	foreach ($line in $lines) {
		if ($line -match $linePat) {
			$removed = $true
			continue
		}
		[void]$kept.Add($line)
	}
	if ($removed) {
		$changed.Value = $true
		return ($kept -join "`n")
	}
	return $text
}

# Insert a new key into the JSON text, alphabetically sorted with its peers.
function Insert-Key([string]$text, [string]$key, [string]$value, [ref]$changed) {
	$existsPattern = '(?m)^\s*"' + (Escape-Regex $key) + '":'
	if ($text -match $existsPattern) {
		return $text
	}

	# Source value is already JSON-escaped — emit as-is.
	$newLine = "`t`"$key`": `"$value`","

	$contentLines = $text -split "`n"

	$inserted = $false
	for ($i = 0; $i -lt $contentLines.Length; $i++) {
		$line = $contentLines[$i]
		if ($line -match '^\s*"([^"]+)":') {
			$existingKey = $matches[1]
			if ([string]::Compare($existingKey, $key, $false) -gt 0) {
				$before = $contentLines[0..($i - 1)]
				$after  = $contentLines[$i..($contentLines.Length - 1)]
				$contentLines = $before + @($newLine) + $after
				$inserted = $true
				break
			}
		}
	}

	if (-not $inserted) {
		Write-Warning "Could not place key '$key' alphabetically - appending before closing brace."
		for ($i = $contentLines.Length - 1; $i -ge 0; $i--) {
			if ($contentLines[$i] -match '^\s*\}\s*$') {
				$before = $contentLines[0..($i - 1)]
				$after  = $contentLines[$i..($contentLines.Length - 1)]
				$contentLines = $before + @($newLine) + $after
				$inserted = $true
				break
			}
		}
	}

	if ($inserted) {
		$changed.Value = $true
		return ($contentLines -join "`n")
	}

	return $text
}

# --- Main loop ---
Get-ChildItem -Path $LocalesDir -Filter "*.json" | ForEach-Object {
	$file = $_
	if ($ExcludeFiles -contains $file.Name) {
		Write-Output "Skipping $($file.Name) (excluded)."
		return
	}

	$text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
	$changed = $false
	$changedRef = [ref]$changed

	# Replace stale values first so newly-inserted keys never collide.
	foreach ($entry in $ReplacedKeys.GetEnumerator()) {
		$text = Replace-Key $text $entry.Key $entry.Value $changedRef
	}

	# Drop superseded keys before reinserting fresh ones — keeps the locale
	# files free of stale dead weight.
	foreach ($k in $DeletedKeys) {
		$text = Delete-Key $text $k $changedRef
	}

	# For brand-new keys: refresh the value if it already exists (e.g. a previous
	# run wrote a buggy double-escaped variant we now need to fix), then insert
	# if absent. Replace-Key is a no-op on missing keys, so the order is safe.
	foreach ($entry in $NewKeys.GetEnumerator()) {
		$text = Replace-Key $text $entry.Key $entry.Value $changedRef
		$text = Insert-Key  $text $entry.Key $entry.Value $changedRef
	}

	if ($changed) {
		[System.IO.File]::WriteAllText($file.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
		Write-Output "Updated $($file.Name)"
	} else {
		Write-Output "No changes for $($file.Name)"
	}
}

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
$ReplacedKeys = @{
	"dialog.metrics.enable_warning"   = "WARNING: You are about to enable the keylogger.\n\nIt records your keystrokes to the millisecond. Logs are stored locally under:\n    %s\n\nPassword fields are ignored automatically (UIA filter), and key content is also dropped while you are in a private/incognito browser window. Even so, this remains a keylogger " + $EmDash + " PAUSE the script when entering sensitive data outside those contexts.\n\nEnable?"
	"onboarding.gestures.desc"        = "Do you want to enable trackpad gesture support?\n\nThis lets you trigger custom actions with trackpad gestures (swipes, taps, pinches)."
	"onboarding.magic_key.desc"       = "Pick the character that triggers your hotstrings.\n\nDefault: * (asterisk). Recommended: " + $UGrave + " on AZERTY, ; on other layouts. Anything else works too."
	"onboarding.magic_key.hint"       = "Default: * " + $EmDash + " Suggestions: " + $UGrave + " (AZERTY), ; (other layouts). Pick any character you prefer."
	"onboarding.metrics.desc"         = "Do you want to enable typing metrics collection?\n\nWhat ErgoptiPlus tracks for you:\n" + $Bullet + " Typing speed (WPM) per session, per app and over time\n" + $Bullet + " Most-typed keys, words, n-grams and ergonomic strain\n" + $Bullet + " Hand alternation, finger load, same-finger bigrams\n" + $Bullet + " Time spent per application (RescueTime-style) with productivity scoring\n" + $Bullet + " Trends, heatmaps and detailed dashboards in the Metrics window"
}

# --- Brand-new keys ---
$NewKeys = @{
	"onboarding.gestures.register_auto"        = "Automatic registration (Registry)"
	"onboarding.gestures.register_auto_hint"   = "Writes the touchpad gesture keys under HKCU\\" + $Ellipsis + "\\PrecisionTouchPad so Windows forwards your trackpad gestures to ErgoptiPlus. Does not require administrator rights."
	"onboarding.gestures.register_failed"      = "Automatic registration failed. Please use the manual method below."
	"onboarding.gestures.register_manual"      = "Manual method"
	"onboarding.gestures.register_manual_hint" = "Open the Registry Editor at HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\PrecisionTouchPad and configure the gesture keys by hand. Use this if automatic registration is blocked."
	"onboarding.gestures.register_section"     = "Gestures need a small Windows Registry entry to forward trackpad swipes/taps to ErgoptiPlus. Choose how to install it:"
	"onboarding.gestures.register_success"     = "Registry entries created. Gestures are now ready."
	"onboarding.magic_key.choose_freely"       = "You can choose any character you like " + $EmDash + " it just has to be reachable by a single keypress on your physical keyboard."
	"onboarding.welcome.heading"               = "Choose your language"
	"onboarding.welcome.title"                 = "Ergopti " + $EmDash + " Setup"
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

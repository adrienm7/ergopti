# tools/translate_welcome_keys.ps1
#
# ==============================================================================
# Translates the two welcome-screen keys (onboarding.welcome.title and
# onboarding.welcome.heading) into every supported locale. These strings show
# BEFORE the user picks a language, so they must already be in the locale's
# native script instead of falling back to English.
#
# Every multi-byte character is built via [char] so the .ps1 source itself
# stays plain ASCII: PowerShell 5.1 reads .ps1 files in ANSI by default and
# mojibakes embedded UTF-8 bytes into "Ã¤" etc., which is exactly the bug
# the first version of this script introduced. Keeping the source ASCII-only
# sidesteps that entirely without requiring a UTF-8 BOM.
# ==============================================================================

$ErrorActionPreference = "Stop"

$LocalesDir = Join-Path $PSScriptRoot "..\static\locales"
$LocalesDir = (Resolve-Path $LocalesDir).Path

$EmDash = [char]0x2014

# Short helpers for code points used in more than one entry.
function U([int]$c) { return [char]$c }

# Per-locale translations. Use string concatenation with explicit [char]
# escapes for every non-ASCII rune so the source stays ANSI-compatible.
$Translations = @{
	"ar" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x0625) + (U 0x0639) + (U 0x062F) + (U 0x0627) + (U 0x062F)
		"onboarding.welcome.heading" = (U 0x0627) + (U 0x062E) + (U 0x062A) + (U 0x0631) + " " + (U 0x0644) + (U 0x063A) + (U 0x062A) + (U 0x0643)
	}
	"cs" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Nastaven" + (U 0x00ED)
		"onboarding.welcome.heading" = "Vyberte sv" + (U 0x016F) + "j jazyk"
	}
	"da" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Ops" + (U 0x00E6) + "tning"
		"onboarding.welcome.heading" = "V" + (U 0x00E6) + "lg dit sprog"
	}
	"de" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Einrichtung"
		"onboarding.welcome.heading" = "W" + (U 0x00E4) + "hlen Sie Ihre Sprache"
	}
	"es" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Configuraci" + (U 0x00F3) + "n"
		"onboarding.welcome.heading" = "Elige tu idioma"
	}
	"he" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x05D4) + (U 0x05EA) + (U 0x05E7) + (U 0x05E0) + (U 0x05D4)
		"onboarding.welcome.heading" = (U 0x05D1) + (U 0x05D7) + (U 0x05E8) + " " + (U 0x05E9) + (U 0x05E4) + (U 0x05D4)
	}
	"hi" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x0938) + (U 0x0947) + (U 0x091F) + (U 0x0905) + (U 0x092A)
		"onboarding.welcome.heading" = (U 0x0905) + (U 0x092A) + (U 0x0928) + (U 0x0940) + " " + (U 0x092D) + (U 0x093E) + (U 0x0937) + (U 0x093E) + " " + (U 0x091A) + (U 0x0941) + (U 0x0928) + (U 0x0947) + (U 0x0902)
	}
	"it" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Configurazione"
		"onboarding.welcome.heading" = "Scegli la tua lingua"
	}
	"ja" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x30BB) + (U 0x30C3) + (U 0x30C8) + (U 0x30A2) + (U 0x30C3) + (U 0x30D7)
		"onboarding.welcome.heading" = (U 0x8A00) + (U 0x8A9E) + (U 0x3092) + (U 0x9078) + (U 0x629E) + (U 0x3057) + (U 0x3066) + (U 0x304F) + (U 0x3060) + (U 0x3055) + (U 0x3044)
	}
	"ko" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0xC124) + (U 0xC815)
		"onboarding.welcome.heading" = (U 0xC5B8) + (U 0xC5B4) + (U 0xB97C) + " " + (U 0xC120) + (U 0xD0DD) + (U 0xD558) + (U 0xC138) + (U 0xC694)
	}
	"nl" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Installatie"
		"onboarding.welcome.heading" = "Kies uw taal"
	}
	"no" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Oppsett"
		"onboarding.welcome.heading" = "Velg spr" + (U 0x00E5) + "ket dit"
	}
	"pl" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Konfiguracja"
		"onboarding.welcome.heading" = "Wybierz sw" + (U 0x00F3) + "j j" + (U 0x0119) + "zyk"
	}
	"pt" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Configura" + (U 0x00E7) + (U 0x00E3) + "o"
		"onboarding.welcome.heading" = "Escolha o seu idioma"
	}
	"ru" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x041D) + (U 0x0430) + (U 0x0441) + (U 0x0442) + (U 0x0440) + (U 0x043E) + (U 0x0439) + (U 0x043A) + (U 0x0430)
		"onboarding.welcome.heading" = (U 0x0412) + (U 0x044B) + (U 0x0431) + (U 0x0435) + (U 0x0440) + (U 0x0438) + (U 0x0442) + (U 0x0435) + " " + (U 0x044F) + (U 0x0437) + (U 0x044B) + (U 0x043A)
	}
	"sv" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Inst" + (U 0x00E4) + "llning"
		"onboarding.welcome.heading" = "V" + (U 0x00E4) + "lj ditt spr" + (U 0x00E5) + "k"
	}
	"tr" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " Kurulum"
		"onboarding.welcome.heading" = "Dilinizi se" + (U 0x00E7) + "in"
	}
	"uk" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x041D) + (U 0x0430) + (U 0x043B) + (U 0x0430) + (U 0x0448) + (U 0x0442) + (U 0x0443) + (U 0x0432) + (U 0x0430) + (U 0x043D) + (U 0x043D) + (U 0x044F)
		"onboarding.welcome.heading" = (U 0x0412) + (U 0x0438) + (U 0x0431) + (U 0x0435) + (U 0x0440) + (U 0x0456) + (U 0x0442) + (U 0x044C) + " " + (U 0x043C) + (U 0x043E) + (U 0x0432) + (U 0x0443)
	}
	"zh" = @{
		"onboarding.welcome.title"   = "Ergopti " + $EmDash + " " + (U 0x8BBE) + (U 0x7F6E)
		"onboarding.welcome.heading" = (U 0x9009) + (U 0x62E9) + (U 0x60A8) + (U 0x7684) + (U 0x8BED) + (U 0x8A00)
	}
}

function Escape-Regex([string]$s) { [Regex]::Escape($s) }

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

foreach ($locale in $Translations.Keys) {
	$file = Join-Path $LocalesDir "$locale.json"
	if (-not (Test-Path $file)) {
		Write-Warning "Locale file not found: $file"
		continue
	}
	$text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
	$changed = $false
	$changedRef = [ref]$changed
	foreach ($entry in $Translations[$locale].GetEnumerator()) {
		$text = Replace-Key $text $entry.Key $entry.Value $changedRef
	}
	if ($changed) {
		[System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))
		Write-Output "Updated $locale.json"
	} else {
		Write-Output "No changes for $locale.json"
	}
}

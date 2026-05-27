# tools/translate_radio_labels.ps1
#
# ==============================================================================
# Authored translations for the four magic-key radio labels shown on Step 3 of
# the onboarding wizard. These are short, user-facing strings; they must read
# naturally in every locale so the bulk update_locales_onboarding.ps1 falls
# back to English on the option_* keys and we override them here.
#
# Every multi-byte character is built via [char] so the .ps1 source stays
# ASCII-safe under PowerShell 5.1's default ANSI reader.
# ==============================================================================

$ErrorActionPreference = "Stop"

$LocalesDir = Join-Path $PSScriptRoot "..\static\locales"
$LocalesDir = (Resolve-Path $LocalesDir).Path

$EmDash = [char]0x2014
$Star   = [char]0x2605
$UGrave = [char]0x00F9

function U([int]$c) { return [char]$c }

# Keys: option_star, option_ugrave, option_semicolon, option_custom.
$Translations = @{
	"ar" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " " + (U 0x064A) + (U 0x064F) + (U 0x0648) + (U 0x0635) + (U 0x0649) + " " + (U 0x0628) + (U 0x0647) + (U 0x0627) + " " + (U 0x0639) + (U 0x0644) + (U 0x0649) + " Ergopti+"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " " + (U 0x064A) + (U 0x064F) + (U 0x0648) + (U 0x0635) + (U 0x0649) + " " + (U 0x0628) + (U 0x0647) + (U 0x0627) + " " + (U 0x0639) + (U 0x0644) + (U 0x0649) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " " + (U 0x064A) + (U 0x064F) + (U 0x0648) + (U 0x0635) + (U 0x0649) + " " + (U 0x0628) + (U 0x0647) + (U 0x0627) + " " + (U 0x0639) + (U 0x0644) + (U 0x0649) + " QWERTY"
		"onboarding.magic_key.option_custom"    = (U 0x0645) + (U 0x062E) + (U 0x0635) + (U 0x0635) + " (" + (U 0x0627) + (U 0x0643) + (U 0x062A) + (U 0x0628) + " " + (U 0x062E) + (U 0x064A) + (U 0x0627) + (U 0x0631) + (U 0x0643) + " " + (U 0x0623) + (U 0x062F) + (U 0x0646) + (U 0x0627) + (U 0x0647) + ")"
	}
	"cs" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " doporu" + (U 0x010D) + "eno na Ergopti+ (vyhrazen" + (U 0x00E1) + " kl" + (U 0x00E1) + "vesa)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " doporu" + (U 0x010D) + "eno na AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " doporu" + (U 0x010D) + "eno na QWERTY"
		"onboarding.magic_key.option_custom"    = "Vlastn" + (U 0x00ED) + " (zadejte n" + (U 0x00ED) + (U 0x017E) + "e)"
	}
	"da" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " anbefales p" + (U 0x00E5) + " Ergopti+ (dedikeret tast)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " anbefales p" + (U 0x00E5) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " anbefales p" + (U 0x00E5) + " QWERTY"
		"onboarding.magic_key.option_custom"    = "Brugerdefineret (skriv din egen nedenfor)"
	}
	"de" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " empfohlen auf Ergopti+ (eigene Taste)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " empfohlen auf AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " empfohlen auf QWERTY"
		"onboarding.magic_key.option_custom"    = "Benutzerdefiniert (unten eingeben)"
	}
	"es" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " recomendado en Ergopti+ (tecla dedicada)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " recomendado en AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " recomendado en QWERTY"
		"onboarding.magic_key.option_custom"    = "Personalizado (escr" + (U 0x00ED) + "belo abajo)"
	}
	"he" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " " + (U 0x05DE) + (U 0x05D5) + (U 0x05DE) + (U 0x05DC) + (U 0x05E5) + " " + (U 0x05E2) + (U 0x05DC) + " Ergopti+"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " " + (U 0x05DE) + (U 0x05D5) + (U 0x05DE) + (U 0x05DC) + (U 0x05E5) + " " + (U 0x05E2) + (U 0x05DC) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " " + (U 0x05DE) + (U 0x05D5) + (U 0x05DE) + (U 0x05DC) + (U 0x05E5) + " " + (U 0x05E2) + (U 0x05DC) + " QWERTY"
		"onboarding.magic_key.option_custom"    = (U 0x05DE) + (U 0x05D5) + (U 0x05EA) + (U 0x05D0) + (U 0x05DD) + " " + (U 0x05D0) + (U 0x05D9) + (U 0x05E9) + (U 0x05D9) + (U 0x05EA) + " (" + (U 0x05D4) + (U 0x05E7) + (U 0x05DC) + (U 0x05D3) + (U 0x05D5) + " " + (U 0x05DC) + (U 0x05DE) + (U 0x05D8) + (U 0x05D4) + ")"
	}
	"hi" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " Ergopti+ " + (U 0x092A) + (U 0x0930) + " " + (U 0x0905) + (U 0x0928) + (U 0x0941) + (U 0x0936) + (U 0x0902) + (U 0x0938) + (U 0x093F) + (U 0x0924) + " (" + (U 0x0938) + (U 0x092E) + (U 0x0930) + (U 0x094D) + (U 0x092A) + (U 0x093F) + (U 0x0924) + " " + (U 0x0915) + (U 0x0941) + (U 0x0902) + (U 0x091C) + (U 0x0940) + ")"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " AZERTY " + (U 0x092A) + (U 0x0930) + " " + (U 0x0905) + (U 0x0928) + (U 0x0941) + (U 0x0936) + (U 0x0902) + (U 0x0938) + (U 0x093F) + (U 0x0924)
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " QWERTY " + (U 0x092A) + (U 0x0930) + " " + (U 0x0905) + (U 0x0928) + (U 0x0941) + (U 0x0936) + (U 0x0902) + (U 0x0938) + (U 0x093F) + (U 0x0924)
		"onboarding.magic_key.option_custom"    = (U 0x0915) + (U 0x0938) + (U 0x094D) + (U 0x091F) + (U 0x092E) + " (" + (U 0x0928) + (U 0x0940) + (U 0x091A) + (U 0x0947) + " " + (U 0x091F) + (U 0x093E) + (U 0x0907) + (U 0x092A) + " " + (U 0x0915) + (U 0x0930) + (U 0x0947) + (U 0x0902) + ")"
	}
	"it" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " consigliato su Ergopti+ (tasto dedicato)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " consigliato su AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " consigliato su QWERTY"
		"onboarding.magic_key.option_custom"    = "Personalizzato (digita il tuo qui sotto)"
	}
	"ja" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " Ergopti+" + (U 0x3067) + (U 0x63A8) + (U 0x5968) + (U 0xFF08) + (U 0x5C02) + (U 0x7528) + (U 0x30AD) + (U 0x30FC) + (U 0xFF09)
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " AZERTY" + (U 0x3067) + (U 0x63A8) + (U 0x5968)
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " QWERTY" + (U 0x3067) + (U 0x63A8) + (U 0x5968)
		"onboarding.magic_key.option_custom"    = (U 0x30AB) + (U 0x30B9) + (U 0x30BF) + (U 0x30E0) + (U 0xFF08) + (U 0x4E0B) + (U 0x306B) + (U 0x5165) + (U 0x529B) + (U 0xFF09)
	}
	"ko" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " Ergopti+" + (U 0xC5D0) + (U 0xC11C) + " " + (U 0xAD8C) + (U 0xC7A5) + " (" + (U 0xC804) + (U 0xC6A9) + " " + (U 0xD0A4) + ")"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " AZERTY" + (U 0xC5D0) + (U 0xC11C) + " " + (U 0xAD8C) + (U 0xC7A5)
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " QWERTY" + (U 0xC5D0) + (U 0xC11C) + " " + (U 0xAD8C) + (U 0xC7A5)
		"onboarding.magic_key.option_custom"    = (U 0xC0AC) + (U 0xC6A9) + (U 0xC790) + " " + (U 0xC9C0) + (U 0xC815) + " (" + (U 0xC544) + (U 0xB798) + (U 0xC5D0) + " " + (U 0xC785) + (U 0xB825) + ")"
	}
	"nl" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " aanbevolen op Ergopti+ (specifieke toets)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " aanbevolen op AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " aanbevolen op QWERTY"
		"onboarding.magic_key.option_custom"    = "Aangepast (typ uw eigen hieronder)"
	}
	"no" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " anbefales p" + (U 0x00E5) + " Ergopti+ (dedikert tast)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " anbefales p" + (U 0x00E5) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " anbefales p" + (U 0x00E5) + " QWERTY"
		"onboarding.magic_key.option_custom"    = "Egendefinert (skriv din egen nedenfor)"
	}
	"pl" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " zalecane na Ergopti+ (dedykowany klawisz)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " zalecane na AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " zalecane na QWERTY"
		"onboarding.magic_key.option_custom"    = "W" + (U 0x0142) + "asne (wpisz poni" + (U 0x017C) + "ej)"
	}
	"pt" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " recomendado em Ergopti+ (tecla dedicada)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " recomendado em AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " recomendado em QWERTY"
		"onboarding.magic_key.option_custom"    = "Personalizado (digite o seu abaixo)"
	}
	"ru" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " " + (U 0x0440) + (U 0x0435) + (U 0x043A) + (U 0x043E) + (U 0x043C) + (U 0x0435) + (U 0x043D) + (U 0x0434) + (U 0x0443) + (U 0x0435) + (U 0x0442) + (U 0x0441) + (U 0x044F) + " " + (U 0x043D) + (U 0x0430) + " Ergopti+"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " " + (U 0x0440) + (U 0x0435) + (U 0x043A) + (U 0x043E) + (U 0x043C) + (U 0x0435) + (U 0x043D) + (U 0x0434) + (U 0x0443) + (U 0x0435) + (U 0x0442) + (U 0x0441) + (U 0x044F) + " " + (U 0x043D) + (U 0x0430) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " " + (U 0x0440) + (U 0x0435) + (U 0x043A) + (U 0x043E) + (U 0x043C) + (U 0x0435) + (U 0x043D) + (U 0x0434) + (U 0x0443) + (U 0x0435) + (U 0x0442) + (U 0x0441) + (U 0x044F) + " " + (U 0x043D) + (U 0x0430) + " QWERTY"
		"onboarding.magic_key.option_custom"    = (U 0x0421) + (U 0x0432) + (U 0x043E) + (U 0x0439) + " (" + (U 0x0432) + (U 0x0432) + (U 0x0435) + (U 0x0434) + (U 0x0438) + (U 0x0442) + (U 0x0435) + " " + (U 0x043D) + (U 0x0438) + (U 0x0436) + (U 0x0435) + ")"
	}
	"sv" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " rekommenderas p" + (U 0x00E5) + " Ergopti+ (dedikerad tangent)"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " rekommenderas p" + (U 0x00E5) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " rekommenderas p" + (U 0x00E5) + " QWERTY"
		"onboarding.magic_key.option_custom"    = "Anpassad (skriv din egen nedan)"
	}
	"tr" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " Ergopti+ " + (U 0x00FC) + "zerinde " + (U 0x00F6) + "nerilir (" + (U 0x00F6) + "zel tu" + (U 0x015F) + ")"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " AZERTY " + (U 0x00FC) + "zerinde " + (U 0x00F6) + "nerilir"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " QWERTY " + (U 0x00FC) + "zerinde " + (U 0x00F6) + "nerilir"
		"onboarding.magic_key.option_custom"    = "" + (U 0x00D6) + "zel (kendinizinkini a" + (U 0x015F) + (U 0x0131) + "" + (U 0x011F) + (U 0x0131) + "ya yaz" + (U 0x0131) + "n)"
	}
	"uk" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " " + (U 0x0440) + (U 0x0435) + (U 0x043A) + (U 0x043E) + (U 0x043C) + (U 0x0435) + (U 0x043D) + (U 0x0434) + (U 0x043E) + (U 0x0432) + (U 0x0430) + (U 0x043D) + (U 0x043E) + " " + (U 0x043D) + (U 0x0430) + " Ergopti+"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " " + (U 0x0440) + (U 0x0435) + (U 0x043A) + (U 0x043E) + (U 0x043C) + (U 0x0435) + (U 0x043D) + (U 0x0434) + (U 0x043E) + (U 0x0432) + (U 0x0430) + (U 0x043D) + (U 0x043E) + " " + (U 0x043D) + (U 0x0430) + " AZERTY"
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " " + (U 0x0440) + (U 0x0435) + (U 0x043A) + (U 0x043E) + (U 0x043C) + (U 0x0435) + (U 0x043D) + (U 0x0434) + (U 0x043E) + (U 0x0432) + (U 0x0430) + (U 0x043D) + (U 0x043E) + " " + (U 0x043D) + (U 0x0430) + " QWERTY"
		"onboarding.magic_key.option_custom"    = (U 0x0412) + (U 0x043B) + (U 0x0430) + (U 0x0441) + (U 0x043D) + (U 0x0438) + (U 0x0439) + " (" + (U 0x0432) + (U 0x0432) + (U 0x0435) + (U 0x0434) + (U 0x0456) + (U 0x0442) + (U 0x044C) + " " + (U 0x043D) + (U 0x0438) + (U 0x0436) + (U 0x0447) + (U 0x0435) + ")"
	}
	"zh" = @{
		"onboarding.magic_key.option_star"      = $Star + " " + $EmDash + " " + (U 0x5728) + " Ergopti+ " + (U 0x4E0A) + (U 0x63A8) + (U 0x8350) + " (" + (U 0x4E13) + (U 0x7528) + (U 0x952E) + ")"
		"onboarding.magic_key.option_ugrave"    = $UGrave + " " + $EmDash + " " + (U 0x5728) + " AZERTY " + (U 0x4E0A) + (U 0x63A8) + (U 0x8350)
		"onboarding.magic_key.option_semicolon" = "; " + $EmDash + " " + (U 0x5728) + " QWERTY " + (U 0x4E0A) + (U 0x63A8) + (U 0x8350)
		"onboarding.magic_key.option_custom"    = (U 0x81EA) + (U 0x5B9A) + (U 0x4E49) + " (" + (U 0x5728) + (U 0x4E0B) + (U 0x9762) + (U 0x8F93) + (U 0x5165) + (U 0x60A8) + (U 0x7684) + ")"
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

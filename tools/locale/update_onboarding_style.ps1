# tools/update_onboarding_style.ps1
#
# Rewrites onboarding UI strings to a professional, impersonal style
# (no direct address to the user) across all 21 locale files.
# EN and FR get native copy; the 19 others get the EN fallback.

$LocalesDir = "$PSScriptRoot\..\static\locales"

$DASH   = [char]0x2014  # em-dash
$BULL   = [char]0x2022  # bullet
$RSQUO  = [char]0x2019  # right single quotation mark
$ARROW  = [char]0x2192  # right arrow
$EACU   = [char]0x00e9  # e acute
$EGRAV  = [char]0x00e8  # e grave
$ECIRC  = [char]0x00ea  # e circumflex
$AGRAV  = [char]0x00e0  # a grave
$NL     = '\n'          # literal \n for JSON

# ---------------------------------------------------------------------------
# Canonical new values  (EN)
# ---------------------------------------------------------------------------

$EN = [ordered]@{}
$EN["onboarding.magic_key.option_custom"]     = "(custom input)"
$EN["onboarding.magic_key.option_star"]       = "* $DASH recommended (works on all layouts)"
$EN["onboarding.magic_key.desc"]              = "Character that triggers hotstrings."
$EN["onboarding.magic_key.choose_freely"]     = "Any character can serve as a trigger $DASH rare enough to avoid false positives, easy enough to reach."
$EN["onboarding.layout.desc"]                 = "Activates layout emulation (base layer + AltGr) and Ergopti hotstrings."
$EN["onboarding.gestures.desc"]               = "Enables trackpad gesture support $DASH custom actions triggered by swipes, taps and pinches."
$EN["onboarding.gestures.open_settings_hint"] = "Opens Settings $ARROW Bluetooth & devices $ARROW Touchpad $ARROW Advanced gestures. Each slot accepts a Ctrl + Win + Shift + F1..F10 shortcut."
$EN["onboarding.gestures.register_section"]   = "Gestures must be configured in Windows Settings (Bluetooth & devices $ARROW Touchpad $ARROW Advanced gestures):"
$EN["onboarding.metrics.desc"]                = "Enables typing metrics collection.${NL}${NL}What ErgoptiPlus tracks:${NL}$BULL typing speed (WPM) per session, per app and over time;${NL}$BULL most-typed keys, words, n-grams and ergonomic strain;${NL}$BULL hand alternation, finger load, same-finger bigrams;${NL}$BULL time spent per application (RescueTime-style) with productivity scoring;${NL}$BULL trends, heatmaps and detailed dashboards in the Metrics window."
$EN["onboarding.done.body"]                   = "Configuration saved. The script will now reload."

# ---------------------------------------------------------------------------
# Native FR values
# ---------------------------------------------------------------------------

$FR = [ordered]@{}
$FR["onboarding.magic_key.option_custom"]     = "(saisie personnalis${EACU}e)"
$FR["onboarding.magic_key.option_star"]       = "* $DASH recommand${EACU} (fonctionne sur toutes les dispositions)"
$FR["onboarding.magic_key.desc"]              = "Caract${EGRAV}re d${EACU}clencheur des hotstrings."
$FR["onboarding.magic_key.choose_freely"]     = "N${RSQUO}importe quel caract${EGRAV}re peut ${ECIRC}tre utilis${EACU} $DASH suffisamment rare pour ${EACU}viter les faux positifs, suffisamment accessible pour rester pratique."
$FR["onboarding.layout.desc"]                 = "Active l${RSQUO}${EACU}mulation de disposition (couche de base + AltGr) et les hotstrings Ergopti."
$FR["onboarding.gestures.desc"]               = "Active le support des gestes pour pav${EACU} tactile $DASH actions personnalis${EACU}es d${EACU}clench${EACU}es par glissements, pressions et pincements."
$FR["onboarding.gestures.open_settings_hint"] = "Ouvre Param${EGRAV}tres $ARROW Bluetooth et appareils $ARROW Pav${EACU} tactile $ARROW Gestes avanc${EACU}s. Chaque emplacement accepte un raccourci Ctrl + Win + Shift + F1..F10."
$FR["onboarding.gestures.register_section"]   = "Les gestes doivent ${ECIRC}tre configur${EACU}s dans les Param${EGRAV}tres Windows (Bluetooth et appareils $ARROW Pav${EACU} tactile $ARROW Gestes avanc${EACU}s) :"
$FR["onboarding.metrics.desc"]                = "Active la collecte de m${EACU}triques de frappe.${NL}${NL}Ce qu${RSQUO}ErgoptiPlus suit :${NL}$BULL vitesse de frappe (MPM, mots par minute) par session, par application et au fil du temps ;${NL}$BULL touches, mots et n-grammes les plus tap${EACU}s, charge ergonomique ;${NL}$BULL alternance des mains, charge par doigt, bigrammes de m${ECIRC}me doigt ;${NL}$BULL temps pass${EACU} par application (${AGRAV} la RescueTime) avec score de productivit${EACU} ;${NL}$BULL tendances, heatmaps et tableaux de bord d${EACU}taill${EACU}s dans la fen${ECIRC}tre M${EACU}triques."
$FR["onboarding.done.body"]                   = "Configuration enregistr${EACU}e. Le script va maintenant se recharger."

# ---------------------------------------------------------------------------
# Helper: replace one key in a locale JSON file (preserves formatting)
# ---------------------------------------------------------------------------

function Set-JsonKey {
    param([string]$FilePath, [string]$Key, [string]$Value)
    $enc   = New-Object System.Text.UTF8Encoding $false
    $lines = [System.IO.File]::ReadAllLines($FilePath, $enc)

    # Escape the value for JSON inline string
    $esc = $Value `
        -replace '\\', '\\' `
        -replace '"',  '\"'
    # \n is already the literal two-char sequence we want in JSON, keep as-is

    $pat = ('^(\s*)"' + [regex]::Escape($Key) + '"\s*:.*?(,?)$')
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pat) {
            $indent = $Matches[1]
            $comma  = $Matches[2]
            $lines[$i] = $indent + '"' + $Key + '": "' + $esc + '"' + $comma
            $found = $true
        }
    }
    if ($found) {
        [System.IO.File]::WriteAllLines($FilePath, $lines, $enc)
    }
}

# ---------------------------------------------------------------------------
# Apply EN
# ---------------------------------------------------------------------------

$enFile = "$LocalesDir\en.json"
foreach ($kv in $EN.GetEnumerator()) { Set-JsonKey -FilePath $enFile -Key $kv.Key -Value $kv.Value }
Write-Host "Updated en.json"

# ---------------------------------------------------------------------------
# Apply FR
# ---------------------------------------------------------------------------

$frFile = "$LocalesDir\fr.json"
foreach ($kv in $FR.GetEnumerator()) { Set-JsonKey -FilePath $frFile -Key $kv.Key -Value $kv.Value }
Write-Host "Updated fr.json"

# ---------------------------------------------------------------------------
# Apply EN values to the 19 other locales (EN fallback)
# ---------------------------------------------------------------------------

$others = @("ar","cs","da","de","es","he","hi","it","ja","ko","nl","no","pl","pt","ru","sv","tr","uk","zh")
foreach ($code in $others) {
    $f = "$LocalesDir\$code.json"
    foreach ($kv in $EN.GetEnumerator()) { Set-JsonKey -FilePath $f -Key $kv.Key -Value $kv.Value }
    Write-Host "Updated $code.json"
}

Write-Host "`nDone."

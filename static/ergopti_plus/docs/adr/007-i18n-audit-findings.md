# ADR 007 — i18n Audit Findings (1.3.6)

**Date:** 2026-05-26  
**Status:** Partially resolved — AHK startup MsgBox still pending (see Cluster C)

---

## Context

Item 1.3.6 of the hexagonal-architecture sprint requires an audit of every
user-visible string to verify it flows through the i18n system (`i18n.get()`)
rather than being hardcoded in source files.

The project rule (copilot-instructions §1) states: *"ONLY user-facing text must
be written in French"*, and by implication all UI strings must be internationalised
through the 21-language i18n table — never hardcoded.

---

## Findings

### Cluster A — `ui/menu/menu_about.lua` (8 violations, English)

All eight `hs.dialog.alert(...)` calls in `check_for_update()` contain hardcoded
English strings. None pass through `i18n.get()`.

| Line | String (truncated) |
|------|--------------------|
| 117 | "Running from local source — update checking…" |
| 124 | "Could not reach GitHub.\nCheck your internet…" |
| 129 | "Could not parse the latest release tag…" |
| 133 | "ErgoptiPlus is up to date.\n\nCurrent version: " |
| 136 | "A new version is available!\n\nCurrent: " |
| 154 | "Could not reach GitHub…" (duplicate) |
| 160 | "Could not retrieve release information from GitHub." |
| 165 | (another release dialog, hardcoded) |

**Fix:** add i18n keys `menu.about.update.*` covering all eight message variants;
replace hardcoded strings with `i18n.get("menu.about.update.up_to_date")` etc.

---

### Cluster B — `modules/karabiner/onboarding.lua` (~5 violations, French)

The Karabiner onboarding error-path calls `callback(false, "…")` and
`hs.alert.show("…")` with hardcoded French strings.

| Approx. line | String |
|--------------|--------|
| 533 | "• Karabiner-Elements n'est pas installé" |
| 545 | "• L'extension système (DriverKit) n'est pas activée" |
| 553 | "\n\nL'application va être téléchargée depuis le dépôt officiel…" |
| ~561 | "Manifest non configuré (champs TODO)." |
| ~563 | "Mount échoué : " + err |

**Fix:** add i18n keys `karabiner.onboarding.error.*`; route through `i18n.get()`.

---

### Cluster C — `ErgoptiPlus.ahk` (1 MsgBox + 3–4 French log messages)

| Line | Issue | Status |
|------|-------|--------|
| 603–605 | `MsgBox(…"Erreur de démarrage : …", "ErgoptiPlus — manifest manquant"…)` — hardcoded French UI | **Pending** — will be fixed in a dedicated commit |
| 883–894 | Log messages in French ("ignoré", "enregistré", "Échec") — violates log rule (§4.4: English-only logs) | Fixed |

**Fix for MsgBox:** move to a dedicated startup error handler; use i18n key
`startup.manifest_missing`. **Fix for logs:** translate to English in place
(no i18n needed — logs are developer-facing).

> **Note (2026-05-28):** The French `MsgBox` at `windows/ErgoptiPlus.ahk:603–605`
> is the sole remaining violation. It will be resolved in a follow-up commit
> once the startup error handler is in place.

---

### Minor — `modules/karabiner/ke_lifecycle.lua`

One callback string: `"Karabiner-Elements non disponible — vérifier l'installation."`.
Should be `i18n.get("karabiner.lifecycle.unavailable")`.

---

## Total violation count

| Category | Count |
|----------|-------|
| HS `hs.dialog.alert` hardcoded | 8 |
| HS `hs.alert.show` / callback hardcoded | 5 |
| AHK `MsgBox` hardcoded | 1 |
| AHK French log messages | 3 |
| **Total** | **17** |

---

## Decision

These violations are tracked here and will be fixed in a dedicated i18n pass.
Priority order:

1. **AHK logs in French** (§4.4 violation) — fix in-place, no i18n infrastructure needed.
2. **`menu_about.lua`** — highest user-facing impact; needs new i18n keys.
3. **`karabiner/onboarding.lua`** — error path rarely triggered; fix after menu_about.
4. **`ErgoptiPlus.ahk` MsgBox** — fatal startup error; low priority (only shown once, before i18n is loaded).

---

## References

- copilot-instructions §1 Language Enforcement
- copilot-instructions §4.4 Log Level Language rule
- Sprint item 1.3.6 — i18n audit

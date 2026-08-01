; infra/hotstrings/hotstring_live_toggle.ahk

; ==============================================================================
; MODULE: Hotstring Live-Toggle Classification
; DESCRIPTION:
; Classifies which hotstring section toggles can be applied LIVE versus which
; must still trigger a full script Reload.
;
; Since the registration is wrapped into a single re-runnable
; RegisterAllHotstrings() function, the live path no longer splices individual
; HSE groups; it clears the engine and re-runs the whole registration in-process
; (RebuildHotstringsLive in tray_menu.ahk). Re-running re-evaluates every
; "if Features[...]" guard, so cross-dependencies (sfbs_reduction.bu reads
; magic_key.text_expansion), inline-generated sections (comma_j, rolls operators)
; and the boot-captured SpaceAroundSymbols all resolve correctly. So ALL hotstring
; sections are live-eligible BY DEFAULT.
;
; The exceptions kept reload-only:
;   1. Ê deadkey and "…" multiple-punctuation — now HSE raw-callback hotstrings
;      (migrated off the native AHK Hotstring() engine), so RegisterAllHotstrings
;      DOES re-register them on a live rebuild. They are kept reload-only as a
;      conservative default: their context-conditional dispatch is new on the HSE
;      path, so toggling them takes the proven Reload route until verified live.
;   2. magic_key.replace — the magic-key remap (J → ★). It lives under
;      "hotstrings.*" but is a LAYOUT feature (modules/keymap/layout.ahk RemapKey at
;      boot), so a hotstring rebuild does nothing for it.
;
; FEATURES & RATIONALE:
; 1. Inverted model: everything is live unless explicitly blocklisted. A new
;    HSE section is automatically live-eligible — no whitelist entry to forget.
; 2. Fail-safe blocklist: the reload-only groups are pinned by exact id, so a
;    native or layout-backed feature can never be toggled live.
; 3. Pure and dependency-light: the blocklist and helpers below touch no menu,
;    no path translator and no OS API, so they are unit-testable in isolation
;    (tests/test_hotstring_live_toggle.ahk) without loading the tray menu.
; ==============================================================================





; =============================================
; =============================================
; ======= 1/ Reload-Only Blocklist ============
; =============================================
; =============================================

; HSE group strings ("<loader_category>.<section>") that must NOT be toggled live
; because RegisterAllHotstrings does not apply them via the live rebuild, so an
; in-process rebuild has no effect and they still need a Reload. The loader
; category drops underscores from the v2 category (distances_reduction ->
; distancesreduction); the section id keeps its underscores. Everything NOT listed
; here is live-eligible.
global _HS_RELOAD_ONLY_GROUPS := Map(
	"distancesreduction.dead_key_e_circumflex",  true,  ; HSE raw-callback; reload-only (conservative)
	"autocorrection.multiple_punctuation_marks", true,  ; HSE raw-callback; reload-only (conservative)
	"magickey.replace",                          true,  ; layout remap (J -> star), not a hotstring
)





; =====================================
; =====================================
; ======= 2/ Pure Helpers =============
; =====================================
; =====================================

; Derive the HSE group string from a v2 manifest category and section id.
; The loader category drops the underscores from the v2 category so it matches
; the LoadHotstringsSection / generated-loader naming.
; @param V2CategoryUnderscored {String} v2 category, e.g. "distances_reduction".
; @param Section {String} v2 section id, e.g. "qu".
; @returns {String} HSE group, e.g. "distancesreduction.qu".
_HS_DeriveLiveToggleGroup(V2CategoryUnderscored, Section) {
	return StrReplace(V2CategoryUnderscored, "_", "") . "." . Section
}

; Returns true when Group is not applied by the live rebuild (native-engine or
; layout-backed) and therefore must take the Reload path instead.
; @param Group {String} HSE group string ("<loader_category>.<section>").
; @returns {Boolean}
_HS_IsReloadOnlyGroup(Group) {
	global _HS_RELOAD_ONLY_GROUPS
	return _HS_RELOAD_ONLY_GROUPS.Has(Group)
}

; Returns true when FullPath is a personal hotstring section ("Personal.<id>"),
; which is always live-eligible: personal sections are loaded purely via
; LoadHotstringsSection with no cross-feature dependency.
; @param FullPath {String} v1 dotted feature path.
; @returns {Boolean}
_HS_IsPersonalLiveToggle(FullPath) {
	Parts := StrSplit(FullPath, ".")
	return (Parts.Length == 2 and Parts[1] == "Personal")
}

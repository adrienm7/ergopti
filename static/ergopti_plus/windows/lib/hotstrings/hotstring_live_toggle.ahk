; static/ergopti_plus/windows/lib/hotstrings/hotstring_live_toggle.ahk

; ==============================================================================
; MODULE: Hotstring Live-Toggle Whitelist
; DESCRIPTION:
; Classifies which hotstring section toggles can be applied LIVE (enable or
; disable a HSE group at runtime, with no script Reload) versus which must
; still trigger a full Reload.
;
; Only sections registered PURELY via LoadHotstringsSection are eligible: a
; single TOML section, with no inline supplemental CreateHotstring calls, no
; cross-feature dependency, and no boot-captured global (SpaceAroundSymbols,
; the magic key, resolved per-category delays). Everything else stays on the
; Reload path: inline-generated sections (comma_j, rolls operators, dynamic
; dates / phone / SSN / IBAN), dependency targets (magic_key.text_expansion is
; read by the sfbs_reduction.bu block), and the non-hotstring categories
; (layout, tap-holds, shortcuts, gestures).
;
; FEATURES & RATIONALE:
; 1. Fail-safe by omission: an unlisted group is never toggled live, so a
;    misclassification degrades to the correct Reload path, never to a silent
;    no-op or a stale expansion. The caller adds a second guard (the group must
;    actually exist in the HSE registry before a live disable) so an id mismatch
;    also degrades to Reload.
; 2. Pure and dependency-light: the whitelist and helpers below touch no menu,
;    no path translator and no OS API, so they are unit-testable in isolation
;    (tests/test_hotstring_live_toggle.ahk) without loading the tray menu.
; 3. Single source of truth: tray_menu.ahk derives a "<category>.<section>"
;    group from a feature path and asks this module whether it is eligible.
; ==============================================================================





; =============================================
; =============================================
; ======= 1/ Live-Toggle Whitelist ============
; =============================================
; =============================================

; HSE group strings ("<loader_category>.<section>") that are safe to enable or
; disable live. The loader category is the LoadHotstringsSection name: the v2
; category with underscores removed (distances_reduction -> distancesreduction,
; sfbs_reduction -> sfbsreduction, magic_key -> magickey). Personal sections are
; handled separately (always eligible) and are deliberately not listed here.
;
; A section is listed ONLY when its entire registration in modules/hotstrings.ahk
; is a single LoadHotstringsSection call with a standalone "enabled" guard.
global _HS_LIVE_TOGGLE_GROUPS := Map(
	"distancesreduction.qu",                  true,
	"distancesreduction.e_circumflex_e",      true,
	"distancesreduction.suffixes_a",          true,
	"sfbsreduction.comma",                    true,
	"sfbsreduction.e_circ",                   true,
	"sfbsreduction.e_grave",                  true,
	"rolls.close_chevron_tag",                true,
	"rolls.ez",                               true,
	"rolls.comment_open",                     true,
	"rolls.comment_close",                    true,
	"rolls.hashtag_parenthesis",              true,
	"rolls.hashtag_open_bracket",             true,
	"rolls.hashtag_close_bracket",            true,
	"rolls.hc",                               true,
	"rolls.sx",                               true,
	"rolls.cx",                               true,
	"rolls.ct",                               true,
	"autocorrection.errors",                  true,
	"autocorrection.ou",                      true,
	"autocorrection.suffixes_a_chaining",     true,
	"autocorrection.minus",                   true,
	"autocorrection.minus_apostrophe",        true,
	"autocorrection.names",                   true,
	"autocorrection.accents",                 true,
	"magickey.text_expansion_auto",           true,
	"magickey.text_expansion_emojis",         true,
	"magickey.text_expansion_symbols",        true,
	"magickey.text_expansion_symbols_typst",  true,
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

; Returns true when Group is a bundled section that may be toggled live.
; @param Group {String} HSE group string ("<loader_category>.<section>").
; @returns {Boolean}
_HS_IsLiveToggleGroup(Group) {
	global _HS_LIVE_TOGGLE_GROUPS
	return _HS_LIVE_TOGGLE_GROUPS.Has(Group)
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

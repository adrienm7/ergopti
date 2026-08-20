; modules/hotstrings.ahk

; ==============================================================================
; MODULE: Hotstrings (orchestrator shim)
; DESCRIPTION:
; Entry-point for the hotstring registration subsystem. Declares
; RegisterAllHotstrings(), the single function called by ErgoptiPlus.ahk at boot
; and on every live menu toggle, which orchestrates all category sub-registrars.
; The actual registration logic lives in the sub-modules below:
;   hotstrings/hotstrings_distances.ahk    — distances + SFBs + rolls.
;   hotstrings/hotstrings_autocorrection.ahk — autocorrection categories.
;   hotstrings/hotstrings_text_expansion.ahk — text expansion (magic-key entries).
;   hotstrings/hotstrings_personal.ahk     — personal + extension TOML files.
;   hotstrings/hotstrings_helpers.ahk      — deferred emoji pass + deadkey helpers.
;   ../dynamic_hotstrings/dynamic_hotstrings.ahk — dates + phone/SSN/IBAN prefixes,
;     the folder name macOS and Linux already use for the same behaviour.
; ==============================================================================

#Include hotstrings\hotstrings_distances.ahk
#Include hotstrings\hotstrings_autocorrection.ahk
#Include hotstrings\hotstrings_text_expansion.ahk
#Include hotstrings\hotstrings_personal.ahk
#Include hotstrings\hotstrings_helpers.ahk
; Sibling folder, not a hotstrings/ sub-file: the three drivers name this
; subsystem modules/dynamic_hotstrings/ and the tree-parity gate counts it.
#Include dynamic_hotstrings\dynamic_hotstrings.ahk





; ============================================================
; ============================================================
; ======= 1/ RegisterAllHotstrings — main orchestrator =======
; ============================================================
; ============================================================

; Registers every hotstring category into the engine. Wrapped in a function so
; the whole registration can be re-run in-process (live menu toggles) instead of
; restarting the script via Reload. Called once at boot from ErgoptiPlus.ahk
; right after the #Include, and again on every live hotstring toggle.
;
; ``DeferHeavy`` remains for compatibility with explicit live callers. The boot
; passes false: the driver may publish ready only after every advertised trigger
; and its preview index are available. A live rebuild also passes false so it
; atomically returns a complete registry.
RegisterAllHotstrings(DeferHeavy := false) {
	global Features, ScriptInformation, PersonalInformation, PersonalInformationLetters
	global DeadkeyMappingCircumflex, SpaceAroundSymbols, PersonalInformationHotstrings

	if (!DeferHeavy) {
		try SetTimer(RegisterEmojisSymbolsDeferred, 0)
	}

	; Recompute SpaceAroundSymbols from the live Features on every run, so a live
	; toggle of distances_reduction.space_around_symbols re-bakes the rolls operator
	; replacements (":=", "->", …) with the new spacing — a cross-dependency that
	; would otherwise need a Reload. At boot this reproduces the exact value
	; ErgoptiPlus.ahk computed just before the #Include.
	_SpaceNode := (Features.Has("hotstrings")
		and Features["hotstrings"].Has("distances_reduction")
		and Features["hotstrings"]["distances_reduction"].Has("space_around_symbols"))
		? Features["hotstrings"]["distances_reduction"]["space_around_symbols"]
		: Map()
	SpaceAroundSymbols := (_SpaceNode.Has("enabled") and _SpaceNode["enabled"]) ? " " : ""

	_HS_RegisterDistancesAndRolls()
	_HS_RegisterAutocorrection()
	_HS_RegisterTextExpansionAndDynamic(DeferHeavy)
	_HS_RegisterPersonal()
}

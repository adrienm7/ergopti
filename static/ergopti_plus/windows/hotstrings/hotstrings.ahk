; hotstrings/hotstrings.ahk

; ==============================================================================
; MODULE: Hotstrings (orchestrator shim)
; DESCRIPTION:
; Entry-point for the hotstring registration subsystem. Declares
; RegisterAllHotstrings(), the single function called by ErgoptiPlus.ahk at boot
; and on every live menu toggle, which orchestrates all category sub-registrars.
; The actual registration logic lives in the sub-modules below:
;   engine/catalogue/distances.ahk    — distances + SFBs + rolls.
;   engine/catalogue/autocorrection.ahk — autocorrection categories.
;   engine/catalogue/text_expansion.ahk — text expansion (magic-key entries).
;   engine/catalogue/personal.ahk     — personal + extension TOML files.
;   engine/catalogue/helpers.ahk      — deferred emoji pass + deadkey helpers.
;   ../dynamic_hotstrings/dynamic_hotstrings.ahk — dates + phone/SSN/IBAN prefixes,
;     the folder name macOS and Linux already use for the same behaviour.
; ==============================================================================

#Include %A_LineFile%\..\..\_generated\config_keys.ahk
#Include engine\catalogue\distances.ahk
#Include engine\catalogue\autocorrection.ahk
#Include engine\catalogue\text_expansion.ahk
#Include engine\catalogue\personal.ahk
#Include engine\catalogue\helpers.ahk
; Sibling folder, not a hotstrings/ sub-file: the three drivers name this
; subsystem hotstrings/engine/dynamic/ and the tree-parity gate counts it.
#Include engine\dynamic\hotstrings.ahk
#Include engine\dynamic\user_code.ahk





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
; ``DeferHeavy`` is the boot's: the emoji and symbol sections keep their rank but
; register after ready, in slices (RegisterEmojisSymbolsDeferred), and the boot
; starts them once ready. A live rebuild passes false so it atomically returns a
; complete registry, and drops a deferred job still pending. ColdBoot is reserved
; for the sole startup call: unavailable common families are classified while
; unrelated registrars still run. Live callers refuse before the first registry
; mutation.
RegisterAllHotstrings(DeferHeavy := false, ColdBoot := false) {
	global Features, ScriptInformation, PersonalInformation, PersonalInformationLetters
	global DeadkeyMappingCircumflex, SpaceAroundSymbols, PersonalInformationHotstrings
	global _HotstringExtensionPacks

	CommonRefusal := HotstringsCommonAdmissionRefusal(Features)
	if CommonRefusal != "" && !ColdBoot {
		try LoggerError("Hotstrings", CommonRefusal)
		return false
	}

	if (!DeferHeavy) {
		HSE_DeferredRegistrationCancel()
	}

	; Recompute SpaceAroundSymbols from the live Features on every run, so a live
	; toggle of distances_reduction.space_around_symbols re-bakes the rolls operator
	; replacements (":=", "->", …) with the new spacing — a cross-dependency that
	; would otherwise need a Reload. At boot this reproduces the exact value
	; ErgoptiPlus.ahk computed just before the #Include.
	_SpaceNode := (Features.Has("hotstrings")
		and Features["hotstrings"].Has(ConfigLeaf.DISTANCES_REDUCTION)
		and Features["hotstrings"][ConfigLeaf.DISTANCES_REDUCTION].Has("space_around_symbols"))
		? Features["hotstrings"][ConfigLeaf.DISTANCES_REDUCTION]["space_around_symbols"]
		: Map()
	SpaceAroundSymbols := (_SpaceNode.Has("enabled") and _SpaceNode["enabled"]) ? " " : ""

	_HS_RegisterDistancesAndRolls()
	_HS_RegisterAutocorrection()
	_HS_RegisterTextExpansionAndDynamic(DeferHeavy)
	_HS_RegisterPersonal()
	HotstringExtensions_Register(Features, _HotstringExtensionPacks, IsCategoryGated("Hotstrings"))
	UserHotstringsInit()
	if ColdBoot
		return Map("committed", true, "complete", CommonRefusal == "",
			"unavailable", CommonRefusal == "" ? [] : ["autocorrection"])
	return true
}

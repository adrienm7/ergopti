; tests/meta/test_text_expansion_critical_path.ahk

; ==============================================================================
; MODULE: Text-Expansion On-Critical-Path Test
; DESCRIPTION:
; Guards that the magic-key text-expansion sections register ON the boot critical
; path (unconditionally, not behind DeferHeavy), while the emoji/symbol sections
; stay deferred off it.
;
; WHY THIS MATTERS (the regression this encodes):
;   text_expansion is the MOST-USED feature (more than the rolls). It was briefly
;   deferred off the boot path as a time-to-ready optimization, but that made the
;   most-used feature the LAST to come online and ran its ~240 ms registration on
;   a post-"ready" timer that could freeze the single thread mid-keystroke. It now
;   registers at boot so "ready" means the user's everyday expansions already work.
;   Only the truly heavy + rarely-instant emoji/symbol categories remain deferred.
;   If a future edit re-gates text_expansion behind DeferHeavy (re-deferring it),
;   the most-used feature silently goes offline for the first ~half second after
;   boot: exactly the regression this test makes loud.
;
; SCOPE: source introspection of modules/hotstrings.ahk and its modules/hotstrings/
;   sub-modules (the registration module the headless runner does not load). The
;   god-file split (334b5c04a) moved the section-loader helpers and the 4.3-4.5
;   subsections out of the shim into modules/hotstrings/*.ahk, so the shim alone
;   no longer contains them -- concatenate shim + sub-dir like every other
;   introspection test does for a module the split touched.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckTextExpansionOnCriticalPath() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	HsFile := WindowsDir . "\modules\hotstrings.ahk"

	Body := ""
	try Body := FileRead(HsFile)
	Assert(Body != "", "modules\hotstrings.ahk must be readable for the text-expansion critical-path meta-test")
	; The shim itself only #Includes the sub-modules now -- fold in modules/hotstrings/
	; (hotstrings_helpers.ahk + hotstrings_text_expansion.ahk) so the assertions below
	; see the same source the running driver actually loads.
	Body .= _DriverDirConcat("modules/hotstrings")

	; The shared section loader must exist and load the magickey.text_expansion section.
	Assert(InStr(Body, "_RegisterTextExpansionSections("),
		"hotstrings.ahk must define _RegisterTextExpansionSections() shared by boot + live rebuild")
	Assert(InStr(Body, 'LoadHotstringsSection("magickey", "text_expansion"') > 0,
		"the text-expansion loader must load the magickey.text_expansion section")

	; The deferred orchestrator must be GONE (text_expansion is no longer deferred).
	Assert(!InStr(Body, "RegisterTextExpansionDeferred"),
		"RegisterTextExpansionDeferred() must be removed -- text_expansion registers on the critical path now")

	; text_expansion (section 4.3) must register UNCONDITIONALLY: between the 4.3
	; header and its BootProfile mark there must be NO 'if !DeferHeavy' gate. The
	; first DeferHeavy gate after the 4.3 header is the EMOJI gate, which sits AFTER
	; the text_expansion mark -- so GatePos > MarkPos proves 4.3 is ungated.
	HeaderPos := InStr(Body, "4.3) Text expansion")
	Assert(HeaderPos > 0, "hotstrings.ahk must keep the 4.3 Text expansion subsection header")
	MarkPos := InStr(Body, "magickey text_expansion registered")
	Assert(MarkPos > HeaderPos,
		"the 'magickey text_expansion registered' BootProfile mark must follow the 4.3 header")
	GatePos := InStr(Body, "if !DeferHeavy", , HeaderPos)
	Assert(GatePos > MarkPos,
		"text_expansion (section 4.3) must NOT sit behind 'if !DeferHeavy' -- it registers on the "
		. "boot critical path. The next DeferHeavy gate must be the emoji/symbol one, after the mark.")

	; Emoji/symbols must STAY deferred: the deferred orchestrator exists and the
	; 4.4-4.5 section keeps its DeferHeavy gate.
	Assert(InStr(Body, "RegisterEmojisSymbolsDeferred("),
		"hotstrings.ahk must keep RegisterEmojisSymbolsDeferred() -- emoji/symbols stay off the critical path")
	Assert(InStr(Body, "_RegisterEmojisSymbolsSections("),
		"hotstrings.ahk must keep _RegisterEmojisSymbolsSections() shared by boot-defer + live rebuild")
}

Test("meta hotstrings: text_expansion on the boot critical path, emoji/symbols deferred",
	_MetaCheckTextExpansionOnCriticalPath)

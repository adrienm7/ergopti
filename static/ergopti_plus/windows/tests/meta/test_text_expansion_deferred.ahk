; tests/meta/test_text_expansion_deferred.ahk

; ==============================================================================
; MODULE: Text-Expansion Deferred-Registration Test
; DESCRIPTION:
; Guards that the magic-key text-expansion sections register OFF the boot
; critical path (the single heaviest category, ~2119 case variants / ~1.36 s),
; mirroring the emoji/symbol deferral.
;
; WHY THIS MATTERS (the regression this encodes):
;   text_expansion was the dominant time-to-ready cost. It is now skipped on the
;   boot pass (RegisterAllHotstrings DeferHeavy = true) and loaded a moment after
;   "ready" by RegisterTextExpansionDeferred(). If a future edit re-registers it
;   inline on the boot pass, time-to-ready regresses by ~1.36 s with no error:
;   exactly the silent slowdown this test makes loud.
;
; SCOPE: source introspection of modules/hotstrings.ahk (the registration module
;   the headless runner does not load). The matching deferred timer is armed after
;   "ready"; that ordering is enforced separately by test_boot_deferred_tasks.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckTextExpansionDeferred() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	HsFile := WindowsDir . "\modules\hotstrings.ahk"

	Body := ""
	try Body := FileRead(HsFile)
	Assert(Body != "", "modules\hotstrings.ahk must be readable for the text-expansion deferred meta-test")

	; The deferred orchestrator + its shared section loader must exist.
	Assert(InStr(Body, "RegisterTextExpansionDeferred("),
		"hotstrings.ahk must define RegisterTextExpansionDeferred() (the off-path text-expansion pass)")
	Assert(InStr(Body, "_RegisterTextExpansionSections("),
		"hotstrings.ahk must define _RegisterTextExpansionSections() shared by boot-defer and live rebuild")

	; The shared loader must actually register the text_expansion section. Single-quoted
	; literal so the embedded double quotes need no backtick escape.
	Assert(InStr(Body, 'LoadHotstringsSection("magickey", "text_expansion"') > 0,
		"the text-expansion pass must load the magickey.text_expansion section")

	; The inline section-4.3 registration must be gated so the BOOT pass skips it:
	; between the 4.3 header and its BootProfile mark there must be an if !DeferHeavy.
	; InStr from HeaderPos finds the text_expansion gate first (the emoji gate sits
	; AFTER the mark), so GatePos < MarkPos proves the boot pass skips text_expansion.
	HeaderPos := InStr(Body, "4.3) Text expansion")
	Assert(HeaderPos > 0, "hotstrings.ahk must keep the 4.3 Text expansion subsection header")
	MarkPos := InStr(Body, "magickey core (text_expansion) registered")
	Assert(MarkPos > HeaderPos,
		"the 'magickey core (text_expansion) registered' BootProfile mark must follow the 4.3 header")
	GatePos := InStr(Body, "if !DeferHeavy", , HeaderPos)
	Assert(GatePos > 0 and GatePos < MarkPos,
		"the inline text_expansion registration must sit behind 'if !DeferHeavy' so the boot pass "
		. "(DeferHeavy = true) skips it and the deferred pass loads it off the critical path")
}

Test("meta hotstrings: text_expansion registered off the boot critical path",
	_MetaCheckTextExpansionDeferred)

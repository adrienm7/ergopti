; tests/meta/test_altgr_rolls_precedence.ahk

; ==============================================================================
; MODULE: AltGr Rolls Registration-Precedence Guard Meta Test
; DESCRIPTION:
; Static source guard for the altgr-rolls-dead-precedence finding.
;
; The two AltGr rolls (SC138 & SC012 chevron_equal, SC138 & SC017 hashtag_quote /
; paren_quote / bracket_quote) bind the SAME custom-combination chords that the
; ErgoptiAltGr base rows bind. AHK fires the MOST-RECENTLY-registered variant
; whose #HotIf criterion is true. The rolls were registered FIRST (lowest
; precedence), so in the default config the base-row variant always won and the
; roll handlers (_RollChevronEqualHandler / _RollHashtagQuoteHandler) never ran —
; the whole roll feature set was silently dead and its menu toggles inert.
;
; The fix registers the AltGr layer FIRST and the rolls LAST, so the roll variant
; wins the shared chord. The roll handlers already replicate the exact base-row /
; override fallback, so the non-roll output is unchanged.
;
; Meta-static (scans source text) because modules/keymap/layout.ahk registers top-level
; hotkeys and is not #Included by the headless runner, and the live SC138-prefix
; variant precedence cannot be exercised without a physical AltGr/Kana key. The
; regression is locked by asserting the registration ORDER the precedence rule
; depends on.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; ==================================================
; ==================================================
; ======= 2/ Registration-order assertion ==========
; ==================================================
; ==================================================

; Position of the bare CALL line "Name()" (flush-left, own line). The multiline
; anchors exclude the "Name() {" definition (line does not end after the parens)
; and any "; ... Name() ..." comment (line does not start with the call).
_ARP_CallLinePos(Src, Name) {
	if RegExMatch(Src, "m)^" . Name . "\(\)\s*$", &M)
		return M.Pos
	return 0
}

_ARP_RollsRegisteredLast() {
	; Move-resilient: both call sites live in modules/keymap/layout.ahk; scope to the
	; modules tree so their relative registration order is preserved in the concat
	Src := _DriverDirConcat("modules")
	PosLayer := _ARP_CallLinePos(Src, "RegisterAltGrLayer")
	PosRolls := _ARP_CallLinePos(Src, "_RegisterRollsAltGrHotkeys")
	Assert(PosLayer > 0, "RegisterAltGrLayer() call site must exist in modules/keymap/layout.ahk")
	Assert(PosRolls > 0, "_RegisterRollsAltGrHotkeys() call site must exist in modules/keymap/layout.ahk")
	Assert(PosLayer < PosRolls,
		"RegisterAltGrLayer() must be called BEFORE _RegisterRollsAltGrHotkeys() so the rolls are the most-recently-registered (highest-precedence) variant on SC138 & SC012 / SC138 & SC017 — otherwise the base rows shadow the rolls and the roll feature is silently dead (altgr-rolls-dead-precedence)")
}
Test("layout: AltGr rolls are registered LAST so they outrank the base rows (altgr-rolls-dead-precedence)", _ARP_RollsRegisteredLast)

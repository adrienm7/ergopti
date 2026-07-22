; tests/meta/test_dead_state_and_single_source.ahk

; ==============================================================================
; MODULE: Dead State & Single-Source Meta Test
; DESCRIPTION:
; Four small defects of two shared shapes, each one a lie the source told a
; reader:
;
;   WRITE-ONLY STATE (conventions 5.6). _TooltipPendingGeneration was
;   incremented at two sites and read at none, so it looked like the tooltip's
;   generation-counter discipline applied to the deferred path when it did not —
;   the actual guard is _TooltipPendingActive plus a timer cancel. REG_NOT_FOUND
;   was documented as "the sentinel Reg_Read returns", which Reg_Read never
;   returns; storage.ahk declares its own STORAGE_REG_NOT_FOUND instead.
;
;   DUPLICATED CONSTANTS (conventions 5.2). The deferred app-category save was
;   extracted into DEFERRED_SAVE_RETRY_MS but only one of its two arm sites was
;   migrated, leaving a bare -5000 that would not follow the constant. The
;   hotstring preview boundaries were extracted into
;   HOTSTRINGS_QUOTE_WORD_BOUNDARIES, but the initialiser it came from still
;   spelled the characters out — so the initial value and every later refresh
;   could disagree about what counts as a word boundary.
;
; FEATURES & RATIONALE:
; A partially-applied extraction is worse than none: the constant's existence
; advertises a single source of truth that does not hold, and the site that was
; left behind is invisible precisely because the refactor looks finished.
;
; SCOPE: source introspection of the driver via the move-resilient helpers.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ==============================================
; ======= 1/ Deleted state stays deleted =======
; ==============================================
; ============================================

_DSSS_NoResurrectedDeadState() {
	Src := _DriverSourceNoComments()

	Assert(InStr(Src, "_TooltipPendingGeneration") == 0,
		"_TooltipPendingGeneration is write-only state that was removed — reintroducing it implies the deferred tooltip path validates a generation, which it does not; the real guard is _TooltipPendingActive plus the timer cancel")
	; Anchored on a non-identifier character so the sibling STORAGE_REG_NOT_FOUND,
	; which is a real and consumed constant, does not match as a substring.
	Assert(RegExMatch(Src, "(^|[^A-Za-z0-9_])REG_NOT_FOUND\s*:=") == 0,
		"REG_NOT_FOUND was a documented-but-dead sentinel: Reg_Read never returned it and nothing consumed it. If a real sentinel is wanted, give Reg_Read the default and have storage.ahk consume it rather than declaring its own")
}




; ==============================================
; ==============================================
; ======= 2/ Extractions are complete ==========
; ==============================================
; ==============================================

; Both arm sites of the deferred app-category save must follow the constant.
; Migrating one of two is how a "single source of truth" silently becomes two.
_DSSS_DeferredSaveRetryIsSingleSourced() {
	Src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(Src, "DEFERRED_SAVE_RETRY_MS := 5000") > 0,
		"prerequisite: the deferred-save retry constant must still be declared")

	Bare := 0
	Pos := 1
	while (Pos := InStr(Src, "KLAppCat.save_fn, -", , Pos)) {
		Tail := SubStr(Src, Pos, 60)
		if (InStr(Tail, "DEFERRED_SAVE_RETRY_MS") == 0)
			Bare += 1
		Pos += 20
	}
	Assert(Bare == 0,
		"every deferred app-category save must arm with KLAppCatConst.DEFERRED_SAVE_RETRY_MS (found " . Bare . " bare literal(s)) — a site left behind will not follow the constant when it is tuned")
}

; The preview-boundary initialiser must build from the extracted constant, not
; respell the characters. Two spellings can drift, and then the boundary set
; differs between boot and the first refresh.
_DSSS_PreviewBoundariesUseTheConstant() {
	Src := _DriverSourceNoComments()

	Assert(InStr(Src, "HOTSTRINGS_QUOTE_WORD_BOUNDARIES :=") > 0,
		"prerequisite: the extracted boundary constant must still be declared")
	; Within the hotstrings layer the quote codepoints must be spelled exactly
	; once — in the boundary constant. Respelling them recreates the original
	; defect: two spellings drift, and the tooltip then anchors on a set the
	; matcher does not gate on. Scoped to this layer because the keymap
	; legitimately spells the same codepoint for the AltGr key that TYPES a
	; curly quote, which has nothing to do with word boundaries.
	HsSrc := _DriverDirConcat("lib/hotstrings")
	Assert(HsSrc != "", "the hotstrings source must be readable")
	Spellings := 0
	Pos := 1
	while (Pos := InStr(HsSrc, "Chr(0x201C)", false, Pos)) {
		Spellings += 1
		Pos += 1
	}
	Assert(Spellings == 1,
		"the curly-quote boundary codepoint must be spelled exactly ONCE in lib/hotstrings (found " . Spellings . ") — a second spelling is how the preview and the matcher came to disagree about which characters open a word")

	; One derivation, referenced by both consumers. The constant is declared in
	; hotstring_engine_main.ahk rather than hotstrings_io.ahk on purpose: the
	; matcher gate reads it at auto-execute time, and hotstrings_io.ahk loads
	; later, so a reference there would be unassigned at boot and kill the driver
	; outright — verified by doing exactly that and watching the suite report
	; "FATAL STARTUP ERROR: This global variable has not been assigned a value."
	Derive := _DriverFuncBody("_HSE_WordBoundarySet")
	Assert(Derive != "", "_HSE_WordBoundarySet() must exist as the one derivation")
	Assert(InStr(Derive, "HOTSTRINGS_QUOTE_WORD_BOUNDARIES") > 0,
		"the one derivation must build the boundary set from HOTSTRINGS_QUOTE_WORD_BOUNDARIES")
	Assert(InStr(Derive, "HSE_WORD_TERMINATORS") > 0,
		"the one derivation must extend the LIVE terminator set, so a user delimiter override still takes effect")
}

; CB_Read's catch returned with no value at all, and three docstring sentences
; had lost their "" literals, leaving the module's documented contract
; unreadable ("yields  —"). An implicit empty return also breaks the file's own
; convention: every sibling returns its sentinel explicitly.
_DSSS_ClipboardReadReturnsExplicitEmpty() {
	Body := _DriverFuncBody("CB_Read")
	Assert(Body != "", "CB_Read() must exist in adapters/clipboard.ahk")
	Assert(RegExMatch(Body, 'return\s+""') > 0,
		"CB_Read's catch branch must return an explicit empty string — a bare `return` leaves the documented String contract to an implicit value and reads as an oversight")
}


Test("meta cleanup: removed write-only state is not resurrected",
	_DSSS_NoResurrectedDeadState)
Test("meta cleanup: the deferred-save retry window has one source",
	_DSSS_DeferredSaveRetryIsSingleSourced)
Test("meta cleanup: the preview boundaries build from the extracted constant",
	_DSSS_PreviewBoundariesUseTheConstant)
Test("meta cleanup: CB_Read returns an explicit empty string",
	_DSSS_ClipboardReadReturnsExplicitEmpty)

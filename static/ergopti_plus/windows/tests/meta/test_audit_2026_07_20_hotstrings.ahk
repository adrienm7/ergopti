; static/ergopti_plus/windows/tests/meta/test_audit_2026_07_20_hotstrings.ahk

; ==============================================================================
; MODULE: Audit 2026-07-20 (second pass) — hotstring findings F-02, F-03, F-04
; DESCRIPTION:
; Three defects in the hotstring engine, each a case of two code paths that had
; to agree about one fact and silently stopped agreeing.
;
; F-02  _PREFIX_WORD_BOUNDARIES was a top-level global built by concatenating
;       HSE_WORD_TERMINATORS at its own include position — a SNAPSHOT of the
;       compile-time constant. lib/boot.ahk then REPLACED HSE_WORD_TERMINATORS
;       with the catalogue-derived set and never recomputed the preview set. The
;       two diverged: the tooltip anchored on a set containing the apostrophe
;       while the matcher did not, so typing l'ame previewed âme and then simply
;       did not expand. No error, no log — the preview and the engine were
;       answering from different data. Fixed by DERIVING the preview set through
;       HotstringsRefreshPrefixBoundaries() instead of snapshotting it.
;
; F-03  The TOML `is_case_sensitive` flag was interpreted in OPPOSITE directions
;       by two groups of loaders. Generator semantics, documented at
;       hotstring_registry.ahk:132, are `is_case_sensitive = not case_sensitive`:
;       TRUE registers the literal trigger only, FALSE registers the cased family.
;       hotstrings_cache and personal_toml_io had it right; LoadHotstringsSection
;       and LoadExtTomlFile were inverted. Bundled categories short-circuit into
;       the cache registrar, so only personal + extension entries were affected —
;       the two paths with no corpus coverage. Symptom: the same entry registered
;       a different casing family depending on whether it came from boot or from
;       a live editor save, with the preview index disagreeing either way.
;
; F-04  HSE_TypoNbspStripped is set during end-char candidate DISCOVERY, before a
;       winner is known, but read by the dispatcher as if it described the WINNER.
;       When the star path won, the stale-but-true flag added one extra BackSpace
;       and ate the character typed before the trigger (a b Ê Shift+comma emitted
;       aU, instead of abU,). Silent because the emit and the buffer applied the
;       same +1, so no desync surfaced.
; ==============================================================================

#Requires AutoHotkey v2.0

_A0720HS_PrefixBoundariesAreDerived() {
	; STRONGER than the original assertion, which required a refresh FUNCTION to
	; recompute a cached preview global after every write to HSE_WORD_TERMINATORS.
	; That contract depended on every writer remembering to call it, and a second
	; divergence shipped anyway because the refresh derived from a WIDER expression
	; than the matcher gated on. There is now no cache to refresh: the preview and
	; the matcher both call _HSE_WordBoundarySet() on every read, which makes the
	; original bug unrepresentable rather than merely guarded.
	Assert(_DriverFuncBody("_HSE_WordBoundarySet") != "",
		"_HSE_WordBoundarySet() must exist as the single word-boundary derivation")

	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "globals+_PREFIX_WORD_BOUNDARIES") == 0,
		"the preview boundary set must not be a cached global again — both cached forms shipped a divergence (a compile-time snapshot, then a refreshed copy built from a different expression), each rendering suggestions the engine refused to fire")

	PreviewFn := _DriverFuncBody("_PrefixWordBoundaries")
	Assert(PreviewFn != "", "_PrefixWordBoundaries() must exist as the preview accessor")
	Assert(InStr(PreviewFn, "_HSE_WordBoundarySet()") > 0,
		"the preview accessor must delegate to the matcher derivation rather than compute its own")

	; And the values must actually agree at runtime, not merely share a call.
	Assert(_PrefixWordBoundaries() == _HSE_WordBoundarySet(),
		"the preview and the matcher must answer the word-boundary question identically")
}
Test("hotstrings: the preview boundary set is derived, never snapshotted (F-02)",
	_A0720HS_PrefixBoundariesAreDerived)


; Class-wide: no loader may open-code the branch again. This is the assertion
; that would have caught the original inversion, which a per-site test could not.
_A0720HS_AllLoadersShareTheCaseMapping() {
	Helper := _DriverFuncBody("HSE_RegisterFromTomlFlags")
	Assert(Helper != "",
		"HSE_RegisterFromTomlFlags must exist as the single source of truth for the is_case_sensitive -> registrar mapping")

	; TRUE must mean literal-only; FALSE must mean the cased family. Assert the
	; helper's own branch direction, since every loader now inherits it.
	TruePos := InStr(Helper, "CreateHotstring(")
	FalsePos := InStr(Helper, "CreateCaseSensitiveHotstrings(")
	Assert(TruePos > 0 and FalsePos > 0, "the helper must reference both registrars")
	Assert(TruePos < FalsePos,
		"HSE_RegisterFromTomlFlags must map is_case_sensitive=TRUE to CreateHotstring (literal trigger only) and FALSE to CreateCaseSensitiveHotstrings (cased family) — the generator convention is `is_case_sensitive = not case_sensitive`, documented at hotstring_registry.ahk:132")

	; No loader may BRANCH on the flag to pick a registrar — that branch is what
	; drifted. A flagless default is fine: LoadExtTomlFile's simple-entry form
	; (a bare trigger-equals-output pair, no is_case_sensitive field) legitimately registers
	; the cased family unconditionally, so this asserts the absence of the BRANCH,
	; not the absence of the registrar call.
	for _, Fn in ["LoadHotstringsSection", "LoadExtTomlFile", "_HsCacheRegisterSection", "ReloadPersonalSection"] {
		Body := _DriverFuncBody(Fn)
		if (Body == "")
			continue
		Assert(RegExMatch(Body, "if\s+IsCaseSens\b") = 0,
			Fn . " must not branch on IsCaseSens to choose a registrar — route through HSE_RegisterFromTomlFlags. Two of the four open-coded copies had drifted into opposite meanings, so the same entry registered a different casing family depending on which loader ran")
		Assert(RegExMatch(Body, 'if\s+E\["is_case_sensitive"\]') = 0,
			Fn . " must not branch on the entry is_case_sensitive key to choose a registrar — route through HSE_RegisterFromTomlFlags")
	}
}
Test("hotstrings: every loader shares one is_case_sensitive mapping (F-03)",
	_A0720HS_AllLoadersShareTheCaseMapping)


_A0720HS_NbspFlagDescribesTheWinner() {
	Body := _DriverFuncBody("HSE_FindMatchAtEnd")
	Assert(Body != "", "HSE_FindMatchAtEnd must exist in lib/hotstrings/hotstring_match.ahk")

	SetPos := InStr(Body, "HSE_TypoNbspStripped := true")
	Assert(SetPos > 0, "prerequisite: the end-char probe must still record the NBSP strip")

	; Search AFTER the set: the function already resets the flag on entry, so a
	; naive first-occurrence search finds that reset and proves nothing.
	ClearPos := InStr(Body, "HSE_TypoNbspStripped := false", , SetPos)
	Assert(ClearPos > SetPos,
		"HSE_FindMatchAtEnd must clear HSE_TypoNbspStripped when the STAR path wins — the flag is set during candidate DISCOVERY but read by the dispatcher as if it described the WINNER, so a star win carried a stale true and the extra BackSpace deleted the character typed before the trigger")

	ReturnPos := InStr(Body, "return BestMatch")
	Assert(ReturnPos > ClearPos,
		"the clear must happen before the function returns, at the one point where the winning candidate is known")

	; The clear must be conditional on a star win, not unconditional — clearing it
	; always would break the legitimate end-char case that consumed the NBSP.
	Assert(RegExMatch(Body, 'BestEndChar\s*==\s*""') > 0,
		"the clear must be gated on BestEndChar being empty (a star win); clearing unconditionally would drop the BackSpace the genuine end-char path needs")
}
Test("hotstrings: the NBSP-strip flag describes the winning candidate (F-04)",
	_A0720HS_NbspFlagDescribesTheWinner)

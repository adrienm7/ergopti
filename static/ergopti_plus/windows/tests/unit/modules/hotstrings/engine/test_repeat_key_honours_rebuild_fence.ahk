; tests/unit/modules/hotstrings/engine/test_repeat_key_honours_rebuild_fence.ahk

; ==============================================================================
; MODULE: Regression — the live-rebuild fence covers the repeat fallback too
;         (repeat-key-ignores-live-rebuild-fence)
; DESCRIPTION:
; Toggling a hotstring section from the tray runs RebuildHotstringsLive, which
; raises HSE_RebuildInProgress and then spends ~1.3 s rewriting the registry
; deliberately OUTSIDE Critical, so the user can keep typing. Its stated
; contract is that keystrokes "simply pass through unexpanded for the duration
; of the rebuild".
;
; ROOT CAUSE ENCODED: the fence was checked in exactly ONE place,
; HSE_FindMatchAtEnd. During a rebuild that function answers "" for every
; sequence — which means "the registry cannot answer right now", NOT "no
; trigger claims this". _OnPrefixChar cannot tell the two apart: it treats the
; empty match as a no-match and falls through to the engine-level repeat
; fallback, which has everything it needs (HSE_Buffer is still fed normally
; during the fence) and happily doubles the letter. So typing « at » + the
; magic key emitted « tt » instead of « attention » — positively wrong output
; rather than the pass-through the contract promises, and indistinguishable
; from a legitimate repeat in the logs.
;
; The guarantee is transitive across every site that turns a buffer into an
; expansion verdict, so the source half below loops the CLASS rather than
; naming the one function that was fixed.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every site that decides "what does this buffer expand to?". The fence has to
; hold at all of them: guarding only the matcher leaves the fallback free to
; emit different text for the whole rebuild window.
global _RKF_EXPANSION_DECISION_SITES := ["HSE_FindMatchAtEnd", "HSE_TryRepeatKey"]






; ==========================================================================
; ==========================================================================
; ======= 1/ Behavioural — the fallback stays silent under the fence =======
; ==========================================================================
; ==========================================================================

_RKF_Reset() {
	global HSE_Suppressed, HSE_RepeatEnabled, _PrefixWatcherSuppressed
	HSE_RegistryClear()
	HSE_Suppressed := 0
	if IsSet(_PrefixWatcherSuppressed)
		_PrefixWatcherSuppressed := 0
	HSE_RepeatEnabled := true
	HSE_HardReset()
	HSE_FeedReset(true)
}

_RKF_RepeatIsSilentDuringRebuild() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_RebuildInProgress
	MK := "★"
	_RKF_Reset()
	try {
		HSE_Register("*", "at" . MK, 0, Map("Replacement", "attention"))
		HSE_Buffer := "at" . MK
		HSE_StartIsWordBoundary := true

		; Sanity: with the registry available, this sequence IS one the repeat
		; fallback claims — so the assertion below is about the fence, not about
		; the fallback happening to refuse for an unrelated reason.
		Armed := HSE_TryRepeatKey(MK)
		Assert(IsObject(Armed),
			"sanity: the repeat fallback must claim <letter><magic key> mid-word when the registry is available — otherwise the fence assertion below could pass for the wrong reason")

		HSE_RebuildInProgress := true
		Fenced := HSE_TryRepeatKey(MK)
		Assert(!IsObject(Fenced) and Fenced == "",
			"the repeat fallback must stay silent while HSE_RebuildInProgress is raised. During a live rebuild an empty match means the registry cannot answer, not that no trigger claims the sequence, so doubling the letter replaces the expansion the user asked for with different text for the ~1.3 s the registry is being rewritten")
	} finally {
		HSE_RebuildInProgress := false
		_RKF_Reset()
	}
}
Test("hotstrings: the repeat fallback honours the live-rebuild fence (repeat-key-ignores-live-rebuild-fence)",
	_RKF_RepeatIsSilentDuringRebuild)






; =========================================================================
; =========================================================================
; ======= 2/ Source — every expansion decision site reads the fence =======
; =========================================================================
; =========================================================================

_RKF_EveryDecisionSiteHonoursTheFence() {
	global _RKF_EXPANSION_DECISION_SITES
	for FuncName in _RKF_EXPANSION_DECISION_SITES {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")
		Assert(InStr(Body, "HSE_RebuildInProgress") > 0,
			FuncName . " must honour the live-rebuild fence — guarding only the matcher left the repeat fallback free to emit wrong output for the whole window in which the registry is being rewritten")
	}
}
Test("meta hotstrings: every expansion decision site honours the live-rebuild fence",
	_RKF_EveryDecisionSiteHonoursTheFence)






; ========================================================================
; ========================================================================
; ======= 3/ The shared corpora (repeat key and idle reset, PAR-2) =======
; ========================================================================
; ========================================================================

; Reads one shared hotstrings corpus file and returns its vector list. A missing
; or malformed file throws: a cross-driver contract that can be deleted without
; the suite noticing is not a contract.
_RKF_CorpusVectors(Name) {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\" . Name
	if !FileExist(Path)
		throw Error("shared corpus not found at '" . Path . "'")
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	if !(Corpus is Map) or !Corpus.Has("vectors") or Corpus["vectors"].Length = 0
		throw Error("shared corpus '" . Name . "' has no vectors")
	return Corpus["vectors"]
}

_RKF_ReplaysRepeatKeyCorpus() {
	global HSE_Buffer, HSE_StartIsWordBoundary
	_RKF_Reset()
	try {
		for Vector in _RKF_CorpusVectors("repeat_key_vectors.json") {
			HSE_Buffer := Vector["buffer"]
			HSE_StartIsWordBoundary := true
			Spec := HSE_TryRepeatKey(Vector["magic_key"])
			if Vector["fires"] {
				Assert(IsObject(Spec), Vector["id"] . ": " . Vector["description"])
				AssertEqual(Vector["replacement"] . Vector["replacement"], Spec.Replacement,
					Vector["id"] . ": the doubled character")
			} else {
				Assert(!IsObject(Spec), Vector["id"] . ": " . Vector["description"])
			}
		}
	} finally {
		_RKF_Reset()
	}
}
Test("hotstrings: the repeat key replays the shared repeat_key_vectors corpus (repeat-key-corpus)",
	_RKF_ReplaysRepeatKeyCorpus)

_RKF_ReplaysIdleResetCorpus() {
	for Vector in _RKF_CorpusVectors("idle_reset_vectors.json") {
		Last := Vector["last_ms"] is Number ? Vector["last_ms"] : ""
		AssertEqual(Vector["resets"] ? true : false,
			HSE_IdleResetsWord(Last, Vector["now_ms"], Vector["idle_seconds"]) ? true : false,
			Vector["id"] . ": " . Vector["description"])
	}
}
Test("hotstrings: the idle word reset replays the shared idle_reset_vectors corpus (idle-reset-corpus)",
	_RKF_ReplaysIdleResetCorpus)

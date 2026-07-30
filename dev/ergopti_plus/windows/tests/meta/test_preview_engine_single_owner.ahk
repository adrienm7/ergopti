; tests/meta/test_preview_engine_single_owner.ahk

; ==============================================================================
; MODULE: Regression — one owner for each shared rule, and no dead code in the
;         preview path (preview-engine-single-owner)
; DESCRIPTION:
; Three findings from the same zone, all consequences of the preview keeping its
; own copy of something the engine already owned.
;
;   L-04  COLLISION PRECEDENCE, WRITTEN TWICE. _PrefixCandidateBeats restated
;         the engine's _HSE_Beats rule and had drifted: it defaulted a missing
;         Priority to 0 where the engine defaults to 50, and had no GroupOrder
;         or Seq tiebreak at all. Two implementations of "which trigger wins"
;         mean the tooltip can rank a collision differently from the engine that
;         fires it — the user is shown one expansion and gets another.
;
;   L-32  NEAR-MISS ANALYTICS, BLINDED. The star-fire path re-seeds the preview
;         from HSE_Buffer, so the buffer handed to _CheckNearMiss can hold
;         several words plus the replacement just inserted. Every registered
;         trigger is a single word, so after the first star fire of a sentence
;         no comparison could ever match again. The metric went quiet with no
;         error.
;
;   L-07/L-31  DEAD CODE. _SuffixAfterLastBoundary was orphaned when its only
;         caller was deleted, and TooltipRearmTimer had no callers at all while
;         still being advertised as public API.
;
; ROOT CAUSE ENCODED: a duplicated rule is not fixed by keeping the two copies
; in step — it is fixed by deleting the second one. Convention 5.6 says the same
; about code that is no longer reached.
;
; SCOPE: behavioural for the shared rules; source-level for the absence of the
; dead code, which is the only way to assert that something is gone.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ Collision precedence has exactly one owner ============
; ==================================================================
; ==================================================================

; The preview and the engine must reach the SAME verdict on the same pair, or
; the tooltip promises an expansion the engine will not choose.
_PESO_PrecedenceAgreesWithTheEngine() {
	; Longer trigger wins regardless of priority.
	Long  := { Trigger: "abcd", Length: 4, Priority: 10 }
	Short := { Trigger: "abc",  Length: 3, Priority: 99 }
	Assert(_PrefixCandidateBeats(Long, Short) == _HSE_Beats(Long, Short),
		"the preview and the engine must agree that the longer trigger wins")
	Assert(_PrefixCandidateBeats(Long, Short),
		"the longer trigger must win — that is the first rule of the shared precedence")

	; Equal length: higher priority wins, on both sides.
	HiPrio := { Trigger: "abc", Length: 3, Priority: 80 }
	LoPrio := { Trigger: "abd", Length: 3, Priority: 20 }
	Assert(_PrefixCandidateBeats(HiPrio, LoPrio) == _HSE_Beats(HiPrio, LoPrio),
		"the preview and the engine must agree on the priority tiebreak")

	; The drifted default is the interesting case: a candidate carrying NO
	; Priority compared against one that does. The preview defaulted it to 0 and
	; the engine to 50, so the two ranked this pair differently.
	NoPrio  := { Trigger: "abc", Length: 3 }
	Mid     := { Trigger: "abd", Length: 3, Priority: 30 }
	Assert(_PrefixCandidateBeats(NoPrio, Mid) == _HSE_Beats(NoPrio, Mid),
		"a candidate with no Priority must be ranked identically by both. The preview defaulted it to 0 and the engine to 50, so exactly this pair could be ordered one way in the tooltip and the other way by the engine")
}

; Delegation, not duplication: the rule must have one definition.
_PESO_PreviewDelegatesRatherThanRestates() {
	Body := _DriverFuncBody("_PrefixCandidateBeats")
	Assert(Body != "", "_PrefixCandidateBeats() must exist in the driver source")
	Assert(InStr(Body, "_HSE_Beats") > 0,
		"the preview's precedence must delegate to the engine's rule. Restating it is what let the two drift apart, and keeping two copies in step by hand is not a fix")
	Assert(InStr(Body, "Priority") == 0,
		"the preview must not restate the priority tiebreak at all — the whole rule belongs to one owner")
}




; ==================================================================
; ==================================================================
; ======= 2/ The near-miss scan measures the current word ==========
; ==================================================================
; ==================================================================

; The shared "current word" derivation, which is what makes the near-miss scan
; work again on a buffer that holds a whole sentence.
_PESO_WordTailIsTheCurrentWord() {
	AssertEqual("teh", _PrefixWordTail("bonjour le teh"),
		"the current word is the trailing run after the last boundary — a multi-word buffer must not be compared against single-word triggers as a whole")
	AssertEqual("teh", _PrefixWordTail("teh"),
		"a single-word buffer is entirely the current word")
	AssertEqual("", _PrefixWordTail("bonjour "),
		"a buffer ending on a boundary has no current word")
}

_PESO_NearMissMeasuresTheWord() {
	Body := _DriverFuncBody("_CheckNearMiss")
	Assert(Body != "", "_CheckNearMiss() must exist in the driver source")
	Assert(InStr(Body, "_PrefixWordTail") > 0,
		"the near-miss scan must compare the current WORD. The star-fire path re-seeds the preview from HSE_Buffer, so the buffer it receives can hold several words plus a just-inserted replacement — and since every trigger is a single word, a whole-buffer comparison can never match again after the first star fire of a sentence")
	Assert(InStr(Body, "StrLower(Buf)") == 0,
		"the scan must not key off the raw buffer any more — that is the comparison that went permanently blind")
}




; ==================================================================
; ==================================================================
; ======= 3/ The dead code is gone and stays gone ==================
; ==================================================================
; ==================================================================

; Convention 5.6: removed means removed. Both of these sat in the preview path
; looking like live behaviour while nothing could reach them.
_PESO_DeadCodeIsRemoved() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")

	Assert(InStr(Src, "_SuffixAfterLastBoundary") == 0,
		"_SuffixAfterLastBoundary must stay removed — it was orphaned when the buffer-sync block that called it was deleted, and a helper nothing reaches is a standing invitation to reason about behaviour that does not happen")
	Assert(InStr(Src, "TooltipRearmTimer") == 0,
		"TooltipRearmTimer must stay removed — it had no callers while still being advertised as public API, and its one side effect (LLM_Bridge_ScheduleAfterHotstring) is already performed on the live path")
	Assert(InStr(Src, "_TooltipLastItems") == 0,
		"_TooltipLastItems must stay removed — it existed solely to feed TooltipRearmTimer, so leaving it behind would keep a write-only global alive")
}

; The behaviour the dead function claimed to own must still happen where it
; really lives, or "remove the dead code" would have removed a live feature.
_PESO_PostFireLlmSchedulingSurvives() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "LLM_Bridge_ScheduleAfterHotstring") > 0,
		"the post-hotstring LLM scheduling must still be invoked from the live prefix-watcher path — removing the dead re-arm helper must not have removed the behaviour it duplicated")
}


Test("meta preview-engine-single-owner: precedence agrees with the engine",
	_PESO_PrecedenceAgreesWithTheEngine)
Test("meta preview-engine-single-owner: the preview delegates rather than restates",
	_PESO_PreviewDelegatesRatherThanRestates)
Test("meta preview-engine-single-owner: the word tail is the current word",
	_PESO_WordTailIsTheCurrentWord)
Test("meta preview-engine-single-owner: the near-miss scan measures the word",
	_PESO_NearMissMeasuresTheWord)
Test("meta preview-engine-single-owner: the dead code is removed",
	_PESO_DeadCodeIsRemoved)
Test("meta preview-engine-single-owner: post-fire LLM scheduling survives",
	_PESO_PostFireLlmSchedulingSurvives)

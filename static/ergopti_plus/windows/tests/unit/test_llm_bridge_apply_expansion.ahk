; tests/unit/test_llm_bridge_apply_expansion.ahk

; ==============================================================================
; MODULE: LLM Bridge Apply Expansion Unit Tests
; DESCRIPTION:
; Regression guard for AHK-23: physical characters typed inside the 60 ms
; post-expansion suppression window were dropped from _LLM_Bridge_Buffer because
; LLM_Bridge_FeedCharIfActive is called AFTER the suppressed-branch early-return
; in _OnPrefixChar. After every hotstring fire the LLM rolling context was
; permanently desynced: the trigger chars stayed in the buffer, the replacement
; text was never appended, and any chars typed during the drain window were lost.
; The LLM then predicted completions against a context that no longer matched
; the document.
;
; The engine now publishes one canonical edit and HSE_DispatchMatch mirrors that
; exact value into the LLM buffer. No bridge-local expansion predictor remains.
;
; These tests assert that the engine effect covers consumed delimiters,
; typographic spaces and Send-key syntax, then that production applies it once.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Helpers ================================================
; ===================================================================
; ===================================================================

_TLBAE_MakeSpec(trigger) {
	Spec := {}
	Spec.Trigger := trigger
	Spec.Length := StrLen(trigger)
	return Spec
}

_TLBAE_SetupBuffer(buf) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := buf
	_LLM_Bridge_Active := true
}

_TLBAE_Teardown() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	_LLM_Bridge_Buffer := ""
	_LLM_Bridge_Active := false
}




; ===================================================================
; ===================================================================
; ======= 2/ Test cases =============================================
; ===================================================================
; ===================================================================

_TLBAE_TestEnginePublishesCanonicalEffect() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_TypoNbspStripped
	global HSE_CONSUMED_DELIMITERS
	SavedBuffer := HSE_Buffer
	SavedBoundary := HSE_StartIsWordBoundary
	SavedTypoNbsp := HSE_TypoNbspStripped
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	try {
		HSE_CONSUMED_DELIMITERS := " "
		HSE_TypoNbspStripped := true
		HSE_StartIsWordBoundary := true
		HSE_Buffer := "left" . Chr(0x202F) . "ab "
		Effect := HSE_ApplyExpansion(_TLBAE_MakeSpec("ab"), "Z", " ")

		Assert(IsObject(Effect),
			"hotstring-llm-canonical-effect: the engine must publish the exact committed edit")
		AssertEqual(4, Effect.DeleteFromEnd,
			"the canonical delete count must include trigger, end char, and stripped typographic nbsp")
		AssertEqual("Z", Effect.InsertedText,
			"a consumed delimiter must be absent from the canonical inserted text")
		AssertFalse(Effect.KnownBoundaryAfter,
			"a consumed delimiter must not claim a boundary which is absent from the screen")
		AssertEqual("leftZ", HSE_Buffer,
			"the engine must apply the same canonical edit it publishes")

		HSE_Buffer := 'leftab'
		HSE_StartIsWordBoundary := true
		SendModeSpec := _TLBAE_MakeSpec("ab")
		SendModeSpec.OnlyText := false
		SendModeEffect := HSE_ApplyExpansion(SendModeSpec, '""{Left}')
		AssertEqual(true, SendModeEffect.ClearAll,
			"Send-key syntax must publish an explicit clear effect instead of pretending its payload is literal text")
		AssertEqual("", HSE_Buffer,
			"the engine must clear an unknowable post-command caret context")
		AssertEqual(false, HSE_StartIsWordBoundary,
			"a cleared Send-key context must not invent a word boundary")
	} finally {
		HSE_Buffer := SavedBuffer
		HSE_StartIsWordBoundary := SavedBoundary
		HSE_TypoNbspStripped := SavedTypoNbsp
		HSE_CONSUMED_DELIMITERS := SavedConsumed
	}
}

_TLBAE_TestDispatchMirrorsCanonicalEffect() {
	Body := _DriverFuncBody("HSE_DispatchMatch")
	Assert(Body != "", "HSE_DispatchMatch must exist in the driver source")
	ApplyPos := InStr(Body, "ExpansionEffect := HSE_ApplyExpansion")
	MirrorPos := InStr(Body, "_HSE_MirrorCanonicalEffectToLlm(ExpansionEffect)")
	Assert(ApplyPos > 0 and MirrorPos > ApplyPos,
		"hotstring-llm-canonical-effect: production dispatch must mirror the engine's returned effect")
	Assert(InStr(Body, "CommittedEffect := ExpansionEffect") > MirrorPos,
		"the watcher must receive that same committed effect instead of re-deriving its post-fire state")
	Assert(InStr(Body, "LLM_Bridge_ApplyExpansionIfActive") == 0,
		"production dispatch must not re-derive expansion semantics through the legacy bridge helper")

	RawBody := _StripFullLineComments(_DriverFuncBody("_HSE_DispatchRawCallback"))
	Assert(RawBody != "", "_HSE_DispatchRawCallback must exist in the driver source")
	EffectPos := InStr(RawBody, "CanonicalEffect :=")
	MirrorPos := EffectPos > 0
		? InStr(RawBody, "_HSE_MirrorCanonicalEffectToLlm(CanonicalEffect)", true, EffectPos)
		: 0
	PublishPos := EffectPos > 0
		? InStr(RawBody, "CommittedEffect := CanonicalEffect", true, EffectPos)
		: 0
	Assert(EffectPos > 0,
		"a successful raw callback must construct one named canonical effect")
	EffectBlock := (MirrorPos > EffectPos)
		? SubStr(RawBody, EffectPos, MirrorPos - EffectPos)
		: ""
	for Field in ["ClearAll:", "DeleteFromEnd:", "InsertedText:", "KnownBoundaryAfter:"] {
		Assert(InStr(EffectBlock, Field) > 0,
			"the raw callback canonical effect must publish field " . Field)
	}
	Assert(MirrorPos > EffectPos and PublishPos > EffectPos,
		"raw callbacks must route that SAME canonical effect to both the LLM mirror "
		. "and the caller instead of rebuilding either sink from Bs/Ins")
}

_TLBAE_TestCanonicalMirrorMutatesLlmOnce() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	SavedBuffer := _LLM_Bridge_Buffer
	SavedActive := _LLM_Bridge_Active
	SavedGeneration := _LLM_Bridge_ContentGeneration
	PreviousCritical := Critical("On")
	try {
		_LLM_Bridge_Buffer := "leftab"
		_LLM_Bridge_Active := true
		_LLM_Bridge_ContentGeneration := 40
		_HSE_MirrorCanonicalEffectToLlm({ DeleteFromEnd: 2, InsertedText: "Z" })
		AssertEqual("leftZ", _LLM_Bridge_Buffer,
			"the canonical mirror must apply the declared delete and insert exactly once")
		AssertEqual(41, _LLM_Bridge_ContentGeneration,
			"the canonical mirror must advance the LLM content epoch exactly once")
		_HSE_MirrorCanonicalEffectToLlm({
			ClearAll: true, DeleteFromEnd: 0, InsertedText: ""
		})
		AssertEqual("", _LLM_Bridge_Buffer,
			"an unknowable Send-key effect must clear the LLM context rather than append command syntax")
		AssertEqual(42, _LLM_Bridge_ContentGeneration,
			"the clear effect must advance the LLM content epoch exactly once")
	} finally {
		_LLM_Bridge_Buffer := SavedBuffer
		_LLM_Bridge_Active := SavedActive
		_LLM_Bridge_ContentGeneration := SavedGeneration
		Critical(PreviousCritical)
	}
}


Test("unit G5: HSE publishes one canonical expansion effect including consumed delimiters and typo nbsp (hotstring-llm-canonical-effect)",
	_TLBAE_TestEnginePublishesCanonicalEffect)

Test("meta G5: production hotstring dispatch mirrors the canonical HSE effect into the LLM buffer (hotstring-llm-canonical-effect)",
	_TLBAE_TestDispatchMirrorsCanonicalEffect)

Test("unit G5: the canonical hotstring sink mutates the LLM buffer and epoch exactly once (hotstring-llm-canonical-effect)",
	_TLBAE_TestCanonicalMirrorMutatesLlmOnce)

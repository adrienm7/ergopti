; tests/unit/test_activate_hotstrings_commits_synchronously.ahk

; ==============================================================================
; MODULE: Regression — the pending end-char hotstring is committed inside
;         ActivateHotstrings (activate-hotstrings-poke-never-round-trips)
; DESCRIPTION:
; ActivateHotstrings runs on every Shift French-punctuation key: the layer emits
; the abbreviation-flushing poke, then the narrow no-break space and the
; punctuation itself.
;
; ROOT CAUSE ENCODED: the commit used to be a HOOK ROUND-TRIP. The poke space
; was injected at the caller's send level, the prefix-watcher InputHook observed
; it, and _OnPrefixChar fired the pending trigger. That design requires the
; message loop to run BETWEEN the two sends — and every caller reaches this
; function from a serialized layer hotkey holding Critical across the poke AND
; the punctuation emit that follows, so no InputHook callback can be delivered
; until all of it has already landed on screen. The deferred OnChar then fired
; the expansion at a caret that had moved past the punctuation, destroying the
; character the user had just typed, while HSE_ApplyExpansion mirrored the same
; wrong edit into HSE_Buffer so no desync alarm could trip. The round-trip the
; whole function was built on had become structurally impossible; production
; logs across a week contain zero end-char fires from this path.
;
; These tests pin the property that replaced it: the commit happens INSIDE the
; call with no message pump, and a fired transaction consumes its private poke
; through the dispatcher's canonical effect instead of issuing a second erase.
;
; SCOPE: behavioural, driving the real engine with the send recorder installed.
; ==============================================================================

#Requires AutoHotkey v2.0






; =========================================================================
; =========================================================================
; ======= 1/ A fire consumes its private poke in the canonical edit =======
; =========================================================================
; =========================================================================

_AHCS_RunForcedCommitCase(ConsumedSpace) {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, HSE_CONSUMED_DELIMITERS
	global _Stub_RecordedSends, _PrefixWatcherSuppressed
	global _PrefixBuffer, _PrefixContentGeneration, _PrefixPrivateResidue
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	SavedPrefix := _PrefixBuffer
	SavedPrefixGeneration := _PrefixContentGeneration
	SavedPrivateResidue := _PrefixPrivateResidue
	SavedLlmBuffer := _LLM_Bridge_Buffer
	SavedLlmActive := _LLM_Bridge_Active
	SavedLlmGeneration := _LLM_Bridge_ContentGeneration
	SavedRing := _LSC_RING.Clone()
	SavedRingCursor := _LSC_CURSOR
	SavedRingLen := _LSC_LEN
	InstallHotstringHooks()
	ResetHotstringRecorders()
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	if IsSet(_PrefixWatcherSuppressed)
		_PrefixWatcherSuppressed := 0
	HSE_FeedReset(true)
	SimulateRegularApp()
	try {
		; Run once under each user delimiter configuration. ActivateHotstrings'
		; temporary completion key is private implementation state and must be
		; consumed in BOTH cases, independent of the ordinary delimiter setting.
		HSE_CONSUMED_DELIMITERS := ConsumedSpace ? " " : ""
		HSE_Register("", "ia", 0, Map("Replacement", "IA", "Category", "test", "Section", "activate"))
		HSE_Buffer := "ia"
		HSE_StartIsWordBoundary := true
		_LLM_Bridge_Active := true
		_LLM_Bridge_Buffer := "ctxia"
		_PrefixBuffer := "ia"
		_PrefixPrivateResidue := false
		_LSCResetFrom(["seed"])

		AssertEqual(true, ActivateHotstrings(),
			"the forced end-char transaction must report success")

		Sends := _Stub_RecordedSends
		AssertEqual(2, Sends.Length,
			"a fired forced commit must contain only the temporary poke and expansion burst; a cleanup backspace would erase replacement text")
		Assert(Sends[1].fn == "SendNewResult" and Sends[1].args[1] == " ",
			"the space must still really be emitted — the expansion's own backspace count assumes it is on screen")
		Assert(Sends[2].fn == "SendFinalResult",
			"the pending expansion must commit synchronously inside the call")
		Assert(InStr(Sends[2].args[1], "{Text}IA") > 0,
			"and it must carry the replacement the pending trigger resolves to")
		Assert(HSE_Buffer == "IA",
			"HSE must contain the replacement without the private poke")
		Assert(_PrefixBuffer == "IA",
			"the prefix watcher must consume the dispatcher's canonical post-fire effect")
		Assert(_LLM_Bridge_Buffer == "ctxIA",
			"the LLM context must receive the same poke deletion and replacement exactly once")
		AssertEqual("A", GetLastSentCharacterAt(-1),
			"the output ring must end at the real replacement tail")
		AssertEqual("seed", GetLastSentCharacterAt(-2),
			"the temporary poke must not be retained behind the replacement")
		AssertEqual("", GetLastSentCharacterAt(-3),
			"the temporary poke must not create a second hidden ring entry")
	} finally {
		if IsSet(_PrefixCancelRender)
			try _PrefixCancelRender()
		HSE_Suppressed := 0
		if IsSet(_PrefixWatcherSuppressed)
			_PrefixWatcherSuppressed := 0
		HSE_RegistryClear()
		HSE_HardReset()
		HSE_CONSUMED_DELIMITERS := SavedConsumed
		_PrefixBuffer := SavedPrefix
		_PrefixContentGeneration := SavedPrefixGeneration
		_PrefixPrivateResidue := SavedPrivateResidue
		_LLM_Bridge_Buffer := SavedLlmBuffer
		_LLM_Bridge_Active := SavedLlmActive
		_LLM_Bridge_ContentGeneration := SavedLlmGeneration
		_LSC_RING := SavedRing
		_LSC_CURSOR := SavedRingCursor
		_LSC_LEN := SavedRingLen
		ResetHotstringRecorders()
	}
}

_AHCS_DefaultDelimiterStillConsumesPrivatePoke() {
	_AHCS_RunForcedCommitCase(false)
}
Test("hotstrings: ActivateHotstrings consumes its private poke under the default emitted-delimiter configuration (activate-hotstrings-poke-never-round-trips)",
	_AHCS_DefaultDelimiterStillConsumesPrivatePoke)

_AHCS_ConsumedDelimiterDoesNotEraseReplacement() {
	_AHCS_RunForcedCommitCase(true)
}
Test("hotstrings: ActivateHotstrings does not erase replacement text when Space is configured consumed (activate-hotstrings-consumed-poke-no-double-cleanup)",
	_AHCS_ConsumedDelimiterDoesNotEraseReplacement)

; An empty engine buffer means there is no pending abbreviation to commit. This
; is the hot common case for punctuation typed at a boundary: the function must
; return before it sends or mutates any of the four mirrored typing states.
_AHCS_EmptyEngineBufferIsPureNoOp() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_LastMatch, HSE_LastEndChar
	global HSE_TypoNbspStripped, HSE_Suppressed, _SendHook, _Stub_RecordedSends
	global _PrefixWatcherSuppressed, _PrefixBuffer, _PrefixContentGeneration, _PrefixPrivateResidue
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	SavedHseBuffer := HSE_Buffer
	SavedHseBoundary := HSE_StartIsWordBoundary
	SavedHseLastMatch := HSE_LastMatch
	SavedHseLastEndChar := HSE_LastEndChar
	SavedHseTypoNbsp := HSE_TypoNbspStripped
	SavedHseSuppressed := HSE_Suppressed
	SavedSendHook := _SendHook
	SavedRecordedSends := _Stub_RecordedSends
	SavedPrefixSuppressed := _PrefixWatcherSuppressed
	SavedPrefix := _PrefixBuffer
	SavedPrefixGeneration := _PrefixContentGeneration
	SavedPrivateResidue := _PrefixPrivateResidue
	SavedLlmBuffer := _LLM_Bridge_Buffer
	SavedLlmActive := _LLM_Bridge_Active
	SavedLlmGeneration := _LLM_Bridge_ContentGeneration
	SavedRing := _LSC_RING.Clone()
	SavedRingCursor := _LSC_CURSOR
	SavedRingLen := _LSC_LEN
	try {
		_SendHook := _HOOK_RecordSend
		_Stub_RecordedSends := []
		HSE_Buffer := ""
		HSE_StartIsWordBoundary := false
		HSE_LastMatch := "empty-buffer-last-match"
		HSE_LastEndChar := "empty-buffer-last-end-char"
		HSE_TypoNbspStripped := true
		HSE_Suppressed := 0
		_PrefixWatcherSuppressed := 2
		_PrefixBuffer := "prefix-sentinel"
		_PrefixPrivateResidue := true
		_LLM_Bridge_Buffer := "llm-sentinel"
		_LLM_Bridge_Active := true
		_LSCResetFrom(["ring-a", "ring-b"])

		ExpectedPrefixGeneration := _PrefixContentGeneration
		ExpectedLlmGeneration := _LLM_Bridge_ContentGeneration
		ExpectedRing := _LSC_RING.Clone()
		ExpectedRingCursor := _LSC_CURSOR
		ExpectedRingLen := _LSC_LEN

		AssertEqual(true, ActivateHotstrings(),
			"an empty engine buffer must report success without starting a forced-commit transaction")
		AssertEqual(0, _Stub_RecordedSends.Length,
			"an empty engine buffer must emit zero SendNewResult calls")

		AssertEqual("", HSE_Buffer,
			"the empty-buffer fast path must not mutate HSE_Buffer")
		AssertEqual(false, HSE_StartIsWordBoundary,
			"the empty-buffer fast path must not mutate the HSE boundary state")
		AssertEqual("empty-buffer-last-match", HSE_LastMatch,
			"the empty-buffer fast path must not clear HSE_LastMatch")
		AssertEqual("empty-buffer-last-end-char", HSE_LastEndChar,
			"the empty-buffer fast path must not clear HSE_LastEndChar")
		AssertEqual(true, HSE_TypoNbspStripped,
			"the empty-buffer fast path must not mutate HSE match metadata")
		AssertEqual(0, HSE_Suppressed,
			"the empty-buffer fast path must not mutate HSE suppression depth")

		AssertEqual(2, _PrefixWatcherSuppressed,
			"the empty-buffer fast path must not mutate prefix suppression depth")
		AssertEqual("prefix-sentinel", _PrefixBuffer,
			"the empty-buffer fast path must not mutate the prefix buffer")
		AssertEqual(ExpectedPrefixGeneration, _PrefixContentGeneration,
			"the empty-buffer fast path must not invalidate prefix content")
		AssertEqual(true, _PrefixPrivateResidue,
			"the empty-buffer fast path must not mutate prefix privacy state")

		AssertEqual("llm-sentinel", _LLM_Bridge_Buffer,
			"the empty-buffer fast path must not mutate LLM context")
		AssertEqual(true, _LLM_Bridge_Active,
			"the empty-buffer fast path must not mutate LLM bridge activity")
		AssertEqual(ExpectedLlmGeneration, _LLM_Bridge_ContentGeneration,
			"the empty-buffer fast path must not invalidate LLM content")

		AssertEqual(ExpectedRingCursor, _LSC_CURSOR,
			"the empty-buffer fast path must not move the output-ring cursor")
		AssertEqual(ExpectedRingLen, _LSC_LEN,
			"the empty-buffer fast path must not change output-ring length")
		AssertEqual(ExpectedRing.Length, _LSC_RING.Length,
			"the empty-buffer fast path must not resize the output ring")
		Loop ExpectedRing.Length {
			AssertEqual(ExpectedRing[A_Index], _LSC_RING[A_Index],
				"the empty-buffer fast path must not mutate output-ring slot " . A_Index)
		}
	} finally {
		HSE_Buffer := SavedHseBuffer
		HSE_StartIsWordBoundary := SavedHseBoundary
		HSE_LastMatch := SavedHseLastMatch
		HSE_LastEndChar := SavedHseLastEndChar
		HSE_TypoNbspStripped := SavedHseTypoNbsp
		HSE_Suppressed := SavedHseSuppressed
		_PrefixWatcherSuppressed := SavedPrefixSuppressed
		_PrefixBuffer := SavedPrefix
		_PrefixContentGeneration := SavedPrefixGeneration
		_PrefixPrivateResidue := SavedPrivateResidue
		_LLM_Bridge_Buffer := SavedLlmBuffer
		_LLM_Bridge_Active := SavedLlmActive
		_LLM_Bridge_ContentGeneration := SavedLlmGeneration
		_LSC_RING := SavedRing
		_LSC_CURSOR := SavedRingCursor
		_LSC_LEN := SavedRingLen
		_SendHook := SavedSendHook
		_Stub_RecordedSends := SavedRecordedSends
	}
}
Test("hotstrings: ActivateHotstrings is a pure no-op when HSE_Buffer is empty (activate-hotstrings-empty-buffer-pure-noop)",
	_AHCS_EmptyEngineBufferIsPureNoOp)

; With nothing pending, the poke must stay exactly what it was: two sends and no
; expansion. This is the common case on every punctuation key, and it is what
; the empty-buffer gate above it protects.
_AHCS_NothingPendingStillJustPokes() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, _Stub_RecordedSends
	global _PrefixWatcherSuppressed, _PrefixBuffer
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	SavedPrefix := _PrefixBuffer
	SavedLlmBuffer := _LLM_Bridge_Buffer
	SavedLlmActive := _LLM_Bridge_Active
	SavedLlmGeneration := _LLM_Bridge_ContentGeneration
	SavedRing := _LSC_RING.Clone()
	SavedRingCursor := _LSC_CURSOR
	SavedRingLen := _LSC_LEN
	InstallHotstringHooks()
	ResetHotstringRecorders()
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	HSE_FeedReset(true)
	SimulateRegularApp()
	try {
		HSE_Buffer := "zzq"
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "zzq"
		_LLM_Bridge_Active := true
		_LLM_Bridge_Buffer := "ctxzzq"
		_LSCResetFrom(["seed"])
		AssertEqual(true, ActivateHotstrings(),
			"a no-match poke and successful cleanup must report success")
		AssertEqual(2, _Stub_RecordedSends.Length,
			"with no trigger claiming the buffer the dance must stay a bare space + backspace")
		AssertEqual("zzq", HSE_Buffer,
			"successful cleanup must remove the temporary Space from HSE")
		AssertEqual("zzq", _PrefixBuffer,
			"a temporary no-match poke must not disturb preview text")
		AssertEqual("ctxzzq", _LLM_Bridge_Buffer,
			"successful cleanup must remove the temporary Space from LLM context")
		AssertEqual("seed", GetLastSentCharacterAt(-1),
			"a poke which was removed from screen must never enter output history")
	} finally {
		HSE_Suppressed := 0
		if IsSet(_PrefixWatcherSuppressed)
			_PrefixWatcherSuppressed := 0
		HSE_RegistryClear()
		HSE_HardReset()
		_PrefixBuffer := SavedPrefix
		_LLM_Bridge_Buffer := SavedLlmBuffer
		_LLM_Bridge_Active := SavedLlmActive
		_LLM_Bridge_ContentGeneration := SavedLlmGeneration
		_LSC_RING := SavedRing
		_LSC_CURSOR := SavedRingCursor
		_LSC_LEN := SavedRingLen
		ResetHotstringRecorders()
	}
}
Test("hotstrings: ActivateHotstrings still only pokes when nothing is pending",
	_AHCS_NothingPendingStillJustPokes)

_AHCS_FailCleanupRecorder(FnName, Args*) {
	global _Stub_RecordedSends
	_Stub_RecordedSends.Push({ fn: FnName, args: Args })
	if (FnName == "SendNewResult" and Args.Length > 0
		and Args[1] == "{BackSpace}")
		return false
	return true
}

_AHCS_FailedCleanupPreservesVisibleSpace() {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_Suppressed, _SendHook
	global _Stub_RecordedSends, _PrefixWatcherSuppressed
	global _PrefixBuffer, _PrefixContentGeneration
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active, _LLM_Bridge_ContentGeneration
	global _LSC_RING, _LSC_CURSOR, _LSC_LEN
	SavedSendHook := _SendHook
	SavedPrefix := _PrefixBuffer
	SavedPrefixGeneration := _PrefixContentGeneration
	SavedLlmBuffer := _LLM_Bridge_Buffer
	SavedLlmActive := _LLM_Bridge_Active
	SavedLlmGeneration := _LLM_Bridge_ContentGeneration
	SavedRing := _LSC_RING.Clone()
	SavedRingCursor := _LSC_CURSOR
	SavedRingLen := _LSC_LEN
	ResetHotstringRecorders()
	_SendHook := _AHCS_FailCleanupRecorder
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_Suppressed := 0
	if IsSet(_PrefixWatcherSuppressed)
		_PrefixWatcherSuppressed := 0
	HSE_FeedReset(true)
	SimulateRegularApp()
	try {
		HSE_Buffer := "zzq"
		HSE_StartIsWordBoundary := true
		_PrefixBuffer := "zzq"
		_LLM_Bridge_Active := true
		_LLM_Bridge_Buffer := "ctxzzq"
		_LSCResetFrom(["seed"])

		AssertEqual(false, ActivateHotstrings(),
			"a rejected cleanup send must be surfaced to the punctuation caller")
		AssertEqual(2, _Stub_RecordedSends.Length,
			"the failed transaction must stop after poke plus rejected cleanup")
		AssertEqual("zzq ", HSE_Buffer,
			"a failed cleanup must preserve the Space which remains visible on screen")
		AssertEqual("", _PrefixBuffer,
			"the prefix preview must reset at the visible Space boundary")
		AssertEqual("ctxzzq ", _LLM_Bridge_Buffer,
			"LLM context must preserve the same visible Space rather than rolling it back")
		AssertEqual(" ", GetLastSentCharacterAt(-1),
			"the permanent fallback Space must enter output history exactly once")
		AssertEqual("seed", GetLastSentCharacterAt(-2),
			"the failed cleanup must not duplicate that Space in the ring")
	} finally {
		HSE_Suppressed := 0
		if IsSet(_PrefixWatcherSuppressed)
			_PrefixWatcherSuppressed := 0
		HSE_RegistryClear()
		HSE_HardReset()
		_PrefixBuffer := SavedPrefix
		_PrefixContentGeneration := SavedPrefixGeneration
		_LLM_Bridge_Buffer := SavedLlmBuffer
		_LLM_Bridge_Active := SavedLlmActive
		_LLM_Bridge_ContentGeneration := SavedLlmGeneration
		_LSC_RING := SavedRing
		_LSC_CURSOR := SavedRingCursor
		_LSC_LEN := SavedRingLen
		_SendHook := SavedSendHook
		ResetHotstringRecorders()
	}
}
Test("hotstrings: a failed ActivateHotstrings cleanup preserves the visible Space in every buffer and the ring",
	_AHCS_FailedCleanupPreservesVisibleSpace)






; ====================================================================
; ====================================================================
; ======= 2/ The poke is emitted below the watcher input level =======
; ====================================================================
; ====================================================================

; The direct commit is only safe because the poke cannot ALSO come back through
; the InputHook: a level-0 send is below the watcher's I1 minimum, so the space
; and any no-fire cleanup are never re-ingested on top of the feeds done here.
_AHCS_PokeIsBelowTheWatcherLevel() {
	Body := _DriverFuncBody("ActivateHotstrings")
	Assert(Body != "", "ActivateHotstrings() must exist in the driver source")
	Assert(InStr(Body, "HSE_FeedChar") > 0,
		"ActivateHotstrings must commit through a direct engine call — the hook round-trip it used to rely on cannot complete inside the Critical the poke is emitted under")
	Assert(InStr(Body, "SendLevel(0)") > 0,
		"and it must emit the poke below the prefix-watcher InputHook's minimum send level, or the deferred callbacks would feed the same space a second time")
	Assert(InStr(Body, "A_SendLevel") > 0 and InStr(Body, "finally") > 0,
		"the previous send level must be restored in a finally — leaking level 0 into the caller would silence the watcher for the punctuation that follows")
}
Test("meta hotstrings: the activation poke commits directly and stays below the watcher level",
	_AHCS_PokeIsBelowTheWatcherLevel)

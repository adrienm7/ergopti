; modules/keymap/llm_bridge.ahk

; ==============================================================================
; MODULE: LLM Bridge
; DESCRIPTION:
; Keyboard hook that feeds the typed buffer to the prediction engine.
; Intercepts printable keystrokes and backspace to maintain a rolling context
; string, then forwards it to LLM_Engine_OnKeystroke().
;
; FEATURES & RATIONALE:
; 1. Non-blocking: hook only updates the buffer and restarts a timer — the LLM
;    call happens on a separate timer fire, not inside the hook itself.
; 2. Context reset: Escape, Enter, and Tab flush the buffer so predictions
;    remain relevant to the current editing context.
; 3. AcceptChar filter: only printable ASCII + accented Latin chars are buffered;
;    navigation keys (arrows, F-keys) are ignored to keep context clean.
; 4. PrefixWatcher integration: keystrokes are fed from the prefix watcher's
;    pass-through InputHook (``hotstring_prefix_watcher.ahk``). On Windows,
;    HookDispatcher + Keylogger + PrefixWatcher each create an InputHook;
;    the LLM bridge no longer registers with HookDispatcher because keystrokes
;    were not reaching it on some machines while the prefix hook was reliable.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================
; ===============================
; ======= 1/ Buffer State =======
; ===============================
; ===============================

; Hard ceiling on the rolling context buffer. Unlike HSE_Buffer (capped at 64
; chars — the longest hotstring trigger it must match), this buffer feeds
; menu_settings.ahk's SubStr(_LLM_Bridge_Buffer, -_LLM_Menu["ctx_chars"]), and
; ctx_chars is user-configurable up to 10000 (LLM_Menu_PromptCtxChars's range
; in menu_settings.ahk) — so the cap must stay >= that maximum or a high
; ctx_chars setting would silently lose context. It exists only to bound
; per-keystroke growth on an unbroken long typing run: every sibling hot-path
; buffer (HSE_Buffer, KLRoi.current_word) is capped; this one previously was
; not (F47).
global LLM_BRIDGE_BUFFER_MAX_CHARS := 10000
global _LLM_Bridge_Buffer := ""
global _LLM_Bridge_ContentGeneration := 0
global _LLM_Bridge_Active := false
; Fallback path when Ollama becomes ready before PrefixWatcher's InputHook exists.
global _LLM_Bridge_DispatcherCharFn := 0
global _LLM_Bridge_DispatcherKeyFn := 0
; Throttle keystroke logs — one INFO line per ~2 s of typing is enough to
; confirm the pipeline is alive without flooding ErgoptiPlus_*.log.
global _LLM_Bridge_LastLogTick := 0
; Single acceptance transaction guard shared by the HotIf and InputHook paths.
; Production keeps it raised through sender completion and one deferred turn,
; so both callbacks observing one physical Tab consume one claim.
global _LLM_AcceptInProgress := false
global _LLM_ACCEPT_CLAIM_RELEASE_DELAY_MS := 25
; Pointer-dismiss watcher — mirrors macOS tooltip_llm.lua mouseMoved/click/scroll.
global _LLM_PointerWatch_Armed     := false
global _LLM_PointerWatch_LastX     := unset
global _LLM_PointerWatch_LastY     := unset
global _LLM_PointerWatch_MoveFn    := unset
global _LLM_PointerWatch_ActivityFn := unset
global _LLM_POINTER_POLL_MS        := 50
; Cursor travel (px, per axis) FROM THE ORIGIN where the prediction appeared,
; before pointer movement counts as a DELIBERATE dismiss. It must clear two kinds
; of incidental motion that the user considers "rien touché": optical-sensor
; jitter / slow drift (1-3 px), AND the ~30-50 px lurch the mouse makes when a
; hand lifts off it and it settles. A real relocation to click/use something else
; crosses far more (200+ px across the screen), and a click dismisses regardless.
; Measured against a FIXED origin (total displacement), not per tick, so a slow
; deliberate move still accumulates past it; drift cannot reach it within the
; prediction's ~20 s lifetime. Tunable — raise it if a mouse lurches further.
global _LLM_POINTER_MOVE_THRESHOLD_PX := 100
; Mirrors macOS llm_bridge.lua HOTSTRING_CHAIN_OFFSET_SEC — prediction fires
; just after the hotstring tooltip would normally close.
global _LLM_HOTSTRING_CHAIN_OFFSET_SEC := 0.05
global _LLM_INFINITE_TOOLTIP_SEC       := 86400
global _LLM_MIN_TOOLTIP_DURATION_SEC   := 0.05

; Canonical owner for every runtime mutation of the rolling LLM context. The
; old cap lived only in OnChar, so accepted and inline predictions could grow
; the same buffer forever without passing through it. Every edit now keeps the
; newest tail and advances an ABA-safe generation even when the visible value
; returns to the same text after an append/backspace pair.
; @param DeleteFromEnd {Integer|unset} Characters removed from the current
;        tail. Omitted means clear every character, including oversized legacy
;        state created before this invariant existed.
; @param InsertedText {String} Text appended after deletion.
; @return {String} The newly published bounded buffer.
_LLM_Bridge_ApplyBufferEdit(DeleteFromEnd := unset, InsertedText := "") {
	global _LLM_Bridge_Buffer, _LLM_Bridge_ContentGeneration
	global LLM_BRIDGE_BUFFER_MAX_CHARS
	DeleteAll := !IsSet(DeleteFromEnd)
	DeleteCount := DeleteAll ? 0 : Max(0, DeleteFromEnd)
	InsertedTail := InsertedText
	if (StrLen(InsertedTail) > LLM_BRIDGE_BUFFER_MAX_CHARS)
		InsertedTail := SubStr(InsertedTail, -LLM_BRIDGE_BUFFER_MAX_CHARS)
	PreviousCritical := Critical("On")
	try {
		RemainingLen := DeleteAll ? 0
			: Max(0, StrLen(_LLM_Bridge_Buffer) - DeleteCount)
		Remaining := RemainingLen > 0
			? SubStr(_LLM_Bridge_Buffer, 1, RemainingLen) : ""
		Available := LLM_BRIDGE_BUFFER_MAX_CHARS - StrLen(InsertedTail)
		if (Available <= 0) {
			KeptTail := ""
		} else if (StrLen(Remaining) > Available) {
			KeptTail := SubStr(Remaining, -Available)
		} else {
			KeptTail := Remaining
		}
		_LLM_Bridge_Buffer := KeptTail . InsertedTail
		_LLM_Bridge_ContentGeneration += 1
		return _LLM_Bridge_Buffer
	} finally {
		Critical(PreviousCritical)
	}
}

_LLM_Bridge_ClearBuffer() {
	return _LLM_Bridge_ApplyBufferEdit()
}

; Pure admission policy for a deferred LLM output. Maps keep the test seam
; readable while every production field remains mandatory and strictly typed.
; The three epochs are complementary: physical input catches mouse/chords,
; bridge content catches text ABA even inside one tick quantum, and prefix
; context catches caret/navigation resets that do not change the LLM text.
_LLM_Bridge_TextAdmissionMatches(Expected, Live) {
	if !(Expected is Map) or !(Live is Map)
		return false
	static IdentityKeys := ["hwnd", "control", "physical_generation",
		"content_generation", "context_generation", "request_id"]
	for Key in IdentityKeys {
		if !Expected.Has(Key) or !Live.Has(Key)
			return false
		if !(Expected[Key] is Integer) or !(Live[Key] is Integer)
			return false
		if Expected[Key] != Live[Key]
			return false
	}
	if (Expected["hwnd"] <= 0 or Expected["control"] <= 0)
		return false
	if !Live.Has("suspended") or !(Live["suspended"] is Integer)
		return false
	return Live["suspended"] == false
}

_LLM_Bridge_CaptureAdmissionSeed(Source) {
	global _LLM_Bridge_ContentGeneration, _PrefixInputContextGeneration
	if !(Source is Map)
		Source := Map()
	return Map(
		"hwnd", Source.Get("hwnd", 0),
		"control", Source.Get("control", 0),
		"physical_generation", KS_GetPhysicalInputGeneration(),
		"content_generation", _LLM_Bridge_ContentGeneration,
		"context_generation", IsSet(_PrefixInputContextGeneration)
			? _PrefixInputContextGeneration : -1
	)
}

_LLM_Bridge_TextAdmissionStillCurrent(Expected) {
	global _LLM_Bridge_ContentGeneration, _PrefixInputContextGeneration, _LLM_Engine
	LiveRequestId := (IsSet(_LLM_Engine) and _LLM_Engine is Map)
		? _LLM_Engine.Get("request_id", -1) : -1
	Live := Map(
		"hwnd", WIGetForegroundHwnd(),
		"control", WIGetFocusedControlToken(),
		"physical_generation", KS_GetPhysicalInputGeneration(),
		"content_generation", _LLM_Bridge_ContentGeneration,
		"context_generation", IsSet(_PrefixInputContextGeneration)
			? _PrefixInputContextGeneration : -1,
		"request_id", LiveRequestId,
		"suspended", A_IsSuspended ? true : false
	)
	return _LLM_Bridge_TextAdmissionMatches(Expected, Live)
}

_LLM_Bridge_MakeTextAdmission(Seed, RequestId) {
	if !(Seed is Map)
		throw TypeError("LLM text admission requires an immutable seed Map.")
	Expected := Seed.Clone()
	Expected["request_id"] := RequestId
	return {
		Expected: Expected,
		Predicate: _LLM_Bridge_TextAdmissionStillCurrent.Bind(Expected)
	}
}

_LLM_Bridge_NewInjectionTransaction(Text, Seed, RequestId,
		Inline := false, Slots := unset, ActiveIdx := 1,
		PresentedRecord := 0, PresentedLifecycle := 0) {
	Admission := _LLM_Bridge_MakeTextAdmission(Seed, RequestId)
	SlotSnapshot := (IsSet(Slots) and Slots is Array) ? Slots.Clone() : [Text]
	return {
		Text: Text,
		SourceHwnd: Admission.Expected["hwnd"],
		SourceControl: Admission.Expected["control"],
		Inline: Inline ? true : false,
		Slots: SlotSnapshot,
		ActiveIdx: ActiveIdx,
		PresentedRecord: PresentedRecord,
		PresentedLifecycle: PresentedLifecycle,
		Admission: Admission.Predicate
	}
}

; RAM-only half of an injected-text commit. TextSender calls this after the OS
; primitive returned, without leaving the same Critical transaction. It returns
; only the presentation finalizer, which TextSender executes after restoring the
; scheduler. Any exception is treated as post-output state damage and triggers
; the fail-safe reset below; it must never turn into a retryable send failure.
_LLM_Bridge_CommitInjectedText(Transaction) {
	global _LLM_Engine
	if !A_IsCritical
		throw Error("LLM injected-text commit requires a Critical output transaction.")
	_LLM_Bridge_ApplyBufferEdit(0, Transaction.Text)
	if Transaction.Inline {
		if !(_LLM_Engine is Map)
			throw Error("LLM engine state is unavailable during inline commit.")
		_LLM_Engine["inline_last_typed"] := Transaction.Text
	}
	if !IsSet(_PrefixCommitInputContext) or !IsSet(_PrefixFinishInputContext)
		throw Error("Prefix/HSE paired commit owner is unavailable.")
	PrefixCommit := _PrefixCommitInputContext(Transaction.SourceControl, false)
	if IsSet(_LSCResetFrom) {
		Tail := []
		N := Min(StrLen(Transaction.Text), 5)
		loop N
			Tail.Push(SubStr(Transaction.Text,
				StrLen(Transaction.Text) - N + A_Index, 1))
		_LSCResetFrom(Tail)
	}
	return _PrefixFinishInputContext.Bind(PrefixCommit)
}

_LLM_Bridge_RecoverInjectedState(Transaction, CommitError := "") {
	global _LLM_Engine
	if !A_IsCritical
		throw Error("LLM injected-text recovery requires a Critical output transaction.")
	Failures := []
	PrefixCommit := 0
	try
		_LLM_Bridge_ClearBuffer()
	catch as Err
		Failures.Push("bridge=" . Err.Message)
	if Transaction.Inline {
		if (_LLM_Engine is Map)
			_LLM_Engine["inline_last_typed"] := ""
		else
			Failures.Push("inline=engine state unavailable")
	}
	if !IsSet(_PrefixCommitInputContext) or !IsSet(_PrefixFinishInputContext) {
		Failures.Push("prefix=paired commit owner unavailable")
	} else {
		try
			PrefixCommit := _PrefixCommitInputContext(0, false)
		catch as Err
			Failures.Push("prefix=" . Err.Message)
	}
	try
		_LSCResetFrom([])
	catch as Err
		Failures.Push("lsc=" . Err.Message)
	return _LLM_Bridge_FinishInjectedRecovery.Bind(PrefixCommit, Failures)
}

_LLM_Bridge_FinishInjectedRecovery(PrefixCommit, Failures) {
	if IsObject(PrefixCommit) {
		try
			_PrefixFinishInputContext(PrefixCommit)
		catch as Err
			Failures.Push("prefix_finalizer=" . Err.Message)
	}
	if Failures.Length > 0 {
		Message := ""
		for Index, Failure in Failures
			Message .= (Index == 1 ? "" : "; ") . Failure
		throw Error(Message)
	}
}

_LLM_Bridge_InjectionOptions(Transaction) {
	return Map(
		"mode", "auto",
		"atomic_input", true,
		"admission", Transaction.Admission,
		"atomic_prepare", _LLM_Bridge_PrepareOutputJournal.Bind(Transaction),
		"atomic_journal", _LLM_Bridge_CommitOutputJournal,
		"atomic_commit", _LLM_Bridge_CommitInjectedText.Bind(Transaction),
		"commit_failure", _LLM_Bridge_RecoverInjectedState.Bind(Transaction)
	)
}

_LLM_Bridge_PrepareOutputJournal(Transaction) {
	return KL_PrepareLlmOutputJournal(Map(
		"source_hwnd", Transaction.SourceHwnd,
		"prediction", Transaction.Text,
		"all_predictions", Transaction.Slots,
		"chosen_index", Transaction.ActiveIdx,
		"deletes", 0,
		"deleted_text", "",
		; Inline output has no rendered tooltip, so its suggestion denominator
		; must be committed with the accepted row. Tab acceptance already has a
		; suggested row from the final tooltip render.
		"include_suggested", (Transaction.Inline
			or (IsObject(Transaction.PresentedLifecycle)
				and !Transaction.PresentedLifecycle.Suggested))
	), Transaction.Admission)
}

_LLM_Bridge_CommitOutputJournal(Token) {
	return KL_CommitPreparedLlmOutputJournal(Token)
}





; ===========================================
; ===========================================
; ======= 2/ Canonical Tab Acceptance =======
; ===========================================
; ===========================================

; Snapshot the physical event and current focus in one fail-closed probe. Raw
; InputHook events, the Tab hotkey, gestures and tap-hold remaps all converge on
; this same shape; a caller cannot accidentally substitute logical modifier
; state for the physical state that decides whether Tab means "accept".
_LLM_Accept_ReadInputSnapshot() {
	Snapshot := Map(
		"known", false,
		"tab_down", false,
		"ctrl_down", false,
		"alt_down", false,
		"shift_down", false,
		"win_down", false,
		"current_hwnd", 0,
		"current_control", 0
	)
	try {
		Snapshot["tab_down"] := GetKeyState("Tab", "P") ? true : false
		Snapshot["ctrl_down"] := GetKeyState("Ctrl", "P") ? true : false
		Snapshot["alt_down"] := GetKeyState("Alt", "P") ? true : false
		Snapshot["shift_down"] := GetKeyState("Shift", "P") ? true : false
		Snapshot["win_down"] := (GetKeyState("LWin", "P")
			or GetKeyState("RWin", "P")) ? true : false
		Snapshot["current_hwnd"] := WinGetID("A")
		Snapshot["current_control"] := WIGetFocusedControlToken()
		Snapshot["known"] := (Snapshot["current_hwnd"] is Integer
			and Snapshot["current_hwnd"] > 0
			and Snapshot["current_control"] is Integer
			and Snapshot["current_control"] > 0)
	} catch {
		; Keep known=false. An unverifiable focus or key state must never inject.
	}
	return Snapshot
}

_LLM_Accept_HasDeclaredModifiers(Modifiers) {
	if (Modifiers is Array)
		return Modifiers.Length > 0
	if (Modifiers is String)
		return Modifiers != ""
	return true
}

_LLM_Accept_ReleaseClaim() {
	global _LLM_AcceptInProgress
	PreviousCritical := Critical("On")
	try {
		_LLM_AcceptInProgress := false
	} finally {
		Critical(PreviousCritical)
	}
}

; Release on a later scheduler turn, after every HotIf/InputHook callback for the
; physical Tab that created the claim has had a chance to observe it. A direct
; release after TextSend would reopen the still-visible tooltip before its
; generation-fenced hide timer runs and permit a second injection.
_LLM_Accept_DeferClaimRelease() {
	global _LLM_ACCEPT_CLAIM_RELEASE_DELAY_MS
	SetTimer(_LLM_Accept_ReleaseClaim, -_LLM_ACCEPT_CLAIM_RELEASE_DELAY_MS)
}

_LLM_Accept_IsBarePhysicalTabEvent(IsPhysicalTabEvent, Modifiers, InputSnapshot) {
	if !(IsPhysicalTabEvent is Integer) or IsPhysicalTabEvent != true
		return false
	if _LLM_Accept_HasDeclaredModifiers(Modifiers)
		return false
	if !(InputSnapshot is Map)
		return false
	static RequiredInputKeys := ["known", "tab_down", "ctrl_down", "alt_down",
		"shift_down", "win_down", "current_hwnd", "current_control"]
	for Key in RequiredInputKeys {
		if !InputSnapshot.Has(Key)
			return false
	}
	for Key in ["known", "tab_down", "ctrl_down", "alt_down", "shift_down", "win_down"] {
		if !(InputSnapshot[Key] is Integer)
			return false
	}
	if !InputSnapshot["known"] or !InputSnapshot["tab_down"]
		return false
	if (InputSnapshot["ctrl_down"] or InputSnapshot["alt_down"]
			or InputSnapshot["shift_down"] or InputSnapshot["win_down"])
		return false
	return true
}

; Pure policy predicate used by the canonical acceptance primitive. The source
; is the one published by the render, not the mutable source of the newest
; pending keystroke: a visible tooltip from control A must stay owned by A even
; after control B has armed another request.
_LLM_Accept_IsAllowed(IsPhysicalTabEvent, Modifiers, InputSnapshot, RenderedSource) {
	if !_LLM_Accept_IsBarePhysicalTabEvent(IsPhysicalTabEvent, Modifiers, InputSnapshot)
		return false
	if !(RenderedSource is Map)
		return false
	SourceHwnd := RenderedSource.Get("hwnd", 0)
	SourceControl := RenderedSource.Get("control", 0)
	CurrentHwnd := InputSnapshot["current_hwnd"]
	CurrentControl := InputSnapshot["current_control"]
	if !(SourceHwnd is Integer and SourceHwnd > 0
			and SourceControl is Integer and SourceControl > 0
			and CurrentHwnd is Integer and CurrentHwnd > 0
			and CurrentControl is Integer and CurrentControl > 0)
		return false
	return (SourceHwnd == CurrentHwnd and SourceControl == CurrentControl)
}

/**
 * Canonical LLM acceptance primitive. Only an unmodified PHYSICAL Tab in the
 * exact HWND/control that owns the rendered prediction may inject it. Optional
 * snapshots/callbacks are deterministic unit-test seams; production call sites
 * and their physical-event provenance are exhaustively meta-guarded.
 * @param {boolean} IsPhysicalTabEvent - True only at a real Tab event source.
 * @param {Array|String} Modifiers - Declared TextPressKey modifiers.
 * @param {Map} InputSnapshot - Optional current physical/focus snapshot.
 * @param {Func} AcceptFn - Optional injection callback.
 * @returns {boolean} True when this Tab owns, or joins, the one active claim.
 */
LLM_Tooltip_TryAcceptTab(IsPhysicalTabEvent := false, Modifiers := [], InputSnapshot := unset, AcceptFn := unset) {
	global _LLM_AcceptInProgress
	; Snapshot one presented tuple before any OS/focus probe. The later claim
	; revalidates this exact record, so navigation or a replacement render cannot
	; splice B's text onto A's focus source while the probe yields.
	Presented := LLM_Tooltip_GetAcceptSnapshot()
	if !IsSet(InputSnapshot)
		InputSnapshot := _LLM_Accept_ReadInputSnapshot()
	PreviousCritical := Critical("On")
	try {
		; The HotIf and InputHook callbacks can observe the SAME physical Tab. The
		; first callback owns injection; a sibling may join only when it proves the
		; same bare physical-Tab profile. Chords and remaps keep their normal output.
		if _LLM_AcceptInProgress {
			return _LLM_Accept_IsBarePhysicalTabEvent(
				IsPhysicalTabEvent, Modifiers, InputSnapshot)
		}
		if !IsObject(Presented)
			return false
		if !_LLM_Accept_IsAllowed(
			IsPhysicalTabEvent, Modifiers, InputSnapshot,
			Presented.AcceptSource)
			return false
		if !IsSet(AcceptFn) {
			AdmissionSeed := _LLM_Bridge_CaptureAdmissionSeed(
				Presented.AcceptSource)
		}
		ClaimedLifecycle := LLM_Tooltip_ClaimAcceptance(
			Presented.Record, Presented.Surface, Presented.ActiveIdx)
		if !IsObject(ClaimedLifecycle)
			return false
		_LLM_AcceptInProgress := true
	} finally {
		Critical(PreviousCritical)
	}
	KeepClaimForProductionCompletion := !IsSet(AcceptFn)
	DispatchCompleted := false
	try {
		if IsSet(AcceptFn)
			AcceptFn.Call(Presented.Text)
		else
			LLM_Bridge_OnAccept(
				Presented.Text, AdmissionSeed, Presented.Slots,
				Presented.ActiveIdx, Presented.Record, ClaimedLifecycle)
		DispatchCompleted := true
	} finally {
		; Deterministic test callbacks have no sender-owned completion lifecycle.
		; Production releases one deferred turn after direct or clipboard sender
		; completion. A thrown production dispatch owns no future callback, but it
		; still defers release so the sibling callback for this physical Tab cannot
		; retry the failed transaction.
		if !KeepClaimForProductionCompletion {
			LLM_Tooltip_FinalizeAcceptance(
				ClaimedLifecycle, DispatchCompleted)
			LLM_Tooltip_HideExact(Presented.Record, DispatchCompleted)
			_LLM_Accept_ReleaseClaim()
		} else if !DispatchCompleted {
			LLM_Tooltip_FinalizeAcceptance(ClaimedLifecycle, false)
			LLM_Tooltip_HideExact(Presented.Record)
			_LLM_Accept_DeferClaimRelease()
		}
	}
	return true
}

; Emit Tab normally whenever canonical acceptance rejects it. This is used by
; tap-hold/gesture remaps too: they retain the default non-physical provenance,
; so they navigate as configured and can never accept an LLM prediction.
LLM_Tooltip_FireTabOrAccept(Modifiers := [], IsPhysicalTabEvent := false) {
	if LLM_Tooltip_TryAcceptTab(IsPhysicalTabEvent, Modifiers)
		return true
	TextPressKey("Tab", Modifiers)
	return false
}





; =================================
; =================================
; ======= 3/ Initialisation =======
; =================================
; =================================

/**
 * Starts the LLM bridge with the given configuration.
 * Keystrokes are delivered by PrefixWatcher (see ``LLM_Bridge_Feed*``).
 * @param {Map} opts - Configuration passed through to LLM_Engine_Init().
 */
LLM_Bridge_Start(opts) {
	global _LLM_Bridge_Active
	LLM_Engine_Init(opts)
	if _LLM_Bridge_Active
		return
	if (IsSet(_PrefixInputHook) && _PrefixInputHook) {
		_LLM_Bridge_Activate("PrefixWatcher")
		_LLM_PointerWatch_Start()
		return
	}
	_LLM_Bridge_RegisterDispatcherFallback()
	_LLM_Bridge_Active := true
	_LLM_PointerWatch_Start()
	try LoggerInfo("LLM", "Bridge engine ready — keystrokes via HookDispatcher until PrefixWatcher starts.")
}

/**
 * Turns on keystroke capture once a reliable hook exists.
 * @param {string} source - ``PrefixWatcher`` or ``HookDispatcher`` (for logs).
 */
_LLM_Bridge_Activate(source) {
	global _LLM_Bridge_Active
	_LLM_Bridge_UnregisterDispatcherFallback()
	if _LLM_Bridge_Active
		return
	_LLM_Bridge_Active := true
	_LLM_PointerWatch_Start()
	try LoggerInfo("LLM", "Bridge active — keystrokes via {1}.", source)
}

_LLM_Bridge_RegisterDispatcherFallback() {
	global _LLM_Bridge_DispatcherCharFn, _LLM_Bridge_DispatcherKeyFn
	if !IsSet(HookDispatcher) or !IsSet(HookDispatcherConst)
		return
	if !(_LLM_Bridge_DispatcherCharFn is Func) {
		_LLM_Bridge_DispatcherCharFn := _LLM_Bridge_OnDispatcherChar.Bind()
		_LLM_Bridge_DispatcherKeyFn := _LLM_Bridge_OnDispatcherKey.Bind()
	}
	try HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_DispatcherCharFn)
	try HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_DispatcherKeyFn)
}

_LLM_Bridge_UnregisterDispatcherFallback() {
	global _LLM_Bridge_DispatcherCharFn, _LLM_Bridge_DispatcherKeyFn
	if (_LLM_Bridge_DispatcherCharFn is Func) {
		try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_DispatcherCharFn)
		try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_DispatcherKeyFn)
	}
}

; One of the two consumers of every character event, and the one with no segment:
; the profiler showed ~600 slow OnChar events with no matching slow HSE.FeedChar,
; which left this path as the only unattributed candidate. Two QPC reads, and the
; line is gated by the profiler floor so ordinary typing logs nothing.
_LLM_Bridge_OnDispatcherChar(ih, ch) {
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		return
	_hpLlmChar := HotPath_Now()
	LLM_Bridge_OnChar(ch)
	HotPath_LogIfSlow("LLM.OnChar", _hpLlmChar, "")
}

_LLM_Bridge_OnDispatcherKey(ih, vk, sc) {
	if (IsSet(_PrefixInputHook) && _PrefixInputHook)
		return
	LLM_Bridge_FeedKeyDownIfActive(vk)
}

/**
 * Stops the bridge and hides any visible tooltip.
 */
LLM_Bridge_Stop() {
	global _LLM_Bridge_Active
	_LLM_Bridge_UnregisterDispatcherFallback()
	_LLM_PointerWatch_Stop()
	if !_LLM_Bridge_Active
		return
	_LLM_Bridge_Active := false
	_LLM_Bridge_ClearBuffer()
	try LLM_Engine_StopGeneration()   ; Cancel in-flight HTTP before disabling the engine
	LLM_Engine_SetEnabled(false)
	try LLM_OllamaCancelWarmupRetry()
	LLM_Tooltip_Hide()
	try LoggerInfo("LLM", "Bridge stopped.")
}

/**
 * Called when PrefixWatcher's InputHook comes online after an early Ollama bootstrap.
 */
LLM_Bridge_OnPrefixWatcherReady() {
	global _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		_LLM_Bridge_Activate("PrefixWatcher")
	else
		_LLM_Bridge_UnregisterDispatcherFallback()
}

/**
 * Called from PrefixWatcher on each printable character (when not suppressed).
 * @param {string} ch - Character from the prefix InputHook.
 */
LLM_Bridge_FeedCharIfActive(ch) {
	if (IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		LLM_Bridge_OnChar(ch)
}

/**
 * Called from PrefixWatcher or the early HookDispatcher fallback for
 * navigation / editing keys.
 * @param {Integer} vk - Virtual key code.
 * @param {boolean} IsPhysicalEvent - True only for the I1-filtered prefix hook.
 */
LLM_Bridge_FeedKeyDownIfActive(vk, IsPhysicalEvent := false) {
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	if (vk = 0x08)
		LLM_Bridge_OnBackspace()
	else if (vk = 0x09) {
		if LLM_Tooltip_TryAcceptTab(IsPhysicalEvent, []) {
			; Cancel the debounce timer so a stale prediction does not flash
			; the tooltip again immediately after the user accepted the suggestion
			LLM_Engine_CancelTimer()
			return
		}
		LLM_Bridge_OnFlush()
	} else if (vk = 0x0D or vk = 0x1B)
		LLM_Bridge_OnFlush()
}





; =========================================
; =========================================
; ======= 4/ Keyboard Hook Handlers =======
; =========================================
; =========================================

/**
 * Schedules an LLM prediction to fire when the hotstring tooltip closes.
 * Called from the prefix watcher after a hotstring preview is shown.
 * Parity with macOS llm_bridge.update_preview() chain branch.
 * @param {Array} items - Tooltip rows shown by TooltipShow (DurationSec per row).
 * @param {Object} SurfaceToken - Optional immutable owner from the pixel commit.
 */
LLM_Bridge_ScheduleAfterHotstring(items, SurfaceToken := 0) {
	global _LLM_Bridge_Active, _LLM_Bridge_Buffer, _LLM_Engine
	global _LLM_HOTSTRING_CHAIN_OFFSET_SEC, _LLM_INFINITE_TOOLTIP_SEC
	global _LLM_MIN_TOOLTIP_DURATION_SEC

	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	if !(IsSet(_LLM_Engine) && _LLM_Engine["enabled"] && _LLM_Engine["after_hotstring"])
		return
	if !(IsObject(items) && items.Length > 0)
		return false
	if (IsObject(SurfaceToken)
		and !TooltipSurfaceTokenIsCurrent(SurfaceToken))
		return false

	minDur := 0
	hasDur := false
	for , Item in items {
		D := Item.HasOwnProp("DurationSec") ? Item.DurationSec : 0
		if (D > 0) {
			hasDur := true
			if (minDur == 0 or D < minDur)
				minDur := D
		}
	}
	tooltipTimeout := hasDur
		? Max(_LLM_MIN_TOOLTIP_DURATION_SEC, minDur)
		: _LLM_INFINITE_TOOLTIP_SEC
	delaySec := tooltipTimeout + _LLM_HOTSTRING_CHAIN_OFFSET_SEC
    BridgeBuffer := _LLM_Bridge_Buffer
	; StartTimer performs focus capture outside its short mutation span, then
	; rechecks this surface token atomically with cancel + re-arm. A stale tooltip
	; callback therefore cannot cancel a newer typing timer or install its own.
	Scheduled := IsObject(SurfaceToken)
		? LLM_Engine_StartTimer(delaySec, BridgeBuffer,
			TooltipSurfaceTokenIsCurrent.Bind(SurfaceToken))
		: LLM_Engine_StartTimer(delaySec, BridgeBuffer)
	if !Scheduled
		return false
	try LoggerDebug("LLM", "Hotstring chain scheduled in {1:.3f}s.", delaySec)
	return true
}

; Returns true when char ``c`` is a word boundary — whitespace or common sentence/
; clause punctuation. Apostrophes are intentionally NOT boundaries (French "l'arbre").
_LLM_Bridge_IsBoundaryChar(c) {
	static _boundaries := " `t`n`r.,;:!?" . Chr(0x00A0) . Chr(0x202F)
	return (c != "" and InStr(_boundaries, c) > 0)
}

; True when the just-typed char completes a word and instant_on_word_end is enabled:
; the char is a boundary and the character before it (the buffer already has ch
; appended) is a word character. Mirrors macOS engine.start_timer_word_end gating.
_LLM_Bridge_IsWordEndTrigger(ch) {
	global _LLM_Engine, _LLM_Bridge_Buffer
	if !(_LLM_Engine.Has("instant_on_word_end") and _LLM_Engine["instant_on_word_end"])
		return false
	if !_LLM_Bridge_IsBoundaryChar(ch)
		return false
	prev := SubStr(_LLM_Bridge_Buffer, -2, 1)  ; the char before the just-appended ch
	return (prev != "" and !_LLM_Bridge_IsBoundaryChar(prev))
}

; Queue layered-Gui teardown off a keyboard hook while preserving the exact
; presented record. A generation-only snapshot allowed an A callback to hide B
; after wrap/rebuild paths changed the active semantics between snapshot and run.
LLM_Bridge_DeferTooltipHide(accepted := false, ExpectedRecord := 0) {
	Record := IsObject(ExpectedRecord)
		? ExpectedRecord : LLM_Tooltip_GetPresentedToken()
	if !IsObject(Record)
		return false
	SetTimer(_LLM_Bridge_DeferredTooltipHide.Bind(Record, accepted), -1)
	return true
}

_LLM_Bridge_DeferredTooltipHide(ExpectedRecord, accepted) {
	LLM_Tooltip_HideExact(ExpectedRecord, accepted)
}

/**
 * Must be called from a hotkey or keyboard hook on every typed character.
 * Maintains the rolling context buffer and feeds it to the prediction engine.
 * @param {string} ch - The character that was just typed.
 */
LLM_Bridge_OnChar(ch) {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return

	_LLM_Bridge_ApplyBufferEdit(0, ch)
	; Hotstring tooltip priority: if the PrefixWatcher's tooltip is visible,
	; update the buffer but do NOT arm the LLM timer — LLM_Bridge_ScheduleAfterHotstring
	; (fired from _LookupAndRender) owns the chain delay until
	; the overlay closes, mirroring HS update_preview().
	if TooltipIsVisible()
		return
	; Only hide OUR tooltip — never dismiss a hotstring overlay. The canonical
	; lifecycle emits dismissal for the exact offer this keystroke supersedes.
	if LLM_Tooltip_IsVisible() {
		; Minimum-display window: a keystroke that was already in flight when the
		; slow model finally answered must not kill the prediction before the user
		; can perceive it. The buffer still advances below; only the dismiss is
		; deferred. Once the window elapses, typing dismisses as usual.
		if (IsSet(LLM_Tooltip_InGracePeriod) && LLM_Tooltip_InGracePeriod()) {
			try LoggerDebug("LLM.tt", "KEEP: keystroke '{1}' ignored — prediction still in min-display window.", ch)
		} else {
			try LoggerDebug("LLM.tt", "DISMISS: keystroke '{1}' typed while a prediction was shown.", ch)
			; Defer the tooltip teardown off the InputHook thread: the dismiss tears
			; down a multi-window layered overlay (DeferWindowPos batch + Gui Destroy),
			; and a slow DWM compositor can stretch that past Windows'
			; LowLevelHooksTimeout, dropping the in-flight or next physical key. The
			; hook stays fast — buffer + engine feed below are cheap — while the
			; expensive GDI/DWM work runs on a fresh thread once the hook returns
			; (mirrors the auto-hide TimerFn, which already runs off-thread).
			LLM_Bridge_DeferTooltipHide()
		}
	}
	global _LLM_Bridge_LastLogTick
	now := A_TickCount
	; Wrap-safe tick delta: A_TickCount overflows at ~49.7 days
	if (((now - _LLM_Bridge_LastLogTick + 0x100000000) & 0xFFFFFFFF) > 2000) {
		_LLM_Bridge_LastLogTick := now
		try LoggerInfo("LLM", "Keystroke buffered ({1} chars) — debounce pending.", StrLen(_LLM_Bridge_Buffer))
	}
	; instant_on_word_end: when the just-typed char completes a word (a word char
	; followed by whitespace/punctuation) and the user enabled the option, fire the
	; prediction immediately instead of waiting the full debounce — macOS parity with
	; engine.start_timer_word_end (llm-instant-word-end-trigger).
	if _LLM_Bridge_IsWordEndTrigger(ch)
		LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer, 0)
	else
		LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer)
}

/**
 * Must be called when Backspace is pressed.
 * Removes the last character from the buffer.
 */
LLM_Bridge_OnBackspace() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return

	_LLM_Bridge_ApplyBufferEdit(1, "")

	; Same hotstring-priority guard as OnChar.
	if TooltipIsVisible()
		return
	if LLM_Tooltip_IsVisible()
		LLM_Bridge_DeferTooltipHide()
	LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer)
}

/**
 * Must be called on Enter, Escape, or Tab.
 * Flushes the buffer so the next prediction starts from a fresh context.
 */
LLM_Bridge_OnFlush() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return
	_LLM_Bridge_ClearBuffer()
	LLM_Bridge_ResetPredictions()
}

/**
 * Returns true when pointer activity should cancel LLM work (tooltip, loading,
 * debounce timer, or in-flight HTTP/stream).
 */
LLM_Bridge_HasActivePredictionWork() {
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return false
	if (IsSet(LLM_Tooltip_IsVisible) && LLM_Tooltip_IsVisible())
		return true
	if (IsSet(LLM_Tooltip_IsLoading) && LLM_Tooltip_IsLoading())
		return true
	return LLM_Engine_IsBusy()
}

/**
 * Clears predictions, cancels generation, and hides the tooltip.
 * Parity with macOS LLMBridge.reset_predictions() + engine.reset().
 */
LLM_Bridge_ResetPredictions() {
	global _LLM_Bridge_Buffer, _LLM_Engine, _LLM_Bridge_Active
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active)
		return
	if !LLM_Bridge_HasActivePredictionWork()
		return
	try LoggerDebug("LLM.tt", "ResetPredictions: cancelling generation + hiding any tooltip.")
	if (IsSet(_LLM_Engine) and _LLM_Engine.Has("reset_on_nav") and _LLM_Engine["reset_on_nav"])
		_LLM_Bridge_ClearBuffer()
	; Timings only: the surface is about to be hidden, so the full re-render the
	; old call performed here was painted and thrown away in the same breath.
	try LLM_Tooltip_MarkChainTimingOnly(A_TickCount)
	LLM_Engine_StopGeneration()
	if ((IsSet(LLM_Tooltip_IsVisible) && LLM_Tooltip_IsVisible())
			or (IsSet(LLM_Tooltip_IsLoading) && LLM_Tooltip_IsLoading()))
		LLM_Bridge_DeferTooltipHide()
}

/**
 * Entry point for mouse / touchpad / wheel activity. Cancels ANY in-progress LLM
 * work — the loading spinner, an in-flight generation, or a shown prediction — so
 * any user input dismisses the prediction (macOS parity: its mouse_tap calls
 * reset_predictions on a click in every phase, and a keystroke cancels generation
 * via stop_timer). A real prediction is still shielded during its minimum-display
 * grace window so an incidental click / drift the instant it renders cannot kill it
 * before it is seen — the loading spinner has no grace, so it cancels immediately.
 */
LLM_Bridge_OnPointerActivity(reason := "?") {
	if !LLM_Bridge_HasActivePredictionWork()
		return
	; Minimum-display window: ignore stray pointer drift in the first moments after a
	; real prediction renders so it cannot vanish before the user perceives it.
	; InGracePeriod is false during loading, so the spinner stays fully cancellable.
	if (IsSet(LLM_Tooltip_InGracePeriod) && LLM_Tooltip_InGracePeriod())
		return
	; ``reason`` names the exact trigger: a mouse-button / wheel hotkey passes its
	; own name (e.g. "~LButton"), the move-tick passes "move dx=.. dy=..". This is
	; the lens for "it vanished while I sat still" — the log says whether it was a
	; real click, a wheel event, or pointer travel, and by how much.
	try LoggerDebug("LLM.tt", "DISMISS: pointer activity ({1}) — cancelling in-progress generation + tooltip.", reason)
	LLM_Bridge_ResetPredictions()
}

_LLM_PointerWatch_Start() {
    global _LLM_PointerWatch_Armed, _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY
	if _LLM_PointerWatch_Armed
		return
	_LLM_PointerWatch_Armed := true
	_LLM_PointerWatch_LastX := unset
	_LLM_PointerWatch_LastY := unset
	; Always create a fresh Func object on each arm so the previous stop/start
	; cycle cannot leave a stale closure still registered in HookDispatcher — a
	; second Register with the SAME Func object would fire the handler twice per
	; event if HookDispatcher does not deduplicate by identity
	_LLM_PointerWatch_ActivityFn := LLM_Bridge_OnPointerActivity.Bind()
	; Subscribe via HookDispatcher for every key the dispatcher owns so we do not
	; clobber the dispatcher's central handlers (mouse-hotkey-clobber). XButton1/2
	; are not registered by the dispatcher — keep those as direct hotkeys.
	for evt in [HookDispatcherConst.EVT_MS_LDOWN, HookDispatcherConst.EVT_MS_RDOWN,
			HookDispatcherConst.EVT_MS_MDOWN, HookDispatcherConst.EVT_MS_WUP,
			HookDispatcherConst.EVT_MS_WDN, HookDispatcherConst.EVT_MS_WLEFT,
			HookDispatcherConst.EVT_MS_WRIGHT] {
		HookDispatcher.Register(evt, _LLM_PointerWatch_ActivityFn)
	}
	try Hotkey("~XButton1", _LLM_PointerWatch_ActivityFn, "On")
	try Hotkey("~XButton2", _LLM_PointerWatch_ActivityFn, "On")
	; Similarly create a fresh move-tick closure so SetTimer can cancel the old
	; one cleanly even if _LLM_PointerWatch_Stop was called without cancelling
	_LLM_PointerWatch_MoveFn := _LLM_PointerWatch_OnMoveTick.Bind()
	global _LLM_POINTER_POLL_MS
	SetTimer(_LLM_PointerWatch_MoveFn, _LLM_POINTER_POLL_MS)
	try LoggerDebug("LLM", "Pointer-dismiss watcher armed.")
}

_LLM_PointerWatch_Stop() {
	global _LLM_PointerWatch_Armed, _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn
	if !_LLM_PointerWatch_Armed
		return
	_LLM_PointerWatch_Armed := false
	if IsSet(_LLM_PointerWatch_MoveFn) and (_LLM_PointerWatch_MoveFn is Func)
		try SetTimer(_LLM_PointerWatch_MoveFn, 0)
	if IsSet(_LLM_PointerWatch_ActivityFn) and (_LLM_PointerWatch_ActivityFn is Func) {
		for evt in [HookDispatcherConst.EVT_MS_LDOWN, HookDispatcherConst.EVT_MS_RDOWN,
				HookDispatcherConst.EVT_MS_MDOWN, HookDispatcherConst.EVT_MS_WUP,
				HookDispatcherConst.EVT_MS_WDN, HookDispatcherConst.EVT_MS_WLEFT,
				HookDispatcherConst.EVT_MS_WRIGHT] {
			HookDispatcher.Unregister(evt, _LLM_PointerWatch_ActivityFn)
		}
		try Hotkey("~XButton1", _LLM_PointerWatch_ActivityFn, "Off")
		try Hotkey("~XButton2", _LLM_PointerWatch_ActivityFn, "Off")
	}
	try LoggerDebug("LLM", "Pointer-dismiss watcher stopped.")
}

; True when the cursor has travelled far enough from its origin to count as a
; deliberate move rather than sensor jitter / a hand resting on the mouse. Pure,
; so the threshold logic is unit-testable without a real pointer.
_LLM_PointerMovedEnough(x, y, ox, oy) {
	global _LLM_POINTER_MOVE_THRESHOLD_PX
	return (Abs(x - ox) > _LLM_POINTER_MOVE_THRESHOLD_PX
			or Abs(y - oy) > _LLM_POINTER_MOVE_THRESHOLD_PX)
}

_LLM_PointerWatch_OnMoveTick(*) {
	global _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY
	local _c := Critical("On")
	try {
	; AHK SetTimer threads bypass native Suspend, so this poll keeps firing
	; (MouseGetPos + branch) ~20x/s while the driver is paused. Inert it here so
	; "pause = tout eteint" holds even if the suspend reactor's _Stop call is ever
	; bypassed — the timer is also stopped from Ergopti_OnSuspendEnter, but this
	; guard is the cheap, local safety net.
	if A_IsSuspended
		return
	; Dismiss-on-move applies whenever LLM work is active — the loading spinner, an
	; in-flight generation, or a shown prediction (any input cancels). While NO work
	; is active we drop the origin so the next cycle captures a fresh one; the grace
	; branch below still shields a just-rendered prediction during its window.
	if !LLM_Bridge_HasActivePredictionWork() {
		_LLM_PointerWatch_LastX := unset
		_LLM_PointerWatch_LastY := unset
		return
	}
	; During the minimum-display window, ignore pointer movement entirely and keep
	; the origin unset, so motion that happened while the prediction was settling in
	; cannot dismiss it the instant the window opens.
	if (IsSet(LLM_Tooltip_InGracePeriod) && LLM_Tooltip_InGracePeriod()) {
		_LLM_PointerWatch_LastX := unset
		_LLM_PointerWatch_LastY := unset
		return
	}
	MouseGetPos(&x, &y)
	; First tick past the window: capture the ORIGIN once and never dismiss on it.
	if !IsSet(_LLM_PointerWatch_LastX) {
		_LLM_PointerWatch_LastX := x
		_LLM_PointerWatch_LastY := y
		return
	}
	; Measure TOTAL displacement from that fixed origin and dismiss only once it
	; clears the threshold — a deliberate relocation of the cursor. The origin is
	; never reassigned, so a hand lifting off the mouse (a ~50 px settle) and any
	; jitter/drift stay below it and keep the prediction up; only travelling well
	; away from where the prediction appeared counts as "the user moved on". This is
	; the "arrêté, rien touché" fix. A click still dismisses via its own hotkeys.
	dx := Abs(x - _LLM_PointerWatch_LastX)
	dy := Abs(y - _LLM_PointerWatch_LastY)
	if _LLM_PointerMovedEnough(x, y, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY)
		LLM_Bridge_OnPointerActivity("move dx=" . dx . " dy=" . dy)
	} finally {
		Critical(_c)
	}
}

/**
 * Called when the user accepts the suggestion (e.g. pressing Tab over tooltip).
 * Appends the accepted text to the buffer and types it into the active window.
 * @param {string} text - The accepted prediction text.
 */
LLM_Bridge_OnAccept(text, AdmissionSeed, Slots := unset, ActiveIdx := 1,
		PresentedRecord := 0, PresentedLifecycle := 0) {
	; AHK-09: invalidate every in-flight sequential/streaming variant callback so
	; they cannot re-show the tooltip after the user has already accepted a
	; suggestion. StopGeneration bumps request_id (all async callbacks bail on id
	; mismatch), cancels curl+WinHTTP streams, cancels the debounce timer, and
	; drops last_ctx/last_results so the dismissed context cannot replay from cache.
	; Must run BEFORE the injection so the id is bumped while callbacks are live.
	RequestId := LLM_Engine_StopGeneration()
	if !(RequestId is Integer) or RequestId < 0
		throw Error("LLM acceptance requires initialized engine state.")
	Transaction := _LLM_Bridge_NewInjectionTransaction(
		text, AdmissionSeed, RequestId, false, Slots, ActiveIdx,
		PresentedRecord, PresentedLifecycle)
	TextSend(text, _LLM_Bridge_InjectionOptions(Transaction),
		_LLM_Bridge_OnInjectComplete.Bind(Transaction))
}

; Invoked after TextSender atomically emitted the accepted prediction and
; committed the canonical metrics row and every RAM mirror. This open-thread
; phase owns only tooltip teardown and the acceptance-claim lifecycle.
_LLM_Bridge_OnInjectComplete(Transaction, Ok := true, ErrorMessage := "") {
	HideQueued := false
	try {
		if !Ok {
			try LoggerWarn("LLM", "Prediction acceptance was not injected: {1}", ErrorMessage)
			LLM_Tooltip_FinalizeAcceptance(
				Transaction.PresentedLifecycle, false)
			LLM_Bridge_DeferTooltipHide(false,
				Transaction.PresentedRecord)
			return
		}
		if (ErrorMessage != "")
			try LoggerWarn("LLM", "Prediction output completed with a non-retryable warning: {1}", ErrorMessage)
		LLM_Tooltip_FinalizeAcceptance(
			Transaction.PresentedLifecycle, true)
		LLM_Bridge_DeferTooltipHide(true,
			Transaction.PresentedRecord)
		_LLM_Accept_DeferClaimRelease()
		HideQueued := true
	} finally {
		; A failed sender callback (or a failure while committing its state) never
		; reaches the success path that normally releases the acceptance claim.
		if !HideQueued
			_LLM_Accept_DeferClaimRelease()
	}
}

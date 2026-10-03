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
; 5. Agent-only feed: while the bridge is inactive (the AI menu switched off,
;    or its backend not ready), keystrokes still reach the AI agent's automatic
;    mode through a context of its own, and nothing of the predictions runs.
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
global _LLM_Bridge_PrefixObserver := 0
; The AI agent's typing context while the prediction bridge is inactive. The
; agent's automatic mode does not depend on the AI menu's switch (macOS feeds
; its observer from update_preview, Linux from on_char, whatever the switch
; says), so the keystrokes the inactive bridge would drop still reach
; LLM_Agent_OnTyping. It is kept apart from _LLM_Bridge_Buffer, whose content
; generation fences the prediction outputs: observing for the agent leaves
; every prediction state untouched.
global _LLM_Bridge_AgentBuffer := ""
global _LLM_Bridge_AgentFeeding := false
global _LLM_Bridge_AgentFeedErrorTick := 0
global _LLM_BRIDGE_AGENT_FEED_ERROR_THROTTLE_MS := 60000
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
global _LLM_PointerWatch_CleanupPending := false
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
	LLM_Bridge_CancelPrefixObserver()
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

; The live foreground window and focused control an injected text is admitted
; into, as Map("hwnd", "control"). A global holding a function, as
; _AHK_SendInput is, so a test can drive a real acceptance through admission
; without owning the foreground window of a headless runner.
global _LLM_Bridge_ReadLiveFocus := () => Map(
	"hwnd", WIGetForegroundHwnd(), "control", WIGetFocusedControlToken())

_LLM_Bridge_TextAdmissionStillCurrent(Expected) {
	global _LLM_Bridge_ContentGeneration, _PrefixInputContextGeneration, _LLM_Engine
	global _LLM_Bridge_ReadLiveFocus
	LiveRequestId := (IsSet(_LLM_Engine) and _LLM_Engine is Map)
		? _LLM_Engine.Get("request_id", -1) : -1
	Focus := _LLM_Bridge_ReadLiveFocus.Call()
	Live := Map(
		"hwnd", Focus["hwnd"],
		"control", Focus["control"],
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
		PresentedRecord := 0, PresentedLifecycle := 0, Edit := 0) {
	Admission := _LLM_Bridge_MakeTextAdmission(Seed, RequestId)
	SlotSnapshot := (IsSet(Slots) and Slots is Array) ? Slots.Clone() : [Text]
	; A rewrite erases the end of what the user typed before typing Text; every
	; other prediction only appends. The count is in Backspace presses (one per
	; codepoint), the text is what they erase, in the buffer's UTF-16 units.
	HasEdit := (Edit is Map)
	return {
		Text: Text,
		Deletes: HasEdit ? Edit["deletes"] : 0,
		DeletedText: HasEdit ? Edit["deleted_text"] : "",
		RewriteSpan: HasEdit ? Edit["span"] : "",
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
	; A rewrite's Backspaces erased DeletedText from the screen in the same OS
	; batch as the text: the buffer mirrors both, as a delete then an insert.
	_LLM_Bridge_ApplyBufferEdit(StrLen(Transaction.DeletedText), Transaction.Text)
	if Transaction.Inline {
		if !(_LLM_Engine is Map)
			throw Error("LLM engine state is unavailable during inline commit.")
		_LLM_Engine["inline_last_typed"] := Transaction.Text
	}
	if !IsSet(_PrefixCommitInputContext) or !IsSet(_PrefixFinishInputContext)
		throw Error("Prefix/HSE paired commit owner is unavailable.")
	PrefixCommit := _PrefixCommitInputContext(Transaction.SourceControl, false)
	; Feed the WPM widget one sample per accepted character, marked AI, so the
	; pill turns the AI colour as it does on macOS and Linux. Nothing marked
	; AI text on this driver, so that colour was never shown.
	if IsSet(WPMWidget_Push) {
		Loop StrLen(Transaction.Text)
			try WPMWidget_Push(false, true)
	}
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
		"erase_before", Transaction.Deletes,
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
		"deletes", Transaction.Deletes,
		"deleted_text", Transaction.DeletedText,
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

; Whether a Tab is the user's own bare Tab key: the physical Tab, down now, or
; the tap of a tap-hold key whose tap is Tab (the recommended AltGr), while the
; dispatcher still runs that very tap (TapHoldTapProvenance). Anything else, a
; gesture, a macro, a text send or a timer, carries no provenance. No modifier
; may be declared or physically held (llm-accept-inserts).
_LLM_Accept_IsBareUserTabEvent(TabProvenance, Modifiers, InputSnapshot) {
	return _LLM_Accept_BareTabRefusal(TabProvenance, Modifiers, InputSnapshot) == ""
}

; The tap-hold key a Tab provenance names, or "" when it names none.
_LLM_Accept_TapHoldTapKey(TabProvenance) {
	if !(TabProvenance is Map) || TabProvenance.Get("kind", "") != "tap_hold_tap"
		return ""
	KeyId := TabProvenance.Get("key_id", "")
	return (KeyId is String) ? KeyId : ""
}

; Whether a Tab comes from a key the user pressed, the only Tabs worth tracing.
_LLM_Accept_IsUserTabProvenance(TabProvenance) {
	return ((TabProvenance is Integer) && TabProvenance == true)
		|| _LLM_Accept_TapHoldTapKey(TabProvenance) != ""
}

_LLM_Accept_AnyModifierDown(InputSnapshot) {
	return (InputSnapshot["ctrl_down"] or InputSnapshot["alt_down"]
		or InputSnapshot["shift_down"] or InputSnapshot["win_down"])
		? true : false
}

; True when the snapshot's verified focus is the exact HWND/control that owns
; the rendered prediction. Shared by the Tab and slot-chord policies.
_LLM_Accept_FocusMatchesSource(InputSnapshot, RenderedSource) {
	if !(InputSnapshot is Map) or !(RenderedSource is Map)
		return false
	if !InputSnapshot.Get("known", false)
		return false
	SourceHwnd := RenderedSource.Get("hwnd", 0)
	SourceControl := RenderedSource.Get("control", 0)
	CurrentHwnd := InputSnapshot.Get("current_hwnd", 0)
	CurrentControl := InputSnapshot.Get("current_control", 0)
	if !(SourceHwnd is Integer and SourceHwnd > 0
			and SourceControl is Integer and SourceControl > 0
			and CurrentHwnd is Integer and CurrentHwnd > 0
			and CurrentControl is Integer and CurrentControl > 0)
		return false
	return (SourceHwnd == CurrentHwnd and SourceControl == CurrentControl)
}

; Pure policy predicate used by the canonical acceptance primitive. The source
; is the one published by the render, not the mutable source of the newest
; pending keystroke: a visible tooltip from control A must stay owned by A even
; after control B has armed another request.
_LLM_Accept_IsAllowed(TabProvenance, Modifiers, InputSnapshot, RenderedSource) {
	if !_LLM_Accept_IsBareUserTabEvent(TabProvenance, Modifiers, InputSnapshot)
		return false
	return _LLM_Accept_FocusMatchesSource(InputSnapshot, RenderedSource)
}

; Names the gate of the canonical policy that refuses a Tab, or "" when the
; policy admits it. It evaluates the same two predicates as _LLM_Accept_IsAllowed
; in the same order, so a refusal always has exactly one name.
_LLM_Accept_RefusalGate(TabProvenance, Modifiers, InputSnapshot, RenderedSource) {
	Gate := _LLM_Accept_BareTabRefusal(TabProvenance, Modifiers, InputSnapshot)
	if Gate != ""
		return Gate
	if !_LLM_Accept_FocusMatchesSource(InputSnapshot, RenderedSource)
		return "the focus is not the control the prediction was rendered for"
	return ""
}

; The first condition of the bare user-Tab policy that fails, or "" when it
; admits the Tab. The single implementation of that policy, so a refusal always
; has exactly one name.
_LLM_Accept_BareTabRefusal(TabProvenance, Modifiers, InputSnapshot) {
	IsPhysical := (TabProvenance is Integer) && TabProvenance == true
	TapKey := _LLM_Accept_TapHoldTapKey(TabProvenance)
	if !IsPhysical && TapKey == ""
		return "the Tab is neither the physical Tab nor a tap-hold's tap"
	if _LLM_Accept_HasDeclaredModifiers(Modifiers)
		return "the Tab declares modifiers"
	if !(InputSnapshot is Map)
		return "the input snapshot is missing"
	for Key in ["known", "tab_down", "ctrl_down", "alt_down", "shift_down",
			"win_down", "current_hwnd", "current_control"] {
		if !InputSnapshot.Has(Key)
			return "the input snapshot is incomplete"
	}
	for Key in ["known", "tab_down", "ctrl_down", "alt_down", "shift_down", "win_down"] {
		if !(InputSnapshot[Key] is Integer)
			return "the input snapshot is incomplete"
	}
	if !InputSnapshot["known"]
		return "the focus could not be verified"
	; The physical Tab is down while it is pressed; a tap-hold's tap runs on its
	; key's release, so its proof is that the dispatcher still runs this tap.
	if IsPhysical && !InputSnapshot["tab_down"]
		return "Tab is not physically down"
	if !IsPhysical && TapHoldTapInDispatch() != TapKey
		return "the tap of " . TapKey . " is no longer being dispatched"
	if _LLM_Accept_AnyModifierDown(InputSnapshot)
		return "a modifier is physically held"
	return ""
}

/**
 * Warns with the gate that refused the user's Tab (the physical Tab or a
 * tap-hold's Tab tap) while a prediction is on screen. That refusal is
 * otherwise invisible: the Tab reaches the application or the key's tap-hold
 * instead. Silent while no prediction is shown, which is every ordinary Tab
 * press, and while only the loading indicator is.
 * @param {String} Gate - What refused the press.
 * @returns {Boolean} True when the refusal was traced.
 */
LLM_Tooltip_ReportTabRefusal(Gate) {
	if !(Gate is String) || Gate == ""
		throw ValueError("A refused Tab must name the gate that refused it.")
	if !LLM_Tooltip_IsVisible() || LLM_Tooltip_IsLoading()
		return false
	try LoggerWarn("LLM", "Tab not accepted over a shown prediction: {1}.", Gate)
	return true
}

/**
 * Canonical LLM acceptance primitive. Only the user's unmodified Tab key (the
 * physical Tab, or a tap-hold's Tab tap while it is dispatched) in the exact
 * HWND/control that owns the rendered prediction may inject it. Optional
 * snapshots/callbacks are deterministic unit-test seams; production call sites
 * and their event provenance are exhaustively meta-guarded.
 * @param {boolean|Map} TabProvenance - True only at a real Tab event source,
 *     the map TapHoldTapProvenance returns for a tap-hold's Tab tap, false
 *     otherwise.
 * @param {Array|String} Modifiers - Declared TextPressKey modifiers.
 * @param {Map} InputSnapshot - Optional current physical/focus snapshot.
 * @param {Func} AcceptFn - Optional injection callback.
 * @returns {boolean} True when this Tab owns, or joins, the one active claim.
 */
LLM_Tooltip_TryAcceptTab(TabProvenance := false, Modifiers := [], InputSnapshot := unset, AcceptFn := unset) {
	global _LLM_AcceptInProgress
	; Snapshot one presented tuple before any OS/focus probe. The later claim
	; revalidates this exact record, so navigation or a replacement render cannot
	; splice B's text onto A's focus source while the probe yields.
	Presented := LLM_Tooltip_GetAcceptSnapshot()
	if !IsSet(InputSnapshot)
		InputSnapshot := _LLM_Accept_ReadInputSnapshot()
	; Only the user's Tab key can accept, so only its refusal is worth a trace.
	TraceRefusal := _LLM_Accept_IsUserTabProvenance(TabProvenance)
	RefusedGate := ""
	Joined := false
	PreviousCritical := Critical("On")
	try {
		; The HotIf and InputHook callbacks can observe the SAME physical Tab. The
		; first callback owns injection; a sibling may join only when it proves the
		; same bare physical-Tab profile. Chords and remaps keep their normal output.
		if _LLM_AcceptInProgress {
			Joined := _LLM_Accept_IsBareUserTabEvent(
				TabProvenance, Modifiers, InputSnapshot)
			if !Joined
				RefusedGate := "another acceptance owns the claim"
		} else if !IsObject(Presented) {
			RefusedGate := "the shown prediction offers no acceptable snapshot"
		} else if !_LLM_Accept_IsAllowed(
				TabProvenance, Modifiers, InputSnapshot,
				Presented.AcceptSource) {
			RefusedGate := TraceRefusal
				? _LLM_Accept_RefusalGate(TabProvenance, Modifiers,
					InputSnapshot, Presented.AcceptSource)
				: "the Tab is not a physical event"
		}
	} finally {
		Critical(PreviousCritical)
	}
	if Joined
		return true
	if (RefusedGate == "") {
		if _LLM_Accept_ClaimAndDispatch(Presented, AcceptFn?)
			return true
		RefusedGate := "the shown prediction changed before its claim"
	}
	if TraceRefusal
		LLM_Tooltip_ReportTabRefusal(RefusedGate)
	return false
}

/**
 * Claims one policy-approved presented prediction and injects its text. Both
 * canonical primitives (Tab and the slot chord) end here, so the claim, the
 * shared in-progress latch and the single LLM_Bridge_OnAccept call site cannot
 * diverge between them. The caller has already applied its own policy.
 * @param {Object} Presented - Snapshot from LLM_Tooltip_GetAcceptSnapshot.
 * @param {Func} AcceptFn - Optional deterministic injection callback.
 * @returns {boolean} True when this call claimed and dispatched the prediction.
 */
_LLM_Accept_ClaimAndDispatch(Presented, AcceptFn := unset) {
	global _LLM_AcceptInProgress
	PreviousCritical := Critical("On")
	try {
		if _LLM_AcceptInProgress || !IsObject(Presented)
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

/**
 * Second canonical acceptance primitive: inserts slot SlotIdx of the exact
 * prediction whose validation chord (val_modifiers + digit) the native owner
 * consumed. It runs after the chord's modifiers were released, so it demands
 * the same record and surface, the chosen slot still active and painted, no
 * modifier held (it would alter the injected text), and verified focus in the
 * control that owns the render (llm-val-chord-inserts).
 * @param {Object} ExpectedRecord - Record named by the consumed jump receipt.
 * @param {Object} ExpectedSurface - Surface named by the same receipt.
 * @param {Integer} SlotIdx - One-based slot the chord selected.
 * @param {Map} InputSnapshot - Optional current physical/focus snapshot.
 * @param {Func} AcceptFn - Optional injection callback.
 * @returns {boolean} True when the prediction was claimed and dispatched.
 */
LLM_Tooltip_TryAcceptSlot(ExpectedRecord, ExpectedSurface, SlotIdx,
		InputSnapshot := unset, AcceptFn := unset) {
	Presented := LLM_Tooltip_GetAcceptSnapshot()
	if !IsSet(InputSnapshot)
		InputSnapshot := _LLM_Accept_ReadInputSnapshot()
	if !_LLM_Accept_SlotIsAllowed(Presented, ExpectedRecord, ExpectedSurface,
			SlotIdx, InputSnapshot)
		return false
	return _LLM_Accept_ClaimAndDispatch(Presented, AcceptFn?)
}

_LLM_Accept_SlotIsAllowed(Presented, ExpectedRecord, ExpectedSurface, SlotIdx,
		InputSnapshot) {
	return _LLM_Accept_SlotRefusal(Presented, ExpectedRecord, ExpectedSurface,
		SlotIdx, InputSnapshot) == ""
}

; The first condition of the validation-chord policy that fails, or "" when it
; admits the insertion: the single implementation of that policy, so a refused
; insertion always has exactly one name (llm-accept-inserts).
_LLM_Accept_SlotRefusal(Presented, ExpectedRecord, ExpectedSurface, SlotIdx,
		InputSnapshot) {
	if !IsObject(Presented) || !IsObject(ExpectedRecord)
			|| !IsObject(ExpectedSurface)
		return "no prediction offers an acceptable snapshot"
	if ObjPtr(Presented.Record) != ObjPtr(ExpectedRecord)
			|| ObjPtr(Presented.Surface) != ObjPtr(ExpectedSurface)
		return "another prediction replaced the one the chord named"
	if !(SlotIdx is Integer) || SlotIdx < 1
			|| !(Presented.Slots is Array) || SlotIdx > Presented.Slots.Length
			|| Presented.ActiveIdx != SlotIdx
		return "the chosen slot is not the active one"
	if !(InputSnapshot is Map)
		return "the input snapshot is missing"
	for Key in ["ctrl_down", "alt_down", "shift_down", "win_down"] {
		if !InputSnapshot.Has(Key) || !(InputSnapshot[Key] is Integer)
			return "the input snapshot is incomplete"
	}
	if _LLM_Accept_AnyModifierDown(InputSnapshot)
		return "a modifier is physically held"
	if !_LLM_Accept_FocusMatchesSource(InputSnapshot, Presented.AcceptSource)
		return "the focus is not the control the prediction was rendered for"
	return ""
}

; Only the newest chord may insert: a second Alt+N while Alt is still held
; retargets the pending insertion instead of queueing a second one.
global _LLM_SlotAccept_Generation := 0

/**
 * Arms insertion of the slot a consumed validation chord selected, once every
 * modifier is physically released. Driven by the native owner's jump-receipt
 * completion; the wait is bounded so a lost key-up can never leave it armed.
 * @returns {boolean} True when the wait was armed.
 */
LLM_Tooltip_ScheduleSlotAcceptance(Record, Surface, SlotIdx) {
	global _LLM_SlotAccept_Generation
	if !IsObject(Record) || !IsObject(Surface)
			|| !(SlotIdx is Integer) || SlotIdx < 1
		return false
	PreviousCritical := Critical("On")
	try {
		_LLM_SlotAccept_Generation += 1
		State := Map(
			"generation", _LLM_SlotAccept_Generation,
			"record", Record, "surface", Surface, "slot", SlotIdx,
			"poll_ms", TimingsGet("llm", "val_chord_release_poll_ms"),
			"delay_ms", TimingsGet("llm", "val_chord_insert_delay_ms"),
			"started_at", A_TickCount,
			"timeout_ms", TimingsGet("llm", "val_chord_release_timeout_ms"))
	} finally Critical(PreviousCritical)
	SetTimer(_LLM_SlotAccept_Tick.Bind(State), -State["poll_ms"])
	return true
}

; Pure decision for one wait step: "wait", "insert" or "drop".
_LLM_SlotAccept_Step(State, CurrentGeneration, ModifierDown, Now) {
	if !(State is Map) || State["generation"] != CurrentGeneration
		return "drop"
	if TickExpired(State["started_at"], State["timeout_ms"], Now)
		return "drop"
	if !ModifierDown
		return "insert"
	return "wait"
}

_LLM_SlotAccept_Tick(State) {
	global _LLM_SlotAccept_Generation
	ModifierDown := true
	try ModifierDown := _LLM_Accept_AnyModifierDown(
		_LLM_Accept_ReadInputSnapshot())
	Step := _LLM_SlotAccept_Step(State, _LLM_SlotAccept_Generation,
		ModifierDown, A_TickCount)
	if Step == "wait" {
		SetTimer(_LLM_SlotAccept_Tick.Bind(State), -State["poll_ms"])
		return
	}
	if Step == "drop" {
		if State is Map && State["generation"] == _LLM_SlotAccept_Generation
			try LoggerWarn("LLM", "Validation chord expired before prediction {1} could be inserted.", State["slot"])
		return
	}
	SetTimer(_LLM_SlotAccept_Insert.Bind(State), -State["delay_ms"])
}

_LLM_SlotAccept_Insert(State) {
	global _LLM_SlotAccept_Generation
	if State["generation"] != _LLM_SlotAccept_Generation
		return
	if LLM_Tooltip_TryAcceptSlot(State["record"], State["surface"],
			State["slot"]) {
		LLM_Engine_CancelTimer()
		return
	}
	; The chord was consumed, so a refusal leaves the user with nothing typed:
	; name the gate (llm-accept-inserts).
	Gate := _LLM_Accept_SlotRefusal(LLM_Tooltip_GetAcceptSnapshot(),
		State["record"], State["surface"], State["slot"],
		_LLM_Accept_ReadInputSnapshot())
	try LoggerWarn("LLM", "Validation chord did not insert prediction {1}: {2}.",
		State["slot"], Gate != "" ? Gate : "another acceptance owned the claim")
}

; Emit Tab normally whenever canonical acceptance rejects it. A tap-hold's Tab
; tap passes TapHoldTapProvenance(), the user's own key, and accepts like the
; physical Tab; a gesture keeps the default false provenance, so it navigates as
; configured and can never accept an LLM prediction (llm-accept-inserts). The
; same tap under one Shift is the user's Shift+Tab and moves the marker of a
; multi-slot prediction instead (LLM_Menu_NavShiftTabTap).
; @param {Func} ModifierIsHeldFn - Test seam of the Shift+Tab chord; the logical
;     key state when omitted.
LLM_Tooltip_FireTabOrAccept(Modifiers := [], TabProvenance := false,
		ModifierIsHeldFn := 0) {
	if _LLM_Accept_TapHoldTapKey(TabProvenance) != ""
			&& LLM_Menu_NavShiftTabTap(ModifierIsHeldFn)
		return true
	if LLM_Tooltip_TryAcceptTab(TabProvenance, Modifiers)
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
		return
	}
	_LLM_Bridge_RegisterDispatcherFallback()
	try _LLM_PointerWatch_Start()
	catch as Err {
		_LLM_Bridge_UnregisterDispatcherFallback()
		throw Err
	}
	_LLM_Bridge_Active := true
	try LoggerInfo("LLM", "Bridge engine ready — keystrokes via HookDispatcher until PrefixWatcher starts.")
}

/**
 * Turns on keystroke capture once a reliable hook exists.
 * @param {string} source - ``PrefixWatcher`` or ``HookDispatcher`` (for logs).
 */
_LLM_Bridge_Activate(source) {
	global _LLM_Bridge_Active
	if _LLM_Bridge_Active
		return
	_LLM_PointerWatch_Start()
	_LLM_Bridge_UnregisterDispatcherFallback()
	_LLM_Bridge_Active := true
	try LoggerInfo("LLM", "Bridge active — keystrokes via {1}.", source)
}

_LLM_Bridge_RegisterDispatcherFallback(Port := 0) {
	global _LLM_Bridge_DispatcherCharFn, _LLM_Bridge_DispatcherKeyFn
	if !(Port is Map) {
		if !IsSet(HookDispatcher) or !IsSet(HookDispatcherConst)
			throw Error("HookDispatcher is unavailable for the LLM keyboard fallback.")
		Port := Map(
			"register", (EventType, Callback) => HookDispatcher.Register(EventType, Callback),
			"unregister", (EventType, Callback) => HookDispatcher.Unregister(EventType, Callback))
	}
	for Name in ["register", "unregister"] {
		if !HasMethod(Port.Get(Name, 0), "Call")
			throw TypeError("LLM dispatcher fallback port is missing callable '" . Name . "'.")
	}
	if !(_LLM_Bridge_DispatcherCharFn is Func) {
		_LLM_Bridge_DispatcherCharFn := _LLM_Bridge_OnDispatcherChar.Bind()
		_LLM_Bridge_DispatcherKeyFn := _LLM_Bridge_OnDispatcherKey.Bind()
	}
	RegisterFn := Port["register"]
	UnregisterFn := Port["unregister"]
	Subscriptions := [
		[HookDispatcherConst.EVT_KB_CHAR, _LLM_Bridge_DispatcherCharFn],
		[HookDispatcherConst.EVT_KB_DOWN, _LLM_Bridge_DispatcherKeyFn]
	]
	Registered := []
	PreviousCritical := Critical("On")
	try {
		for Subscription in Subscriptions {
			RegisterFn.Call(Subscription[1], Subscription[2])
			Registered.Push(Subscription)
		}
	} catch as Err {
		loop Registered.Length {
			Subscription := Registered[Registered.Length - A_Index + 1]
			try UnregisterFn.Call(Subscription[1], Subscription[2])
		}
		throw Err
	} finally {
		Critical(PreviousCritical)
	}
	return true
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
	LLM_Bridge_CancelPrefixObserver()
	_LLM_Bridge_UnregisterDispatcherFallback()
	_LLM_PointerWatch_Stop()
	if !_LLM_Bridge_Active
		return
	_LLM_Bridge_Active := false
	_LLM_Bridge_ClearBuffer()
	; The agent-only feed takes over from here on a fresh context: whatever it
	; held before the bridge started predates everything typed since
	LLM_Bridge_ResetAgentFeed("the prediction bridge stopped")
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
	else
		_LLM_Bridge_ObserveAgentTyping(0, ch)
}

/**
 * Mirrors a prefix-hook character without running file-backed observers.
 * The caller serializes this RAM edit with HSE admission and native output.
 * @param {String} ch Character already delivered to the application.
 * @returns {Boolean} True when an observer owns the deferred notification.
 */
LLM_Bridge_FeedCharForPrefix(ch, ScheduleFn := TimerSetCallback, FocusFn := unset,
		AgentWantedFn := unset) {
	global _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding, _LLM_Bridge_AgentBuffer
	global _LLM_Bridge_PrefixObserver, _LLM_Engine, _LLM_Bridge_ReadLiveFocus
	global _PrefixDeferredGeneration
	if !A_IsCritical
		throw Error("Prefix character mirroring requires a serialized input transaction.")
	Active := _LLM_Bridge_Active
	if Active {
		_LLM_Bridge_ApplyBufferEdit(0, ch)
		; Invalidate stale responses now; transport release and callbacks are deferred.
		LLM_Engine_CancelTimer()
		_LLM_Engine["request_id"] := _LLM_Engine.Get("request_id", 0) + 1
		_LLM_Engine["active_request_signature"] := ""
	} else {
		Wanted := IsSet(AgentWantedFn) ? AgentWantedFn.Call()
			: (IsSet(LLM_Agent_WatchesTyping) && LLM_Agent_WatchesTyping())
		_LLM_Bridge_AgentFeeding := Wanted ? true : false
		if !Wanted {
			_LLM_Bridge_AgentBuffer := ""
			LLM_Bridge_CancelPrefixObserver()
			return false
		}
		LLM_Bridge_MirrorAgentEdit(0, ch)
	}
	return _LLM_Bridge_SchedulePrefixObserver(ch,
		ScheduleFn, IsSet(FocusFn) ? FocusFn : _LLM_Bridge_ReadLiveFocus)
}

_LLM_Bridge_SchedulePrefixObserver(ch, ScheduleFn, ReadFocus) {
	global _LLM_Bridge_PrefixObserver, _LLM_Bridge_Active, _PrefixDeferredGeneration
	LLM_Bridge_CancelPrefixObserver()
	Source := ReadFocus.Call()
	Owner := { Active: _LLM_Bridge_Active, Char: ch, Source: Source.Clone(), FocusFn: ReadFocus,
		PhysicalGeneration: KS_GetPhysicalInputGeneration(),
		LifecycleGeneration: _PrefixDeferredGeneration, Timer: 0 }
	Owner.Timer := _LLM_Bridge_RunPrefixObserver.Bind(Owner)
	_LLM_Bridge_PrefixObserver := Owner
	ScheduleFn.Call(Owner.Timer, -1)
	return true
}

/** Retires the exact pending prefix observer before lifecycle or content resets. */
LLM_Bridge_CancelPrefixObserver() {
	global _LLM_Bridge_PrefixObserver
	PreviousCritical := Critical("On")
	try {
		Owner := _LLM_Bridge_PrefixObserver
		_LLM_Bridge_PrefixObserver := 0
		if IsObject(Owner) && IsObject(Owner.Timer)
			TimerSetCallback(Owner.Timer, 0)
	} finally {
		Critical(PreviousCritical)
	}
	return IsObject(Owner)
}

_LLM_Bridge_PrefixObserverStillCurrent(Owner, ContentGeneration := unset) {
	global _LLM_Bridge_PrefixObserver, _LLM_Bridge_Active
	global _LLM_Bridge_ContentGeneration, _PrefixDeferredGeneration
	if A_IsSuspended || !IsObject(_LLM_Bridge_PrefixObserver)
		return false
	if (ObjPtr(_LLM_Bridge_PrefixObserver) != ObjPtr(Owner)
		|| Owner.Active != _LLM_Bridge_Active
		|| Owner.LifecycleGeneration != _PrefixDeferredGeneration
		|| Owner.PhysicalGeneration != KS_GetPhysicalInputGeneration())
		return false
	if (IsSet(ContentGeneration) && Owner.Active
		&& ContentGeneration != _LLM_Bridge_ContentGeneration)
		return false
	Focus := Owner.FocusFn.Call()
	return Owner.Source.Get("hwnd", 0) > 0 && Owner.Source.Get("control", 0) > 0
		&& Focus.Get("hwnd", 0) == Owner.Source["hwnd"]
		&& Focus.Get("control", 0) == Owner.Source["control"]
}

_LLM_Bridge_RunPrefixObserver(Owner) {
	global _LLM_Bridge_PrefixObserver, _LLM_Bridge_Buffer
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_ContentGeneration
	Started := HotPath_Now()
	try {
		if !_LLM_Bridge_PrefixObserverStillCurrent(Owner)
			return false
		; Read the canonical buffer after any expansion, never the original trigger.
		ContentGeneration := _LLM_Bridge_ContentGeneration
		CurrentFn := _LLM_Bridge_PrefixObserverStillCurrent.Bind(Owner, ContentGeneration)
		if Owner.Active {
			LLM_Engine_CancelInflight(CurrentFn)
			if !CurrentFn.Call()
				return false
			_LLM_Bridge_NotifyChar(Owner.Char, _LLM_Bridge_Buffer, CurrentFn)
		} else if _LLM_Bridge_AgentFeedIsWanted() {
			LLM_Agent_OnTyping(_LLM_Bridge_AgentBuffer, CurrentFn)
		}
		return true
	} catch as Err {
		LoggerError("LLM", "Deferred prefix observer failed: {1}.", Err.Message)
		return false
	} finally {
		PreviousCritical := Critical("On")
		try {
			if IsObject(_LLM_Bridge_PrefixObserver)
				&& ObjPtr(_LLM_Bridge_PrefixObserver) == ObjPtr(Owner)
				_LLM_Bridge_PrefixObserver := 0
		} finally {
			Critical(PreviousCritical)
		}
		HotPath_LogIfSlow("LLM.PrefixObservers", Started)
	}
}

/**
 * Called from PrefixWatcher or the early HookDispatcher fallback for
 * navigation / editing keys.
 * @param {Integer} vk - Virtual key code.
 * @param {boolean} IsPhysicalEvent - True only for the I1-filtered prefix hook.
 */
LLM_Bridge_FeedKeyDownIfActive(vk, IsPhysicalEvent := false) {
	global _LLM_Bridge_AgentBuffer
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active) {
		; Predictions are off: only the AI agent's typing observer listens
		if (vk = 0x08)
			_LLM_Bridge_ObserveAgentTyping(_TextTailCodeUnits(_LLM_Bridge_AgentBuffer, 1), "")
		else if (vk = 0x09 or vk = 0x0D or vk = 0x1B)
			LLM_Bridge_MirrorAgentEdit(0, "", true)
		return
	}
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
	; Live mode waits for the hotstring tooltip to close whatever after_hotstring
	; says: its tooltip follows every keystroke, so it must come back after it.
	if !(IsSet(_LLM_Engine) && _LLM_Engine["enabled"]
			&& (_LLM_Engine["after_hotstring"] || LLM_Engine_LiveIsActive()))
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
	return _LLM_Bridge_NotifyChar(ch, _LLM_Bridge_Buffer)
}

_LLM_Bridge_NotifyChar(ch, Buffer, PublishGuard := unset) {
	if IsSet(PublishGuard) && !PublishGuard.Call()
		return false
	; The AI agent's automatic mode waits for a pause in the same typing, and
	; every keystroke retires its flow in flight, hotstring tooltip or not
	if IsSet(LLM_Agent_OnTyping)
		LLM_Agent_OnTyping(Buffer, IsSet(PublishGuard) ? PublishGuard : (*) => true)
	if IsSet(PublishGuard) && !PublishGuard.Call()
		return false
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
		try LoggerInfo("LLM", "Keystroke buffered ({1} chars) — debounce pending.", StrLen(Buffer))
	}
	; instant_on_word_end: when the just-typed char completes a word (a word char
	; followed by whitespace/punctuation) and the user enabled the option, fire the
	; prediction immediately instead of waiting the full debounce — macOS parity with
	; engine.start_timer_word_end (llm-instant-word-end-trigger).
	if _LLM_Bridge_IsWordEndTrigger(ch)
		LLM_Engine_OnKeystroke(Buffer, 0, TimerSetCallback,
			IsSet(PublishGuard) ? PublishGuard : (*) => true)
	else
		LLM_Engine_OnKeystroke(Buffer, "", TimerSetCallback,
			IsSet(PublishGuard) ? PublishGuard : (*) => true)
}

/**
 * Asks live mode again after a hotstring expansion rewrote the end of the
 * buffer. The request the trigger's last character armed holds the text the
 * expansion replaced, and a live tooltip shown for it no longer applies: it is
 * dismissed, and the request re-issued on the text after the expansion. Does
 * nothing outside live mode, whose next-word prediction is left as it was.
 * Called from the hotstring engine's LLM mirror, inside its Critical span.
 * @returns {Integer} True when a live request was re-armed.
 */
LLM_Bridge_ReissueLiveAfterExpansion() {
	global _LLM_Bridge_Active, _LLM_Bridge_ReadLiveFocus
	if !(IsSet(_LLM_Bridge_Active) && _LLM_Bridge_Active) || !LLM_Engine_LiveIsActive()
		return false
	if LLM_Tooltip_IsVisible()
		LLM_Bridge_DeferTooltipHide()
	; Armed even while the consumed preview is still retiring: the live request
	; waits at fire time for any hotstring tooltip left on screen, whose own
	; chain (LLM_Bridge_ScheduleAfterHotstring) asks again once it closes.
	_LLM_Bridge_SchedulePrefixObserver("", TimerSetCallback, _LLM_Bridge_ReadLiveFocus)
	return true
}

/**
 * Must be called when Backspace is pressed.
 * Removes the last character from the buffer.
 */
LLM_Bridge_OnBackspace() {
	global _LLM_Bridge_Buffer, _LLM_Bridge_Active
	if !_LLM_Bridge_Active
		return

	_LLM_Bridge_ApplyBufferEdit(_TextTailCodeUnits(_LLM_Bridge_Buffer, 1), "")
	if IsSet(LLM_Agent_OnTyping)
		LLM_Agent_OnTyping(_LLM_Bridge_Buffer)

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

; Feeds one keystroke the inactive bridge received to the AI agent's typing
; observer: the agent-only context is edited, then LLM_Agent_OnTyping arms the
; automatic mode's pause on it. Nothing of the predictions runs: no buffer, no
; engine timer, no tooltip. Called from the PrefixWatcher's InputHook
; callbacks, so a failure is logged (throttled) instead of escaping into the
; hook, which would stop delivering keystrokes for good.
; @param {Integer} DeleteFromEnd Characters the keystroke erased.
; @param {String} InsertedText The character it typed.
; @returns {Boolean} True when the agent observed it.
_LLM_Bridge_ObserveAgentTyping(DeleteFromEnd, InsertedText) {
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeedErrorTick
	global _LLM_BRIDGE_AGENT_FEED_ERROR_THROTTLE_MS
	if !_LLM_Bridge_AgentFeedIsWanted()
		return false
	LLM_Bridge_MirrorAgentEdit(DeleteFromEnd, InsertedText)
	try {
		LLM_Agent_OnTyping(_LLM_Bridge_AgentBuffer)
	} catch as Err {
		Now := A_TickCount
		; Wrap-safe tick delta: A_TickCount overflows at ~49.7 days
		if (_LLM_Bridge_AgentFeedErrorTick == 0
				|| ((Now - _LLM_Bridge_AgentFeedErrorTick + 0x100000000) & 0xFFFFFFFF)
					> _LLM_BRIDGE_AGENT_FEED_ERROR_THROTTLE_MS) {
			_LLM_Bridge_AgentFeedErrorTick := Now
			LoggerError("LLM", "AI agent typing observer raised: {1}.", Err.Message)
		}
		return false
	}
	return true
}

; Tells whether the inactive bridge feeds the AI agent: its automatic mode
; watches the typing (LLM_Agent_WatchesTyping: mode "auto", not paused). The
; answer is read on every keystroke from the agent's own settings, so a mode
; change, a pause or a restored config starts or stops the feed at the next
; keystroke with no second copy of that state; the transitions are logged.
; @returns {Boolean}
_LLM_Bridge_AgentFeedIsWanted() {
	global _LLM_Bridge_AgentFeeding
	Wanted := (IsSet(LLM_Agent_WatchesTyping) && LLM_Agent_WatchesTyping()) ? true : false
	if (Wanted && !_LLM_Bridge_AgentFeeding) {
		_LLM_Bridge_AgentFeeding := true
		LoggerInfo("LLM", "Bridge feeds the AI agent's typing observer only: predictions are not running.")
	} else if (!Wanted && _LLM_Bridge_AgentFeeding) {
		LLM_Bridge_ResetAgentFeed("the agent's automatic mode no longer watches the typing")
	}
	return Wanted
}

/**
 * Applies one edit to the AI agent's context while the agent-only feed runs;
 * does nothing otherwise. Keystrokes go through _LLM_Bridge_ObserveAgentTyping;
 * the hotstring engine mirrors its expansions here while predictions are off,
 * as it mirrors them into _LLM_Bridge_Buffer while they are on.
 * @param {Integer} DeleteFromEnd Characters removed from the end.
 * @param {String} InsertedText Text appended after them.
 * @param {Boolean} ClearAll True to empty the context (Enter, Escape, Tab, an
 *     edit that cannot be known).
 * @returns {Boolean} True when the context was edited.
 */
LLM_Bridge_MirrorAgentEdit(DeleteFromEnd, InsertedText := "", ClearAll := false) {
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding, LLM_BRIDGE_BUFFER_MAX_CHARS
	if !_LLM_Bridge_AgentFeeding
		return false
	PreviousCritical := Critical("On")
	try {
		if ClearAll {
			_LLM_Bridge_AgentBuffer := ""
			return true
		}
		KeptLen := Max(0, StrLen(_LLM_Bridge_AgentBuffer) - Max(0, DeleteFromEnd))
		Edited := SubStr(_LLM_Bridge_AgentBuffer, 1, KeptLen) . InsertedText
		; The same ceiling as the prediction context: the agent reads only the
		; current sentence, but an unbroken typing run must not grow forever
		if (StrLen(Edited) > LLM_BRIDGE_BUFFER_MAX_CHARS)
			Edited := SubStr(Edited, -LLM_BRIDGE_BUFFER_MAX_CHARS)
		_LLM_Bridge_AgentBuffer := Edited
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

/**
 * Stops the agent-only feed and drops its context. The next keystroke starts
 * it again when the agent still watches the typing. Called when the agent
 * leaves its automatic mode, on pause and when the prediction bridge stops.
 * @param {String} Reason Why, for the log.
 * @returns {Boolean} True when a running feed was stopped.
 */
LLM_Bridge_ResetAgentFeed(Reason) {
	global _LLM_Bridge_AgentBuffer, _LLM_Bridge_AgentFeeding
	LLM_Bridge_CancelPrefixObserver()
	WasFeeding := _LLM_Bridge_AgentFeeding
	_LLM_Bridge_AgentFeeding := false
	_LLM_Bridge_AgentBuffer := ""
	if WasFeeding
		LoggerInfo("LLM", "Bridge stopped feeding the AI agent's typing observer ({1}).", Reason)
	return WasFeeding
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

_LLM_PointerWatch_Start(Port := 0) {
    global _LLM_PointerWatch_Armed, _LLM_PointerWatch_CleanupPending, _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn, _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY
	if _LLM_PointerWatch_Armed {
		if _LLM_PointerWatch_CleanupPending
			throw Error("Pointer watcher cleanup is pending; Stop must succeed before Start can retry.")
		return true
	}
	UseNativeTimer := !(Port is Map)
	if UseNativeTimer {
		Port := Map(
			"register", (EventType, Callback) => HookDispatcher.Register(EventType, Callback),
			"unregister", (EventType, Callback) => HookDispatcher.Unregister(EventType, Callback),
			"hotkey", (KeyName, Callback, Mode) => Hotkey(KeyName, Callback, Mode))
	}
	RequiredPorts := UseNativeTimer
		? ["register", "unregister", "hotkey"]
		: ["register", "unregister", "hotkey", "timer"]
	for Name in RequiredPorts {
		if !HasMethod(Port.Get(Name, 0), "Call")
			throw TypeError("Pointer watcher port is missing callable '" . Name . "'.")
	}
	RegisterFn := Port["register"]
	UnregisterFn := Port["unregister"]
	HotkeyFn := Port["hotkey"]
	TimerFn := UseNativeTimer ? 0 : Port["timer"]
	Events := [HookDispatcherConst.EVT_MS_LDOWN, HookDispatcherConst.EVT_MS_RDOWN,
		HookDispatcherConst.EVT_MS_MDOWN, HookDispatcherConst.EVT_MS_WUP,
		HookDispatcherConst.EVT_MS_WDN, HookDispatcherConst.EVT_MS_WLEFT,
		HookDispatcherConst.EVT_MS_WRIGHT]
	RegisteredEvents := []
	XButton1Armed := false
	XButton2Armed := false
	TimerAttempted := false
	; Always create a fresh Func object on each arm so the previous stop/start
	; cycle cannot leave a stale closure still registered in HookDispatcher — a
	; second Register with the SAME Func object would fire the handler twice per
	; event if HookDispatcher does not deduplicate by identity
	ActivityFn := LLM_Bridge_OnPointerActivity.Bind()
	MoveFn := _LLM_PointerWatch_OnMoveTick.Bind()
	global _LLM_POINTER_POLL_MS
	_PointerCritical := Critical("On")
	try {
	; Subscribe via HookDispatcher for every key the dispatcher owns so we do not
	; clobber the dispatcher's central handlers (mouse-hotkey-clobber). XButton1/2
	; are not registered by the dispatcher — keep those as direct hotkeys.
		for EventType in Events {
			RegisterFn.Call(EventType, ActivityFn)
			RegisteredEvents.Push(EventType)
		}
		HotkeyFn.Call("~XButton1", ActivityFn, "On")
		XButton1Armed := true
		HotkeyFn.Call("~XButton2", ActivityFn, "On")
		XButton2Armed := true
	; Similarly create a fresh move-tick closure so SetTimer can cancel the old
	; one cleanly even if _LLM_PointerWatch_Stop was called without cancelling
		_LLM_PointerWatch_MoveFn := MoveFn
		TimerAttempted := true
		if UseNativeTimer
			SetTimer(_LLM_PointerWatch_MoveFn, _LLM_POINTER_POLL_MS)
		else
			TimerFn.Call(MoveFn, _LLM_POINTER_POLL_MS)
		_LLM_PointerWatch_LastX := unset
		_LLM_PointerWatch_LastY := unset
		_LLM_PointerWatch_ActivityFn := ActivityFn
		_LLM_PointerWatch_CleanupPending := false
		_LLM_PointerWatch_Armed := true
	} catch as Err {
		CleanupErrors := []
		if TimerAttempted {
			if UseNativeTimer {
				try SetTimer(_LLM_PointerWatch_MoveFn, 0)
				catch as CleanupErr
					CleanupErrors.Push(CleanupErr.Message)
			} else {
				try TimerFn.Call(MoveFn, 0)
				catch as CleanupErr
					CleanupErrors.Push(CleanupErr.Message)
			}
		}
		if XButton2Armed {
			try HotkeyFn.Call("~XButton2", ActivityFn, "Off")
			catch as CleanupErr
				CleanupErrors.Push(CleanupErr.Message)
		}
		if XButton1Armed {
			try HotkeyFn.Call("~XButton1", ActivityFn, "Off")
			catch as CleanupErr
				CleanupErrors.Push(CleanupErr.Message)
		}
		loop RegisteredEvents.Length {
			Index := RegisteredEvents.Length - A_Index + 1
			try UnregisterFn.Call(RegisteredEvents[Index], ActivityFn)
			catch as CleanupErr
				CleanupErrors.Push(CleanupErr.Message)
		}
		if CleanupErrors.Length > 0 {
			; At least one native owner may still exist. Preserve every callback
			; identity and block Start until lifecycle retries the idempotent Stop.
			_LLM_PointerWatch_MoveFn := MoveFn
			_LLM_PointerWatch_ActivityFn := ActivityFn
			_LLM_PointerWatch_CleanupPending := true
			_LLM_PointerWatch_Armed := true
			throw Error("Pointer watcher start failed and rollback left cleanup debt: "
				. Err.Message . "; " . CleanupErrors[1])
		}
		_LLM_PointerWatch_ActivityFn := unset
		_LLM_PointerWatch_MoveFn := unset
		_LLM_PointerWatch_CleanupPending := false
		_LLM_PointerWatch_Armed := false
		throw Err
	} finally {
		Critical(_PointerCritical)
	}
	try LoggerDebug("LLM", "Pointer-dismiss watcher armed.")
	return true
}

_LLM_PointerWatch_StopTimer(Callback, Period) {
	if Period != 0
		throw ValueError("Pointer watcher teardown only accepts timer cancellation.")
	SetTimer(Callback, 0)
}

_LLM_PointerWatch_Stop(Port := 0) {
	global _LLM_PointerWatch_Armed, _LLM_PointerWatch_CleanupPending
	global _LLM_PointerWatch_MoveFn, _LLM_PointerWatch_ActivityFn
	if !_LLM_PointerWatch_Armed
		return true
	if !(Port is Map) {
		Port := Map(
			"timer", _LLM_PointerWatch_StopTimer,
			"unregister", (EventType, Callback) => HookDispatcher.Unregister(EventType, Callback),
			"hotkey", (KeyName, Callback, Mode) => Hotkey(KeyName, Callback, Mode))
	}
	for Name in ["timer", "unregister", "hotkey"] {
		if !HasMethod(Port.Get(Name, 0), "Call")
			throw TypeError("Pointer watcher stop port is missing callable '" . Name . "'.")
	}
	MoveFn := IsSet(_LLM_PointerWatch_MoveFn) ? _LLM_PointerWatch_MoveFn : 0
	ActivityFn := IsSet(_LLM_PointerWatch_ActivityFn) ? _LLM_PointerWatch_ActivityFn : 0
	PreviousCritical := Critical("On")
	try {
		if HasMethod(MoveFn, "Call")
			Port["timer"].Call(MoveFn, 0)
		if HasMethod(ActivityFn, "Call") {
			for EventType in [HookDispatcherConst.EVT_MS_LDOWN, HookDispatcherConst.EVT_MS_RDOWN,
					HookDispatcherConst.EVT_MS_MDOWN, HookDispatcherConst.EVT_MS_WUP,
					HookDispatcherConst.EVT_MS_WDN, HookDispatcherConst.EVT_MS_WLEFT,
					HookDispatcherConst.EVT_MS_WRIGHT] {
				Port["unregister"].Call(EventType, ActivityFn)
			}
			Port["hotkey"].Call("~XButton1", ActivityFn, "Off")
			Port["hotkey"].Call("~XButton2", ActivityFn, "Off")
		}
		; Publish stopped only after every native owner has accepted teardown.
		_LLM_PointerWatch_MoveFn := unset
		_LLM_PointerWatch_ActivityFn := unset
		_LLM_PointerWatch_CleanupPending := false
		_LLM_PointerWatch_Armed := false
	} finally {
		Critical(PreviousCritical)
	}
	try LoggerDebug("LLM", "Pointer-dismiss watcher stopped.")
	return true
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
 * The erasure the accepted slot performs, read from the slot the tooltip
 * shows: a rewrite slot (_LLM_Engine_RewriteDisplaySlot) carries it, every
 * other slot erases nothing.
 * @param {String} Text The accepted text.
 * @param {Array} Slots The presented slots.
 * @param {Integer} ActiveIdx The accepted slot.
 * @returns {Map|Integer} Map("deletes", "deleted_text", "span"), or 0.
 */
_LLM_Bridge_AcceptedSlotEdit(Text, Slots := unset, ActiveIdx := 1) {
	if !IsSet(Slots) || !(Slots is Array) || ActiveIdx < 1 || ActiveIdx > Slots.Length
		return 0
	Slot := Slots[ActiveIdx]
	if !IsObject(Slot) || !Slot.HasOwnProp("Deletes")
		return 0
	if !Slot.HasOwnProp("Text") || !(Slot.Text == Text)
		throw Error("The accepted text is not the text of the slot that carries its erasure.")
	return Map("deletes", Slot.Deletes, "deleted_text", Slot.DeletedText,
		"span", Slot.RewriteSpan)
}

/**
 * Tells whether a rewrite still applies to the text before the caret. The
 * model rewrote a span that ended the buffer; a keystroke admitted meanwhile
 * (the tooltip's minimum-display window keeps it up) moved that end, and
 * erasing the recorded count would then delete the wrong characters.
 * @param {Object} Transaction The acceptance transaction.
 * @returns {Integer} True when nothing is erased, or the span still ends the buffer.
 */
_LLM_Bridge_RewriteStillApplies(Transaction) {
	global _LLM_Bridge_Buffer
	if (Transaction.Deletes <= 0)
		return true
	Span := Transaction.RewriteSpan
	BufferLength := StrLen(_LLM_Bridge_Buffer)
	SpanLength := StrLen(Span)
	return (SpanLength > 0 and SpanLength <= BufferLength
		and SubStr(_LLM_Bridge_Buffer, BufferLength - SpanLength + 1) == Span)
}

/**
 * Called when the user accepts the suggestion (e.g. pressing Tab over tooltip).
 * Types the accepted text into the active window, after erasing the typed
 * text a rewrite replaces, and mirrors both edits in the buffer.
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
		text, AdmissionSeed, RequestId, false, Slots?, ActiveIdx,
		PresentedRecord, PresentedLifecycle,
		_LLM_Bridge_AcceptedSlotEdit(text, Slots?, ActiveIdx))
	; A slot with an accept handler of its own (an AI agent action) runs it
	; instead of typing anything: the offer is retired like a typed one, then
	; the handler runs on a fresh thread, off the Tab key's
	Handler := _LLM_Bridge_AcceptedSlotHandler(Transaction)
	if HasMethod(Handler, "Call") {
		_LLM_Bridge_OnInjectComplete(Transaction, true)
		SetTimer(Handler, -1)
		return
	}
	; The completion callback owns the tooltip and the acceptance claim, so a
	; refusal goes through it exactly like a sender that rejected the output.
	if !_LLM_Bridge_RewriteStillApplies(Transaction) {
		try LoggerWarn("LLM", "Rewrite not applied: the text it replaces changed since it was generated.")
		_LLM_Bridge_OnInjectComplete(Transaction, false,
			"the rewritten sentence no longer ends the typed text")
		return
	}
	TextSend(text, _LLM_Bridge_InjectionOptions(Transaction),
		_LLM_Bridge_OnInjectComplete.Bind(Transaction))
}

; The accept handler of the accepted slot, when it has one: the AI agent's
; candidates carry the action they run in place of a text to type.
; @param {Object} Transaction The acceptance transaction.
; @returns {Func|String} The handler, "" for an ordinary slot.
_LLM_Bridge_AcceptedSlotHandler(Transaction) {
	Slots := Transaction.Slots
	Index := Transaction.ActiveIdx
	if !(Slots is Array) || Index < 1 || Index > Slots.Length
		return ""
	Slot := Slots[Index]
	if !IsObject(Slot) || !Slot.HasOwnProp("OnAccept") || !HasMethod(Slot.OnAccept, "Call")
		return ""
	return Slot.OnAccept
}

; Selects the text an accepted slot typed again when the slot asks for it: a
; translation replaces the selection it was made from (llm_translate_selection)
; and stays selected, like a tone step, so the next action applies to it.
; @param {Object} Transaction The completed acceptance transaction.
; @returns {Boolean} True when the typed text was selected again.
_LLM_Bridge_SelectAcceptedText(Transaction) {
	Slots := Transaction.Slots
	Index := Transaction.ActiveIdx
	if !(Slots is Array) || Index < 1 || Index > Slots.Length
		return false
	Slot := Slots[Index]
	if !IsObject(Slot) || !Slot.HasOwnProp("SelectAfterAccept") || !Slot.SelectAfterAccept
		return false
	if TextSelectBack(LLM_Rewrite_CodepointLength(Transaction.Text))
		return true
	try LoggerWarn("LLM", "Accepted text typed over the selection but not selected again.")
	return false
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
		; After the teardown is queued: the selection is a courtesy, never a
		; reason to leave the accepted offer on screen
		_LLM_Bridge_SelectAcceptedText(Transaction)
	} finally {
		; A failed sender callback (or a failure while committing its state) never
		; reaches the success path that normally releases the acceptance claim.
		if !HideQueued
			_LLM_Accept_DeferClaimRelease()
	}
}

; infra/hotstrings/hotstring_dispatch.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Dispatch
; DESCRIPTION:
; Expansion dispatch for the custom hotstring engine: owns the full
; backspace+replacement burst, suppression lifecycle, AltGr fixup, Notepad
; clipboard route, case-conform resolution, and deferred KL marker release.
;
; FEATURES & RATIONALE:
; 1. Atomic SendInput burst — backspaces + replacement + end-char injected
;    as one unit so no physical keystroke can splice into the middle.
; 2. Raw-callback path — migrated native AHK Hotstring() registrations (e.g.
;    E-circumflex deadkey, ellipsis) dispatch through _HSE_DispatchRawCallback
;    with their own variable-length send contract.
; 3. Suppression via PrefixWatcherSuppress (refcount) so the InputHook ignores
;    AHK-generated characters during the burst.
;
; Included by infra/hotstrings/hotstring_engine_main.ahk.
; ==============================================================================

; Number of milliseconds we wait after the SendEvent burst before
; releasing HSE_Suppressed. Just enough margin for the OS message loop
; to drain the BackSpace/Replacement events through the InputHook so
; they are filtered out instead of polluting the buffer with our own
; replayed characters.
global HSE_SUPPRESS_RELEASE_DELAY_MS := 60

; Terminal/TUI inputs commonly update their edit state once per render turn.
; A zero-delay run of Backspaces can therefore collapse onto one stale snapshot,
; after which the replacement is appended to the untouched trigger. Keep the
; host list narrow: ordinary GUI controls retain the faster SendInput path.
global HSE_TERMINAL_INPUT_EXES := Map(
		"windowsterminal.exe", true,
		"openconsole.exe", true,
		"conhost.exe", true,
		"wezterm-gui.exe", true,
		"alacritty.exe", true,
		"kitty.exe", true,
		"mintty.exe", true,
		"tabby.exe", true,
		"hyper.exe", true
)
global _HSE_TerminalOwner := 0
global _HSE_TerminalOwnerSerial := 0
global _HSE_TerminalReplayPending := 0
global _HSE_TerminalReplaying := false

_HSE_IsTerminalInputHost(Exe, Title := "") {
		global HSE_TERMINAL_INPUT_EXES
		NormalizedExe := StrLower(Trim(Exe))
		if HSE_TERMINAL_INPUT_EXES.Has(NormalizedExe)
				return true
		; Covers an embedded terminal hosting the two known OpenTUI products without
		; slowing every editor field in the parent IDE process.
		NormalizedTitle := StrLower(Title)
		return InStr(NormalizedTitle, "freebuff") > 0
				|| InStr(NormalizedTitle, "codebuff") > 0
}

; Build explicit key tokens because AHK does not apply SetKeyDelay between the
; internal repetitions of compact ``{BackSpace N}`` syntax.
_HSE_BuildTerminalBurst(BSCount, Tail) {
		BSCount := Max(0, Floor(BSCount))
		Burst := ""
		loop BSCount
				Burst .= "{BackSpace}"
		return Burst . Tail
}

_HSE_SetTerminalKeyDelay(DelayMs, DurationMs, DelayFn := 0) {
		if HasMethod(DelayFn, "Call")
				return DelayFn.Call(DelayMs, DurationMs)
		SetKeyDelay(DelayMs, DurationMs)
		return true
}

; One SendEvent call retains real SetKeyDelay pacing inside the terminal. The
; native keyboard arbiter owns physical edges for the whole call; BlockInput's
; Send mode is deliberately absent because it discards rather than buffers them.
_HSE_SendTerminalPaced(BSCount, Tail, DelayMs, EmitFn := 0,
		DelayFn := 0) {
		Burst := _HSE_BuildTerminalBurst(BSCount, Tail)
		PreviousKeyDelay := A_KeyDelay
		PreviousKeyDuration := A_KeyDuration
		PreviousSendLevel := A_SendLevel
		try {
				; The prefix watcher accepts input above I1. Pin output below that
				; boundary instead of inheriting the completing hotkey thread's level.
				SendLevel(0)
				_HSE_SetTerminalKeyDelay(Max(1, Floor(DelayMs)), 0, DelayFn)
				if HasMethod(EmitFn, "Call")
						return _SendVerdictSucceeded(EmitFn.Call(Burst))
				SendEvent(Burst)
				return true
		} finally {
				try _HSE_SetTerminalKeyDelay(
						PreviousKeyDelay, PreviousKeyDuration, DelayFn)
				finally SendLevel(PreviousSendLevel)
		}
}

HSE_TerminalTransactionPending() {
	global _HSE_TerminalOwner, _HSE_TerminalReplayPending
	return ((_HSE_TerminalOwner is Map) && _HSE_TerminalOwner["Pending"])
		|| (_HSE_TerminalReplayPending is Map)
}

_HSE_TerminalOwnerIsCurrent(Owner) {
	global _HSE_TerminalOwner, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	global _PrefixInputContextGeneration, _PrefixDeferredGeneration, HSE_Buffer
	if !(_HSE_TerminalOwner is Map) || _HSE_TerminalOwner != Owner || !Owner["Pending"]
		return false
	if A_IsSuspended
		return false
	if (HSE_RegistryGeneration != Owner["RegistryGeneration"]
			|| HSE_RuntimeDecisionGeneration != Owner["DecisionGeneration"]
			|| _PrefixInputContextGeneration != Owner["InputGeneration"]
			|| _PrefixDeferredGeneration != Owner["LifecycleGeneration"])
		return false
	Host := OutputHostResolve()
	if !Host["Valid"]
			|| Host["Hwnd"] != Owner["Hwnd"] || Host["Pid"] != Owner["Pid"]
		return false
	Snapshot := Owner["BufferSnapshot"]
	return StrLen(HSE_Buffer) >= StrLen(Snapshot)
		&& SubStr(HSE_Buffer, 1, StrLen(Snapshot)) == Snapshot
}

_HSE_CommitTerminalOwner(Owner, TrailingText) {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN
	global _PrefixPrivateResidue
	if HasMethod(Owner.Get("CommitFn", 0), "Call")
		return Owner["CommitFn"].Call(Owner, TrailingText)
	if Owner.Has("RawEffect")
		return _HSE_CommitTerminalRawOwner(Owner, TrailingText)
	DeleteCount := Owner["Backspaces"] + StrLen(TrailingText)
	; TrailingText was already visible before capture admission.  The paced burst
	; erases and restores it on screen, but the canonical buffers deliberately
	; stop at the replacement.  After native release, the exact characters are
	; fed through _OnPrefixChar again in order, so each one can complete a second
	; hotstring instead of being frozen into the first transaction's result.
	InsertedText := Owner["OnlyText"] ? Owner["PlainInsertedText"] : ""
	ClearAll := !Owner["OnlyText"]
	Effect := {
		ClearAll: ClearAll,
		DeleteFromEnd: DeleteCount,
		InsertedText: InsertedText,
		EndCharEmitted: Owner["EndCharPart"] != "",
		KnownBoundaryAfter: !ClearAll && InsertedText != ""
			&& InStr(_HSE_WordBoundarySet(), SubStr(InsertedText, -1)) > 0
	}
	BufferCritical := Critical("On")
	PreviousBuffer := HSE_Buffer
	PreviousBoundary := HSE_StartIsWordBoundary
	try {
		try {
			if ClearAll {
				HSE_Buffer := ""
				HSE_StartIsWordBoundary := false
			} else {
				CurrentLength := StrLen(HSE_Buffer)
				HSE_Buffer := CurrentLength >= DeleteCount
					? SubStr(HSE_Buffer, 1, CurrentLength - DeleteCount) : ""
				HSE_Buffer .= InsertedText
				if StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN {
					HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
					HSE_StartIsWordBoundary := false
				}
			}
			_HSE_MirrorCanonicalEffectToLlm(Effect)
		} catch {
			HSE_Buffer := PreviousBuffer
			HSE_StartIsWordBoundary := PreviousBoundary
			throw
		}
	} finally {
		Critical(BufferCritical)
	}
	try {
		if Owner["OnlyText"]
			UpdateLastSentCharacter(SubStr(
				TrailingText != "" ? TrailingText : InsertedText, -1))
		else
			_LSCResetFrom([])
	} catch as Err {
		try LoggerError("HSE", "Terminal last-character publication failed: {1}.", Err.Message)
	}
	if IsSet(_PrefixCommitPostFireEffect) {
		try _PrefixCommitPostFireEffect(Effect)
		catch as Err
			try LoggerError("HSE", "Terminal prefix publication failed: {1}.", Err.Message)
	}
	if Owner["IsPrivate"] && IsSet(_PrefixPrivateResidue)
		_PrefixPrivateResidue := true
	if IsSet(_HSE_QueueFireLog) {
		try _HSE_QueueFireLog(Owner["Trigger"], Owner["ReplacementForLog"],
				Owner["HType"], Owner["Category"], Owner["Section"], Owner["IsPrivate"])
		catch as Err
			try LoggerError("HSE", "Terminal fire-log publication failed: {1}.", Err.Message)
	}
	return Effect
}

_HSE_CommitTerminalRawOwner(Owner, TrailingText := "") {
	global HSE_Buffer, HSE_StartIsWordBoundary, HSE_MAX_BUFFER_LEN
	global _PrefixPrivateResidue
	RawEffect := Owner["RawEffect"]
	BufferCritical := Critical("On")
	PreviousBuffer := HSE_Buffer
	PreviousBoundary := HSE_StartIsWordBoundary
	try {
		try {
			BufferLength := StrLen(HSE_Buffer)
			Backspaces := Max(0, Min(
				RawEffect.Bs + StrLen(TrailingText), BufferLength))
			InsertedText := RawEffect.Ins
			HSE_Buffer := (BufferLength >= Backspaces
				? SubStr(HSE_Buffer, 1, BufferLength - Backspaces) : "")
				. InsertedText
			if StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN {
				HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
				HSE_StartIsWordBoundary := false
			}
			Effect := {
				ClearAll: false,
				DeleteFromEnd: Backspaces,
				InsertedText: InsertedText,
				EndCharEmitted: false,
				KnownBoundaryAfter: HSE_Buffer != ""
					&& InStr(_HSE_WordBoundarySet(), SubStr(HSE_Buffer, -1)) > 0
			}
			_HSE_MirrorCanonicalEffectToLlm(Effect)
		} catch {
			HSE_Buffer := PreviousBuffer
			HSE_StartIsWordBoundary := PreviousBoundary
			throw
		}
	} finally Critical(BufferCritical)
	try UpdateLastSentCharacter(SubStr(
		TrailingText != "" ? TrailingText : InsertedText, -1))
	catch as Err
		try LoggerError("HSE", "Terminal raw last-character publication failed: {1}.", Err.Message)
	if IsSet(_PrefixCommitPostFireEffect) {
		try _PrefixCommitPostFireEffect(Effect)
		catch as Err
			try LoggerError("HSE", "Terminal raw prefix publication failed: {1}.", Err.Message)
	}
	if Owner["IsPrivate"] && IsSet(_PrefixPrivateResidue)
		_PrefixPrivateResidue := true
	if IsSet(_HSE_QueueFireLog) {
		try _HSE_QueueFireLog(Owner["Trigger"], Owner["ReplacementForLog"],
				Owner["HType"], Owner["Category"], Owner["Section"], Owner["IsPrivate"])
		catch as Err
			try LoggerError("HSE", "Terminal raw fire-log publication failed: {1}.", Err.Message)
	}
	return Effect
}

_HSE_DispatchTerminalRawCallback(Spec, EndChar, OutputHost, SchedulerFn := 0,
		EmitOverride := 0) {
	global _HSE_TerminalOwnerSerial, HSE_Buffer
	global HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
	global _PrefixInputContextGeneration, _PrefixDeferredGeneration
	global _SendHook
	Prepared := 0
	try Prepared := (Spec.Callback)(EndChar, true)
	catch as Err {
		try LoggerError("HSE", "Terminal raw callback preparation failed: {1}.", Err.Message)
		return false
	}
	if !(IsObject(Prepared) && Prepared.HasOwnProp("Prepared")
			&& Prepared.Prepared && Prepared.HasOwnProp("Ok") && Prepared.Ok
			&& Prepared.HasOwnProp("Bs") && Prepared.HasOwnProp("Ins"))
		return false
	if Prepared.Bs <= 0 && Prepared.Ins == ""
		return false
	if IsSet(PrefixWatcherSuppress)
		PrefixWatcherSuppress(true)
	else
		HSE_Suppress(true)
	SyntheticOwner := KL_MarkSynthetic("hotstring",
		Spec.HasOwnProp("IsPrivate") && Spec.IsPrivate)
	if HasMethod(EmitOverride, "Call")
		EmitFn := EmitOverride
	else if _SendHook {
		Hook := _SendHook
		EmitFn := (Payload) => Hook("SendTerminalResult", Payload, false)
	} else
		EmitFn := 0
	Owner := Map(
		"Id", ++_HSE_TerminalOwnerSerial,
		"Pending", true,
		"Backspaces", Prepared.Bs,
		"PlainInsertedText", Prepared.Ins,
		"SendPayload", "{Text}" . Prepared.Ins,
		"EndCharPart", "",
		"OnlyText", false,
		"RawEffect", Prepared,
		"DelayMs", TimingsGet("debounce", "terminal_hotstring_key_delay_ms"),
		"EmitFn", EmitFn,
		"DelayFn", 0,
		"BufferSnapshot", HSE_Buffer,
		"Hwnd", OutputHost["Hwnd"],
		"Pid", OutputHost["Pid"],
		"RegistryGeneration", HSE_RegistryGeneration,
		"DecisionGeneration", HSE_RuntimeDecisionGeneration,
		"InputGeneration", _PrefixInputContextGeneration,
		"LifecycleGeneration", _PrefixDeferredGeneration,
		"Trigger", Spec.HasOwnProp("Trigger") ? Spec.Trigger : "",
		"ReplacementForLog", Prepared.Ins,
		"HType", IsSet(_ResolveFireHType) ? _ResolveFireHType(Spec) : "star",
		"Category", Spec.HasOwnProp("Category") ? Spec.Category : "",
		"Section", Spec.HasOwnProp("Section") ? Spec.Section : "",
		"IsPrivate", Spec.HasOwnProp("IsPrivate") && Spec.IsPrivate,
		"SyntheticOwner", SyntheticOwner,
		"Port", 0)
	try {
		Result := _HSE_BeginOwnedTerminalTransaction(Owner, SchedulerFn)
		if Result is Map {
			return Result["Pending"] ? Result : Result["FinalSucceeded"]
		}
		return false
	} catch as Err {
		try LoggerError("HSE", "Terminal raw callback scheduling failed: {1}.", Err.Message)
		return false
	}
}

_HSE_ReleaseTerminalCapture(Owner, Committed) {
	global _HSE_TerminalReplayPending, _HSE_TerminalReplaying
	Replay := Map("Token", Owner["Id"], "Committed", Committed,
		"Port", Owner.Get("Port", 0),
		"TrailingText", Committed ? Owner.Get("TrailingText", "") : "",
		"TrailingChars", Committed ? Owner.Get("TrailingChars", []) : [],
		"ObservedChars", [],
		"ReplayVisibleFn", Owner.Get("ReplayVisibleFn", 0))
	_HSE_TerminalReplayPending := Replay
	_HSE_TerminalReplaying := true
	Released := false
	PreviousCritical := Critical("On")
	try {
		Released := LLM_NavEventOwner_ReleaseTerminalCapture(
			Replay["Token"], Replay["Committed"], Replay["Port"])
		if Released && _HSE_TerminalReplayPending == Replay {
			_HSE_TerminalReplayPending := 0
			_HSE_ReplayVisibleTerminalChars(
				_HSE_TerminalReplayChars(Replay), Replay["ReplayVisibleFn"])
		}
	}
	finally {
		_HSE_TerminalReplaying := false
		Critical(PreviousCritical)
	}
	return Released
}

_HSE_RetryTerminalReplay() {
	global _HSE_TerminalReplayPending, _HSE_TerminalReplaying
	if !(_HSE_TerminalReplayPending is Map) || _HSE_TerminalReplaying
		return true
	Replay := _HSE_TerminalReplayPending
	_HSE_TerminalReplaying := true
	Released := false
	PreviousCritical := Critical("On")
	try {
		Released := LLM_NavEventOwner_ReleaseTerminalCapture(
			Replay["Token"], Replay["Committed"], Replay["Port"])
		if Released && _HSE_TerminalReplayPending == Replay {
			_HSE_TerminalReplayPending := 0
			_HSE_ReplayVisibleTerminalChars(
				_HSE_TerminalReplayChars(Replay), Replay["ReplayVisibleFn"])
		}
	}
	finally {
		_HSE_TerminalReplaying := false
		Critical(PreviousCritical)
	}
	return Released
}

_HSE_RetainTerminalReplayChar(Char) {
	global _HSE_TerminalReplayPending
	if !(_HSE_TerminalReplayPending is Map)
		return false
	_HSE_TerminalReplayPending["ObservedChars"].Push(Char)
	return true
}

_HSE_TerminalReplayChars(Replay) {
	Chars := []
	for Char in Replay["TrailingChars"]
		Chars.Push(Char)
	for Char in Replay["ObservedChars"]
		Chars.Push(Char)
	return Chars
}

_HSE_ReplayVisibleTerminalChars(Chars, ReplayFn := 0) {
	if !(Chars is Array) || Chars.Length == 0
		return true
	for Char in Chars {
		if HasMethod(ReplayFn, "Call")
			ReplayFn.Call(Char)
		else
			_OnPrefixChar(0, Char)
	}
	return true
}

_HSE_ClearTerminalOutputOwnership(Owner) {
	try {
		if IsSet(PrefixWatcherSuppress)
			PrefixWatcherSuppress(false)
		else
			HSE_Suppress(false)
	} catch as Err {
		try LoggerError("HSE", "Terminal prefix ownership release failed: {1}.", Err.Message)
	}
	try KL_ClearSynthetic(Owner.Get("SyntheticOwner", 0))
	catch as Err {
		try LoggerError("HSE", "Terminal synthetic ownership release failed: {1}.", Err.Message)
	}
	return true
}

_HSE_FinishTerminalOwner(Owner, OutputSucceeded, TrailingText := "") {
	global _HSE_TerminalOwner
	Committed := false
	try {
		if OutputSucceeded {
			_HSE_CommitTerminalOwner(Owner, TrailingText)
			Committed := true
		}
	} catch as Err {
		try LoggerError("HSE", "Terminal canonical commit failed: {1}.", Err.Message)
	} finally {
		Owner["Pending"] := false
		Owner["FinalSucceeded"] := Committed
		if (_HSE_TerminalOwner == Owner)
			_HSE_TerminalOwner := 0
		_HSE_ClearTerminalOutputOwnership(Owner)
		_HSE_ReleaseTerminalCapture(Owner, Committed)
	}
	return Committed
}

_HSE_RunOwnedTerminalTransaction(Owner) {
	global HSE_Buffer
	RunnerCritical := Critical("On")
	try {
		if Owner.Get("RunnerClaimed", false)
			return Owner.Get("FinalSucceeded", false)
		Owner["RunnerClaimed"] := true
	} finally Critical(RunnerCritical)
	OutputSucceeded := false
	TrailingText := ""
	try {
		if _HSE_TerminalOwnerIsCurrent(Owner) {
			TrailingText := SubStr(
				HSE_Buffer, StrLen(Owner["BufferSnapshot"]) + 1)
			if TrailingText != Owner.Get("TrailingText", "")
				return _HSE_FinishTerminalOwner(Owner, false)
			Owner["TrailingText"] := TrailingText
			Tail := Owner["OnlyText"]
				? "{Text}" . Owner["PlainInsertedText"] . TrailingText
				: Owner["SendPayload"]
					. (TrailingText != "" ? "{Text}" . TrailingText : "")
			OutputSucceeded := _HSE_SendTerminalPaced(
				Owner["Backspaces"] + StrLen(TrailingText),
				Tail, Owner["DelayMs"],
				Owner["EmitFn"], Owner["DelayFn"])
			if !OutputSucceeded
				try LoggerError("HSE", "Terminal expansion sender refused an event.")
		}
	} catch as Err {
		try LoggerError("HSE", "Terminal expansion transaction failed: {1}.", Err.Message)
	}
	return _HSE_FinishTerminalOwner(Owner, OutputSucceeded, TrailingText)
}

_HSE_DefaultTerminalScheduler(Runner, DelayMs) {
	SetTimer(Runner, -Max(1, Floor(DelayMs)))
	return true
}

_HSE_BeginOwnedTerminalTransaction(Owner, SchedulerFn := 0) {
	global _HSE_TerminalOwner
	if HSE_TerminalTransactionPending() {
		_HSE_ClearTerminalOutputOwnership(Owner)
		return false
	}
	Owner["Pending"] := true
	Owner["FinalSucceeded"] := false
	Owner["CaptureAdmitted"] := false
	Owner["TrailingText"] := ""
	Owner["TrailingChars"] := []
	Owner["RunnerClaimed"] := false
	_HSE_TerminalOwner := Owner
	if !LLM_NavEventOwner_BeginTerminalCapture(Owner["Id"], Owner.Get("Port", 0)) {
		Owner["Pending"] := false
		_HSE_TerminalOwner := 0
		_HSE_ClearTerminalOutputOwnership(Owner)
		return false
	}
	Owner["CaptureAdmitted"] := true
	Runner := _HSE_RunOwnedTerminalTransaction.Bind(Owner)
	if !HasMethod(SchedulerFn, "Call")
		SchedulerFn := _HSE_DefaultTerminalScheduler
	try Scheduled := _SendVerdictSucceeded(
		SchedulerFn.Call(Runner, Owner["DelayMs"]))
	catch as Err {
		if !Owner["Pending"]
			return Owner
		_HSE_RejectTerminalOwner(Owner)
		throw Err
	}
	if !Scheduled {
		if !Owner["Pending"]
			return Owner
		_HSE_RejectTerminalOwner(Owner)
		return false
	}
	return Owner
}

_HSE_RejectTerminalOwner(Owner) {
	global _HSE_TerminalOwner
	if !(Owner is Map)
		return false
	Owner["Pending"] := false
	if _HSE_TerminalOwner == Owner
		_HSE_TerminalOwner := 0
	_HSE_ClearTerminalOutputOwnership(Owner)
	return _HSE_ReleaseTerminalCapture(Owner, false)
}




; ===============================================
; ===============================================
; ======= 1/ Dispatch ===========================
; ===============================================
; ===============================================

; Fire the expansion attached to a matched Spec. Owns the entire
; replacement burst end-to-end:
;   1. Optional time-activation gate.
;   2. Suppression on, AltGr Kana fixup if needed.
;   3. BackSpace ``Spec.Length + (EndChar != "" ? 1 : 0)`` characters off
;      the screen — when an end character is involved, the OS already
;      typed it through the InputHook so we have to delete it too.
;   4. SendEvent / SendInput / SendInstant the replacement and the end
;      character, mirroring the three branches of the original
;      _HotstringDispatch (Notepad clipboard route, FinalResult, default).
;   5. HSE_ApplyExpansion to mirror the new screen state into the buffer.
;   6. Deferred Suppress(false) so in-flight events stay filtered.
;
; Specs without dispatch metadata (Replacement undefined — the unit-test
; path) fall through to invoking Spec.Callback for backwards
; compatibility with the test-only registrations.
; Mirror one already-resolved screen edit into the longer LLM context. The
; caller owns the Critical span which also commits the matching HSE edit, so a
; physical character can never reach only one buffer. Both normal replacements
; and raw callbacks route here; neither is allowed to re-derive the edit.
_HSE_MirrorCanonicalEffectToLlm(Effect) {
		if !A_IsCritical
				throw Error("_HSE_MirrorCanonicalEffectToLlm requires a Critical buffer transaction.")
		if !(IsObject(Effect) and Effect.HasOwnProp("DeleteFromEnd")
				and Effect.HasOwnProp("InsertedText"))
				throw Error("Canonical hotstring effect is missing DeleteFromEnd or InsertedText.")
		if (IsSet(_LLM_Bridge_Active) and _LLM_Bridge_Active
				and IsSet(_LLM_Bridge_ApplyBufferEdit)) {
				if (Effect.HasOwnProp("ClearAll") and Effect.ClearAll)
						_LLM_Bridge_ApplyBufferEdit()
				else
						_LLM_Bridge_ApplyBufferEdit(Effect.DeleteFromEnd, Effect.InsertedText)
		}
}

; Dispatch a "raw callback" hotstring (the natives migrated into the HSE: the
; E-circumflex deadkey and the "..." ellipsis). The callback does ALL of its own
; conditional, variable-length sending/backspacing and returns an { Ok, Bs, Ins }
; transaction. Ok is true only after output succeeds; Bs chars are then removed
; from the buffer's right and Ins appended. A false Ok means either a deliberate
; decline or a contained send failure. We wrap it with the same prefix suppression +
; keylogger synthetic-marking the Replacement path uses, and resync HSE_Buffer from
; the effect so the next keystroke matches the post-expansion screen. This is what
; lets those two former native AHK Hotstring() registrations live in the HSE — no
; A_InputLevel dependency remains, so they register on the normal (and live-rebuild)
; path like every other section.
_HSE_DispatchRawCallback(Spec, EndChar, &CommittedEffect := 0) {
		global HSE_SUPPRESS_RELEASE_DELAY_MS, HSE_Buffer, HSE_MAX_BUFFER_LEN, HSE_StartIsWordBoundary
		CommittedEffect := 0
		if !(Spec.HasOwnProp("Callback") and Spec.Callback) {
				return false
		}
		; Whether the callback actually expanded. A raw callback is allowed to DECLINE
		; (the E-circumflex deadkey and ellipsis guards refuse in the wrong context) by
		; returning {Ok:false, Bs:0, Ins:""} — the caller must not then log a fire or
		; strip the preview buffer for an expansion the user never saw.
		Fired := false
		; Route through PrefixWatcherSuppress when available — it delegates to
		; HSE_Suppress internally, so a SINGLE matched pair (true/false) keeps
		; HSE_Suppressed balanced at depth 1. The direct HSE_Suppress(true) path is
		; the fallback for contexts where the prefix watcher is not loaded (tools/,
		; standalone tests). Mixing both paths would double-increment HSE_Suppressed
		; to 2, requiring two release timers to fire — a timing assumption that breaks
		; in CI environments where timer ordering is not guaranteed.
		if IsSet(PrefixWatcherSuppress) {
				try PrefixWatcherSuppress(true)
		} else {
				HSE_Suppress(true)
		}
		; The privacy flag rides along: the keylogger's InputHook observes the
		; characters this callback is about to type, and without it they land in
		; the typing row verbatim.
		SyntheticOwner := 0
		try SyntheticOwner := KL_MarkSynthetic("hotstring",
			Spec.HasOwnProp("IsPrivate") and Spec.IsPrivate)
		try {
				Effect := (Spec.Callback)(EndChar)
				; A falsy Effect means the callback declined to expand — leave the buffer
				; (with the trigger chars still in it) untouched.
				if (IsObject(Effect) and Effect.HasOwnProp("Ok") and Effect.HasOwnProp("Bs")) {
						EffectOk := Effect.Ok
						; The raw callback owns the screen transaction, so its buffer effect is
						; publishable only with an explicit successful Boolean verdict. This
						; prevents a failed sender from rewriting HSE_Buffer as if output landed.
						if !((EffectOk is Integer) and EffectOk)
								return false
						BufLen := StrLen(HSE_Buffer)
						Bs  := Max(0, Min(Effect.Bs, BufLen))
						if (Bs != Effect.Bs)
								try LoggerWarn("HSE", "Raw callback returned Bs={1} out of range [0,{2}] — clamped.", Effect.Bs, BufLen)
						Ins := Effect.HasOwnProp("Ins") ? Effect.Ins : ""
						; Deleted nothing AND inserted nothing == the callback declined.
						Fired := (Bs > 0 or Ins != "")
						if Fired {
								_BufferCrit := Critical("On")
								try {
										HSE_Buffer := (BufLen >= Bs ? SubStr(HSE_Buffer, 1, BufLen - Bs) : "") . Ins
										; Mirror HSE_ApplyExpansion's cap so a future raw callback with a large
										; Ins can never grow the buffer unbounded or drift the boundary flag.
										if (StrLen(HSE_Buffer) > HSE_MAX_BUFFER_LEN) {
												HSE_Buffer := SubStr(HSE_Buffer, -HSE_MAX_BUFFER_LEN)
												HSE_StartIsWordBoundary := false
										}
										CanonicalEffect := {
												ClearAll: false,
												DeleteFromEnd: Bs,
												InsertedText: Ins,
												EndCharEmitted: false,
												KnownBoundaryAfter: HSE_Buffer != ""
														and InStr(_HSE_WordBoundarySet(), SubStr(HSE_Buffer, -1)) > 0
										}
										_HSE_MirrorCanonicalEffectToLlm(CanonicalEffect)
										CommittedEffect := CanonicalEffect
								} finally {
										Critical(_BufferCrit)
								}
						}
				}
		} finally {
				; Gated on Fired. A raw callback that DECLINED changed nothing on screen:
				; the trigger characters are all still there and HSE_Buffer still holds
				; them (the branch above leaves it untouched). Wiping the preview anyway
				; made the tooltip describe a word the engine was still matching against,
				; so the suggestion vanished for text that would still have expanded.
				if (Fired and IsSet(_ResetPrefixBuffer)) {
						try _ResetPrefixBuffer(true)
				}
				; Release via the same path used to suppress — a single matched pair keeps
				; HSE_Suppressed balanced. The PrefixWatcherSuppress path handles both the
				; prefix-watcher counter and HSE_Suppressed in one call.
				if IsSet(PrefixWatcherSuppress) {
						if Fired
								SetTimer((*) => PrefixWatcherSuppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
						else
								PrefixWatcherSuppress(false)
				} else {
						if Fired
								SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
						else
								HSE_Suppress(false)
				}
				if Fired
						SetTimer((*) => KL_ClearSynthetic(SyntheticOwner),
							-HSE_SUPPRESS_RELEASE_DELAY_MS)
				else
						KL_ClearSynthetic(SyntheticOwner)
		}
		return Fired
}

; Resolve every dispatch gate into one immutable decision shared by the preview
; and the fire path. Keeping time, casing and callable resolution below in one
; owner prevents a tooltip from advertising a matcher winner that dispatch will
; subsequently refuse — or from showing one dynamic value and resolving another
; after the user presses the completion key.
; @param FrozenResolvedBase Optional value captured by a decision that is still
;   visibly presented. When supplied, the callable is not invoked a second time.
; @return Canonical decision object, or "" when dispatch must decline.
_HSE_PrepareDispatchDecision(Spec, BufferAfterCompletion, EndChar,
		TypoNbspStripped := false, FrozenResolvedBase := unset) {
		global LastSentCharacterKeyTime
		if !IsObject(Spec) or !Spec.HasOwnProp("Replacement")
				return ""
		if (Spec.HasOwnProp("RawCallback") and Spec.RawCallback)
				return ""

		GateOriginTick := 0
		GateDurationMs := 0
		RemainingMs := 0
		if Spec.HasOwnProp("TimeActivationSeconds")
				and Spec.TimeActivationSeconds > 0 {
				if !Spec.HasOwnProp("PrevCharKey") or !IsSet(LastSentCharacterKeyTime)
						or !(LastSentCharacterKeyTime is Map)
						return ""
				PrevKey := Spec.PrevCharKey
				if (Spec.HasOwnProp("CaseConform") and Spec.CaseConform) {
						CompletionStripLen := StrLen(EndChar) + (TypoNbspStripped ? 1 : 0)
						TriggerStart := StrLen(BufferAfterCompletion)
								- CompletionStripLen - Spec.Length + 1
						TypedPrev := TriggerStart >= 1
								? SubStr(BufferAfterCompletion, TriggerStart + Spec.Length - 2, 1)
								: ""
						if (TypedPrev != "")
								PrevKey := TypedPrev
				}
				if !LastSentCharacterKeyTime.Has(PrevKey)
						return ""
				GateOriginTick := LastSentCharacterKeyTime[PrevKey]
				GateDurationMs := Round(Spec.TimeActivationSeconds * 1000)
				ElapsedMs := TickElapsed(GateOriginTick)
				; Preserve the engine's existing strict comparison: equality is the last
				; fireable instant. The renderer separately refuses RemainingMs == 0 so
				; it never paints a promise with no usable interaction window.
				if (ElapsedMs > GateDurationMs)
						return ""
				RemainingMs := Max(0, GateDurationMs - ElapsedMs)
		}

		if IsSet(FrozenResolvedBase) {
				ResolvedBase := FrozenResolvedBase
		} else {
				ResolvedBase := Spec.Replacement
				if HasMethod(ResolvedBase) {
						try ResolvedBase := ResolvedBase.Call()
						catch as Err {
						try LoggerError("HSE", "Resolving a dynamic replacement failed; exception detail withheld.")
								return ""
						}
				}
		}
		if !(ResolvedBase is String) {
				try LoggerError("HSE", "A hotstring replacement resolved to '{1}', not String; dispatch declined.", Type(ResolvedBase))
				return ""
		}

		IsConform := Spec.HasOwnProp("CaseConform") and Spec.CaseConform
		Replacement := ResolvedBase
		if IsConform {
				CompletionStripLen := StrLen(EndChar) + (TypoNbspStripped ? 1 : 0)
				TriggerStart := StrLen(BufferAfterCompletion)
						- CompletionStripLen - Spec.Length + 1
				if (TriggerStart < 1)
						return ""
				TypedTrigger := SubStr(BufferAfterCompletion, TriggerStart, Spec.Length)
				DoFire := true
				Replacement := _HSE_ConformReplacement(ResolvedBase, TypedTrigger, Spec.Trigger,
						(Spec.HasOwnProp("ConformOneChar") and Spec.ConformOneChar), &DoFire)
				if !DoFire
						return ""
		}

		return {
				Spec: Spec,
				ResolvedBase: ResolvedBase,
				Replacement: Replacement,
				OnlyText: Spec.HasOwnProp("OnlyText") ? Spec.OnlyText : true,
				IsConform: IsConform,
				GateOriginTick: GateOriginTick,
				GateDurationMs: GateDurationMs,
				RemainingMs: RemainingMs
		}
}

; Returns TRUE when the match actually produced an expansion, FALSE when it declined
; (no spec, a raw callback that refused, a time-activation timeout, or a mixed-case
; conform verdict). Callers use this to decide whether a fire really happened: logging
; a fire — or stripping the preview buffer — for a decline reports an expansion the
; user never saw.
HSE_DispatchMatch(Spec, EndChar, &CommittedEffect := 0,
		ForceConsumeEndChar := false) {
		global HSE_SUPPRESS_RELEASE_DELAY_MS, _SendHook, HSE_TypoNbspStripped, HSE_Buffer
		global _HSE_TerminalOwnerSerial, HSE_RegistryGeneration, HSE_RuntimeDecisionGeneration
		global _PrefixInputContextGeneration, _PrefixDeferredGeneration
		CommittedEffect := 0
		if (Spec == "") {
				return false
		}
		; Raw-callback specs (the natives migrated into the HSE: E-circumflex deadkey,
		; "..." ellipsis) do all their own conditional, variable-length send/backspace;
		; route them to _HSE_DispatchRawCallback so the engine never auto-strips a
		; trigger the callback may have left in place.
		if (Spec.HasOwnProp("RawCallback") and Spec.RawCallback) {
				RawHost := OutputHostResolve(true)
				if !RawHost["Valid"]
					return false
				if _HSE_IsTerminalInputHost(RawHost["Exe"], RawHost["Title"])
					return _HSE_DispatchTerminalRawCallback(Spec, EndChar, RawHost)
				; Propagate the callback's own verdict: it alone knows whether it expanded.
				return _HSE_DispatchRawCallback(Spec, EndChar, &CommittedEffect)
		}
		if !Spec.HasOwnProp("Replacement") {
				if Spec.HasOwnProp("Callback") and Spec.Callback {
						try return _SendVerdictSucceeded((Spec.Callback)(EndChar))
				}
				return false
		}

		; If the currently visible row owns a resolved dynamic value, claim it only
		; when its registry identity and exact input context still match. Preflight
		; then rechecks the live time/case gates while reusing that shown value.
		VisibleDecision := 0
		if IsSet(HotstringPrefixWatcherClaimVisibleDecision)
				try VisibleDecision := HotstringPrefixWatcherClaimVisibleDecision(
						Spec, EndChar, HSE_Buffer)
		Prepared := IsObject(VisibleDecision)
				? _HSE_PrepareDispatchDecision(Spec, HSE_Buffer, EndChar,
						HSE_TypoNbspStripped, VisibleDecision.ResolvedBase)
				: _HSE_PrepareDispatchDecision(
						Spec, HSE_Buffer, EndChar, HSE_TypoNbspStripped)
		if !IsObject(Prepared)
				return false
		IsConform := Prepared.IsConform
		Replacement := Prepared.Replacement
		OnlyText := Prepared.OnlyText
		; Sender choice and terminal ownership must share one foreground receipt.
		; Acquire it before suppression/synthetic ownership so an ambiguous focus or
		; title probe declines with no output-side mutation.
		OutputHost := OutputHostResolve(true)
		if !OutputHost["Valid"]
			return false

		Fired := false
		DeferredOwner := 0
		TerminalOwnershipTransferred := false
		; Route through PrefixWatcherSuppress when available — it delegates to
		; HSE_Suppress internally, so a SINGLE matched pair (true/false) keeps
		; HSE_Suppressed balanced at depth 1. The direct HSE_Suppress(true) path is
		; the fallback for contexts where the prefix watcher is not loaded (tools/,
		; standalone tests). Mixing both paths would double-increment HSE_Suppressed
		; to 2, requiring two release timers to fire — a timing assumption that breaks
		; in CI environments where timer ordering is not guaranteed.
		; Mirror _HotstringDispatch's PrefixWatcherSuppress guard: mute the
		; prefix watcher for the duration of the send burst so the backspaces
		; and replacement characters do not pollute _PrefixBuffer and stale the
		; tooltip state. Without this, calling HSE_DispatchMatch from outside the
		; InputHook callback (e.g. SpaceTapHold) leaves _PrefixBuffer pointing at
		; the pre-expansion context, causing incorrect tooltip lookups afterward.
		if IsSet(PrefixWatcherSuppress) {
				try PrefixWatcherSuppress(true)
		} else {
				HSE_Suppress(true)
		}
		; Tag the backspace+replacement burst as synthetic so the keylogger keeps
		; it out of the manual `chars` count and attributes the resulting n-grams
		; to the hotstring source (esrc). Released on the same deferred timer as
		; the suppression below so it covers the OS message-loop flush window.
		;
		; The second argument is not bookkeeping: the burst below is typed through
		; the OS, the keylogger's own InputHook sees every character of it, and the
		; typing row it writes is a SECOND sink for the same secret the fire row
		; already redacts.
		SyntheticOwner := 0
		try SyntheticOwner := KL_MarkSynthetic("hotstring",
			Spec.HasOwnProp("IsPrivate") and Spec.IsPrivate)
		try {
				if _ALTGR_KANA_FIXUP {
						; SendInput (not SendEvent) — non-blocking injection that does not
						; yield the message loop. SendEvent was adding ~10-20 ms of latency
						; on every expansion on AltGr-fixup keyboards by flushing through
						; the hook chain synchronously. SendInput injects directly into the
						; kernel input queue, clears the stuck AltGr state before the burst,
						; and returns immediately — consistent with the SendInput burst below.
						AltGrReleased := false
						try {
								if _SendHook {
										Hook := _SendHook
										AltGrReleased := _SendVerdictSucceeded(Hook("SendFinalResult", "{SC138 Up}", false))
								} else {
										SendInput("{SC138 Up}")
										AltGrReleased := true
								}
						} catch as Err {
								try LoggerError("HSE", "AltGr release injection failed: {1}", Err.Message)
						}
						if !AltGrReleased
								return false
				}

				; +1 for the NNBSP/NBSP that was stripped before matching when the
				; end-char is a typographic punctuation (``:`` / `` ; ``).
				BSCount := Spec.Length + (EndChar != "" ? 1 : 0) + (HSE_TypoNbspStripped ? 1 : 0)
				BackSpaceSeq := "{BackSpace " . BSCount . "}"
				; Replacement, casing and OnlyText were frozen by the shared decision
				; preflight above. Never resolve a callable again here: when the tooltip
				; supplied the visible decision, this exact value is what it promised.
				; (KLHook global removed)
				exe := OutputHost["Exe"]
				WindowTitle := OutputHost["Title"]
				IsNotepadApp := (StrLower(exe) = "notepad.exe")
				IsTerminalApp := _HSE_IsTerminalInputHost(exe, WindowTitle)
					; The clipboard route can only paste literal text. A Send-key payload such
					; as '""{Left}' must keep its interpreted cursor movement in Notepad;
					; pasting it would silently put the five characters "{Left}" on screen.
					; Reuse the normal atomic SendInput branch for those entries.
					IsNotepadApp := IsNotepadApp and OnlyText
					SentBurst := ""   ; exactly what we injected — captured for the fire-trace
					ReplacementPart := OnlyText ? ("{Text}" . Replacement) : Replacement
					; Consume the end-char when it is explicitly listed as consumed —
					; otherwise always re-inject it so the user sees what they typed.
					EndCharPart := (EndChar != "" and !ForceConsumeEndChar
							and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)) ? EndChar : ""
					Burst := BackSpaceSeq . ReplacementPart . EndCharPart

				if IsNotepadApp {
						; Windows-11 Notepad mis-handles SendInput-injected hotstrings, so the
						; replacement is routed through the clipboard. SendInstant accepts the
						; erase sequence as a prefix and injects it with Ctrl+V in one SendInput
						; burst, so no physical key can land between erase and paste.
						; Mirror the atomic branch's consumed-delimiter guard so a space
						; (or any other consumed end-char) is not re-injected after the
						; clipboard paste — same contract as the SendInput path.
						EndCharEmitted := (EndChar != "" and !ForceConsumeEndChar
								and !InStr(HSE_CONSUMED_DELIMITERS, EndChar)) ? EndChar : ""
						_NpCrit := Critical("On")
						try {
								; BackSpaceSeq is a control sequence, not emitted text. The actual
								; last character is recorded explicitly below after the atomic paste.
								Fired := SendInstant(Replacement . EndCharEmitted, BackSpaceSeq)
						} finally {
								Critical(_NpCrit)
						}
						if !Fired
								return false
						UpdateLastSentCharacter(SubStr(EndCharEmitted != "" ? EndCharEmitted : Replacement, -1))
						SentBurst := BackSpaceSeq . "[clip]" . Replacement . EndCharEmitted
				} else if IsTerminalApp {
						; OpenTUI/React-style prompts commit deletion state once per render
						; turn. SendInput's zero-delay Backspace array makes every handler see
						; the same pre-deletion value; the following text then appends to the
						; trigger (``xgboostXGBoost``). AHK does not apply SetKeyDelay between
						; repetitions in ``{BackSpace N}``, so emit explicit keys and yield after
						; each one. The timer hand-off lets the completing physical key reach the
						; terminal before the native capture replays later physical input.
						TerminalDelayMs := TimingsGet("debounce", "terminal_hotstring_key_delay_ms")
						_AtCrit := Critical("On")
						try {
								if _SendHook {
										Hook := _SendHook
										EmitFn := (Payload) => Hook("SendTerminalResult", Payload, false)
								} else {
										EmitFn := 0
								}
								DeferredOwner := Map(
									"Id", ++_HSE_TerminalOwnerSerial,
									"Pending", true,
									"Backspaces", BSCount,
									"PlainInsertedText", Replacement . EndCharPart,
									"SendPayload", ReplacementPart . EndCharPart,
									"EndCharPart", EndCharPart,
									"OnlyText", OnlyText,
									"DelayMs", TerminalDelayMs,
									"EmitFn", EmitFn,
									"DelayFn", 0,
									"BufferSnapshot", HSE_Buffer,
									"Hwnd", OutputHost["Hwnd"],
									"Pid", OutputHost["Pid"],
									"RegistryGeneration", HSE_RegistryGeneration,
									"DecisionGeneration", HSE_RuntimeDecisionGeneration,
									"InputGeneration", _PrefixInputContextGeneration,
									"LifecycleGeneration", _PrefixDeferredGeneration,
									"Trigger", Spec.Trigger,
									"ReplacementForLog", Spec.Replacement,
									"HType", IsSet(_ResolveFireHType) ? _ResolveFireHType(Spec) : (EndChar != "" ? "endchar" : "star"),
									"Category", Spec.HasOwnProp("Category") ? Spec.Category : "",
									"Section", Spec.HasOwnProp("Section") ? Spec.Section : "",
									"IsPrivate", Spec.HasOwnProp("IsPrivate") && Spec.IsPrivate,
									"SyntheticOwner", SyntheticOwner,
									"Port", 0
								)
								TerminalOwnershipTransferred := true
								BeginResult := _HSE_BeginOwnedTerminalTransaction(DeferredOwner)
								if BeginResult is Map {
									Fired := BeginResult["Pending"]
										? BeginResult : BeginResult["FinalSucceeded"]
								}
						} catch as Err {
								try LoggerError("HSE", "Terminal expansion scheduling failed: {1}", Err.Message)
						} finally {
								Critical(_AtCrit)
						}
						if !Fired
								return false
						; Admission is not output success. The timer owner revalidates,
						; emits, commits all canonical state, records metrics, and releases
						; suppression only after its sender returns a true verdict.
						return Fired
				} else {
						; SendInput is atomic: the ENTIRE backspace+replacement+endchar burst is
						; injected as one unit, so any physical keystroke the user types during
						; the expansion is buffered by the OS and delivered AFTER it — never
						; spliced into the middle (the race that produced "outpubct" /
						; "Cha[letter]tGPT"). This single path now also serves former
						; final_result triggers: post the SendInput migration every expansion is
						; non-cascading anyway, so the old 3-call SendFinalResult branch (which
						; sent BackSpace, Replacement and EndChar as SEPARATE SendInputs with
						; interleave gaps between them) was both redundant and the interleave
						; source — folded into this one atomic send, which additionally grants
						; those triggers the {Text} wrapping, consumed-delimiter handling and
						; UpdateLastSentCharacter the split branch silently skipped.
						; Critical so AHK cannot start the next physical key's layout-remap
						; SendEvent thread between issuing this burst and it draining — keeping
						; the expansion atomic even when dispatched from a caller that is NOT
						; already Critical (e.g. the Space tap-hold path). Save/restore nests
						; safely under _OnPrefixChar's Critical. No Sleep here, so it is safe to
						; hold. Route through _SendHook when present (test harness) so the entire
						; atomic burst is recorded and assertions can inspect it; in production
						; _SendHook is unset and SendInput fires directly.
						SendError := ""
						_AtCrit := Critical("On")
						try {
								if _SendHook {
										Hook := _SendHook
										Fired := _SendVerdictSucceeded(Hook("SendFinalResult", Burst, false))
								} else {
										SendInput(Burst)
										Fired := true
								}
						} catch as Err {
								SendError := Err.Message
						} finally {
								Critical(_AtCrit)
						}
						if !Fired {
								if SendError != ""
										try LoggerError("HSE", "Atomic expansion injection failed: {1}", SendError)
								return false
						}
						if OnlyText
								UpdateLastSentCharacter(SubStr(EndCharPart != "" ? EndCharPart : Replacement, -1))
						else
								_LSCResetFrom([])
						SentBurst := Burst
				}

				; ── Diagnostic fire-trace (debug only) ──────────────────────────────────
				; One line per expansion capturing the exact injected burst, branch and
				; context, so a reproduction of an interleave/drop ("outpubct",
				; "abcd"->"acd") can be read straight off the log. Debug-gated so normal
				; typing stays silent; enable via tray Debug -> Log level -> DEBUG.
				if LoggerIsDebugEnabled() {
						; The burst IS the replacement (plus the erase sequence), and the
						; trigger is a fragment of the same secret, so a private mapping
						; withholds both. DEBUG is exactly the level a user is asked to
						; switch on when reporting a bug, and this log rotates alongside
						; the metrics store the redaction exists to protect — so the shape
						; of the fire is traced and none of its content is.
						if (Spec.HasOwnProp("IsPrivate") and Spec.IsPrivate) {
								try LoggerDebug("HSEFire",
										"FIRE private mapping bs={1} branch={2} conform={3} burst={4} char(s) (trigger and content withheld).",
										BSCount, IsNotepadApp ? "notepad-clip" : (IsTerminalApp ? "terminal-paced" : "atomic"),
										IsConform ? 1 : 0, StrLen(SentBurst))
						} else {
								try LoggerDebug("HSEFire",
										"FIRE trig='{1}' end='{2}' bs={3} branch={4} conform={5} burst='{6}'.",
										Spec.Trigger, EndChar, BSCount, IsNotepadApp ? "notepad-clip" : (IsTerminalApp ? "terminal-paced" : "atomic"),
										IsConform ? 1 : 0, SentBurst)
						}
				}

					; The engine computes the one canonical screen edit, including consumed
					; delimiters and a stripped typographic nbsp. Apply that SAME immutable
					; edit to the longer LLM context instead of asking the bridge to predict
					; the effect again. Keep both state commits in one short Critical span so
					; a physical OnChar cannot land between the two buffers.
					_BufferCrit := Critical("On")
					try {
							ExpansionEffect := HSE_ApplyExpansion(
									Spec, Replacement, EndChar, ForceConsumeEndChar)
							_HSE_MirrorCanonicalEffectToLlm(ExpansionEffect)
							CommittedEffect := ExpansionEffect
					} finally {
							Critical(_BufferCrit)
					}
		} finally {
				; Reset the prefix watcher buffer synchronously so the post-expansion
				; state is immediately clean. This must happen before the deferred
				; Suppress(false) fires so that PrefixWatcherSuppress(false) does not
				; find a stale buffer and clear it 60 ms later — which would erase the
				; first keystrokes of the next word if the user types quickly.
				if (!TerminalOwnershipTransferred and Fired and IsSet(_ResetPrefixBuffer)) {
						try _ResetPrefixBuffer(true)
				}
				; Release via the same path used to suppress — a single matched pair keeps
				; HSE_Suppressed balanced. The PrefixWatcherSuppress path handles both the
				; prefix-watcher counter and HSE_Suppressed in one call.
				if TerminalOwnershipTransferred {
						; The deferred transaction owns both releases.
				} else if IsSet(PrefixWatcherSuppress) {
						if Fired
								SetTimer((*) => PrefixWatcherSuppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
						else
								PrefixWatcherSuppress(false)
				} else {
						if Fired
								SetTimer((*) => HSE_Suppress(false), -HSE_SUPPRESS_RELEASE_DELAY_MS)
						else
								HSE_Suppress(false)
				}
				; Release the synthetic flag on the same flush window as the suppression
				; — clearing inline would let trailing replacement keystrokes look manual.
				if TerminalOwnershipTransferred {
						; The deferred transaction owns the synthetic marker.
				} else if Fired
						SetTimer((*) => KL_ClearSynthetic(SyntheticOwner),
							-HSE_SUPPRESS_RELEASE_DELAY_MS)
				else
						KL_ClearSynthetic(SyntheticOwner)
		}
		; Reached only when the replacement was actually emitted.
		return true
}

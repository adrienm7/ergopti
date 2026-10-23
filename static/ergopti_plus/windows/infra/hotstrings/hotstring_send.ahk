; infra/hotstrings/hotstring_send.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Low-level Send & Ring Buffer
; DESCRIPTION:
; Low-level send primitives (SendNewResult, SendFinalResult, SendInstant,
; ActivateHotstrings, GetSelection), the last-sent-character ring buffer
; (_LSC_*) used by deadkey sequences, and the last-sent-character timestamps
; that time-gated triggers read.
;
; Included by infra/hotstrings/hotstring_engine.ahk after the constants section.
; ==============================================================================





; =======================================
; =======================================
; ======= 1/ Low-level send layer =======
; =======================================
; =======================================

; Functional routing owns its foreground receipt. Process/class metadata is
; cacheable only for one exact HWND/PID; the title is deliberately not cached
; because one editor window can become a terminal surface without changing
; identity. The final identity probe prevents an A-metadata/B-focus mixture.
global _OUTPUT_HOST_CACHE := 0
global _OUTPUT_HOST_IDENTITY_PROBE := 0
global _OUTPUT_HOST_METADATA_PROBE := 0
global _OUTPUT_HOST_TITLE_PROBE := 0
global _OUTPUT_HOST_RESOLVE_SERIAL := 0

OutputHostResolverConfigure(IdentityProbe := 0, MetadataProbe := 0,
		TitleProbe := 0) {
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE
	global _OUTPUT_HOST_METADATA_PROBE, _OUTPUT_HOST_TITLE_PROBE
	global _OUTPUT_HOST_RESOLVE_SERIAL
	_OUTPUT_HOST_CACHE := 0
	_OUTPUT_HOST_IDENTITY_PROBE := IdentityProbe
	_OUTPUT_HOST_METADATA_PROBE := MetadataProbe
	_OUTPUT_HOST_TITLE_PROBE := TitleProbe
	_OUTPUT_HOST_RESOLVE_SERIAL += 1
}

_OutputHostForegroundIdentity() {
	Hwnd := WIGetForegroundHwnd()
	if !Hwnd
		return Map("Hwnd", 0, "Pid", 0)
	Pid := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd,
		"UInt*", &Pid, "UInt")
	if !ThreadId || !Pid
		return Map("Hwnd", 0, "Pid", 0)
	return Map("Hwnd", Hwnd, "Pid", Pid)
}

_OutputHostReadMetadata(Hwnd, Pid) {
	CurrentPid := 0
	ThreadId := DllCall("User32\GetWindowThreadProcessId", "Ptr", Hwnd,
		"UInt*", &CurrentPid, "UInt")
	if !ThreadId || CurrentPid != Pid
		throw Error("foreground process identity changed")
	Identity := _WIReadProcessIdentityCached(Pid)
	if !IsObject(Identity) || Identity.process_id != Pid
		throw Error("foreground process metadata unavailable")
	ClassName := _WIReadClassNameLocal(Hwnd)
	if !(ClassName is String) || ClassName == ""
		throw Error("foreground class unavailable")
	return Map("Exe", Identity.name, "Class", ClassName)
}

_OutputHostReadTitle(Hwnd, Pid) {
	Result := _WIReadTitleBounded(Hwnd, WI_FOCUS_TITLE_TIMEOUT_MS)
	return Map("Ok", Result.ok, "Title", Result.title,
		"TimedOut", Result.timed_out)
}

_OutputHostInvalidReceipt(Failure, Hwnd := 0, Pid := 0,
		TimedOut := false) {
	return Map(
		"Valid", false, "Failure", Failure, "TimedOut", TimedOut,
		"Hwnd", Hwnd, "Pid", Pid,
		"Exe", "", "Class", "", "Title", ""
	)
}

; Reports one output-host failure, at most once per minute per distinct kind.
; Extracted so the degraded-title path can carry the same throttled diagnostic
; without also having to fail the receipt (hotstring-title-timeout-eats-expansion).
_OutputHostLogFailure(Failure) {
	static LastFailure := ""
	static LastAt := 0
	Now := A_TickCount
	Elapsed := LastAt == 0 ? 0xFFFFFFFF : ((Now - LastAt) & 0xFFFFFFFF)
	if (Failure != LastFailure || Elapsed >= 60000) {
		LastFailure := Failure
		LastAt := Now
		try LoggerWarn("OutputHost",
			"Foreground output-host receipt rejected ({1}).", Failure)
	}
}

_OutputHostReject(Failure, Hwnd := 0, Pid := 0, TimedOut := false) {
	_OutputHostLogFailure(Failure)
	return _OutputHostInvalidReceipt(Failure, Hwnd, Pid, TimedOut)
}

_OutputHostValidReceipt(Hwnd, Pid, Exe, ClassName, Title := "",
		TitleTimedOut := false) {
	return Map(
		"Valid", true, "Failure", "", "TimedOut", TitleTimedOut,
		"Hwnd", Hwnd, "Pid", Pid,
		"Exe", Exe, "Class", ClassName, "Title", Title
	)
}

_OutputHostProbeIdentity() {
	global _OUTPUT_HOST_IDENTITY_PROBE
	; MicrosoftApps() is a parse-time #HotIf criterion. Keep this leaf safe even
	; when AHK evaluates it during the first message pump before module globals
	; have been assigned.
	if !IsSet(_OUTPUT_HOST_IDENTITY_PROBE)
		return Map("Hwnd", 0, "Pid", 0)
	Identity := HasMethod(_OUTPUT_HOST_IDENTITY_PROBE, "Call")
		? _OUTPUT_HOST_IDENTITY_PROBE.Call() : _OutputHostForegroundIdentity()
	if !(Identity is Map) || !Identity.Has("Hwnd") || !Identity.Has("Pid")
		return Map("Hwnd", 0, "Pid", 0)
	Hwnd := Identity["Hwnd"]
	Pid := Identity["Pid"]
	if !(Hwnd is Integer) || Hwnd <= 0 || !(Pid is Integer) || Pid <= 0
		return Map("Hwnd", 0, "Pid", 0)
	return Map("Hwnd", Hwnd, "Pid", Pid)
}

_OutputHostNormalizeTitle(Result) {
	if (Result is String)
		return Map("Ok", true, "Title", Result, "TimedOut", false)
	if !(Result is Map)
		return Map("Ok", false, "Title", "", "TimedOut", false)
	Title := Result.Get("Title", "")
	Ok := Result.Get("Ok", Result.Has("Title"))
	TimedOut := Result.Get("TimedOut", false)
	return Map(
		"Ok", (Ok is Integer) && Ok && (Title is String),
		"Title", (Title is String) ? Title : "",
		"TimedOut", (TimedOut is Integer) && TimedOut
	)
}

/** Acquires a current receipt; a title predicate may skip an irrelevant caption. */
OutputHostResolve(RequireTitle := false) {
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE
	global _OUTPUT_HOST_METADATA_PROBE, _OUTPUT_HOST_TITLE_PROBE
	global _OUTPUT_HOST_RESOLVE_SERIAL
	; MicrosoftApps() is a parse-time #HotIf criterion and reaches this resolver
	; during Bundle_Init's first message pump, before these module globals exist.
	if (!IsSet(_OUTPUT_HOST_CACHE) || !IsSet(_OUTPUT_HOST_IDENTITY_PROBE)
			|| !IsSet(_OUTPUT_HOST_METADATA_PROBE)
			|| !IsSet(_OUTPUT_HOST_TITLE_PROBE)
			|| !IsSet(_OUTPUT_HOST_RESOLVE_SERIAL))
		return _OutputHostInvalidReceipt("not_initialized")

	Serial := ++_OUTPUT_HOST_RESOLVE_SERIAL
	try Identity := _OutputHostProbeIdentity()
	catch {
		return _OutputHostReject("identity_error")
	}
	Hwnd := Identity["Hwnd"]
	Pid := Identity["Pid"]
	if !Hwnd || !Pid {
		if (_OUTPUT_HOST_RESOLVE_SERIAL == Serial)
			_OUTPUT_HOST_CACHE := 0
		return _OutputHostReject("identity_unavailable")
	}

	if (_OUTPUT_HOST_CACHE is Map
			&& _OUTPUT_HOST_CACHE["Hwnd"] == Hwnd
			&& _OUTPUT_HOST_CACHE["Pid"] == Pid) {
		Candidate := _OUTPUT_HOST_CACHE
	} else {
		try Metadata := HasMethod(_OUTPUT_HOST_METADATA_PROBE, "Call")
			? _OUTPUT_HOST_METADATA_PROBE.Call(Hwnd, Pid)
			: _OutputHostReadMetadata(Hwnd, Pid)
		catch {
			if (_OUTPUT_HOST_RESOLVE_SERIAL == Serial)
				_OUTPUT_HOST_CACHE := 0
			return _OutputHostReject("metadata_error", Hwnd, Pid)
		}
		if !(Metadata is Map)
				|| !(Metadata.Get("Exe", "") is String)
				|| Metadata.Get("Exe", "") == ""
				|| !(Metadata.Get("Class", "") is String)
				|| Metadata.Get("Class", "") == ""
			return _OutputHostReject("metadata_invalid", Hwnd, Pid)
		Candidate := Map(
			"Hwnd", Hwnd, "Pid", Pid,
			"Exe", Metadata["Exe"], "Class", Metadata["Class"])
	}

	Title := ""
	TitleTimedOut := false
	TitleRequired := RequireTitle
	if HasMethod(RequireTitle, "Call") {
		try TitleRequired := RequireTitle.Call(Candidate["Exe"])
		catch {
			return _OutputHostReject("title_policy_error", Hwnd, Pid)
		}
		if !(TitleRequired is Integer) || (TitleRequired != 0 && TitleRequired != 1)
			return _OutputHostReject("title_policy_invalid", Hwnd, Pid)
	}
	if TitleRequired {
		try RawTitle := HasMethod(_OUTPUT_HOST_TITLE_PROBE, "Call")
			? _OUTPUT_HOST_TITLE_PROBE.Call(Hwnd, Pid)
			: _OutputHostReadTitle(Hwnd, Pid)
		catch {
			return _OutputHostReject("title_error", Hwnd, Pid)
		}
		TitleResult := _OutputHostNormalizeTitle(RawTitle)
		if !TitleResult["Ok"] {
			; A title probe is a 5 ms SendMessageTimeout against the foreground
			; window. Missing that deadline says the window was busy, not that this
			; receipt names the wrong one -- identity and metadata are already proven
			; above. Failing the whole receipt here silently discarded the user's
			; expansion: every hotstring died for as long as the target app stayed
			; busy, with one throttled log line per minute to show for it, and no
			; reload could clear it (hotstring-title-timeout-eats-expansion).
			;
			; Degrade instead. The title feeds exactly one decision, an embedded
			; terminal substring match, which falls back to the executable list.
			if !TitleResult["TimedOut"]
				return _OutputHostReject("title_error", Hwnd, Pid)
			_OutputHostLogFailure("title_timeout")
			TitleTimedOut := true
		} else {
			Title := TitleResult["Title"]
		}
	}

	try FinalIdentity := _OutputHostProbeIdentity()
	catch {
		return _OutputHostReject("identity_error", Hwnd, Pid)
	}
	if (FinalIdentity["Hwnd"] != Hwnd || FinalIdentity["Pid"] != Pid) {
		if (_OUTPUT_HOST_RESOLVE_SERIAL == Serial)
			_OUTPUT_HOST_CACHE := 0
		return _OutputHostReject("focus_changed", Hwnd, Pid)
	}
	if (_OUTPUT_HOST_RESOLVE_SERIAL != Serial)
		return _OutputHostReject("superseded", Hwnd, Pid)

	_OUTPUT_HOST_CACHE := Candidate
	return _OutputHostValidReceipt(
		Hwnd, Pid, Candidate["Exe"], Candidate["Class"], Title, TitleTimedOut)
}

; Whether the application of an output-host receipt must receive a text by
; paste. Windows 11's Notepad loses characters typed as text in one burst and
; types the last one in their place: a 32-character prediction came out as its
; final « e » 32 times, and one SendInput of Unicode characters sent from
; outside the driver gave « général eeee » for « général de l’histoire
; militaire », where a classic Edit control receives them all. Slowing the
; characters to one every 10 ms still dropped some. The one rule for every
; sender: the hotstring expansions and TextSend's "auto" mode
; (llm-accept-notepad-paste).
; @param Host {Map} A receipt from OutputHostResolve.
; @return {Boolean} True for Notepad; false for any other or an unknown host.
OutputHostTakesTextByPaste(Host) {
	if !(Host is Map) || !Host.Get("Valid", false)
		return false
	return StrLower(Host.Get("Exe", "")) = "notepad.exe"
}

OutputHostResolverPrimeForTest(Exe, ClassName := "fixture") {
	global _OUTPUT_HOST_CACHE, _OUTPUT_HOST_IDENTITY_PROBE
	Identity := HasMethod(_OUTPUT_HOST_IDENTITY_PROBE, "Call")
		? _OUTPUT_HOST_IDENTITY_PROBE.Call() : _OutputHostForegroundIdentity()
	_OUTPUT_HOST_CACHE := Map("Hwnd", Identity["Hwnd"], "Pid", Identity["Pid"],
		"Exe", Exe, "Class", ClassName)
}

; Internal — the production-lean registration path used by every CreateHotstring
; / CreateCaseSensitiveHotstrings / CreateRawCallbackHotstring call. It hands the
; already-known matching flags (the ``*?C`` subset) straight to HSE_Register,
; skipping the ``:flags:B0O:abbrev`` string build AND the matching
; ``_MirrorRegistrationToHSE`` re-parse that the old per-call path incurred on
; every one of the ~3700 boot registrations.
;
; ``Rec`` is the resolved ``_HotstringRegistrar`` (0 in production). When a test
; has installed a recorder, the caller passes the assembled trigger-spec string
; and a real per-spec callback, which we forward to the recorder so the
; introspection tests (registration counts, spec strings, direct callback
; invocation) keep working byte-for-byte. In production Rec is 0, so callers pass
; "" / 0 for those two: HSE_DispatchMatch dispatches via ``Spec.Replacement`` and
; never invokes the callback, so building either would be pure boot-time waste.
_RegisterHotstringFast(Rec, HseFlags, Abbrev, TrigSpec, Callback, Meta := unset) {
		if Rec {
				Rec(TrigSpec, Callback)
		}
		if IsSet(Meta) {
				HSE_Register(HseFlags, Abbrev, Callback, Meta)
		} else {
				HSE_Register(HseFlags, Abbrev, Callback)
		}
}

; Extract just the matching-relevant flag letters (``*``, ``?``, ``C``) in
; canonical order from an AHK option string — the exact subset HSE_Register
; needs, identical to what ``_MirrorRegistrationToHSE`` recovered by re-parsing
; the assembled spec. Computing it directly at the call site is what lets the
; production path skip building and re-parsing the ``:flags:B0O:abbrev`` string.
_HseFlagSubset(Flags) {
		Out := ""
		if InStr(Flags, "*") {
				Out .= "*"
		}
		if InStr(Flags, "?") {
				Out .= "?"
		}
		if InStr(Flags, "C") {
				Out .= "C"
		}
		return Out
}

; Parse the AHK ``:flags:abbrev`` trigger spec and forward to HSE_Register.
; Flag letters that HSE understands (``*``, ``?``, ``C``) are passed
; through verbatim; the rest (``B0``, ``O`` — both irrelevant to matching)
; are dropped. Abbreviations are registered as-is so the HSE bucket
; index stays in lockstep with the upstream registration call.
_MirrorRegistrationToHSE(TriggerSpec, Callback, Meta := unset) {
		; Parse the ``:<flags>:<abbrev>`` spec with InStr rather than a per-call
		; RegExMatch: this runs once for EVERY hotstring registered at boot (~5400
		; calls), and the abbreviation was just assembled by the caller — a regex to
		; pull it back apart is pure overhead on the startup hot path. Semantics match
		; the old ``^:([^:]*):(.+)$``: flags hold no colon, the abbreviation is
		; everything after the second colon and must be non-empty.
		if (SubStr(TriggerSpec, 1, 1) != ":") {
				return
		}
		SecondColon := InStr(TriggerSpec, ":", true, 2)
		if (!SecondColon) {
				return
		}
		RawFlags := SubStr(TriggerSpec, 2, SecondColon - 2)
		Abbrev := SubStr(TriggerSpec, SecondColon + 1)
		if (Abbrev == "") {
				return
		}
		HseFlags := ""
		if InStr(RawFlags, "*") {
				HseFlags .= "*"
		}
		if InStr(RawFlags, "?") {
				HseFlags .= "?"
		}
		if InStr(RawFlags, "C") {
				HseFlags .= "C"
		}
		if IsSet(Meta) {
				HSE_Register(HseFlags, Abbrev, Callback, Meta)
		} else {
				HSE_Register(HseFlags, Abbrev, Callback)
		}
}

; Types Text the way a key of the layout does: a SendEvent at the CALLER's
; SendLevel. The layout and the keylayout emulation call it from their #InputLevel
; 2 hotkeys, where the level makes the keys visible to the prefix watcher, which
; is how a typed trigger (« ia » struck on the layout) reaches the hotstring
; engine at all. A hotstring's OWN output must not come back that way: it goes
; through Atomic=true, one SendInput at TEXT_SENDER_SEND_LEVEL, and the engine
; commits its effect to its buffers itself (hotstring-output-is-final).
; OnlyText=true wraps the payload in {Text}
; to avoid modifier side effects on symbols like ', ", accents. UpdateRing
; controls whether Text feeds the last-sent-character ring: pass false for a
; backspace-only call (e.g. the Notepad clipboard branch's pre-paste erase),
; where Text is a control sequence ("{BackSpace 5}") rather than a real
; emitted character — SubStr(Text, -1) on that sequence would record its
; trailing "}" instead of what actually landed on screen.
; @param Atomic {Boolean} True for a hotstring's own output (SendInput at the
;        TextSender level); false for a stand-in for a typed key (SendEvent).
_SendVerdictSucceeded(Result) {
		; Legacy recorder hooks return an empty string after capturing a send. Only an
		; explicit Boolean false is a failure; type-checking first prevents the AHK v2
		; `"0" = false` coercion from rejecting a string token as a failed injection.
		return !((Result is Integer) and Result = 0)
}

SendNewResult(Text, OnlyText := True, UpdateRing := True, Atomic := False) {
		; Every layout/hotstring callback reaches this primitive.  A failed OS send
		; must be contained here and must NOT advance the output ring: advancing it
		; after a failed injection corrupts deadkey/time-gated decisions as though
		; the character reached the foreground application.
		try {
				if _SendHook {
						Hook := _SendHook
						if !_SendVerdictSucceeded(Hook("SendNewResult", Text, OnlyText))
								return false
				} else if Atomic {
						_TextSenderAtSendLevel(_AHK_SendInput.Bind(OnlyText ? "{Text}" Text : Text))
				} else {
						if OnlyText {
								SendEvent("{Text}" Text)
						} else {
								SendEvent(Text)
						}
				}
		} catch as Err {
				LoggerError("Hotstrings", "SendNewResult failed: {1}", Err.Message)
				return false
		}
		; _EmitReachedScreen for the same reason the catch above returns without
		; advancing the ring: a character that never reached the application must not
		; be recorded as though it had. This is the primitive EVERY Shift/CapsLock/
		; AltGr layer emit goes through, so it is where the gate belongs — the
		; dead-key fix reached the two direct SendEvent emitters and missed this one.
		; Compose "Â" by typing the circumflex dead key then Shift+A and the ring held
		; ['A', 'Â'] for a single visible character; composition plus a Shift capital
		; is the mainline use of that dead key.
		;
		; IsSet-guarded because this primitive is also reachable from contexts where
		; the keymap module is not loaded (tools/, standalone tests), and there the
		; unqualified pre-fix behaviour is correct.
		if UpdateRing and (!IsSet(_EmitReachedScreen) or _EmitReachedScreen()) {
				UpdateLastSentCharacter(SubStr(Text, -_TextTailCodeUnits(Text, 1)))
				; The ring records the last character only; a delimiter anywhere in
				; the literal text ends CapsWord. Key syntax ("{BackSpace}", "^v")
				; is not text and says nothing about what reached the screen.
				if OnlyText and IsSet(CapsWordAutoOffObserveOutput)
						CapsWordAutoOffObserveOutput(Text)
		}
		return true
}

; SendInput prevents other hotstrings/hotkeys from activating, so this is the
; "final" result — used when we do not want cascading expansion.
_SendFinalResultUnchecked(Text, OnlyText) {
		if _SendHook {
				Hook := _SendHook
				Sent := _SendVerdictSucceeded(Hook("SendFinalResult", Text, OnlyText))
		} else {
				if OnlyText
						SendInput("{Text}" Text)
				else
						SendInput(Text)
				Sent := true
		}
		; SendInput lifts the script's own hook, so the auto-off InputHook never
		; sees this text: a checked delimiter in it ends CapsWord here.
		if Sent and OnlyText and IsSet(CapsWordAutoOffObserveOutput)
				CapsWordAutoOffObserveOutput(Text)
		return Sent
}

; @param DeclareBufferEffect {Boolean} True when Text is a caret/document edit
; invisible to the prefix InputHook. The declaration and SendInput then share the
; canonical Critical transaction instead of being two interruptible statements.
SendFinalResult(Text, OnlyText := False, DeclareBufferEffect := false) {
		try {
				if DeclareBufferEffect and IsSet(HS_RunSyntheticInputTransaction)
						return _SendVerdictSucceeded(HS_RunSyntheticInputTransaction(Text,
								_SendFinalResultUnchecked.Bind(Text, OnlyText)))
				return _SendFinalResultUnchecked(Text, OnlyText)
		} catch as Err {
				LoggerError("Hotstrings", "SendFinalResult failed: {1}", Err.Message)
				return false
		}
}

_SendInstant_RestoreClipboard(OldClip, OwnedSequence, OwnerToken) {
	; A delayed restore owns exactly the payload sequence it wrote. The adapter
	; retains both snapshot and owner if Windows temporarily locks the clipboard.
	return CB_RestoreOwnedAllEventually(OldClip, OwnedSequence, OwnerToken,
		"hotstring_send_instant")
}

; SendInput lifts the script's own hook and a paste types nothing at all, so
; the auto-off InputHook never sees what SendInstant puts on screen: a checked
; delimiter in it ends CapsWord here, once the injection succeeded.
_SendInstantReport(Text) {
	if IsSet(CapsWordAutoOffObserveOutput)
		CapsWordAutoOffObserveOutput(Text)
}

SendInstant(Text, Prefix := "") {
	; Sends a large text through the clipboard while keeping Prefix (typically the
	; hotstring erase sequence) in the SAME SendInput burst as Ctrl+V. Splitting
	; these two injections lets a physical key land between erase and paste.
	; Uses try so the user's clipboard is restored even on error/crash.
	if _SendHook {
		try {
			Hook := _SendHook
			Sent := _SendVerdictSucceeded(Hook("SendInstant", Text, Prefix))
			if Sent
				_SendInstantReport(Text)
			return Sent
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant hook failed: {1}", Err.Message)
			return false
		}
	}
	; Reentrancy guard: a previous SendInstant's deferred restore has not run
	; yet, so the clipboard still holds its payload. Touching A_Clipboard now
	; would race the in-flight paste/restore — fall back to the clipboard-free
	; {Text} route so the two dances never interleave.
	; SendInput (not SendEvent) is used here to stay atomic and avoid interleaving
	; with the InputHook, which processes SendEvent characters as physical input.
	OwnerToken := CB_TryBeginPasteTransaction("hotstring_send_instant")
	if !OwnerToken {
		try LoggerDebug("Hotstrings", "SendInstant: a restore is still in flight; routing through the clipboard-free path.")
		try {
			SendInput(Prefix . "{Text}" . Text)
			_SendInstantReport(Text)
			return true
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant clipboard-free injection failed: {1}", Err.Message)
			return false
		}
	}
	; The Notepad caller holds Critical across this whole call, so anything slow
	; here starves the keyboard hook rather than merely delaying one expansion.
	; CB_SaveAll snapshots EVERY format, and A_Clipboard retries for
	; #ClipboardTimeout — a full second by default — when another process holds
	; the clipboard open. A remote-desktop client, a clipboard manager or a
	; freshly captured full-screen bitmap can therefore freeze the thread for
	; ~1-2 s. Route those cases through the clipboard-free path instead: it
	; renders slightly worse in Notepad, which is precisely the trade the
	; reentrancy branch above already accepts.
	if (CB_IsBusy() or CB_HasImage()) {
		CB_EndOwnedTransaction(OwnerToken)
		try LoggerDebug("Hotstrings", "SendInstant: clipboard is contended or holds a bitmap; routing through the clipboard-free path.")
		try {
			SendInput(Prefix . "{Text}" . Text)
			_SendInstantReport(Text)
			return true
		} catch as Err {
			try LoggerError("Hotstrings", "SendInstant clipboard-free injection failed: {1}", Err.Message)
			return false
		}
	}
	OldClipboard := CB_SaveAll()
	if (Type(OldClipboard) == "String" && OldClipboard == "__CB_SAVE_ERROR__") {
		CB_EndOwnedTransaction(OwnerToken)
		try LoggerWarn("Hotstrings", "SendInstant: clipboard snapshot failed; expansion was not injected.")
		return false
	}
	RestoreCallback := false
	RestoreTimerArmed := false
	try {
		if !CB_WriteTextWithReceipt(Text, &OwnedSequence)
			throw Error("clipboard write failed")
		if !OwnedSequence
			throw Error("clipboard sequence unavailable")
		; Arm every fallible post-paste stage before the irreversible injection. If
		; timer registration fails, no erase/paste has reached the application and
		; the caller can safely leave its engine and preview state untouched.
		RestoreCallback := _SendInstant_RestoreClipboard.Bind(OldClipboard, OwnedSequence, OwnerToken)
		SetTimer(RestoreCallback, -SEND_INSTANT_PASTE_DELAY_MS)
		RestoreTimerArmed := true
		; Prefix and Ctrl+V are one kernel injection transaction. Critical callers
		; therefore cannot be interrupted after the erase but before the paste.
		SendInput(Prefix . "^v")
		_SendInstantReport(Text)
		return true
	} catch as err {
		; SendInput can fail after the restore timer was armed. Cancel that exact
		; callback before doing the cleanup inline so ownership is ended once.
		if RestoreTimerArmed
			try SetTimer(RestoreCallback, 0)
		if IsSet(OwnedSequence) && OwnedSequence {
			try CB_RestoreOwnedAllEventually(OldClipboard, OwnedSequence, OwnerToken,
				"hotstring_send_instant_rollback")
		} else {
			CB_EndOwnedTransaction(OwnerToken)
		}
		try LoggerError("Hotstrings", "SendInstant: clipboard injection failed: {1}", err.Message)
		return false
	}
}

; Mirror a literal edit which this module has already proven reached the screen.
; Synthetic sends below the prefix watcher's I1 level never reach its OnChar, so
; callers must publish the same edit to the longer LLM context themselves. Keep
; this helper free of prediction side effects when the bridge is inactive (only
; the AI agent's own context follows the edit then) and require the owner to
; hold the same Critical transaction as the matching HSE mutation.
_HSE_MirrorLiteralEditToLlm(DeleteFromEnd, InsertedText := "") {
		if !A_IsCritical
				throw Error("_HSE_MirrorLiteralEditToLlm requires a Critical buffer transaction.")
		if (IsSet(_LLM_Bridge_Active) and _LLM_Bridge_Active
				and IsSet(_LLM_Bridge_ApplyBufferEdit))
				_LLM_Bridge_ApplyBufferEdit(DeleteFromEnd, InsertedText)
		else if IsSet(LLM_Bridge_MirrorAgentEdit)
				LLM_Bridge_MirrorAgentEdit(DeleteFromEnd, InsertedText)
}

; Commit any pending end-char hotstring before the next symbol is emitted.
; The temporary space is first put on screen so an end-char-gated trigger can
; claim it. A successful dispatch is forced to consume that space; only a
; declined/no-match attempt needs the compensating backspace.
;
; The commit itself is NOT a hook round-trip any more. It used to be: the space
; was injected at the caller's send level, the prefix-watcher InputHook observed
; it, and _OnPrefixChar fired the trigger. That design needs the message loop to
; run BETWEEN the two sends — and every caller reaches this function from a
; serialized layer hotkey that holds Critical across both the poke AND the
; following NNBSP+punctuation emit, so no InputHook callback can be delivered
; until all of it has already landed. The queued OnChar(' ') then fired the
; expansion at a caret that had moved past the punctuation, destroying the
; character the user typed, and HSE_ApplyExpansion mirrored the same wrong edit
; into HSE_Buffer so nothing could detect the corruption. Making the poke atomic
; did not break the round-trip — it proved the round-trip was never possible.
;
; So the engine is fed DIRECTLY, and the poke is emitted BELOW the watcher's
; input level so it is not re-ingested as a phantom keystroke on top of that.
; The space is still really sent: it has to be on screen for the expansion's own
; backspace count to be right.
;
; The whole dance is gated on there actually being a pending abbreviation. When
; HSE_Buffer is empty (the common case — punctuation typed at a word boundary or
; after a space) there is nothing to commit, so the pair is skipped entirely on
; a hot, default key set. IsSet guards the load order: the engine buffer global
; lives in hotstring_engine_main.ahk, included alongside this file.
ActivateHotstrings() {
		global HSE_LastEndChar, _PrefixPrivateResidue
		; Nothing to flush — no pending abbreviation, so skip the costly poke.
		if (IsSet(HSE_Buffer) and HSE_Buffer == "") {
				return true
		}
		previous_critical := Critical("On")
		PreviousSendLevel := A_SendLevel
		try {
				; The prefix watcher's InputHook is armed "V L0 I1", so level 0 is below
				; what it accepts: the poke lands on screen without ever coming back as
				; an OnChar the engine would count twice.
				SendLevel(0)
				; The poke is temporary and is therefore not ring history. A successful
				; fire lets the dispatcher record its real final output; a failed cleanup
				; below records the Space only once it becomes permanent.
				if !SendNewResult(" ", true, false)
						return false
				; IsPhysical=true on both feeds: the dispatch below holds HSE_Suppressed
				; for its own send burst (released on a deferred timer), and a
				; non-physical feed is a no-op while it is up.
				PendingMatch := HSE_FeedChar(" ", true)
				_HSE_MirrorLiteralEditToLlm(0, " ")
				Fired := false
				if (PendingMatch != "") {
						; Contained: this runs inside a layer callback that still owes the
						; user its punctuation, so a throwing expansion must not abort the
						; emit that follows.
						try {
								CommittedScreenEffect := 0
								Fired := HSE_DispatchMatch(PendingMatch, HSE_LastEndChar,
										&CommittedScreenEffect, true)
								if (Fired is Map) && Fired.Has("Pending")
										return true
								; Same metrics contract the prefix-watcher fire path follows:
								; only a real expansion is a fire, and the record is queued
								; rather than logged inline so no disk work lands on the
								; keyboard thread.
								if Fired {
										FiredReplacement := PendingMatch.HasOwnProp("Replacement") ? PendingMatch.Replacement : PendingMatch.Trigger
										FiredCategory := PendingMatch.HasOwnProp("Category") ? PendingMatch.Category : ""
										FiredSection := PendingMatch.HasOwnProp("Section") ? PendingMatch.Section : ""
										; Third of the three fire paths, reaching the same sink —
										; the privacy flag has to travel here too, or a personal
										; expansion committed by a punctuation key leaks while the
										; other two paths are clean.
										FiredIsPrivate := PendingMatch.HasOwnProp("IsPrivate") && PendingMatch.IsPrivate
										if FiredIsPrivate and IsSet(_PrefixPrivateResidue)
												_PrefixPrivateResidue := true
										if IsSet(_PrefixCommitPostFireEffect)
												_PrefixCommitPostFireEffect(CommittedScreenEffect)
										if IsSet(_HSE_QueueFireLog)
												try _HSE_QueueFireLog(PendingMatch.Trigger, FiredReplacement, "endchar", FiredCategory, FiredSection, FiredIsPrivate)
								}
						} catch as CommitErr {
								; ERROR is severity 40 — ABOVE the default INFO level — so unlike the
								; DEBUG sites this line reaches the rotating log with no user action
								; at all. The flag is read here rather than reused from the `if Fired`
								; block above because this catch runs on the path where the dispatch
								; THREW: Fired was never assigned, so that block never executed.
								CommitIsPrivate := PendingMatch.HasOwnProp("IsPrivate") && PendingMatch.IsPrivate
								try LoggerError("Hotstrings", "ActivateHotstrings: committing '{1}' failed: {2}",
										CommitIsPrivate ? PersonalInfoRedactForLog(PendingMatch.Trigger) : PendingMatch.Trigger,
										CommitErr.Message)
						}
				}
				; A successful forced commit consumed the temporary Space as part of its
				; canonical edit. Backspacing here would erase the replacement's last
				; character, especially when Space is also a configured consumed delimiter.
				if Fired
						return true
				if !SendNewResult("{BackSpace}", False, false) {
						; Cleanup failed, so the poke is now real screen state. Preserve the
						; already-appended HSE/LLM Space and publish it to the output ring.
						if IsSet(_ResetPrefixBuffer)
								try _ResetPrefixBuffer()
						UpdateLastSentCharacter(" ")
						return false
				}
				HSE_FeedBackspace(true)
				_HSE_MirrorLiteralEditToLlm(1)
				return true
		} finally {
				SendLevel(PreviousSendLevel)
				Critical(previous_critical)
		}
}

; Clipboard copy completion is asynchronous in many applications. Waiting in a
; hotkey thread with ClipWait freezes every low-level hook dispatch behind it.
; Keep one owned capture job and poll with a zero-timeout probe instead; callers
; receive the text only while the original foreground context is still current.
; "A newer user action" is a newer physical key-down, mouse-down or wheel: the
; KS_GetPhysicalInputGeneration ticket. A_TimeIdlePhysical also moves for the
; key-ups that finish the initiating chord (releasing S, then Win, of Win+S),
; so a capture judged by it cancelled itself whenever the copy took longer than
; the user's key release (copy_selected_path then did nothing at all).
global _SelectionCaptureJob := false
global _SelectionCaptureNextId := 0
global SELECTION_CAPTURE_POLL_MS := 15

GetSelectionAsync(OnReady, Ports := 0) {
		global _SelectionCaptureJob, _SelectionCaptureNextId
		global SELECTION_CAPTURE_POLL_MS

		if A_IsSuspended
				return false
		if !IsObject(OnReady)
				throw TypeError("GetSelectionAsync requires a callback object")
		CaptureId := ++_SelectionCaptureNextId

		; The newest user command owns the clipboard capture. Finishing the prior
		; job first stops its timer and restores its clipboard snapshot before the
		; new Ctrl+C clears the clipboard.
		if IsObject(_SelectionCaptureJob) {
				; A native snapshot or clear may still be on the interrupted stack.
				; Its owner must unwind before another request can take a snapshot.
				if _SelectionCaptureJob.Get("starting", false)
						return false
				_SelectionCaptureFinish(_SelectionCaptureJob, "", false, "superseded")
		}
		if A_IsSuspended or _SelectionCaptureNextId != CaptureId
				return false
		if !(Ports is Map)
				Ports := Map()
		SaveFn := Ports.Get("save", CB_SaveAll)
		ClearFn := Ports.Get("clear", CB_Write.Bind(""))
		SendFn := Ports.Get("send", _SelectionSendCopy)
		SequenceFn := Ports.Get("sequence", _SelectionClipboardSequence)
		RestoreFn := Ports.Get("restore", CB_RestoreAll)
		ForegroundFn := Ports.Get("foreground", _SelectionCaptureForeground)
		GenerationFn := Ports.Get("physical_generation", KS_GetPhysicalInputGeneration)
		BusyFn := Ports.Get("report_busy", _SelectionReportClipboardBusy)

		; The dispatcher has already counted the key-down which started this
		; action (InputHook callbacks run before the hotkey thread), so only a
		; later physical action can advance the generation captured here.
		Job := Map(
				"id", CaptureId,
				"callback", OnReady,
				"started", A_TickCount,
				"physical_generation", GenerationFn.Call(),
				"generation_fn", GenerationFn,
				"foreground", 0,
				"clipboard", "",
				"clear_sequence", 0,
				"owned_sequence", 0,
				"owner_token", 0,
				"expected_change", 0,
				"timer", 0,
				"starting", true,
				"mutated", false
		)
		PreviousCritical := Critical("On")
		try {
				if _SelectionCaptureNextId != Job["id"] or IsObject(_SelectionCaptureJob)
						return false
				_SelectionCaptureJob := Job
		} finally Critical(PreviousCritical)
		Started := false
		try {
				Job["foreground"] := ForegroundFn.Call()
				if !_SelectionCaptureStartCurrent(Job)
						return false
				Job["owner_token"] := CB_TryBeginOwnedTransaction("selection_capture")
				if !Job["owner_token"]
						throw Error("clipboard transaction busy")
				if !_SelectionCaptureStartCurrent(Job)
						return false
				Job["clipboard"] := SaveFn.Call()
				; Another program holding the clipboard past ClipboardAll's own
				; one-second wait is an external condition, not a driver fault:
				; name the holder to the user instead of opening the error window.
				if (Type(Job["clipboard"]) == "String"
						and Job["clipboard"] == "__CB_SAVE_ERROR__") {
						BusyFn.Call()
						return false
				}
				if !_SelectionCaptureStartCurrent(Job)
						return false
				if !ClearFn.Call()
						throw Error("clipboard clear failed")
				Job["mutated"] := true
				Job["clear_sequence"] := SequenceFn.Call()
				Job["owned_sequence"] := Job["clear_sequence"]
				if !_SelectionCaptureStartCurrent(Job)
						return false
				Job["expected_change"] := CB_ExpectOwnedChange()
				SendFn.Call()
				if !_SelectionCaptureStartCurrent(Job)
						return false
				Job["timer"] := _SelectionCapturePoll.Bind(Job)
				SetTimer(Job["timer"], SELECTION_CAPTURE_POLL_MS)
				if !_SelectionCaptureStartCurrent(Job)
						return false
				Started := true
				return true
		} catch as Err {
				try LoggerError("hotstring_engine", "GetSelectionAsync could not start: {1}", Err.Message)
				return false
		} finally {
				Job["starting"] := false
				if !Started
						_SelectionCaptureAbortStart(Job, RestoreFn, SequenceFn)
		}
}

_SelectionCaptureForeground() {
		return WinExist("A")
}

; The copy chord is driver output, not a stand-in for a physical key, so it goes
; out at TEXT_SENDER_SEND_LEVEL. From the #InputLevel 2 Win broker it used to
; be sent at level 2, where the driver's own "I1" InputHooks took it for the
; user's typing: the keystats recorded a "Win+C", and the physical-input
; generation this capture is judged by advanced on its own Ctrl+C.
_SelectionSendCopy(SendFn := SendEvent.Bind("^c")) {
		_TextSenderAtSendLevel(SendFn)
}

; Tells the user which program holds the clipboard when the snapshot that must
; precede Ctrl+C failed, and logs the same holder evidence.
_SelectionReportClipboardBusy() {
		Holder := CB_DescribeClipboardHolder()
		try LoggerWarn("hotstring_engine",
				"GetSelectionAsync could not snapshot the clipboard; the selection was not read (holder: {1}).",
				Holder["summary"])
		Message := Holder["process"] != ""
				? StrReplace(t("selection.clipboard_busy"), "%s", Holder["process"])
				: t("selection.clipboard_busy_unknown")
		try TrayTip(Message, t("notify.clipboard"), "Iconx Mute")
		catch as Err {
				try LoggerError("hotstring_engine", "The busy-clipboard notice could not be shown: {1}.", Err.Message)
		}
}

; Names the new foreground window's process for a "foreground changed" log.
_SelectionForegroundProcess() {
		try return WinGetProcessName("A")
		catch as Err
				return "unavailable (" . Err.Message . ")"
}

_SelectionCaptureStartCurrent(Job) {
		global _SelectionCaptureJob, _SelectionCaptureNextId
		return !A_IsSuspended and _SelectionCaptureJob == Job
				and _SelectionCaptureNextId == Job["id"]
}

; Startup cancellation only revokes admission while the OS call is in flight.
; Its initiating stack retires the exact snapshot and owner after that call.
_SelectionCaptureAbortStart(Job, RestoreFn, SequenceFn) {
		global _SelectionCaptureJob
		if _SelectionCaptureJob == Job
				_SelectionCaptureJob := false
		_SelectionCaptureReleaseTimer(Job)
		if Job["expected_change"]
				CB_CancelExpectedChange(Job["expected_change"])
		if Job["owner_token"] {
				if Job["mutated"] {
						CB_RestoreOwnedAllEventually(Job["clipboard"],
								Job["clear_sequence"], Job["owner_token"],
								"selection_capture_rollback", true, true, RestoreFn, SequenceFn)
				} else {
						CB_EndOwnedTransaction(Job["owner_token"])
				}
		}
		Job["clipboard"] := ""
}

; Cancelling the native timer does not break Map -> BoundFunc -> Map ownership.
; Clear the job's callback reference only after the exact timer is cancelled.
_SelectionCaptureReleaseTimer(Job) {
		Timer := Job["timer"]
		if IsObject(Timer)
				SetTimer(Timer, 0)
		Job["timer"] := 0
}

_SelectionCapturePoll(Job) {
		global _SelectionCaptureJob, GET_SELECTION_TIMEOUT_SEC

		if !IsObject(_SelectionCaptureJob) || _SelectionCaptureJob["id"] != Job["id"]
				return
		Elapsed := TickElapsed(Job["started"])
		if A_IsSuspended {
				_SelectionCaptureFinish(Job, "", false, "suspended")
				return
		}
		; If a new physical action happened after the shortcut, never inject into
		; its potentially different selection. Releasing the initiating chord is
		; not a new action and leaves the generation unchanged.
		if (Job["generation_fn"].Call() != Job["physical_generation"]) {
				_SelectionCaptureFinish(Job, "", false, "superseded by input")
				return
		}
		if (WinExist("A") != Job["foreground"]) {
				_SelectionCaptureFinish(Job, "", false, "foreground changed")
				return
		}
		; Zero timeout is a probe, never a blocking wait. Accept every clipboard
		; format so an image selection resolves immediately to an empty text result.
		if ClipWait(0, 1) {
				_SelectionCaptureReadReady(Job)
				return
		}
		if (Elapsed >= Round(GET_SELECTION_TIMEOUT_SEC * 1000)) {
				try LoggerWarn("hotstring_engine",
						"GetSelectionAsync timed out after {1}s; returning no selection.",
						GET_SELECTION_TIMEOUT_SEC)
				_SelectionCaptureFinish(Job, "", false, "timeout")
		}
}

; Admit the sequence of a ready copy before its potentially blocking text
; read. A later cancellation or external copy cannot rename the clipboard's
; new contents as this job's own mutation. Zero never replaces proven ownership.
_SelectionCaptureReadReady(Job, ReadFn := 0, SequenceFn := 0,
		RestoreFn := 0, ContextFn := 0) {
		global _SelectionCaptureJob, _SelectionCaptureNextId
		if !_SelectionCaptureStartCurrent(Job)
				return false
		if !IsObject(SequenceFn)
				SequenceFn := _SelectionClipboardSequence
		if !IsObject(ReadFn)
				ReadFn := () => A_Clipboard
		Sequence := _SelectionCaptureProbeSequence(SequenceFn)
		if !_SelectionCaptureStartCurrent(Job)
				return false
		if !Sequence {
				try LoggerWarn("hotstring_engine", "Selection read refused: clipboard ownership is unavailable.")
				if !_SelectionCaptureStartCurrent(Job)
						return false
				_SelectionCaptureFinish(Job, "", false, "clipboard sequence unavailable", RestoreFn, SequenceFn, ContextFn)
				return true
		}
		Job["owned_sequence"] := Sequence
		try Text := ReadFn.Call()
		catch as Err {
				try LoggerWarn("hotstring_engine", "Selection clipboard read failed: {1}.", Err.Message)
				; A failed getter must not retain its repeating timer forever.
				; Cleanup is permitted while paused, but never for a replaced job.
				if _SelectionCaptureJob != Job or _SelectionCaptureNextId != Job["id"]
						return false
				_SelectionCaptureFinish(Job, "", false, "clipboard read failed", RestoreFn, SequenceFn, ContextFn)
				return true
		}
		if !_SelectionCaptureStartCurrent(Job)
				return false
		VerifiedSequence := _SelectionCaptureProbeSequence(SequenceFn)
		if !_SelectionCaptureStartCurrent(Job)
				return false
		Deliver := VerifiedSequence && VerifiedSequence == Sequence
		if !Deliver {
				try LoggerWarn("hotstring_engine", "Selection read refused: clipboard ownership changed or became unavailable while reading.")
				if !_SelectionCaptureStartCurrent(Job)
						return false
		}
		_SelectionCaptureFinish(Job, Deliver ? Text : "", Deliver,
				Deliver ? "ready" : "clipboard changed during read", RestoreFn, SequenceFn, ContextFn)
		return true
}

_SelectionCaptureProbeSequence(SequenceFn) {
		try return SequenceFn.Call()
		catch as Err {
				try LoggerWarn("hotstring_engine", "Selection ownership probe failed: {1}.", Err.Message)
				return 0
		}
}

_SelectionCaptureFinish(Job, Text, Deliver, Reason, RestoreFn := 0,
		SequenceFn := 0, ContextFn := 0) {
		global _SelectionCaptureJob, _SelectionCaptureNextId

		if !IsObject(_SelectionCaptureJob) || _SelectionCaptureJob["id"] != Job["id"]
				return
		_SelectionCaptureReleaseTimer(Job)
		_SelectionCaptureJob := false
		Job["end_reason"] := Reason
		; A user action that ends without its selection must say why: these
		; endings used to be silent, so a shortcut that "does nothing" left no
		; trace. A timeout already logged its own warning.
		if (!Deliver and Reason != "timeout")
				try LoggerInfo("hotstring_engine",
						"Selection capture ended without a selection: {1} (foreground: {2}).",
						Reason, _SelectionForegroundProcess())

		; Restore only the clear or received-copy sequence this job admitted.
		; Sampling current contents here would authorize overwriting a newer
		; copy on cancellation, or one published during the text read above.
		if !IsObject(SequenceFn)
				SequenceFn := _SelectionClipboardSequence
		if Job["expected_change"]
				CB_CancelExpectedChange(Job["expected_change"])
		OwnedSequence := Job["owned_sequence"]
		if !CB_RestoreOwnedAllEventually(Job["clipboard"], OwnedSequence,
				Job["owner_token"], "selection_capture_" . Reason, true,
				!OwnedSequence, RestoreFn, SequenceFn)
				try LoggerError("hotstring_engine", "GetSelectionAsync clipboard restore failed ({1}).", Reason)
		Job["clipboard"] := ""

		if !Deliver || A_IsSuspended
				return
		; Restoring ClipboardAll can yield after the job was retired. Reacquire
		; its input context, then fence revocations which happened during either
		; the restore or the context probe before invoking the continuation.
		Context := IsObject(ContextFn) ? ContextFn.Call(Job)
				: _SelectionCaptureCurrentContext(Job)
		if (Context["foreground"] != Job["foreground"]) {
				try LoggerInfo("hotstring_engine",
						"Selection read but not delivered: the foreground changed to {1}.",
						_SelectionForegroundProcess())
				return
		}
		if (Context["physical_generation"] != Job["physical_generation"]) {
				try LoggerInfo("hotstring_engine",
						"Selection read but not delivered: a newer physical action superseded it.")
				return
		}
		if A_IsSuspended or _SelectionCaptureNextId != Job["id"]
				return
		try Job["callback"].Call(Text)
		catch as Err {
				try LoggerError("hotstring_engine", "GetSelectionAsync callback failed: {1}", Err.Message)
		}
}

; Kept as a fail-closed compatibility seam. All user-triggered paths must use
; GetSelectionAsync; a synchronous clipboard wait on the hook thread is unsafe.
GetSelection() {
		try LoggerError("hotstring_engine", "GetSelection() is synchronous-only and must not be used on an input path.")
		return ""
}

GetSelectionCancel(*) {
		global _SelectionCaptureJob, _SelectionCaptureNextId
		; A completion has already retired its job while restoring the clipboard.
		; Revoke that continuation even when there is no timer left to cancel.
		_SelectionCaptureNextId += 1
		if IsObject(_SelectionCaptureJob) and !_SelectionCaptureJob.Get("starting", false)
				_SelectionCaptureFinish(_SelectionCaptureJob, "", false, "cancelled")
}

_SelectionCaptureCurrentContext(Job) {
		return Map("foreground", WinExist("A"),
				"physical_generation", Job["generation_fn"].Call())
}

_SelectionClipboardSequence() {
		try return DllCall("GetClipboardSequenceNumber", "uint")
		catch as Err {
				try LoggerError("hotstring_engine", "GetClipboardSequenceNumber failed: {1}", Err.Message)
				return 0
		}
}

; Set of Microsoft Office (and Teams) executable names.
global MICROSOFT_OFFICE_EXES := Map(
	"Teams.exe", true,
	"ms-teams.exe", true,
	"ONENOTE.exe", true,
	"olk.exe", true,
	"OUTLOOK.EXE", true,
	"WINWORD.EXE", true,
	"EXCEL.EXE", true,
	"POWERPNT.EXE", true,
)

MicrosoftApps() {
		try {
				Host := OutputHostResolve()
				return Host["Valid"] && MICROSOFT_OFFICE_EXES.Has(Host["Exe"])
		}
		return false
}





; ==================================================
; ==================================================
; ======= 2/ Last-sent-character ring buffer =======
; ==================================================
; ==================================================

; Fixed-capacity ring of the last N characters emitted by the driver, used by
; hotstrings / rolls / deadkeys to peek at what the user just typed without
; calling back into Win32. The ring avoids the O(n) ``RemoveAt(1)`` memmove
; the previous Array-based implementation performed on every keystroke.
;
; Indexing contract (unchanged for callers of ``GetLastSentCharacterAt``):
;   - Negative offset -k returns the k-th character from the NEWEST
;     (offset -1 = just-pushed char, offset -2 = the one before, …).
;   - Positive offset +k returns the k-th character from the OLDEST
;     still in the buffer (offset +1 = oldest).
;   - Any offset beyond the current fill count returns "".
global _LSC_CAP := 5
global _LSC_RING := ["", "", "", "", ""]
global _LSC_CURSOR := 0  ; 1-based index of the most recently written slot
global _LSC_LEN := 0     ; number of populated slots, saturates at _LSC_CAP

; Push a new character; O(1), no reallocation after boot.
_LSCPush(Char) {
		global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
		_LSC_CURSOR := Mod(_LSC_CURSOR, _LSC_CAP) + 1
		_LSC_RING[_LSC_CURSOR] := Char
		if _LSC_LEN < _LSC_CAP {
				_LSC_LEN += 1
		}
}

; Reset the ring to a known sequence (oldest-first). Kept as a thin wrapper
; so tests can seed state without reaching into globals.
_LSCResetFrom(Chars) {
		global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
		_LSC_RING := []
		loop _LSC_CAP {
				_LSC_RING.Push("")
		}
		_LSC_CURSOR := 0
		_LSC_LEN := 0
		for c in Chars {
				_LSCPush(c)
		}
}





; =================================================
; =================================================
; ======= 3/ Last-sent-character timestamps =======
; =================================================
; =================================================

; Single write path for LastSentCharacterKeyTime, the origin of every
; time-activation gate (_HSE_PrepareDispatchDecision, IsTimeActivationExpired).
; It lives with the engine rather than with the layout emulation because two
; callers feed it: the emulation stamps what it types (UpdateLastSentCharacter),
; and the prefix watcher stamps every character it observes, so a key typed
; through the OS layout is timed too (hotstring-preview-shows). Pruning keeps
; the map size bounded across a long session.
; @param Character {String} The character that reached the screen.
; @param NowTick {Integer|unset} One observed tick shared by a physical chunk.
AppState_TouchLastSentKey(Character, NowTick := unset) {
		global LastSentCharacterKeyTime, LastSentCharacterKeyComplex
		global LAST_SENT_KEY_TIME_MAX_AGE_MS, LAST_SENT_KEY_TIME_PRUNE_AT
		if !IsSet(NowTick)
				NowTick := A_TickCount
		LastSentCharacterKeyTime[Character] := NowTick
		; Whether Shift, Alt or AltGr was held for this keystroke: the expansion
		; delay widens for a complex reference key (HSE_ComplexDelayMultiplier).
		LastSentCharacterKeyComplex[Character] := HSE_KeyIsComplex()
		if LastSentCharacterKeyTime.Count > LAST_SENT_KEY_TIME_PRUNE_AT {
				Now := NowTick
				for k, ts in LastSentCharacterKeyTime.Clone() {
						if TickExpired(ts, LAST_SENT_KEY_TIME_MAX_AGE_MS, Now) {
								LastSentCharacterKeyTime.Delete(k)
								if LastSentCharacterKeyComplex.Has(k)
										LastSentCharacterKeyComplex.Delete(k)
						}
				}
		}
}

; Complexity of each character's last keystroke, keyed like LastSentCharacterKeyTime.
global LastSentCharacterKeyComplex := Map()

; Test seam: "" reads the keyboard, true / false forces the answer.
global HSE_ComplexKeyOverride := ""

; Whether the keystroke happening now is complex: Shift, Alt or AltGr is held.
; On Windows AltGr is the right Alt (with a left Ctrl), so the physical state of
; Shift, left Alt and right Alt covers the macOS Shift/Alt flags and the Linux
; shift/alt/altgr roles.
; @returns {Boolean}
HSE_KeyIsComplex() {
		global HSE_ComplexKeyOverride
		if (HSE_ComplexKeyOverride != "")
				return HSE_ComplexKeyOverride ? true : false
		return GetKeyState("Shift", "P") or GetKeyState("LAlt", "P") or GetKeyState("RAlt", "P")
}

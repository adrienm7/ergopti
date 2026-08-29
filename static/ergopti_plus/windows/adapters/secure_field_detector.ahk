; adapters/secure_field_detector.ahk

; ==============================================================================
; MODULE: SecureFieldDetector Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the SecureFieldDetector port contract. Detects
; whether the currently focused control is a password/secure input field by
; inspecting the ES_PASSWORD window style (0x20), and whether the active
; application belongs to a hardcoded list of known password-manager processes.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   isSecureField() → SFD_IsSecureField()
;   isSecureApp()   → SFD_IsSecureApp(AppId)
;   refresh()       → SFD_Refresh()
;
; FAIL-SAFE:
; All AHK control-inspection calls are wrapped in try/catch. A detector failure
; is treated as secure while privacy protection is enabled: sending unknown
; focused-field content to an LLM is irreversible, whereas one delayed
; prediction is recoverable. UIA confirmation runs in a disposable worker and
; negative verdicts are cached only for an exact focus generation and UIA
; RuntimeId, never merely for a host HWND or on the character hook.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Known password-manager process names — expansion welcome, never shrink.
global SFD_SECURE_APPS := Map(
	"1Password.exe",        true,
	"KeePass.exe",          true,
	"KeePassXC.exe",        true,
	"Bitwarden.exe",        true,
	"LastPass.exe",         true,
	"Dashlane.exe",         true,
	"RoboForm.exe",         true,
	"Authy.exe",            true,
	"keepass2.exe",         true,
	"credential_guard",     true
)

; One exact-focus triage cache. ``pending_hwnd`` and ``pending_generation``
; prevent repeated calls while typing in one unknown browser/Electron control
; from queuing UIA work per key.
global SFD_FIELD_CACHE := Map(
	"hwnd", 0,
	"secure", true,
	"at", 0,
	"element_id", "",
	"focus_generation", 1,
	"verdict_generation", 0,
	"current_element_id", "",
	"focus_hook", 0,
	"focus_callback", 0,
	"focus_tracking_active", false,
	"pending_hwnd", 0,
	"pending_generation", 0
)
global SFD_FIELD_CACHE_TTL_MS := 1000

; Physical idle required before the deferred UIA probe may start its
; cross-process COM round-trip. Deliberately this adapter's own constant rather
; than a reference to TOOLTIP_UIA_IDLE_REQUIRED_MS or
; UIA_SELECTION_IDLE_REQUIRED_MS: each probe site answers a different question
; on a different cadence, and the two existing ones already differ (200 vs 250).
global SFD_UIA_IDLE_REQUIRED_MS := 250

; How long one unanswered probe silences further probes against that process.
; A UIA-hostile app otherwise re-pays a full timeout on every TTL expiry, i.e.
; roughly once a second, on the thread that also dispatches keystrokes.
global SFD_UIA_HOSTILE_TTL_MS := 30000

; Process name => wrap-safe {Tick, DurationMs} interval during which probes are skipped.
; Entries expire, so the map cannot grow without bound across a long session.
global SFD_UIA_HOSTILE_CACHE := Map()
global SFD_UIA_REQUEST_FN := 0
global SFD_UIA_START_FN := 0
global SFD_UIA_CONTEXT_MATCH_FN := 0





; ====================================
; ====================================
; ======= 2/ Adapter Functions =======
; ====================================
; ====================================

; Returns true if the focused control is secure OR cannot yet be classified.
; The cheap native path is synchronous; an inconclusive browser/Electron/WPF
; control is denied once and confirmed with UIA on a deferred callback.
SFD_IsSecureField() {
	Hwnd := SFD_FocusedHwnd()
	if !Hwnd
		return true
	SFD_EnsureFocusTracking()
	Focus := SFD_FocusSnapshot()
	CachedSecure := true
	if SFD_TryGetCachedVerdict(Hwnd, Focus.Generation, Focus.ElementId,
			&CachedSecure)
		return CachedSecure

	Conclusive := false
	Secure := SFD_DetectNative(Hwnd, &Conclusive)
	if !Conclusive {
		; Unknown is fail-closed until the asynchronous UIA probe establishes a
		; normal field. This protects browser password boxes and UAC-restricted UI.
		Secure := true
		SFD_ScheduleUiaProbe(Hwnd, Focus.Generation)
	}
	SFD_CommitFieldVerdict(Hwnd, Secure, Focus.Generation,
		Conclusive ? "hwnd:" . Hwnd : "")
	return Secure
}

; Binds the higher-level disposable worker at the composition root. The adapter
; stays independently testable and never reaches upward into a domain module.
SFD_ConfigureUiaWorker(RequestFn, StartFn, ContextMatchFn) {
	global SFD_UIA_REQUEST_FN, SFD_UIA_START_FN, SFD_UIA_CONTEXT_MATCH_FN
	if !IsObject(RequestFn) || !IsObject(StartFn) || !IsObject(ContextMatchFn)
		throw TypeError("Secure-field UIA worker ports must be callable objects.")
	if IsObject(SFD_UIA_REQUEST_FN) || IsObject(SFD_UIA_START_FN)
			or IsObject(SFD_UIA_CONTEXT_MATCH_FN)
		throw Error("Secure-field UIA worker ports are already configured.")
	SFD_UIA_REQUEST_FN := RequestFn
	SFD_UIA_START_FN := StartFn
	SFD_UIA_CONTEXT_MATCH_FN := ContextMatchFn
	return true
}

; Returns a cached verdict only when it belongs to the exact focused element.
; Positive verdicts may be conservatively reused for the same HWND, but a
; negative verdict requires both a live focus invalidator and the UIA RuntimeId
; that produced it. Unknown always leaves Secure=true.
SFD_TryGetCachedVerdict(Hwnd, FocusGeneration, ElementId, &Secure) {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
	Secure := true
	if (SFD_FIELD_CACHE["hwnd"] != Hwnd
			or ((A_TickCount - SFD_FIELD_CACHE["at"]) & 0xFFFFFFFF)
				>= SFD_FIELD_CACHE_TTL_MS)
		return false
	if SFD_FIELD_CACHE["secure"] {
		Secure := true
		return true
	}
	if (!SFD_FIELD_CACHE["focus_tracking_active"]
			or SFD_FIELD_CACHE["verdict_generation"] != FocusGeneration
			or ElementId == ""
			or SFD_FIELD_CACHE["element_id"] != ElementId)
		return false
	Secure := false
	return true
}

SFD_FocusSnapshot() {
	global SFD_FIELD_CACHE
	PreviousCritical := Critical("On")
	try return {
		Generation: SFD_FIELD_CACHE["focus_generation"],
		ElementId: SFD_FIELD_CACHE["current_element_id"]
	}
	finally Critical(PreviousCritical)
}

SFD_InvalidateFocus(*) {
	global SFD_FIELD_CACHE
	PreviousCritical := Critical("On")
	try {
		SFD_FIELD_CACHE["focus_generation"] += 1
		SFD_FIELD_CACHE["current_element_id"] := ""
		SFD_FIELD_CACHE["hwnd"] := 0
		SFD_FIELD_CACHE["secure"] := true
		SFD_FIELD_CACHE["at"] := 0
		SFD_FIELD_CACHE["element_id"] := ""
		SFD_FIELD_CACHE["verdict_generation"] := 0
		return SFD_FIELD_CACHE["focus_generation"]
	} finally {
		Critical(PreviousCritical)
	}
}

SFD_FocusEventCallback(*) {
	try SFD_InvalidateFocus()
	catch as Err
		try LoggerError("SecureField", "Focus invalidation callback failed: {1}.",
			Err.Message)
}

SFD_FreeFocusCallback(CallbackPtr) {
	if !CallbackPtr
		return true
	try {
		CallbackFree(CallbackPtr)
		return true
	} catch as Err {
		try LoggerWarn("SecureField", "Focus callback teardown failed: {1}.",
			Err.Message)
	}
	return false
}

SFD_EnsureFocusTracking() {
	global SFD_FIELD_CACHE
	if SFD_FIELD_CACHE["focus_tracking_active"]
		return true
	if (SFD_FIELD_CACHE["focus_hook"] or SFD_FIELD_CACHE["focus_callback"])
		return false
	if IsSet(_AHK_DRY_RUN)
		return false
	CallbackPtr := 0
	try CallbackPtr := CallbackCreate(SFD_FocusEventCallback, "F", 7)
	catch as Err {
		try LoggerError("SecureField", "Focus callback creation failed: {1}.",
			Err.Message)
		return false
	}
	Hook := 0
	try Hook := DllCall("SetWinEventHook",
		"UInt", 0x8005,
		"UInt", 0x8005,
		"Ptr", 0,
		"Ptr", CallbackPtr,
		"UInt", 0,
		"UInt", 0,
		"UInt", 0,
		"Ptr")
	catch as Err {
		if !SFD_FreeFocusCallback(CallbackPtr)
			SFD_FIELD_CACHE["focus_callback"] := CallbackPtr
		try LoggerError("SecureField", "Focus tracking hook creation failed: {1}.",
			Err.Message)
		return false
	}
	if !Hook {
		if !SFD_FreeFocusCallback(CallbackPtr)
			SFD_FIELD_CACHE["focus_callback"] := CallbackPtr
		try LoggerError("SecureField",
			"Focus tracking hook failed; negative UIA verdicts remain fail-closed.")
		return false
	}
	PreviousCritical := Critical("On")
	try {
		SFD_FIELD_CACHE["focus_callback"] := CallbackPtr
		SFD_FIELD_CACHE["focus_hook"] := Hook
		SFD_FIELD_CACHE["focus_tracking_active"] := true
		SFD_FIELD_CACHE["current_element_id"] := ""
		SFD_FIELD_CACHE["focus_generation"] += 1
	} finally {
		Critical(PreviousCritical)
	}
	return true
}

SFD_Stop() {
	global SFD_FIELD_CACHE
	if (!SFD_FIELD_CACHE["focus_tracking_active"]
			and !SFD_FIELD_CACHE["focus_hook"]
			and !SFD_FIELD_CACHE["focus_callback"])
		return true
	PreviousCritical := Critical("On")
	try {
		Hook := SFD_FIELD_CACHE["focus_hook"]
		CallbackPtr := SFD_FIELD_CACHE["focus_callback"]
		SFD_FIELD_CACHE["focus_tracking_active"] := false
		SFD_FIELD_CACHE["current_element_id"] := ""
		SFD_FIELD_CACHE["focus_generation"] += 1
	} finally {
		Critical(PreviousCritical)
	}
	Unhooked := true
	if Hook {
		try Unhooked := !!DllCall("UnhookWinEvent", "Ptr", Hook)
		catch as Err {
			Unhooked := false
			try LoggerWarn("SecureField", "Focus tracking hook teardown failed: {1}.",
				Err.Message)
		}
	}
	if !Unhooked
		return false
	SFD_FIELD_CACHE["focus_hook"] := 0
	if CallbackPtr and !SFD_FreeFocusCallback(CallbackPtr)
		return false
	SFD_FIELD_CACHE["focus_callback"] := 0
	return true
}

SFD_FocusedHwnd() {
	try {
		Hwnd := ControlGetHwnd(ControlGetFocus("A"), "A")
		if Hwnd
			return Hwnd
	}
	try return WinGetID("A")
	return 0
}

SFD_DetectNative(Hwnd, &Conclusive) {
	Conclusive := false
	try {
		ClassName := WinGetClass("ahk_id " . Hwnd)
		if !RegExMatch(ClassName, "i)^(Edit|RichEdit)")
			return false
		; Read the style BEFORE claiming the verdict is conclusive. WinGetStyle
		; throws TargetError if the control is destroyed in the window between
		; the class read above and this line, and a Conclusive already set would
		; turn that OS failure into a confident "not a password field": the
		; caller would then skip its fail-closed branch, never schedule the UIA
		; probe, and cache the wrong answer for a full TTL. Every other unknown
		; in this adapter fails closed; this one used to fail open.
		Style := WinGetStyle("ahk_id " . Hwnd)
		Conclusive := true
		return (Style & 0x20) ? true : false
	} catch as e {
		; The verdict stays inconclusive so the caller falls back to fail-closed
		; plus a UIA probe, but the reason must not vanish (conventions 5.3).
		; DEBUG because a control disappearing mid-classification is an expected,
		; benign outcome — it is only the silent version that was a defect.
		Conclusive := false
		try LoggerDebug("SecureField", "Native field classification failed for hwnd {1}: {2}.", Hwnd, e.Message)
	}
	return false
}

SFD_CommitFieldVerdict(Hwnd, Secure, FocusGeneration, ElementId := "") {
	global SFD_FIELD_CACHE
	; Publish the key last so concurrent reader callbacks cannot pair a new HWND
	; with the previous control's verdict.
	SFD_FIELD_CACHE["secure"] := !!Secure
	SFD_FIELD_CACHE["at"] := A_TickCount
	SFD_FIELD_CACHE["verdict_generation"] := FocusGeneration
	SFD_FIELD_CACHE["element_id"] := ElementId
	if (FocusGeneration = SFD_FIELD_CACHE["focus_generation"])
		SFD_FIELD_CACHE["current_element_id"] := ElementId
	SFD_FIELD_CACHE["hwnd"] := Hwnd
}

; Returns the exact delay still needed before a cross-process provider probe is
; allowed to start. Keeping this calculation separate makes the idle boundary
; deterministic in tests and prevents a short prediction debounce from
; repeatedly abandoning the same fail-closed verdict.
SFD_UiaProbeIdleRemainingMs(IdleMs) {
	global SFD_UIA_IDLE_REQUIRED_MS
	return Max(0, SFD_UIA_IDLE_REQUIRED_MS - Max(0, IdleMs))
}

; Arms one one-shot for the exact pending focus owner. SetTimer failures are
; terminal for that attempt and must be observable: otherwise the cache remains
; fail-closed with no explanation and no worker can ever refine it.
_SFD_ArmUiaProbeTimer(Hwnd, FocusGeneration, DelayMs) {
	try {
		SetTimer(SFD_ProbeFocusedUia.Bind(Hwnd, FocusGeneration),
			-Max(1, Round(DelayMs)))
		return true
	} catch as Err {
		try LoggerError("SecureField", "UIA password probe timer failed: {1}.",
			Err.Message)
		return false
	}
}

SFD_ScheduleUiaProbe(Hwnd, FocusGeneration) {
	global SFD_FIELD_CACHE
	if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd
			and SFD_FIELD_CACHE["pending_generation"] = FocusGeneration)
		return
	SFD_FIELD_CACHE["pending_hwnd"] := Hwnd
	SFD_FIELD_CACHE["pending_generation"] := FocusGeneration
	RemainingMs := SFD_UiaProbeIdleRemainingMs(A_TimeIdlePhysical)
	if !_SFD_ArmUiaProbeTimer(Hwnd, FocusGeneration, RemainingMs)
		_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
}

; Releases the one-probe-in-flight slot. A released slot lets the next
; SFD_IsSecureField call re-arm the probe, which is what makes a deferral
; (suspended, mid-burst, hostile process) transient rather than permanent.
_SFD_ClearPendingProbe(Hwnd, FocusGeneration) {
	global SFD_FIELD_CACHE
	if (SFD_FIELD_CACHE["pending_hwnd"] = Hwnd
			and SFD_FIELD_CACHE["pending_generation"] = FocusGeneration) {
		SFD_FIELD_CACHE["pending_hwnd"] := 0
		SFD_FIELD_CACHE["pending_generation"] := 0
	}
}

; Has this process recently failed to answer a UIA probe? Mirrors the tooltip's
; own hostile cache: one timeout must buy a quiet window instead of being
; re-paid on every field-cache expiry, i.e. roughly once per second.
_SFD_UiaProcessIsHostile(ProcName) {
	global SFD_UIA_HOSTILE_CACHE
	if (ProcName == "" or !SFD_UIA_HOSTILE_CACHE.Has(ProcName))
		return false
	Entry := SFD_UIA_HOSTILE_CACHE[ProcName]
	if !TickExpired(Entry.Tick, Entry.DurationMs)
		return true
	SFD_UIA_HOSTILE_CACHE.Delete(ProcName)
	return false
}

; Record that ProcName did not answer usefully, silencing probes against it for
; SFD_UIA_HOSTILE_TTL_MS.
_SFD_MarkUiaHostile(ProcName) {
	global SFD_UIA_HOSTILE_CACHE, SFD_UIA_HOSTILE_TTL_MS
	if (ProcName == "")
		return
	SFD_UIA_HOSTILE_CACHE[ProcName] := {
		Tick: A_TickCount,
		DurationMs: SFD_UIA_HOSTILE_TTL_MS
	}
}

SFD_CurrentUiaContext() {
	TopHwnd := WIGetForegroundHwnd()
	Control := WIGetFocusedControlToken()
	if !TopHwnd || !Control
		return 0
	ProcName := ""
	try ProcName := WinGetProcessName("ahk_id " . TopHwnd)
	return Map(
		"Hwnd", TopHwnd,
		"Control", Control,
		"InputEpoch", KS_GetPhysicalInputEpoch(),
		"ProcName", ProcName)
}

SFD_ParsePasswordWorkerVerdict(Status, Result) {
	if (Status != "ok" || !(Result is Map))
		return 0
	Payload := Result.Get("Text", "")
	Separator := InStr(Payload, "`n")
	if !Separator
		return 0
	SecureText := SubStr(Payload, 1, Separator - 1)
	ElementId := SubStr(Payload, Separator + 1)
	if ((SecureText != "0" && SecureText != "1") || ElementId == ""
			or InStr(ElementId, "`n") || InStr(ElementId, "`r"))
		return 0
	return Map("Secure", SecureText = "1", "ElementId", ElementId)
}

SFD_OnUiaWorkerTerminal(Hwnd, FocusGeneration, CurrentHwndFn, ContextFn,
		ContextMatchFn,
		Status, Context, Result) {
	try {
		if A_IsSuspended
			return false
		Verdict := SFD_ParsePasswordWorkerVerdict(Status, Result)
		if !(Verdict is Map) {
			if (Status = "timeout" || Status = "failed") {
				ProcName := (Context is Map) ? Context.Get("ProcName", "") : ""
				_SFD_MarkUiaHostile(ProcName)
				try LoggerDebug("SecureField",
					"UIA password worker returned {1}; the verdict remains fail-closed.",
					Status)
			}
			return false
		}
		LiveContext := ContextFn.Call()
		CurrentFocus := SFD_FocusSnapshot()
		if !(LiveContext is Map) || !(Context is Map) || !(Result is Map)
			return false
		if (CurrentFocus.Generation != FocusGeneration
				or CurrentHwndFn.Call() != Hwnd
				or !ContextMatchFn.Call(Context, Result, LiveContext))
			return false
		SFD_CommitFieldVerdict(Hwnd, Verdict["Secure"], FocusGeneration,
			Verdict["ElementId"])
		return true
	} finally {
		_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
	}
}

; Dispatches the provider call to the disposable worker. UIA providers can raise
; native access violations that no AutoHotkey catch can contain; the worker's
; process-kill deadline makes both latency and memory faults non-fatal here.
SFD_ProbeFocusedUia(Hwnd, FocusGeneration,
		CurrentHwndFn := SFD_FocusedHwnd,
		ContextFn := SFD_CurrentUiaContext,
		RequestFn?, StartFn?, ContextMatchFn?) {
	global SFD_UIA_REQUEST_FN, SFD_UIA_START_FN, SFD_UIA_CONTEXT_MATCH_FN
	if A_IsSuspended {
		_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
		return false
	}

	; Retire callbacks whose focus owner changed before their one-shot fired.
	; Validate the HWND before consulting idle time so a stale owner can never
	; keep re-arming itself merely because the user remains active elsewhere.
	try CurrentHwnd := CurrentHwndFn.Call()
	catch as Err {
		try LoggerDebug("SecureField",
			"UIA password probe focus check failed: {1}.", Err.Message)
		_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
		return false
	}
	CurrentFocus := SFD_FocusSnapshot()
	if (CurrentHwnd != Hwnd || CurrentFocus.Generation != FocusGeneration) {
		_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
		return false
	}

	; A physical event may arrive after the first timer is armed. Preserve the
	; exact pending owner and wait only for the missing quiet interval; clearing
	; here would starve every configuration whose debounce is below this gate.
	RemainingMs := SFD_UiaProbeIdleRemainingMs(A_TimeIdlePhysical)
	if (RemainingMs > 0) {
		if !_SFD_ArmUiaProbeTimer(Hwnd, FocusGeneration, RemainingMs)
			_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
		return false
	}

	Accepted := false
	try {
		if !IsSet(RequestFn)
			RequestFn := SFD_UIA_REQUEST_FN
		if !IsSet(StartFn)
			StartFn := SFD_UIA_START_FN
		if !IsSet(ContextMatchFn)
			ContextMatchFn := SFD_UIA_CONTEXT_MATCH_FN
		if !IsObject(RequestFn) || !IsObject(StartFn)
				or !IsObject(ContextMatchFn)
			throw Error("Secure-field UIA worker ports are not configured.")
		Context := ContextFn.Call()
		; The deferred owner is the focused-control HWND, not the foreground
		; top-level HWND. Context retains both identities: ``Control`` owns this
		; request while ``Hwnd`` is matched against the worker result at terminal
		; publication. Comparing this owner with the top-level HWND rejects normal
		; browser/Electron/WPF child controls before they can be classified.
		if !(Context is Map) || Context.Get("Control", 0) != Hwnd
			return false
		if _SFD_UiaProcessIsHostile(Context.Get("ProcName", ""))
			return false
		Terminal := SFD_OnUiaWorkerTerminal.Bind(Hwnd, FocusGeneration,
			CurrentHwndFn, ContextFn, ContextMatchFn)
		Accepted := !!RequestFn.Call(Context, Terminal)
		if !Accepted
			try StartFn.Call()
		return Accepted
	} catch as e {
		try LoggerError("SecureField", "UIA password worker dispatch failed: {1}.",
			e.Message)
		return false
	} finally {
		if !Accepted
			_SFD_ClearPendingProbe(Hwnd, FocusGeneration)
	}
}

; Returns true if AppId matches any entry in the SFD_SECURE_APPS constant Map.
; An empty or missing AppId is treated as non-secure to avoid false positives.
; @param AppId {String} Process name of the active application (e.g. KeePass.exe).
; @return {Boolean} True on success, false on error.
SFD_IsSecureApp(AppId) {
	if AppId = ""
		return false
	try {
		return SFD_SECURE_APPS.Has(AppId) ? true : false
	} catch {
		return false
	}
}

; Retire the focused-element identity and every verdict derived from it.
SFD_Refresh() {
	SFD_InvalidateFocus()
}
; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/test_adapter_compliance_new.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_SECURE_FIELD_DETECTOR := Map(
    "isSecureField", SFD_IsSecureField,
    "isSecureApp",   SFD_IsSecureApp,
    "refresh",       SFD_Refresh,
)

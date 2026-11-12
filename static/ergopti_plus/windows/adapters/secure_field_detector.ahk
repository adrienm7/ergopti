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

; Secure applications: the `windows` process names of _shared/data/secure_apps.json
; (ADD-1, decided by the maintainer on 2026-11-11), read once by SFD_SecureApps.
; 0 until read, then the Map; -1 once a read or parse failed, which
; makes every application secure: a missing list must never open a password manager.
global SFD_SECURE_APPS := 0

; The process verdict of the last focused top-level window, keyed by its handle
; and process id (a handle can be reused by another process), so the name is
; read once per window rather than once per keystroke.
global SFD_SECURE_APP_ROOT := Map("hwnd", 0, "pid", 0, "secure", true)

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

; Process name => native monotonic {Tick, DurationMs} interval during which probes are skipped.
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
SFD_IsSecureField(KnownFocusedHwnd := unset) {
	Hwnd := IsSet(KnownFocusedHwnd) ? KnownFocusedHwnd : SFD_FocusedHwnd()
	if !(Hwnd is Integer) || Hwnd <= 0
		return true
	; A secure application is secure whatever field has focus (ADD-1), so
	; hotstrings, the LLM bridge, predictions, agent actions and metrics follow.
	if SFD_IsSecureAppWindow(Hwnd)
		return true
	SFD_EnsureFocusTracking()
	Focus := SFD_FocusSnapshot()
	; ES_PASSWORD can change without changing HWND, focus or RuntimeId. Native
	; Edit/RichEdit classification is bounded and authoritative on every read;
	; only inconclusive provider fields may reuse their exact UIA receipt.
	NativeElement := "hwnd:" . Hwnd
	Conclusive := false
	Secure := SFD_DetectNative(Hwnd, &Conclusive)
	if Conclusive {
		SFD_CommitFieldVerdict(Hwnd, Secure, Focus.Generation, NativeElement)
		return Secure
	}
	CachedSecure := true
	if SFD_TryGetCachedVerdict(Hwnd, Focus.Generation, Focus.ElementId,
			&CachedSecure, , false)
		return CachedSecure
	; A failed native read cannot reuse an old native negative verdict. Unknown
	; remains fail-closed until the asynchronous UIA owner confirms its field.
	Secure := true
	SFD_ScheduleUiaProbe(Hwnd, Focus.Generation)
	SFD_CommitFieldVerdict(Hwnd, Secure, Focus.Generation, "")
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
SFD_TryGetCachedVerdict(Hwnd, FocusGeneration, ElementId, &Secure, NowTick?, AllowNativeNegative := true) {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS
	Secure := true
	; This map is updated in place. Copy the verdict and identity before sampling
	; native time, so a later callback cannot pair a new origin with an older clock.
	PreviousCritical := Critical("On")
	try {
		CachedHwnd := SFD_FIELD_CACHE["hwnd"]
		CacheAt := SFD_FIELD_CACHE["at"]
		CachedSecure := SFD_FIELD_CACHE["secure"]
		TrackingActive := SFD_FIELD_CACHE["focus_tracking_active"]
		VerdictGeneration := SFD_FIELD_CACHE["verdict_generation"]
		CachedElementId := SFD_FIELD_CACHE["element_id"]
	} finally {
		Critical(PreviousCritical)
	}
	if (CachedHwnd != Hwnd)
		return false
	Now := IsSet(NowTick) ? NowTick : A_TickCount
	if TickExpired64(CacheAt, SFD_FIELD_CACHE_TTL_MS, Now)
		return false
	if CachedSecure
		return true
	if (!TrackingActive
			or VerdictGeneration != FocusGeneration
			or ElementId == ""
			or CachedElementId != ElementId)
		return false
	; A caller which just obtained an inconclusive native read may still use
	; an exact UIA verdict, but cannot revive an earlier native style receipt.
	if !AllowNativeNegative && CachedElementId == "hwnd:" . Hwnd
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
	PreviousCritical := Critical("On")
	try {
		; Verdict, timestamp and identity form one publication. Key-last alone
		; still exposes the old identity while earlier fields already changed.
		SFD_FIELD_CACHE["secure"] := !!Secure
		SFD_FIELD_CACHE["at"] := A_TickCount
		SFD_FIELD_CACHE["verdict_generation"] := FocusGeneration
		SFD_FIELD_CACHE["element_id"] := ElementId
		if (FocusGeneration = SFD_FIELD_CACHE["focus_generation"])
			SFD_FIELD_CACHE["current_element_id"] := ElementId
		SFD_FIELD_CACHE["hwnd"] := Hwnd
	} finally {
		Critical(PreviousCritical)
	}
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
_SFD_UiaProcessIsHostile(ProcName, NowTick?) {
	global SFD_UIA_HOSTILE_CACHE
	PreviousCritical := Critical("On")
	try {
		if (ProcName == "" or !SFD_UIA_HOSTILE_CACHE.Has(ProcName))
			return false
		Entry := SFD_UIA_HOSTILE_CACHE[ProcName]
		Started := Entry.Tick
		DurationMs := Entry.DurationMs
	} finally {
		Critical(PreviousCritical)
	}
	Now := IsSet(NowTick) ? NowTick : A_TickCount
	if !TickExpired64(Started, DurationMs, Now)
		return true
	; A renewal publishes a new object. Expiry owns only the observed entry.
	PreviousCritical := Critical("On")
	try {
		if (SFD_UIA_HOSTILE_CACHE.Has(ProcName)
				and SFD_UIA_HOSTILE_CACHE[ProcName] == Entry)
			SFD_UIA_HOSTILE_CACHE.Delete(ProcName)
	} finally {
		Critical(PreviousCritical)
	}
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

; Returns the secure applications by process name (compared without case),
; read once from _shared/data/secure_apps.json, or false when it cannot be read.
; @return {Map|Integer} The process names, or false after a failed read.
SFD_SecureApps() {
	global SFD_SECURE_APPS, _SharedDir
	if IsObject(SFD_SECURE_APPS)
		return SFD_SECURE_APPS
	if SFD_SECURE_APPS == -1
		return false
	Apps := Map()
	Apps.CaseSense := "Off"
	try {
		Data := JsonParse(FileRead(_SharedDir . "\data\secure_apps.json", "UTF-8"))
		for Entry in Data["apps"]
			for Name in Entry["windows"]
				Apps[Name] := true
	} catch as Err {
		try LoggerError("SecureField", "The secure applications cannot be read ({1}); every application is treated as secure.",
			Err.Message)
		SFD_SECURE_APPS := -1
		return false
	}
	SFD_SECURE_APPS := Apps
	return Apps
}

; Returns true if AppId is a secure application, or when the list cannot be read.
; An empty or missing AppId is treated as non-secure to avoid false positives.
; @param AppId {String} Process name of the active application (e.g. KeePass.exe).
; @return {Boolean} Whether the application is secure.
SFD_IsSecureApp(AppId) {
	if !(AppId is String) || AppId == ""
		return false
	Apps := SFD_SecureApps()
	if !IsObject(Apps)
		return true
	return Apps.Has(AppId)
}

; Returns the process name of the top-level window holding Hwnd, or "" when the
; window is gone (no process to classify; the field checks still run).
; @param Root {Integer} Top-level window handle.
; @return {String}
SFD_ProcessNameOf(Root) {
	try return WinGetProcessName("ahk_id " . Root)
	catch as Err {
		try LoggerDebug("SecureField", "No process name for window {1}: {2}.", Root, Err.Message)
		return ""
	}
}

; Whether the focused control belongs to a secure application, cached per
; top-level window.
; @param Hwnd {Integer} Focused control or window.
; @return {Boolean}
SFD_IsSecureAppWindow(Hwnd) {
	global SFD_SECURE_APP_ROOT
	Root := DllCall("GetAncestor", "ptr", Hwnd, "uint", 2, "ptr")  ; GA_ROOT
	if !Root
		Root := Hwnd
	Pid := 0
	DllCall("GetWindowThreadProcessId", "ptr", Root, "uint*", &Pid)
	if Pid && SFD_SECURE_APP_ROOT["hwnd"] == Root && SFD_SECURE_APP_ROOT["pid"] == Pid
		return SFD_SECURE_APP_ROOT["secure"]
	Secure := SFD_IsSecureApp(SFD_ProcessNameOf(Root))
	SFD_SECURE_APP_ROOT["hwnd"] := Root
	SFD_SECURE_APP_ROOT["pid"] := Pid
	SFD_SECURE_APP_ROOT["secure"] := Secure
	return Secure
}

; Retire the focused-element identity and every verdict derived from it.
SFD_Refresh() {
	SFD_InvalidateFocus()
}
; Machine-readable contract map - consumed by the generic adapter compliance test
; (tests/unit/adapters/test_adapter_compliance.ahk) to verify every required method exists
; and is callable without manually listing functions per-adapter.
global ADAPTER_SECURE_FIELD_DETECTOR := Map(
    "isSecureField", SFD_IsSecureField,
    "isSecureApp",   SFD_IsSecureApp,
    "refresh",       SFD_Refresh,
)

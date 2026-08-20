; infra/metrics/metrics_filters.ahk

; ==============================================================================
; MODULE: Metrics Privacy Filters
; DESCRIPTION:
; Persists and evaluates the privacy filters that gate the keylogger hot
; path: private browsing detection, system-auth dialogs, and a per-app
; exclusion list. Mirrors the « FILTRES DE CONFIDENTIALITÉ » section of
; the Hammerspoon menu_metrics.lua.
;
; FEATURES & RATIONALE:
; 1. INI persistence: settings live alongside metrics_shortcuts.ini under
;    the [filters] / [disabled_apps] sections so they survive restarts.
; 2. Defaults safe: private + system-auth filters default to ON. Users
;    have to explicitly turn them OFF, never the other way around — same
;    contract as the global keylogger toggle.
; 3. Single chokepoint: KL_AppendLog() in modules/keylogger.ahk calls
;    MF_ShouldFilter() before any disk I/O, so every event source
;    (typing flush, shortcuts, hotstrings, system events, …) inherits
;    the filter for free.
;
; STORAGE FORMAT (metrics_shortcuts.ini):
;   [filters]
;   private_browsing = 1
;   system_auth      = 1
;
;   [disabled_apps]
;   list = Notepad.exe|chrome.exe|...
; ==============================================================================

#Requires Autohotkey v2.0+





; ===============================
; ===============================
; ======= 1/ Module state =======
; ===============================
; ===============================

class MetricsFilters {
		; Privacy filters and the at-rest encryption opt-in. The values below are
		; placeholders only: MetricsFiltersApplyManifestDefaults() overwrites all
		; four from the shared manifest before CS_Load() applies the user's config,
		; so the effective default has exactly one declaration
		; (_shared/modules/features/manifest.toml, [[features.metrics]]).
		;
		; They used to be the defaults, hardcoded, alongside a SECOND set of
		; manifest entries declaring the same three toggles AHK-only under
		; different ids. The driver read neither. Three spellings of one setting is
		; how the macOS and Windows privacy defaults get to disagree without any
		; gate noticing — and this is the one setting where disagreeing means
		; logging keystrokes the user asked not to log.
		;
		; They are NOT left unset: this is a privacy fail-closed. If the manifest
		; ever fails to resolve, filtering stays ON and encryption stays OFF rather
		; than the reverse.
		static private_browsing  := true
		static secure_field      := true   ; Ignorer les champs mot de passe (UIA)
		static system_auth       := true
		static encrypt           := false

		; Per-app exclusion list. Keys are process names (e.g. "chrome.exe");
		; presence of the key means « do not log this app ». Map for O(1)
		; lookup on the hot path.
		static disabled_apps := Map()
}


; Seed the four configurable filter flags from the shared manifest. Called by
; CS_Load() before it applies the user's config, so the order is
; manifest default -> user override, with no third source in between.
;
; A missing manifest entry leaves the placeholder in place and logs an ERROR: a
; privacy toggle that silently resolves to "whatever was in the class body" is
; the failure this function exists to make impossible to have unnoticed.
MetricsFiltersApplyManifestDefaults() {
		Pairs := Map(
			"private_browsing", "metrics.private_filter_enabled",
			"secure_field",     "metrics.secure_filter_enabled",
			"system_auth",      "metrics.system_auth_filter_enabled",
			"encrypt",          "metrics.encrypt"
		)
		for Prop, Path in Pairs {
				Entry := ManifestFindEntryByPath(Path)
				if (Entry == false) {
						try LoggerError("MetricsFilters",
							"No manifest entry for '{1}' — keeping the fail-closed placeholder for '{2}'.", Path, Prop)
						continue
				}
				MetricsFilters.%Prop% := (Entry["default"] = true)
		}
}





; ==================================
; ==================================
; ======= 2/ INI load / save =======
; ==================================
; ==================================

; Persistence is delegated to infra/config_shortcuts.ahk (CS_Load / CS_Save)
; which owns the [metrics] section inside <config_dir>/config.toml.
; Explicit candidates use the process-wide configuration gateway so a terminal
; transition can refuse before any live metrics state is inspected or changed.
MF_LoadFromIni() {
		CS_Load()
}

MF_SaveToIni(Updates := unset, Context := "the metrics filters", WriterFn := 0,
		NotifyFn := 0, PublishFn := 0, FinalizeFn := 0,
		CompensateFn := 0) {
	if !IsSet(Updates)
		return CS_Save()
	Committed := CS_Save(Updates, Context, WriterFn, NotifyFn, PublishFn,
		FinalizeFn, CompensateFn)
	return (Committed is Integer) && Committed == 1
}

MF_SaveBuiltToIni(Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
	Committed := CS_SaveBuilt(Context, BuildFn, WriterFn, NotifyFn)
	return (Committed is Integer) && Committed == 1
}

_MF_FilterConfigKey(Prop) {
	static Keys := Map(
		"private_browsing", "private_filter_enabled",
		"secure_field",     "secure_filter_enabled",
		"system_auth",      "system_auth_filter_enabled"
	)
	return Keys.Get(Prop, "")
}

_MF_PublishFlagCandidate(Prop, Target) {
	MetricsFilters.%Prop% := Target
}

_MF_BuildFilterTogglePlan(Prop) {
	ConfigKey := _MF_FilterConfigKey(Prop)
	if (ConfigKey = "")
		throw ValueError("Unknown metrics-filter property '" . Prop . "'.")
	Target := !MetricsFilters.%Prop%
	return {
		updates: [{ Section: "metrics", Key: ConfigKey, Value: Target }],
		publish: _MF_PublishFlagCandidate.Bind(Prop, Target)
	}
}

MF_CommitFilterToggle(Prop, WriterFn := 0, NotifyFn := 0) {
	return MF_SaveBuiltToIni("the '" . Prop . "' metrics filter",
		_MF_BuildFilterTogglePlan.Bind(Prop), WriterFn, NotifyFn)
}

_MF_ApplyEncryptionCandidate(Target, ApplyFn := 0) {
	if HasMethod(ApplyFn, "Call") {
		Applied := ApplyFn.Call(Target)
		return (Applied is Integer) && Applied == 1
	}
	KL_Enc_SetEnabled(Target)
	return KL_Enc_IsEnabled() == Target ? 1 : 0
}

_MF_EncryptionCandidateAvailable(AvailableFn := 0) {
	Available := HasMethod(AvailableFn, "Call")
		? AvailableFn.Call()
		: KL_Enc_IsAvailable()
	return (Available is Integer) && Available == 1
}

_MF_BuildEncryptionTogglePlan(Outcome, ApplyFn := 0, AvailableFn := 0) {
	OldValue := !!MetricsFilters.encrypt
	Target := !OldValue
	if Target && !_MF_EncryptionCandidateAvailable(AvailableFn) {
		try LoggerError("Keylogger", "At-rest encryption requested but no key can be derived - staying off.")
		return { noop: true }
	}
	Outcome["accepted"] := true
	return {
		updates: [{ Section: "metrics", Key: "encrypt", Value: Target }],
		rollback_updates: [{ Section: "metrics", Key: "encrypt",
			Value: OldValue }],
		finalize: _MF_ApplyEncryptionCandidate.Bind(Target, ApplyFn),
		compensate: _MF_ApplyEncryptionCandidate.Bind(OldValue, ApplyFn),
		publish: _MF_PublishFlagCandidate.Bind("encrypt", Target)
	}
}

_MF_NotifyEncryptionUnavailable(NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _MF_NotifyEncryptionUnavailable(NotifyFn)
		finally Critical(InheritedCritical)
	}
	try {
		Message := t("dialog.metrics.encryption_unavailable")
		Options := Map("title", t("dialog.metrics.encrypt_confirm_title"),
			"level", "error")
		Presented := HasMethod(NotifyFn, "Call")
			? NotifyFn.Call(Message, Options)
			: NotifierSend(Message, Options)
		if !(Presented is Integer) || Presented != 1 {
			try LoggerError("MetricsFilters",
				"The at-rest encryption unavailable notification was refused.")
		}
	} catch as Err {
		try LoggerError("MetricsFilters",
			"Could not present the at-rest encryption unavailable notification: {1}.",
			Err.Message)
	}
	return false
}

MF_CommitEncryptionToggle(WriterFn := 0, NotifyFn := 0, ApplyFn := 0,
		AvailableFn := 0) {
	Outcome := Map("accepted", false)
	Committed := MF_SaveBuiltToIni("the at-rest encryption preference",
		_MF_BuildEncryptionTogglePlan.Bind(Outcome, ApplyFn, AvailableFn),
		WriterFn, NotifyFn)
	if !Committed
		return false
	if Outcome.Get("accepted", false)
		return true
	return _MF_NotifyEncryptionUnavailable(NotifyFn)
}

_MF_BuildDisabledAppsPlan(Selected) {
	Candidate := Map()
	Persisted := []
	for _, ProcessName in Selected {
		Key := StrLower(Trim(String(ProcessName)))
		if (Key = "" || Candidate.Has(Key))
			continue
		Candidate[Key] := true
		Persisted.Push(Key)
	}
	return {
		updates: [{ Section: "metrics", Key: "metrics_disabled_apps",
			Value: Persisted }],
		publish: _MF_PublishDisabledAppsCandidate.Bind(Candidate)
	}
}

_MF_PublishDisabledAppsCandidate(Candidate) {
	MetricsFilters.disabled_apps := Candidate
}

MF_CommitDisabledApps(Selected, WriterFn := 0, NotifyFn := 0) {
	return MF_SaveBuiltToIni("the disabled metrics applications",
		_MF_BuildDisabledAppsPlan.Bind(Selected), WriterFn, NotifyFn)
}





; =================================================
; =================================================
; ======= 3/ Window / process introspection =======
; =================================================
; =================================================

; One canonical focused-window snapshot feeds both the privacy predicate and
; the keylogger’s app/title projection. The 50 ms freshness gate remains below
; realistic inter-keystroke intervals, but the acquisition itself is resident:
; SetTimer callbacks share the same AHK thread as keyboard dispatch. The adapter
; therefore bounds its only target-thread message with SendMessageTimeoutW and
; rejects partial results so an unavailable window fails privacy closed.
global MF_FOCUS_TTL_MS := 50

class MetricsFocusCache {
	; Build-then-swap keeps every reader on one complete identity. `valid=false`
	; is part of the snapshot contract, not an empty-context fallback: privacy
	; readers must drop data until a complete probe succeeds.
	static state := {
		valid: false,
		last_at: 0,
		hwnd: 0,
		process_name: "",
		title: "",
		class: "",
		failure_reason: "not_started",
		timed_out: false
	}
	static generation := 0
	; A newer refresh (or Stop) owns publication. This prevents a slow request A
	; from overwriting request B after B already published a newer focus.
	static refresh_generation := 0
	static lifecycle_generation := 0
	static running := false
	static timer_fn := 0
}

; Returns the current tick through an injectable seam used by the interleaving
; regression tests.
_MF_FocusNow(NowFn := 0) {
	Now := HasMethod(NowFn, "Call") ? NowFn.Call() : A_TickCount
	if !IsNumber(Now)
		throw TypeError("Focus refresh clock must return a number")
	return Round(Now)
}

; Normalizes an adapter result into the one immutable cache shape. Any missing
; field rejects the whole candidate; publishing a plausible partial identity is
; exactly how a privacy filter silently becomes permissive.
_MF_NormalizeFocusProbe(Probe, CapturedAt) {
	if !IsObject(Probe) || !Probe.HasOwnProp("ok") || !Probe.ok {
		Reason := IsObject(Probe) && Probe.HasOwnProp("failure_reason")
			? String(Probe.failure_reason) : "probe_failed"
		TimedOut := IsObject(Probe) && Probe.HasOwnProp("timed_out")
			? !!Probe.timed_out : false
		return {
			valid: false,
			last_at: CapturedAt,
			hwnd: 0,
			process_name: "",
			title: "",
			class: "",
			failure_reason: Reason,
			timed_out: TimedOut
		}
	}

	for Field in ["hwnd", "process_name", "title", "class"] {
		if !Probe.HasOwnProp(Field)
			return _MF_NormalizeFocusProbe({
				ok: false, failure_reason: "malformed_probe", timed_out: false
			}, CapturedAt)
	}
	if !IsNumber(Probe.hwnd) || Probe.hwnd <= 0
		|| !(Probe.process_name is String) || Probe.process_name = ""
		|| !(Probe.title is String) || !(Probe.class is String)
		|| Probe.class = "" {
		return _MF_NormalizeFocusProbe({
			ok: false, failure_reason: "malformed_probe", timed_out: false
		}, CapturedAt)
	}
	return {
		valid: true,
		last_at: CapturedAt,
		hwnd: Probe.hwnd,
		process_name: Probe.process_name,
		title: Probe.title,
		class: Probe.class,
		failure_reason: "",
		timed_out: false
	}
}

; Applies a candidate while the caller owns a short memory-only Critical span.
; Timestamp-only refreshes do not advance the privacy epoch; identity or
; validity changes do, because either can change whether telemetry is allowed.
_MF_ApplyFocusStateLocked(Candidate) {
	Current := MetricsFocusCache.state
	SemanticChanged := (Current.valid != Candidate.valid
		|| Current.hwnd != Candidate.hwnd
		|| Current.process_name !== Candidate.process_name
		|| Current.title !== Candidate.title
		|| Current.class !== Candidate.class)
	DiagnosticChanged := (Current.failure_reason !== Candidate.failure_reason
		|| Current.timed_out != Candidate.timed_out)
	MetricsFocusCache.state := Candidate
	if SemanticChanged
		MetricsFocusCache.generation += 1
	return {
		published: true,
		semantic_changed: SemanticChanged,
		diagnostic_changed: DiagnosticChanged,
		became_valid: Candidate.valid && !Current.valid,
		became_invalid: !Candidate.valid && Current.valid
	}
}

; Direct publisher retained for tests and explicit recovery paths. Advancing the
; refresh generation first also invalidates any older native acquisition.
_MF_PublishFocusState(Candidate) {
	PreviousCritical := Critical("On")
	try {
		MetricsFocusCache.refresh_generation += 1
		return _MF_ApplyFocusStateLocked(Candidate)
	} finally {
		Critical(PreviousCritical)
	}
}

_MF_BeginFocusRefresh() {
	PreviousCritical := Critical("On")
	try {
		MetricsFocusCache.refresh_generation += 1
		return MetricsFocusCache.refresh_generation
	} finally {
		Critical(PreviousCritical)
	}
}

_MF_CommitFocusRefresh(RequestGeneration, Candidate) {
	PreviousCritical := Critical("On")
	try {
		if (RequestGeneration != MetricsFocusCache.refresh_generation)
			return { published: false }
		return _MF_ApplyFocusStateLocked(Candidate)
	} finally {
		Critical(PreviousCritical)
	}
}

; Captures one stable reference for both metrics and keylogger consumers.
MF_GetFocusSnapshot() {
	return MetricsFocusCache.state
}

_MF_ReportFocusProbeResult(PublishResult, Candidate) {
	if !PublishResult.published
		return
	if !Candidate.valid && PublishResult.diagnostic_changed {
		try LoggerWarn("MetricsFilters",
			"Bounded focus snapshot unavailable ({1}); privacy filtering is fail-closed.",
			Candidate.failure_reason)
	} else if Candidate.valid && PublishResult.became_valid {
		try LoggerInfo("MetricsFilters", "Bounded focus snapshot recovered ({1}).",
			Candidate.process_name)
	}
}

; Performs the bounded adapter call outside Critical. The request generation is
; claimed before the call and rechecked at commit so a slow A cannot overwrite a
; newer B that published while A yielded to the Windows message transaction.
_MF_RefreshFocusNonCritical(Force, AcquireFn, NowFn) {
	StartedAt := _MF_FocusNow(NowFn)
	if !Force && ((StartedAt - (MetricsFocusCache.state.last_at)) & 0xFFFFFFFF)
			< MF_FOCUS_TTL_MS
		return false

	RequestGeneration := _MF_BeginFocusRefresh()
	Detail := ""
	HotPathStart := HotPath_Now()
	try {
		try {
			Probe := HasMethod(AcquireFn, "Call")
				? AcquireFn.Call(WI_FOCUS_TITLE_TIMEOUT_MS)
				: WICaptureBoundedFocusSnapshot(WI_FOCUS_TITLE_TIMEOUT_MS)
		} catch as Err {
			Probe := {
				ok: false,
				failure_reason: "probe_exception",
				timed_out: false
			}
			try LoggerError("MetricsFilters", "Focus snapshot probe failed: {1}.",
				Err.Message)
		}
		Candidate := _MF_NormalizeFocusProbe(Probe, _MF_FocusNow(NowFn))
		Detail := Candidate.valid ? Candidate.process_name
			: "failed:" . Candidate.failure_reason
		; Stop/suspend invalidates RequestGeneration. This extra state gate prevents
		; a direct test or caller from publishing after suspend without Stop running.
		if A_IsSuspended
			return false
		PublishResult := _MF_CommitFocusRefresh(RequestGeneration, Candidate)
		_MF_ReportFocusProbeResult(PublishResult, Candidate)
		return PublishResult.published && Candidate.valid
	} finally {
		HotPath_LogIfSlow("Metrics.FocusRefresh", HotPathStart, Detail)
	}
}

MF_RefreshFocus(Force := false, AcquireFn := 0, NowFn := 0) {
	; SetTimer callbacks bypass native Suspend, which only disarms hotkeys.
	if A_IsSuspended
		return false
	if !Force && !MetricsFocusCache.running
		return false
	; A caller’s Critical span must not expand across the native window query.
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _MF_RefreshFocusNonCritical(Force, AcquireFn, NowFn)
		finally Critical(InheritedCritical)
	}
	return _MF_RefreshFocusNonCritical(Force, AcquireFn, NowFn)
}

; A timer identity carries the lifecycle generation that created it. A stale
; queued callback from a rapid Stop -> Start transition cannot borrow the new
; owner’s `running=true` state and start another acquisition.
_MF_FocusTimerTick(OwnerGeneration) {
	PreviousCritical := Critical("On")
	try IsOwner := (MetricsFocusCache.running
		&& MetricsFocusCache.lifecycle_generation = OwnerGeneration)
	finally Critical(PreviousCritical)
	if !IsOwner
		return false
	return MF_RefreshFocus()
}





; ====================================
; ====================================
; ======= 4/ Filter predicates =======
; ====================================
; ====================================

; Heuristic patterns for private browsing windows. The match is on the
; window title and is intentionally generous — false positives mean
; "we logged a bit less than we could have", which is the safe direction.
global MF_PRIVATE_TITLE_PATTERNS := [
		"i)\bInPrivate\b",
		"i)\bIncognito\b",
		"i)\bPrivate Browsing\b",
		"i)\(Private\)",
		"i)Navigation privée",
		"i)Privé",
		"i)Privater Modus"
]

; System-auth windows. Both process names AND class names — UAC consent
; runs in consent.exe but the credential prompt that shows up for sudo-
; like operations runs as a XAML host with a stable class name.
global MF_SYSTEM_AUTH_PROCESSES := Map(
		"consent.exe",                 true,    ; UAC
		"logonui.exe",                 true,    ; lock screen
		"credentialuibroker.exe",      true,    ; modern credential prompts
		"credui.exe",                  true,    ; legacy credential prompts
		"winlogon.exe",                true
)
global MF_SYSTEM_AUTH_CLASSES := Map(
		"Credential Dialog Xaml Host", true,
		"ConsentUI",                   true,
		"LogonUI",                     true
)

MF_StartFocusRefresh() {
	if A_IsSuspended
		return false
	PendingState := _MF_NormalizeFocusProbe({
		ok: false, failure_reason: "refresh_pending", timed_out: false
	}, A_TickCount)
	PreviousCritical := Critical("On")
	try {
		if MetricsFocusCache.running
			return true
		; Retire any pre-stop identity before native Suspend can release and the
		; first resumed keystroke can interrupt the bounded seed acquisition.
		_MF_ApplyFocusStateLocked(PendingState)
		MetricsFocusCache.running := true
		MetricsFocusCache.lifecycle_generation += 1
		StartGeneration := MetricsFocusCache.lifecycle_generation
		FocusTimerFn := _MF_FocusTimerTick.Bind(StartGeneration)
		MetricsFocusCache.timer_fn := FocusTimerFn
	} finally {
		Critical(PreviousCritical)
	}

	; Timer mutation stays outside Critical. The BoundFunc identity lets failure
	; cleanup cancel only this start attempt, never a newer owner’s timer.
	try SetTimer(FocusTimerFn, MF_FOCUS_TTL_MS)
	catch as Err {
		PreviousCritical := Critical("On")
		try {
			if MetricsFocusCache.lifecycle_generation = StartGeneration
				&& IsObject(MetricsFocusCache.timer_fn)
				&& ObjPtr(MetricsFocusCache.timer_fn) = ObjPtr(FocusTimerFn) {
				MetricsFocusCache.running := false
				MetricsFocusCache.timer_fn := 0
				MetricsFocusCache.lifecycle_generation += 1
				MetricsFocusCache.refresh_generation += 1
			}
		} finally {
			Critical(PreviousCritical)
		}
		try LoggerError("MetricsFilters", "Could not arm bounded focus refresh: {1}.",
			Err.Message)
		return false
	}
	PreviousCritical := Critical("On")
	try StillOwned := (MetricsFocusCache.running
		&& MetricsFocusCache.lifecycle_generation = StartGeneration
		&& IsObject(MetricsFocusCache.timer_fn)
		&& ObjPtr(MetricsFocusCache.timer_fn) = ObjPtr(FocusTimerFn))
	finally Critical(PreviousCritical)
	if !StillOwned {
		try SetTimer(FocusTimerFn, 0)
		return false
	}

	; Seed before any keylogger callback can consume the cache. This call remains
	; resident but its only target-thread message has an OS-enforced 5 ms deadline.
	try MF_RefreshFocus(true)
	catch as Err
		try LoggerError("MetricsFilters", "Initial bounded focus refresh failed: {1}.",
			Err.Message)
	PreviousCritical := Critical("On")
	try StillOwned := (MetricsFocusCache.running
		&& MetricsFocusCache.lifecycle_generation = StartGeneration
		&& IsObject(MetricsFocusCache.timer_fn)
		&& ObjPtr(MetricsFocusCache.timer_fn) = ObjPtr(FocusTimerFn))
	finally Critical(PreviousCritical)
	if !StillOwned
		return false
	try LoggerTrace("MetricsFilters", "Bounded focus-cache refresh started ({1} ms).",
		MF_FOCUS_TTL_MS)
	return true
}

; Disarm the focus-cache poll. Required because MF_RefreshFocus is a REPEATING
; timer: without a cancel site it runs for the whole process lifetime, including
; the entire pause. Advancing refresh_generation also denies publication to a
; request that was already inside SendMessageTimeoutW when suspend began.
MF_StopFocusRefresh() {
	StoppedState := _MF_NormalizeFocusProbe({
		ok: false, failure_reason: "refresh_stopped", timed_out: false
	}, A_TickCount)
	PreviousCritical := Critical("On")
	try {
		WasRunning := MetricsFocusCache.running
		FocusTimerFn := MetricsFocusCache.timer_fn
		MetricsFocusCache.running := false
		MetricsFocusCache.timer_fn := 0
		MetricsFocusCache.lifecycle_generation += 1
		MetricsFocusCache.refresh_generation += 1
		; Native Suspend is lifted before the resume reactor runs. Publishing the
		; invalid marker here keeps an early resumed keystroke privacy fail-closed.
		_MF_ApplyFocusStateLocked(StoppedState)
	} finally {
		Critical(PreviousCritical)
	}
	if !IsObject(FocusTimerFn)
		return true
	try SetTimer(FocusTimerFn, 0)
	catch as Err {
		try LoggerError("MetricsFilters", "Could not stop bounded focus refresh: {1}.",
			Err.Message)
		return false
	}
	if WasRunning
		try LoggerDone("MetricsFilters", "Bounded focus-cache refresh stopped.")
	return true
}

; Returns true when the keylogger should DROP the current event because one of
; the privacy filters matches, or because focus could not be classified safely.
MF_ShouldFilter() {
		; Last window title the private-browsing pattern scan ran on, with its
		; verdict. The seven RegExMatch calls below used to run on EVERY logged
		; event; the title they read only changes when MF_RefreshFocus publishes a
		; new snapshot (50 ms TTL), so scanning it again per keystroke re-derived a
		; value that could not have changed. Same build-then-swap discipline as
		; MetricsFocusCache: title and verdict are published together through a
		; single reference assignment, so a timer interrupting mid-scan can never
		; expose a new title paired with the old (possibly "not private") verdict.
		static _private_memo := { title: "", is_private: false }

	; The timer is resident on the same cooperative AHK thread; the safe property
	; is the adapter’s hard title deadline, not imaginary background execution.
	; This hot path only captures the already-published canonical reference.
	s := MF_GetFocusSnapshot()
	if !IsObject(s) || !s.HasOwnProp("valid") || !s.valid
		return true
		proc  := StrLower(s.process_name)
		title := s.title
		cls   := s.class

		; 1. Disabled-apps list — fastest check.
		if (proc != "" && MetricsFilters.disabled_apps.Has(proc))
				return true

		; 2. Password field — relies on the UIA-backed detector in
		;    modules/keylogger.ahk §13. Wrapped in try because the function
		;    is loaded later in the include order and an early caller (e.g.
		;    boot-time metrics) might race ahead of it.
		if MetricsFilters.secure_field {
				; Default to "password" BEFORE the try, never after: this caller
				; persists characters to disk, so it cannot be laxer than the LLM
				; caller of the same predicate, which test_disable_password_fields_gate
				; already pins to `IsPw := true` ahead of `try IsPw := SFD_IsSecureField()`.
				; Seeding it false made a throwing detector (a UIA change, a new
				; unguarded call in the chain, KLPW_CACHE_TTL_MS read before the include
				; that defines it has run at boot) answer "ordinary field" and the
				; keystroke got logged. Worse, the bare try swallowed the error before
				; KL_AppendLog's own fail-closed catch could see it.
				is_pw := true
				try {
						is_pw := KL_IsFocusedFieldPassword()
				} catch as err {
						; Staying secure is the right behaviour, but a permanently degraded
						; detector must not look like a healthy one (conventions 5.3).
						try LoggerWarn("MetricsFilters", "KL_IsFocusedFieldPassword unavailable — defaulting to secure: {1}.", err.Message)
				}
				if is_pw
						return true
		}

		; 3. System-auth dialogs.
		if MetricsFilters.system_auth {
				if (proc != "" && MF_SYSTEM_AUTH_PROCESSES.Has(proc))
						return true
				if (cls != "" && MF_SYSTEM_AUTH_CLASSES.Has(cls))
						return true
		}

		; 4. Private browsing (title pattern match), memoized on the title itself.
		if MetricsFilters.private_browsing && title != "" {
				memo := _private_memo
				; Case-sensitive compare: two titles differing only in case are two
				; different titles, and the patterns are already case-insensitive.
				if (title !== memo.title) {
						is_private := false
						for _, pat in MF_PRIVATE_TITLE_PATTERNS {
								if RegExMatch(title, pat) {
										is_private := true
										break
								}
						}
						memo := { title: title, is_private: is_private }
						_private_memo := memo
				}
				if memo.is_private
						return true
		}
		return false
}



; =========================================
; ===== 4.1) Outgoing-context variant =====
; =========================================

; Same predicate as MF_ShouldFilter() but evaluates an explicit (app, title)
; pair instead of the live MetricsFocusCache snapshot. KL_AppendLog uses this
; to re-check the OUTGOING side of an app_switch / window_switch transition:
; by the time such an event is emitted the live focus cache already points
; at the NEW (non-excluded) window, so MF_ShouldFilter() alone always answers
; the wrong question for these two event types (F9 fix). The secure-field
; (password) check is intentionally omitted — it depends on a live UIA probe
; of the CURRENTLY focused control and has no meaning for a context that has
; already lost focus.
MF_ShouldFilterFor(app, title) {
		proc := StrLower(app)

		; 1. Disabled-apps list.
		if (proc != "" && MetricsFilters.disabled_apps.Has(proc))
				return true

		; 2. System-auth dialogs — process name only, there is no live window
		;    class available for a non-focused snapshot.
		if (MetricsFilters.system_auth && proc != "" && MF_SYSTEM_AUTH_PROCESSES.Has(proc))
				return true

		; 3. Private browsing (title pattern match).
		if (MetricsFilters.private_browsing && title != "") {
				for _, pat in MF_PRIVATE_TITLE_PATTERNS {
						if RegExMatch(title, pat)
								return true
				}
		}
		return false
}





; =================================================
; =================================================
; ======= 5/ Disabled-apps mutation helpers =======
; =================================================
; =================================================

; Add or remove an app (process name) from the exclusion list. Persists
; immediately. Returns the new state (true = excluded).
MF_ToggleDisabledApp(ProcessName, WriterFn := 0, NotifyFn := 0) {
	if (ProcessName = "")
		return false
	Outcome := Map("new_state", false)
	Committed := MF_SaveBuiltToIni("the disabled metrics application",
		_MF_BuildDisabledAppTogglePlan.Bind(ProcessName, Outcome), WriterFn,
		NotifyFn)
	return Committed && Outcome["new_state"]
}

_MF_BuildDisabledAppTogglePlan(ProcessName, Outcome) {
	Key := StrLower(ProcessName)
	Candidate := MetricsFilters.disabled_apps.Clone()
	if Candidate.Has(Key) {
		Candidate.Delete(Key)
		Outcome["new_state"] := false
	} else {
		Candidate[Key] := true
		Outcome["new_state"] := true
	}
	Persisted := []
	for Name, _ in Candidate
		Persisted.Push(Name)
	return {
		updates: [{ Section: "metrics", Key: "metrics_disabled_apps",
			Value: Persisted }],
		publish: _MF_PublishDisabledAppsCandidate.Bind(Candidate)
	}
}

MF_DisabledCount() {
		n := 0
		for _, _ in MetricsFilters.disabled_apps
				n += 1
		return n
}

MF_DisabledList() {
		out := []
		for name, _ in MetricsFilters.disabled_apps
				out.Push(name)
		return out
}

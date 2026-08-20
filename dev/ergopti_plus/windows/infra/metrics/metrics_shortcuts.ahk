; infra/metrics/metrics_shortcuts.ahk

; ==============================================================================
; MODULE: Metrics Shortcuts
; DESCRIPTION:
; Persists and applies user-defined hotkeys for the two metrics dashboards.
; Mirrors the role of `apply_metrics_shortcut` / `apply_apps_time_shortcut`
; on the Hammerspoon side.
;
; FEATURES & RATIONALE:
; 1. INI persistence: the chosen hotkey (e.g. "^!m") is saved next to the
;    other AHK config so it survives restarts and is editable by hand.
; 2. Toggle binding: only one hotkey at a time per action — re-binding
;    automatically unregisters the previous one.
; 3. AHK ↔ HS naming: the user types "cmd+alt+m" or "ctrl+alt+m"; we
;    translate to AHK modifier syntax (^!#+) for Hotkey().
;
; STORAGE FORMAT (metrics_shortcuts.ini):
;   [shortcuts]
;   typing = ctrl+alt+m
;   apps   = ctrl+alt+t
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class MetricsShortcuts {
		static STATUS_INACTIVE        := "inactive"
		static STATUS_ACTIVE          := "active"
		static STATUS_ERROR           := "error"
		static STATUS_CLEANUP_PENDING := "cleanup_pending"
		static STATUS_ROLLBACK_PENDING := "rollback_pending"
		; OFF by default. The keylogger captures every keystroke, so we never
		; auto-enable it: the user must tick it on once and confirm the
		; warning dialog. The choice persists across reloads via INI.
		static enabled           := false
		static typing_str        := ""    ; e.g. "ctrl+alt+m"
		static apps_str          := ""
		static typing_ahk        := ""    ; e.g. "^!m"  (active hotkey string)
		static apps_ahk          := ""
		static typing_handle     := ""    ; owner-aware registrar token
		static apps_handle       := ""
		; A failed native Off is exception-atomic: the old callback remains live.
		; Keep every such token addressable until a later recovery pass can retire
		; it; an empty primary handle alone therefore never means "fully clean".
		static typing_status     := "inactive"
		static apps_status       := "inactive"
		static typing_recovery_handles := []
		static apps_recovery_handles := []
		; Real-time WPM display prefs.
		static wpm_menubar_colors     := false  ; Color-code menubar WPM by keystroke origin
}





; =====================================
; =====================================
; ======= 3/ Path + INI helpers =======
; =====================================
; =====================================

; Persistence delegates to infra/config_shortcuts.ahk which owns the
; [shortcuts] section inside <config_dir>/config.toml. The MS_* names
; survive as thin shims so existing call sites keep working without
; needing a global rename.
MS_LoadFromIni() {
		CS_Load()
}

MS_SaveToIni(Updates := unset, Context := "the metrics settings", WriterFn := 0, NotifyFn := 0, PublishFn := 0,
		FinalizeFn := 0, CompensateFn := 0) {
		; Preserve the legacy full-save shim for the preference callers that are
		; migrated independently from the shortcut transaction.
		if !IsSet(Updates)
				return CS_Save()
		Committed := CS_Save(Updates, Context, WriterFn, NotifyFn, PublishFn,
				FinalizeFn, CompensateFn)
		return (Committed is Integer) && Committed == 1
}

MS_SaveBuiltToIni(Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
		Committed := CS_SaveBuilt(Context, BuildFn, WriterFn, NotifyFn)
		return (Committed is Integer) && Committed == 1
}

_MS_PreferenceConfigKey(Prop) {
		static Keys := Map(
				"enabled", "metrics_enabled",
				"wpm_menubar_colors", "metrics_wpm_menubar_colors"
		)
		return Keys.Get(Prop, "")
}

_MS_BuildPreferencePlan(Prop, Target) {
		ConfigKey := _MS_PreferenceConfigKey(Prop)
		if (ConfigKey = "")
				throw ValueError("Unknown metrics preference '" . Prop . "'.")
		Candidate := !!Target
		return {
				updates: [{ Section: "metrics", Key: ConfigKey, Value: Candidate }],
				publish: _MS_PublishPreferenceCandidate.Bind(Prop, Candidate)
		}
}

_MS_PublishPreferenceCandidate(Prop, Candidate) {
		MetricsShortcuts.%Prop% := Candidate
}

MS_CommitPreference(Prop, Target, WriterFn := 0, NotifyFn := 0) {
		return MS_SaveBuiltToIni("the '" . Prop . "' metrics preference",
				_MS_BuildPreferencePlan.Bind(Prop, Target), WriterFn, NotifyFn)
}





; =========================================
; =========================================
; ======= 4/ AHK hotkey translation =======
; =========================================
; =========================================

MS_ToAhkSyntax(human) {
		; All configurable hotkeys share the same aliases, duplicate collapsing,
		; canonical modifier order and named-key translation. A second parser here
		; previously disagreed with the explicit chord corpus on "control" and
		; duplicate aliases, so metrics and the registrar could name different keys.
		if (Type(human) = "String" && Trim(human) = "")
				return ""
		Parsed := ChordParse(human)
		if !Parsed["ok"] {
				try LoggerWarn("MetricsShortcuts", "Rejected shortcut '{1}': {2}.",
						human, Parsed["err"])
				return ""
		}
		Native := HotkeyRegistrarNativeSpec(Parsed["mods"], Parsed["key"])
		if (Native = "")
				try LoggerWarn("MetricsShortcuts",
						"Rejected shortcut '{1}': a modifier has no Windows equivalent.", human)
		return Native
}





; ==========================================
; ==========================================
; ======= 5/ Hotkey (un)registration =======
; ==========================================
; ==========================================

_MS_ReportHotkeyTransitionFailure(raw, which, Stage, ErrorMessage, HotkeyFn := 0) {
		try LoggerError("MetricsShortcuts",
				"Could not {1} shortcut '{2}' for '{3}': {4}.", Stage, raw, which, ErrorMessage)
}

_MS_StatusForAhk(Ahk) {
	return (Ahk = "") ? MetricsShortcuts.STATUS_INACTIVE
		: MetricsShortcuts.STATUS_ACTIVE
}

_MS_AppendRecoveryHandle(State, Handle) {
	if (Handle = "")
		return false
	for Existing in State["recovery_handles"] {
		if (Existing = Handle)
			return false
	}
	State["recovery_handles"].Push(Handle)
	return true
}

MS_BindHotkey(PrevHandle, PrevAhk, NewHuman, Callback, Owner,
		HotkeyFn := 0, ProbeFn := 0) {
		; Boot replay has no config write to perform, but it still uses the staged
		; registrar API so no candidate callback exists before Activate succeeds.
		NewAhk := (NewHuman == "") ? "" : MS_ToAhkSyntax(NewHuman)
		if !MS_ShouldPersistShortcut(NewHuman, NewAhk)
			return { ok: false, handle: PrevHandle, ahk: PrevAhk,
				status: MetricsShortcuts.STATUS_ERROR, recovery_handles: [] }
		if (NewAhk == PrevAhk && PrevHandle != "")
			return { ok: true, handle: PrevHandle, ahk: PrevAhk,
				status: _MS_StatusForAhk(PrevAhk), recovery_handles: [] }
		if (NewHuman == "") {
			if (PrevHandle != "" && !_HotkeyRegistrarRetire(PrevHandle, HotkeyFn)) {
				_MS_ReportHotkeyTransitionFailure(NewHuman, Owner, "clear",
					"the previous native binding remains live and is retained for recovery",
					HotkeyFn)
				return { ok: false, handle: "", ahk: "",
					status: MetricsShortcuts.STATUS_CLEANUP_PENDING,
					recovery_handles: [PrevHandle] }
			}
			return { ok: true, handle: "", ahk: "",
				status: MetricsShortcuts.STATUS_INACTIVE, recovery_handles: [] }
		}
		NewHandle := _HotkeyRegistrarReserveOwned(NewHuman, Callback, Owner,
			HotkeyFn, ProbeFn)
		if (NewHandle == "") {
			_MS_ReportHotkeyTransitionFailure(NewHuman, Owner, "assign",
				"another action owns or refused this native chord", HotkeyFn)
			return { ok: false, handle: PrevHandle, ahk: PrevAhk,
				status: MetricsShortcuts.STATUS_ERROR, recovery_handles: [] }
		}
		if !_HotkeyRegistrarActivate(NewHandle, HotkeyFn) {
			RecoveryHandles := []
			if !_HotkeyRegistrarAbort(NewHandle)
				RecoveryHandles.Push(NewHandle)
			_MS_ReportHotkeyTransitionFailure(NewHuman, Owner, "activate",
				"the candidate remained native-Off", HotkeyFn)
			return { ok: false, handle: PrevHandle, ahk: PrevAhk,
				status: MetricsShortcuts.STATUS_ERROR,
				recovery_handles: RecoveryHandles }
		}
		if (PrevHandle != "" && !_HotkeyRegistrarRetire(PrevHandle, HotkeyFn)) {
			_MS_ReportHotkeyTransitionFailure(NewHuman, Owner, "replace",
				"the replacement is active but the previous native binding remains live",
				HotkeyFn)
			return { ok: false, handle: NewHandle, ahk: NewAhk,
				status: MetricsShortcuts.STATUS_CLEANUP_PENDING,
				recovery_handles: [PrevHandle] }
		}
		return { ok: true, handle: NewHandle, ahk: NewAhk,
			status: MetricsShortcuts.STATUS_ACTIVE, recovery_handles: [] }
}

_MS_NotifyBootBindingFailure(Typing, Apps, NotifyFn := 0) {
	FailedRaw := ""
	if !Typing.ok {
		FailedRaw := MetricsShortcuts.typing_str != ""
			? MetricsShortcuts.typing_str
			: t("keylogger_ui.typing_metrics")
	}
	if !Apps.ok {
		AppsLabel := MetricsShortcuts.apps_str != ""
			? MetricsShortcuts.apps_str
			: t("keylogger_ui.app_metrics")
		FailedRaw .= (FailedRaw != "" ? ", " : "") . AppsLabel
	}
	try {
		Message := Format(t("metrics.shortcut_register_error"), FailedRaw,
			t("common.error_title"))
		Options := Map("title", t("common.error_title"),
			"level", "warning")
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(Message, Options)
		else
			NotifierSend(Message, Options)
	} catch as Err {
		try LoggerError("MetricsShortcuts",
			"Could not surface incomplete startup shortcut activation: {1}.",
			Err.Message)
	}
	return false
}

MS_ApplyAll(ToggleTypingFn, ToggleAppsFn, HotkeyFn := 0, ProbeFn := 0,
		NotifyFn := 0) {
		; Replay both slots independently. A failure in typing must not suppress the
		; apps shortcut; the aggregate false lets boot report incomplete activation.
		if (MetricsShortcuts.typing_recovery_handles.Length > 0) {
			Typing := { ok: false, handle: MetricsShortcuts.typing_handle,
				ahk: MetricsShortcuts.typing_ahk,
				status: MetricsShortcuts.typing_status,
				recovery_handles: MetricsShortcuts.typing_recovery_handles }
		} else {
			Typing := MS_BindHotkey(MetricsShortcuts.typing_handle,
				MetricsShortcuts.typing_ahk, MetricsShortcuts.typing_str,
				ToggleTypingFn, "metrics:typing", HotkeyFn, ProbeFn)
		}
		MetricsShortcuts.typing_handle := Typing.handle
		MetricsShortcuts.typing_ahk := Typing.ahk
		MetricsShortcuts.typing_status := Typing.status
		MetricsShortcuts.typing_recovery_handles := Typing.recovery_handles
		if (MetricsShortcuts.apps_recovery_handles.Length > 0) {
			Apps := { ok: false, handle: MetricsShortcuts.apps_handle,
				ahk: MetricsShortcuts.apps_ahk,
				status: MetricsShortcuts.apps_status,
				recovery_handles: MetricsShortcuts.apps_recovery_handles }
		} else {
			Apps := MS_BindHotkey(MetricsShortcuts.apps_handle,
				MetricsShortcuts.apps_ahk, MetricsShortcuts.apps_str,
				ToggleAppsFn, "metrics:apps", HotkeyFn, ProbeFn)
		}
		MetricsShortcuts.apps_handle := Apps.handle
		MetricsShortcuts.apps_ahk := Apps.ahk
		MetricsShortcuts.apps_status := Apps.status
		MetricsShortcuts.apps_recovery_handles := Apps.recovery_handles
		Ready := Typing.ok && Apps.ok
		if !Ready
			_MS_NotifyBootBindingFailure(Typing, Apps, NotifyFn)
		return Ready
}





; =====================================
; =====================================
; ======= 6/ Interactive editor =======
; =====================================
; =====================================

; Decides whether a candidate shortcut string is safe to persist to disk.
; ``raw`` is the trimmed, lower-cased user input; ``candidate_ahk`` is its
; translated native name ("" for malformed input or an explicit clear). A
; cleared shortcut is syntactically eligible, but the transaction still has to
; commit before disabling the old binding. A malformed non-empty string must
; never reach either Hotkey() or persistence, or it will be replayed at boot.
; @param raw {String} The trimmed, lower-cased user input.
; @param candidate_ahk {String} The translated AHK hotkey name, or "".
; @returns {Boolean} True when ``raw`` is safe to write to the persisted state.
MS_ShouldPersistShortcut(raw, candidate_ahk) {
		return (raw = "") || (candidate_ahk != "")
}

_MS_PublishShortcutCandidate(IsTyping, State) {
		if IsTyping {
				MetricsShortcuts.typing_str := State["new_string"]
				MetricsShortcuts.typing_ahk := State["new_ahk"]
				MetricsShortcuts.typing_handle := State["new_handle"]
				MetricsShortcuts.typing_status := State["status"]
				MetricsShortcuts.typing_recovery_handles := State["recovery_handles"]
		} else {
				MetricsShortcuts.apps_str := State["new_string"]
				MetricsShortcuts.apps_ahk := State["new_ahk"]
				MetricsShortcuts.apps_handle := State["new_handle"]
				MetricsShortcuts.apps_status := State["status"]
				MetricsShortcuts.apps_recovery_handles := State["recovery_handles"]
		}
		State["published"] := true
}

_MS_ActivatePreparedShortcut(State, HotkeyFn) {
	if !State["new_reserved"]
		return true
	State["activate_ok"] := _HotkeyRegistrarActivate(State["new_handle"], HotkeyFn)
	State["new_active"] := State["activate_ok"]
	return State["activate_ok"]
}

; A reserved candidate is known native-Off, so rollback is bookkeeping-only.
; It runs under the same config lease before any notifier can yield.
_MS_AbortPreparedShortcut(State) {
	if !State["new_reserved"] || State["new_active"]
		return true
	State["rollback_ok"] := false
	State["rollback_ok"] := _HotkeyRegistrarAbort(State["new_handle"])
	return State["rollback_ok"]
}

_MS_RetirePreviousShortcut(State, HotkeyFn) {
	if !State["binding_changed"] || State["old_handle"] = ""
		return true
	State["cleanup_ok"] := _HotkeyRegistrarRetire(State["old_handle"], HotkeyFn)
	if !State["cleanup_ok"] {
		_MS_AppendRecoveryHandle(State, State["old_handle"])
		State["status"] := MetricsShortcuts.STATUS_CLEANUP_PENDING
	}
	return State["cleanup_ok"]
}

_MS_RetainShortcutRecovery(IsTyping, State, RecoveryFn, Stage) {
	if (Stage != "compensation_failed" && Stage != "rollback_failed"
			&& Stage != "cleanup_failed") {
		try LoggerError("MetricsShortcuts",
			"Refusing unknown shortcut recovery stage '{1}'.", Stage)
		return false
	}
	if (Stage = "compensation_failed") {
		_MS_AppendRecoveryHandle(State, State["new_handle"])
		State["status"] := MetricsShortcuts.STATUS_ERROR
	} else if (Stage = "rollback_failed") {
		if !State["rollback_ok"]
			_MS_AppendRecoveryHandle(State, State["new_handle"])
		State["status"] := MetricsShortcuts.STATUS_ROLLBACK_PENDING
	} else if (Stage = "cleanup_failed") {
		_MS_AppendRecoveryHandle(State, State["old_handle"])
		State["status"] := MetricsShortcuts.STATUS_CLEANUP_PENDING
	}
	; Cleanup failure is followed immediately by the ordinary publisher, which
	; swaps raw/native/primary/recovery state together. Rollback and compensation
	; have no publisher, so expose their recovery status here in one short swap.
	if (Stage != "cleanup_failed") {
		PreviousCritical := Critical("On")
		try {
			if IsTyping {
				MetricsShortcuts.typing_status := State["status"]
				MetricsShortcuts.typing_recovery_handles := State["recovery_handles"]
			} else {
				MetricsShortcuts.apps_status := State["status"]
				MetricsShortcuts.apps_recovery_handles := State["recovery_handles"]
			}
		} finally Critical(PreviousCritical)
	}
	if (Stage != "rollback_failed")
		return true
	global CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS
	Queued := HasMethod(RecoveryFn, "Call")
		? RecoveryFn.Call()
		: _ConfigQueueFullSave(CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS)
	return (Queued is Integer) && Queued == 1
}

_MS_ShortcutNeedsRecovery(which) {
	IsTyping := (which = "typing")
	PreviousCritical := Critical("On")
	try {
		Status := IsTyping ? MetricsShortcuts.typing_status
			: MetricsShortcuts.apps_status
		Handles := IsTyping ? MetricsShortcuts.typing_recovery_handles
			: MetricsShortcuts.apps_recovery_handles
		return Handles.Length > 0
			|| Status = MetricsShortcuts.STATUS_CLEANUP_PENDING
			|| Status = MetricsShortcuts.STATUS_ROLLBACK_PENDING
	} finally Critical(PreviousCritical)
}

_MS_ClearShortcutRecovery(IsTyping) {
	if IsTyping {
		MetricsShortcuts.typing_recovery_handles := []
		MetricsShortcuts.typing_status := _MS_StatusForAhk(
			MetricsShortcuts.typing_ahk)
	} else {
		MetricsShortcuts.apps_recovery_handles := []
		MetricsShortcuts.apps_status := _MS_StatusForAhk(
			MetricsShortcuts.apps_ahk)
	}
}

_MS_BuildShortcutRecoveryPlan(which, HotkeyFn) {
	IsTyping := (which = "typing")
	Status := IsTyping ? MetricsShortcuts.typing_status
		: MetricsShortcuts.apps_status
	Handles := IsTyping ? MetricsShortcuts.typing_recovery_handles
		: MetricsShortcuts.apps_recovery_handles
	if (Handles.Length = 0
			&& Status != MetricsShortcuts.STATUS_CLEANUP_PENDING
			&& Status != MetricsShortcuts.STATUS_ROLLBACK_PENDING)
		return { noop: true }

	Remaining := []
	for Handle in Handles {
		Retired := _HotkeyRegistrarRetire(Handle, HotkeyFn)
		; Handles are monotonic and never reused. A false retire on an already
		; absent token means another recovery path completed it, not that native
		; authority remains untracked.
		if !Retired && HotkeyRegistrarChordOf(Handle) != ""
			Remaining.Push(Handle)
	}
	if (Remaining.Length > 0)
		throw Error("one or more retained native bindings still refuse retirement")

	Raw := IsTyping ? MetricsShortcuts.typing_str : MetricsShortcuts.apps_str
	ConfigKey := IsTyping ? "metrics_shortcut_typing" : "metrics_shortcut_apps"
	; Rewriting the currently published value repairs rollback_pending and is a
	; harmless idempotent confirmation after cleanup_pending. The warning clears
	; only in the gateway publisher, after this write has succeeded.
	return {
		updates: [{ Section: "metrics", Key: ConfigKey, Value: Raw }],
		publish: _MS_ClearShortcutRecovery.Bind(IsTyping)
	}
}

; Explicit recovery entry used both by a later edit and by tests. It owns the
; config path while retiring retained native handles and repairing any failed
; reverse write, so recovery cannot race a sibling metrics edit.
MS_RetryShortcutRecovery(which, WriterFn := 0, NotifyFn := 0, HotkeyFn := 0) {
	if (which != "typing" && which != "apps") {
		try LoggerError("MetricsShortcuts", "Unknown recovery slot '{1}'.", which)
		return false
	}
	return CS_SaveBuilt("the metrics shortcut recovery for '" . which . "'",
		_MS_BuildShortcutRecoveryPlan.Bind(which, HotkeyFn), WriterFn, NotifyFn)
}

_MS_BuildShortcutPlan(Outcome, which, raw, ToggleFn, HotkeyFn, ProbeFn,
		RecoveryFn) {
	IsTyping := (which = "typing")
	OldString := IsTyping ? MetricsShortcuts.typing_str : MetricsShortcuts.apps_str
	OldAhk := IsTyping ? MetricsShortcuts.typing_ahk : MetricsShortcuts.apps_ahk
	OldHandle := IsTyping ? MetricsShortcuts.typing_handle : MetricsShortcuts.apps_handle
	OldStatus := IsTyping ? MetricsShortcuts.typing_status : MetricsShortcuts.apps_status
	OldRecovery := IsTyping ? MetricsShortcuts.typing_recovery_handles
		: MetricsShortcuts.apps_recovery_handles
	OtherAhk := IsTyping ? MetricsShortcuts.apps_ahk : MetricsShortcuts.typing_ahk
	Outcome["accepted"] := false
	if (OldRecovery.Length > 0
			|| OldStatus = MetricsShortcuts.STATUS_CLEANUP_PENDING
			|| OldStatus = MetricsShortcuts.STATUS_ROLLBACK_PENDING) {
		try LoggerError("MetricsShortcuts",
			"Shortcut recovery became pending while editing '{1}'.", which)
		throw Error("shortcut recovery must complete before a new edit")
	}
	NewAhk := (raw = "") ? "" : MS_ToAhkSyntax(raw)
	if !MS_ShouldPersistShortcut(raw, NewAhk) {
		try LoggerWarn("MetricsShortcuts",
			"Shortcut '{1}' is invalid for '{2}' — keeping previous value '{3}'.",
			raw, which, OldString)
		throw ValueError("the shortcut syntax is invalid")
	}
	if (NewAhk != "" && NewAhk = OtherAhk) {
		_MS_ReportHotkeyTransitionFailure(raw, which, "assign",
			"the other metrics shortcut already owns this native chord", HotkeyFn)
		throw Error("the other metrics shortcut already owns this native chord")
	}
	BindingChanged := (NewAhk != OldAhk) || (NewAhk != "" && OldHandle == "")
	NewHandle := BindingChanged ? "" : OldHandle
	if (BindingChanged && NewAhk != "") {
		NewHandle := _HotkeyRegistrarReserveOwned(raw, ToggleFn,
			"metrics:" . which, HotkeyFn, ProbeFn)
		if (NewHandle = "") {
			_MS_ReportHotkeyTransitionFailure(raw, which, "reserve",
				"the shared registrar refused the candidate", HotkeyFn)
			throw Error("the shared hotkey registrar refused the candidate")
		}
	}
	State := Map(
		"binding_changed", BindingChanged,
		"old_string", OldString,
		"old_ahk", OldAhk,
		"old_handle", OldHandle,
		"new_string", raw,
		"new_ahk", NewAhk,
		"new_handle", NewHandle,
		"new_reserved", BindingChanged && NewAhk != "",
		"new_active", false,
		"activate_ok", true,
		"cleanup_ok", true,
		"rollback_ok", true,
		"published", false,
		"status", _MS_StatusForAhk(NewAhk),
		"recovery_handles", [])
	Outcome["accepted"] := true
	Outcome["state"] := State
	ConfigKey := IsTyping ? "metrics_shortcut_typing" : "metrics_shortcut_apps"
	return {
		updates: [{ Section: "metrics", Key: ConfigKey, Value: raw }],
		rollback_updates: [{ Section: "metrics", Key: ConfigKey, Value: OldString }],
		finalize: _MS_ActivatePreparedShortcut.Bind(State, HotkeyFn),
		cleanup: _MS_RetirePreviousShortcut.Bind(State, HotkeyFn),
		compensate: _MS_AbortPreparedShortcut.Bind(State),
		retain: _MS_RetainShortcutRecovery.Bind(IsTyping, State, RecoveryFn),
		publish: _MS_PublishShortcutCandidate.Bind(IsTyping, State)
	}
}

; The config gateway is the sole cross-slot owner. It claims config.toml before
; this builder snapshots either slot, spans reserve-Off/write/activate/retire,
; and performs any reverse write before releasing the same lease.
MS_CommitShortcutCandidate(which, raw, ToggleFn, WriterFn := 0, NotifyFn := 0,
		HotkeyFn := 0, ProbeFn := 0, RecoveryFn := 0) {
		if (which != "typing" && which != "apps") {
				try LoggerError("MetricsShortcuts", "Unknown shortcut slot '{1}'.", which)
				return false
		}
		Outcome := Map("accepted", false)
		if _MS_ShortcutNeedsRecovery(which) {
			if !MS_RetryShortcutRecovery(which, WriterFn, NotifyFn, HotkeyFn)
				return false
		}
		Committed := CS_SaveBuilt("the metrics shortcut for '" . which . "'",
			_MS_BuildShortcutPlan.Bind(Outcome, which, raw, ToggleFn, HotkeyFn,
				ProbeFn, RecoveryFn), WriterFn, NotifyFn)
		return ((Committed is Integer) && Committed == 1)
			&& Outcome.Get("accepted", false)
}

MS_PromptShortcut(which, ToggleFn) {
		; Shows an InputBox to capture the new shortcut. ``which`` ∈
		; {"typing", "apps"}. Empty string clears the binding.
		label := (which = "typing") ? t("keylogger_ui.typing_metrics") : t("keylogger_ui.app_metrics")
		cur   := (which = "typing") ? MetricsShortcuts.typing_str : MetricsShortcuts.apps_str
		msg := t("metrics.shortcut_format_hint")
		ib := InputBox(msg, Format(t("metrics.shortcut_prompt_title"), label), "w400 h160", cur)
		if (ib.Result != "OK")
				return
		raw := Trim(StrLower(ib.Value))
		return MS_CommitShortcutCandidate(which, raw, ToggleFn)
}

MS_GetDisplayLabel(which) {
		s := (which = "typing") ? MetricsShortcuts.typing_str : MetricsShortcuts.apps_str
		Status := (which = "typing") ? MetricsShortcuts.typing_status
			: MetricsShortcuts.apps_status
		Prefix := (Status = MetricsShortcuts.STATUS_ERROR
			|| Status = MetricsShortcuts.STATUS_CLEANUP_PENDING
			|| Status = MetricsShortcuts.STATUS_ROLLBACK_PENDING)
			? Chr(0x26A0) . " " : ""
		if (s = "")
				return Prefix . t("menu.metrics.shortcut_none")
		return Prefix . s
}

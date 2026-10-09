; ui/menu/menu_llm/enable_admission.ahk

; ==============================================================================
; MODULE: Confirmed Local AI Enable Owner
; DESCRIPTION:
; Keeps the disabled state durable while a fresh selected-origin version probe
; runs. Only a current, settled native receipt enters the existing config owner;
; failed or superseded probes cannot publish or start an installer.
; ==============================================================================

#Requires AutoHotkey v2.0


global _LLM_Menu_EnableAdmission := 0

/** Returns one exact settings and native lifecycle snapshot for enable admission. */
_LLM_Menu_EnableSnapshot() {
	global _LLM_Menu, LLM_OLLAMA_BASE_URL
	return Map("backend", _LLM_Menu.Get("backend", ""),
		"model", _LLM_Menu.Get("model", ""), "origin", LLM_OLLAMA_BASE_URL,
		"generation", LLM_AuxGeneration(), "enabled", _LLM_Menu.Get("enabled", true),
		"paused", A_IsSuspended ? true : false,
		"blocked", !LLM_AuxRetryCleanupDebt() || !LLM_CurlRetryCleanupDebt())
}

; Optional callables are isolated native boundaries, not alternative state owners.
_LLM_Menu_EnablePort(Port, Name, Default) {
	if !(Port is Map) || !Port.Has(Name)
		return Default
	if !HasMethod(Port[Name], "Call")
		throw TypeError("Enable admission port requires callable '" . Name . "'.")
	return Port[Name]
}

_LLM_Menu_EnableReadSource() {
	global ConfigurationFile
	return Map("path", ConfigurationFile, "bytes", FSReadBytesStrict(ConfigurationFile))
}

_LLM_Menu_EnableSourceMatches(Captured, Current) {
	if !(Captured is Map) || !(Current is Map)
			|| Captured.Get("path", "") != Current.Get("path", "")
		return false
	Before := Captured.Get("bytes", 0)
	After := Current.Get("bytes", 0)
	if !(Before is Buffer) || !(After is Buffer) || Before.Size != After.Size
		return false
	loop Before.Size
		if NumGet(Before, A_Index - 1, "UChar") != NumGet(After, A_Index - 1, "UChar")
			return false
	return true
}

_LLM_Menu_EnableStillCurrent(Request) {
	global _LLM_Menu_EnableAdmission
	if !(Request is Map) || !Request.Get("active", false)
			|| !(_LLM_Menu_EnableAdmission is Map)
			|| ObjPtr(_LLM_Menu_EnableAdmission) != ObjPtr(Request)
		return false
	Read := _LLM_Menu_EnablePort(Request["port"], "snapshot", _LLM_Menu_EnableSnapshot)
	return LLM_EnableCurrent(Request["captured"], Read.Call())
}

/** Cancels only the pending enable owner; retained native debts block successors. */
LLM_Menu_CancelEnableAdmission() {
	global _LLM_Menu_EnableAdmission
	Request := _LLM_Menu_EnableAdmission
	_LLM_Menu_EnableAdmission := 0
	if !(Request is Map)
		return true
	Request["active"] := false
	if Request.Get("aux", 0) is Map
		LLM_AuxRetirePrefix("ollama_enable_admission")
	return LLM_AuxRetryCleanupDebt() && LLM_CurlRetryCleanupDebt()
}

/** Starts one selected-origin probe while retaining the disabled preference. */
LLM_Menu_RequestEnableAdmission(Port := 0, CancelPending := true) {
	global _LLM_Menu_EnableAdmission
	if _LLM_Menu_EnableAdmission is Map {
		if !CancelPending
			return false
		; A second click cancels the pending request; it never races a successor.
		LLM_Menu_CancelEnableAdmission()
		return false
	}
	Read := _LLM_Menu_EnablePort(Port, "snapshot", _LLM_Menu_EnableSnapshot)
	Captured := Read.Call()
	if !LLM_EnableCurrent(Captured, Captured)
		return false
	try Source := _LLM_Menu_EnablePort(Port, "read_source", _LLM_Menu_EnableReadSource).Call()
	catch {
		return false
	}
	; Source I/O may yield to another menu action; the winner keeps its owner.
	if _LLM_Menu_EnableAdmission is Map
		return false
	Request := Map("active", true, "captured", Captured.Clone(), "source", Source,
		"port", Port, "aux", 0)
	_LLM_Menu_EnableAdmission := Request
	try {
		Request["aux"] := LLM_AuxBegin("ollama_enable_admission", Map(
			"backend", Captured["backend"], "endpoint", Captured["origin"]))
		if !_LLM_Menu_EnableStillCurrent(Request) {
			LLM_Menu_CancelEnableAdmission()
			return false
		}
		Probe := _LLM_Menu_EnablePort(Port, "probe", _LLM_Menu_EnableProbe)
		Probe.Call(_LLM_Menu_EnableOnReceipt.Bind(Request), Request["aux"])
	} catch {
		LLM_Menu_CancelEnableAdmission()
		return false
	}
	return true
}

_LLM_Menu_EnableProbe(Callback, Owner) {
	return LLM_OllamaIsRunning_Async(Callback, Owner, true)
}

; This writer runs inside the actual borrowed config lease, after full-save
; settlement and candidate preparation. A source changed during the HTTP request
; cannot authorize a different document merely because its settings look equal.
_LLM_Menu_EnableWrite(Request, Path, Updates) {
	if !_LLM_Menu_EnableStillCurrent(Request)
		return false
	ReadSource := _LLM_Menu_EnablePort(Request["port"], "read_source", _LLM_Menu_EnableReadSource)
	if !_LLM_Menu_EnableSourceMatches(Request["source"], ReadSource.Call())
		return false
	if !_LLM_Menu_EnableStillCurrent(Request)
		return false
	Writer := _LLM_Menu_EnablePort(Request["port"], "writer", TOML_BatchWrite)
	return Writer.Call(Path, Updates)
}

_LLM_Menu_EnableCandidate(Request, Candidate) {
	if !_LLM_Menu_EnableStillCurrent(Request)
		return false
	Candidate["enabled"] := true
	return true
}

_LLM_Menu_EnableApplyCommitted(Candidate, Port := 0) {
	; Readiness is a server receipt, not permission to install a local binary.
	; The existing silent lifecycle preserves model checks without an installer
	; fallback if the server disappears between admission and activation.
	Apply := _LLM_Menu_EnablePort(Port, "toggle_apply", _LLM_Menu_ApplyToggleCommitted)
	return Apply.Call(Candidate, false)
}

_LLM_Menu_EnableNotify(Request) {
	Title := StrReplace(t("llm.unreachable.title"), "{1}", "Ollama")
	Body := StrReplace(StrReplace(t("llm.unreachable.body_unconfirmed"),
		"{1}", "Ollama"), "{2}", Request["captured"]["origin"])
	return Ui_MsgBox(Body, Title, "Icon! RetryCancel") == "Retry"
}

_LLM_Menu_EnableOnReceipt(Request, Receipt) {
	global _LLM_Menu_EnableAdmission
	Admitted := LLM_EnableReceipt(Receipt)
	RetryRequested := false
	try {
		if !_LLM_Menu_EnableStillCurrent(Request)
			return false
		if !Admitted["admitted"] {
			Notify := _LLM_Menu_EnablePort(Request["port"], "notify", _LLM_Menu_EnableNotify)
			Choice := Notify.Call(Request)
			RetryRequested := Choice is Integer && Choice == true
			return false
		}
		Port := Request["port"]
		return LLM_Menu_CommitMutation("the confirmed LLM enabled-state change",
			_LLM_Menu_EnableCandidate.Bind(Request),
			_LLM_Menu_EnablePort(Port, "apply", _LLM_Menu_EnableApplyCommitted),
			_LLM_Menu_EnableWrite.Bind(Request),
			_LLM_Menu_EnablePort(Port, "persistence_notify", 0),
			_LLM_Menu_EnablePort(Port, "acquire", 0),
			_LLM_Menu_EnablePort(Port, "settle", 0),
			_LLM_Menu_EnablePort(Port, "collect", 0))
	} finally {
		Request["active"] := false
		Owned := (_LLM_Menu_EnableAdmission is Map)
			&& ObjPtr(_LLM_Menu_EnableAdmission) == ObjPtr(Request)
		if Owned
			_LLM_Menu_EnableAdmission := 0
		if Owned && RetryRequested
			_LLM_Menu_EnableRetry(Request)
	}
}

; Retry is an explicit fresh request, never a retained stale HTTP answer.
_LLM_Menu_EnableRetry(Request) {
	Read := _LLM_Menu_EnablePort(Request["port"], "snapshot", _LLM_Menu_EnableSnapshot)
	if !LLM_EnableCurrent(Request["captured"], Read.Call())
		return false
	ReadSource := _LLM_Menu_EnablePort(Request["port"], "read_source", _LLM_Menu_EnableReadSource)
	if !_LLM_Menu_EnableSourceMatches(Request["source"], ReadSource.Call())
		return false
	if !LLM_EnableCurrent(Request["captured"], Read.Call())
		return false
	return LLM_Menu_RequestEnableAdmission(Request["port"], false)
}

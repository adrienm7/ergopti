; ui/menu/menu_llm/backend_lifecycle.ahk

; ==============================================================================
; MODULE: Backend-owned LLM lifecycle dispatcher
; DESCRIPTION:
; Captures the exact enabled/backend/API-entry generation before deferring any
; bootstrap work. Remote API admission never consults Ollama. Ollama callbacks
; retain their originating intent so a backend switch cannot reinterpret them.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LLM_BackendLifecycleEpoch := 0

_LLM_Menu_CaptureBackendLifecycleIntent(ShowUi := true) {
	global _LLM_Menu, _LLM_BackendLifecycleEpoch
	_LLM_BackendLifecycleEpoch += 1
	return Map(
		"epoch", _LLM_BackendLifecycleEpoch,
		"backend", _LLM_Menu.Get("backend", ""),
		"enabled", _LLM_Menu.Get("enabled", false),
		"api_entry_id", _LLM_Menu.Get("api_entry_id", ""),
		"model", _LLM_Menu.Get("model", ""),
		"show_ui", ShowUi ? true : false)
}

_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent) {
	global _LLM_Menu, _LLM_BackendLifecycleEpoch
	if !(Intent is Map)
			|| !Intent.Has("epoch") || !Intent.Has("backend")
			|| !Intent.Has("enabled") || !Intent.Has("api_entry_id")
		return false
	if Intent["epoch"] != _LLM_BackendLifecycleEpoch
		return false
	return Intent["backend"] == _LLM_Menu.Get("backend", "")
		&& Intent["enabled"] == _LLM_Menu.Get("enabled", false)
		&& Intent["api_entry_id"] == _LLM_Menu.Get("api_entry_id", "")
}

LLM_Menu_BackendLifecycleInvalidate(CancelOllama := false, Port := 0) {
	global _LLM_BackendLifecycleEpoch
	_LLM_BackendLifecycleEpoch += 1
	if CancelOllama
		_LLM_Menu_BackendLifecycleCall(Port, "cancel_ollama")
	return _LLM_BackendLifecycleEpoch
}

_LLM_Menu_BackendLifecycleCall(Port, Name, Args*) {
	if Port is Map {
		if !Port.Has(Name) || !HasMethod(Port[Name], "Call")
			throw Error("LLM backend lifecycle port is missing '" . Name . "'.")
		return Port[Name].Call(Args*)
	}
	switch Name {
		case "cancel_ollama":
			return LLM_Menu_CancelOllamaOwnership()
		case "validate_api":
			return _LLM_Menu_SelectedApiEntryIsUsable()
		case "start_bridge":
			return LLM_Menu_TryStartBridge()
		case "stop_bridge":
			return LLM_Bridge_Stop()
		case "deps_ready":
			return LLM_Deps_IsReady()
		case "deps_check":
			return LLM_Deps_CheckAndInstall(Args*)
		case "menu_build":
			return LLM_Menu_Build()
		case "warmup":
			return _LLM_Menu_WarmCurrentOllamaModel()
		case "deps_failed":
			return _LLM_Menu_ApplyCurrentDepsFailure(Args*)
	}
	throw Error("Unknown LLM backend lifecycle operation '" . Name . "'.")
}

LLM_Menu_CancelOllamaOwnership() {
	Succeeded := true
	for Operation in [
			(*) => LLM_AuxInvalidate("backend_lifecycle",
				_LLM_Menu_ResetOllamaAuxState),
			(*) => LLM_Deps_Cancel(),
			(*) => OllamaWV_Close(),
			(*) => LLM_OllamaCancelWarmupRetry()] {
		try Operation.Call()
		catch {
			Succeeded := false
			try LoggerError("LLM", "Ollama lifecycle cleanup failed during backend ownership transfer.")
		}
	}
	return Succeeded
}

_LLM_Menu_SelectedApiEntryIsUsable() {
	global _LLM_Menu
	EntryId := _LLM_Menu.Get("api_entry_id", "")
	Entries := _LLM_Menu.Get("api_entries", 0)
	if !(EntryId is String) || EntryId == "" || !(Entries is Array)
		return false
	Match := 0
	Matches := 0
	for Entry in Entries {
		if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId {
			Match := Entry
			Matches += 1
		}
	}
	if Matches != 1
		return false
	try return _LLMRemoteResolveEntry(Match) is Map
	catch as Err {
		try LoggerError("LLM", "Remote API lifecycle validation failed: {1}.", Err.Message)
		return false
	}
}

_LLM_Menu_BackendIsReadyForUse(DepsReadyFn := 0, ApiReadyFn := 0) {
	global _LLM_Menu
	if !_LLM_Menu.Get("enabled", false)
		return false
	Backend := _LLM_Menu.Get("backend", "")
	if Backend == "api" {
		if HasMethod(ApiReadyFn, "Call")
			return ApiReadyFn.Call() ? true : false
		return _LLM_Menu_SelectedApiEntryIsUsable()
	}
	if Backend != "ollama"
		return false
	if HasMethod(DepsReadyFn, "Call")
		return DepsReadyFn.Call() ? true : false
	return LLM_Deps_IsReady() ? true : false
}

LLM_Menu_ScheduleBackendLifecycle(ShowUi := true, ScheduleFn := 0, Port := 0) {
	Intent := _LLM_Menu_CaptureBackendLifecycleIntent(ShowUi)
	Callback := () => LLM_Menu_RunBackendLifecycle(Intent, Port)
	if HasMethod(ScheduleFn, "Call")
		ScheduleFn.Call(Callback, -1)
	else
		SetTimer(Callback, -1)
	return Intent
}

LLM_Menu_BootstrapCurrentBackend(ShowUi := true, Port := 0, Intent := 0) {
	if !(Intent is Map)
		Intent := _LLM_Menu_CaptureBackendLifecycleIntent(ShowUi)
	return LLM_Menu_RunBackendLifecycle(Intent, Port)
}

LLM_Menu_RunBackendLifecycle(Intent, Port := 0) {
	global _LLM_Menu
	if !_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent)
		return false
	if !Intent["enabled"]
		return false
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return false
	}
	_LLM_Menu["bootstrap_pending"] := false
	if Intent["backend"] == "api" {
		if !_LLM_Menu_BackendLifecycleCall(Port, "cancel_ollama") {
			try LoggerError("LLM", "Remote API lifecycle refused to start because Ollama ownership could not be retired.")
			_LLM_Menu_BackendLifecycleCall(Port, "stop_bridge")
			return false
		}
		if !_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent)
			return false
		if !_LLM_Menu_BackendLifecycleCall(Port, "validate_api") {
			try LoggerError("LLM", "Remote API lifecycle admission refused the selected API entry.")
			_LLM_Menu_BackendLifecycleCall(Port, "stop_bridge")
			return false
		}
		return _LLM_Menu_BackendLifecycleCall(Port, "start_bridge") ? true : false
	}
	if Intent["backend"] != "ollama" {
		try LoggerError("LLM", "Backend lifecycle refused unsupported backend '{1}'.", Intent["backend"])
		return false
	}
	return LLM_Menu_BootstrapOllama(Intent["show_ui"], Port, Intent)
}

LLM_Menu_BootstrapOllama(ShowUi := true, Port := 0, Intent := 0) {
	global _LLM_Menu
	if !(Intent is Map)
		Intent := _LLM_Menu_CaptureBackendLifecycleIntent(ShowUi)
	if !_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent)
		return false
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return false
	}
	_LLM_Menu["bootstrap_pending"] := false
	if _LLM_Menu_BackendLifecycleCall(Port, "deps_ready")
		return LLM_Menu_OnDepsReady(Intent, Port)
	OnReady := (*) => LLM_Menu_OnDepsReady(Intent, Port)
	OnFailed := (Message) => LLM_Menu_OnDepsFailed(Message, Intent, Port)
	_LLM_Menu_BackendLifecycleCall(Port, "deps_check",
		Intent["model"], OnReady, OnFailed, ShowUi)
	return true
}

LLM_Menu_OnDepsReady(Intent := 0, Port := 0) {
	global _LLM_Menu
	if !(Intent is Map)
		Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	if !_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent)
		return false
	if Intent["backend"] != "ollama" || !Intent["enabled"]
		return false
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return false
	}
	_LLM_Menu_BackendLifecycleCall(Port, "menu_build")
	if !_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent)
		return false
	if !_LLM_Menu_BackendLifecycleCall(Port, "start_bridge")
		return false
	_LLM_Menu_BackendLifecycleCall(Port, "warmup")
	return true
}

LLM_Menu_OnDepsFailed(Message, Intent := 0, Port := 0) {
	global _LLM_Menu
	if !(Intent is Map)
		Intent := _LLM_Menu_CaptureBackendLifecycleIntent(false)
	if !_LLM_Menu_BackendLifecycleIntentIsCurrent(Intent)
		return false
	if Intent["backend"] != "ollama" || !Intent["enabled"]
		return false
	if A_IsSuspended {
		_LLM_Menu["bootstrap_pending"] := true
		return false
	}
	_LLM_Menu_BackendLifecycleCall(Port, "deps_failed", Message)
	return true
}

_LLM_Menu_WarmCurrentOllamaModel() {
	global _LLM_Menu, _LLM_Ollama_IsReady
	if _LLM_Menu.Get("model", "") == "" {
		_LLM_Ollama_IsReady := true
		return true
	}
	_LLM_Ollama_IsReady := false
	LLM_OllamaScheduleWarmupRetry(_LLM_Menu["model"])
	return true
}

_LLM_Menu_ApplyCurrentDepsFailure(*) {
	global _LLM_Menu
	_LLM_Menu["enabled"] := false
	LLM_Menu_Build()
	return true
}

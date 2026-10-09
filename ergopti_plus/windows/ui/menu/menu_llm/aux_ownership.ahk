; ui/menu/menu_llm/aux_ownership.ahk

; ==============================================================================
; MODULE: LLM auxiliary publication ownership
; DESCRIPTION:
; Defines the short, definitions-only commit boundaries for health, installed
; tags, and model-delete completions. The curl/WinHTTP transports own resource
; cleanup; these functions own the exact menu/cache generation that may publish.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLM_Menu_BeginOllamaAux(Kind, Identity := "") {
	global LLM_OLLAMA_BASE_URL
	return LLM_AuxBegin(Kind, Map(
		"backend", "ollama",
		"endpoint", LLM_OLLAMA_BASE_URL,
		"identity", Identity))
}

_LLM_Menu_AuxOwnerIsCurrent(Owner, Backend := "ollama") {
	global _LLM_Menu
	if !LLM_AuxIsCurrent(Owner) || A_IsSuspended
		return false
	if !(_LLM_Menu is Map) || !_LLM_Menu.Get("enabled", false)
		return false
	return _LLM_Menu.Get("backend", "") == Backend
}

_LLM_Menu_DeleteOwnerIsCurrent(Owner) {
	global _LLM_Menu
	return LLM_AuxIsCurrent(Owner)
		&& _LLM_Menu is Map
		&& _LLM_Menu.Get("backend", "") == "ollama"
}

_LLM_Menu_RecordDeleteReconcile(Owner, Name, Tag) {
	global _LLM_Menu_DeleteReconcilePending
	if !(Owner is Map) || !Owner.Has("token")
		return false
	PreviousCritical := Critical("On")
	try _LLM_Menu_DeleteReconcilePending[Owner["token"]] := Map(
		"name", Name, "tag", Tag, "has_result", false, "ok", false)
	finally Critical(PreviousCritical)
	return true
}

_LLM_Menu_UpdateDeleteReconcile(Owner, Ok) {
	global _LLM_Menu_DeleteReconcilePending
	if !(Owner is Map) || !Owner.Has("token")
		return false
	Token := Owner["token"]
	if !_LLM_Menu_DeleteReconcilePending.Has(Token)
		return false
	Pending := _LLM_Menu_DeleteReconcilePending[Token]
	Pending["has_result"] := true
	Pending["ok"] := !!Ok
	return true
}

_LLM_Menu_ClearDeleteReconcile(Owner) {
	global _LLM_Menu_DeleteReconcilePending
	if !(Owner is Map) || !Owner.Has("token")
		return false
	Token := Owner["token"]
	if !_LLM_Menu_DeleteReconcilePending.Has(Token)
		return false
	_LLM_Menu_DeleteReconcilePending.Delete(Token)
	return true
}

_LLM_Menu_ServiceDeleteReconcile(BuildFn := 0, WarnFn := 0) {
	global _LLM_Menu_DeleteReconcilePending, _LLM_InstalledTagsCacheAt
	if A_IsSuspended
		return false
	PreviousCritical := Critical("On")
	try {
		if _LLM_Menu_DeleteReconcilePending.Count == 0
			return false
		Pending := _LLM_Menu_DeleteReconcilePending
		_LLM_Menu_DeleteReconcilePending := Map()
		_LLM_InstalledTagsCacheAt := 0
	} finally Critical(PreviousCritical)
	for _, Record in Pending {
		if !Record["has_result"] || Record["ok"]
			continue
		if HasMethod(WarnFn, "Call")
			WarnFn.Call(Record["name"], Record["tag"])
		else
			try LoggerWarn("LLM",
				"Model cache delete failed for '{1}' (tag '{2}').",
				Record["name"], Record["tag"])
	}
	_LLM_Menu_AuxBuild(BuildFn)
	return true
}

_LLM_Menu_AuxBuild(BuildFn := 0) {
	if HasMethod(BuildFn, "Call") {
		if A_IsSuspended
			return false
		return BuildFn.Call()
	}
	return LLM_Menu_RequestBuild("aux_completion")
}

_LLM_Menu_ResetOllamaAuxState(*) {
	global _LLM_Menu, _LLM_InstalledTagsCache, _LLM_InstalledTagsCacheAt
	global _LLM_Menu_DeleteReconcilePending
	_LLM_InstalledTagsCache := []
	_LLM_InstalledTagsCacheAt := 0
	_LLM_Menu_DeleteReconcilePending := Map()
	if _LLM_Menu is Map {
		_LLM_Menu["last_health_probe_tick"] := 0
		_LLM_Menu["last_health_status"] := ""
	}
	return true
}

_LLM_Menu_PrepareOllamaPortCandidate(Candidate, StopGenerationFn := 0,
		InvalidateFn := 0, CancelFn := 0) {
	if !(Candidate is Map) || !Candidate.Has("ollama_port")
			|| !LLM_Option_TryNormalizeOllamaPort(
				Candidate["ollama_port"], &NormalizedPort)
		return false
	Candidate["ollama_port"] := NormalizedPort
	try {
		if HasMethod(StopGenerationFn, "Call")
			StopGenerationFn.Call()
		else
			LLM_Engine_StopGeneration()
	} catch {
		return false
	}
	if HasMethod(InvalidateFn, "Call")
		InvalidateFn.Call(false)
	else
		LLM_Menu_BackendLifecycleInvalidate(false)
	Cancelled := HasMethod(CancelFn, "Call")
		? CancelFn.Call() : LLM_Menu_CancelOllamaOwnership()
	if !Cancelled
		return false
	return Map("ollama_port", Candidate["ollama_port"])
}

_LLM_Menu_PublishOllamaPortCandidate(CandidateFeatures, CandidateMenu,
		PreparedOwner) {
	if !(PreparedOwner is Map) || !PreparedOwner.Has("ollama_port")
			|| !(CandidateMenu is Map) || !CandidateMenu.Has("ollama_port")
			|| PreparedOwner["ollama_port"] != CandidateMenu["ollama_port"]
		return false
	return _LLM_Menu_PublishCandidate(CandidateFeatures, CandidateMenu)
}

_LLM_Menu_PublishApiEntriesCandidate(CandidateFeatures, CandidateMenu,
		PublishFn := 0) {
	; Retire every validation receipt in the same publication call that makes
	; the new entry graph observable. The API transaction runs non-Critical, so
	; doing this later in ApplyFn leaves a stale-notification interleaving.
	LLM_AuxRetirePrefix("api_validation:")
	if HasMethod(PublishFn, "Call")
		return PublishFn.Call(CandidateFeatures, CandidateMenu)
	return _LLM_Menu_PublishCandidate(CandidateFeatures, CandidateMenu)
}

_LLM_Menu_OnHealthProbeDone(reachable, Owner := 0, BuildFn := 0) {
	global _LLM_Menu
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_AuxOwnerIsCurrent(Owner)
			return false
		Previous := _LLM_Menu.Get("last_health_status", "")
		NewStatus := reachable ? "ok" : "ko"
		_LLM_Menu["last_health_status"] := NewStatus
		Changed := Previous != NewStatus
		if !LLM_AuxFinish(Owner)
			return false
	} finally Critical(PreviousCritical)
	if Changed
		_LLM_Menu_AuxBuild(BuildFn)
	return true
}

_LLM_Menu_OnInstalledTagsProbeDone(tags, Owner := 0, BuildFn := 0) {
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_AuxOwnerIsCurrent(Owner)
			return false
		WasReady := LLM_InstalledTagsCacheReady()
		Previous := _LLM_GetInstalledTagsCached()
		Current := IsSet(tags) && (tags is Array) ? tags : []
		LLM_SetInstalledTagsCache(Current)
		Changed := _LLM_InstalledTagsListChanged(Previous, Current)
		MustResumeBridge := !WasReady
		if !LLM_AuxFinish(Owner)
			return false
	} finally Critical(PreviousCritical)
	if MustResumeBridge {
		if IsSet(LLM_Menu_EnsureModelReady)
			LLM_Menu_EnsureModelReady()
		if IsSet(LLM_Menu_TryStartBridge)
			LLM_Menu_TryStartBridge()
	}
	if Changed
		_LLM_Menu_AuxBuild(BuildFn)
	return true
}

_LLM_Menu_OnDeleteCachedModelDone(name, tag, ok, Owner := 0,
		BuildFn := 0, WarnFn := 0) {
	global _LLM_InstalledTagsCacheAt
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_DeleteOwnerIsCurrent(Owner)
			return false
		_LLM_InstalledTagsCacheAt := 0
		_LLM_Menu_UpdateDeleteReconcile(Owner, ok)
		if !LLM_AuxFinish(Owner)
			return false
	} finally Critical(PreviousCritical)
	if A_IsSuspended
		return true
	_LLM_Menu_ClearDeleteReconcile(Owner)
	if !ok {
		if HasMethod(WarnFn, "Call")
			WarnFn.Call(name, tag)
		else
			try LoggerWarn("LLM", "Model cache delete failed for '{1}' (tag '{2}').", name, tag)
	}
	_LLM_Menu_AuxBuild(BuildFn)
	return true
}

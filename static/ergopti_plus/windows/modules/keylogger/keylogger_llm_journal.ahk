; modules/keylogger/keylogger_llm_journal.ahk

; ==============================================================================
; MODULE: Keylogger - Atomic LLM Output Journal
; DESCRIPTION:
; Prepares privacy-filtered completion rows off-thread and commits them to the
; canonical RAM queue inside TextSender's output transaction.
; ==============================================================================

#Requires AutoHotkey v2.0+

_KL_EmptyPreparedLlmJournal() {
	return Map("entries", [])
}

_KL_CaptureLlmJournalPrivacy() {
	return Map(
		"focus_generation", MetricsFocusCache.generation,
		"disabled_apps_ptr", ObjPtr(MetricsFilters.disabled_apps),
		"private_browsing", MetricsFilters.private_browsing,
		"secure_field", MetricsFilters.secure_field,
		"system_auth", MetricsFilters.system_auth,
		"password_generation", KLPasswordCache.generation
	)
}

_KL_LlmJournalPrivacyStillCurrent(Expected) {
	if !(Expected is Map)
		return false
	try {
		return (Expected.Get("focus_generation", -1) = MetricsFocusCache.generation
			&& Expected.Get("disabled_apps_ptr", 0) = ObjPtr(MetricsFilters.disabled_apps)
			&& Expected.Get("private_browsing", "") = MetricsFilters.private_browsing
			&& Expected.Get("secure_field", "") = MetricsFilters.secure_field
			&& Expected.Get("system_auth", "") = MetricsFilters.system_auth
			&& Expected.Get("password_generation", -1) = KLPasswordCache.generation)
	}
	return false
}

KL_PrepareLlmOutputJournal(Descriptor, PublishGuard := unset) {
	if !(Descriptor is Map)
		throw TypeError("LLM output journal descriptor must be a Map.")
	if !Keylogger.initialized
		return _KL_EmptyPreparedLlmJournal()
	if A_IsSuspended || Keylogger._shutting_down
		return _KL_EmptyPreparedLlmJournal()

	SourceHwnd := Descriptor.Get("source_hwnd", 0)
	Prediction := Descriptor.Get("prediction", "")
	if !(SourceHwnd is Integer) || SourceHwnd <= 0 || !(Prediction is String)
		throw ValueError("LLM output journal requires a target HWND and string prediction.")

	Focus := MetricsFocusCache.state
	if !(Focus.hwnd is Integer) || Focus.hwnd != SourceHwnd
		return _KL_EmptyPreparedLlmJournal()
	try {
		if MF_ShouldFilter() || MF_ShouldFilterFor(Focus.process_name, Focus.title)
			return _KL_EmptyPreparedLlmJournal()
	} catch as Err {
		throw Error("LLM output privacy classification failed: " . Err.Message)
	}

	FlushDeferred := false
	if IsSet(PublishGuard)
		KL_FlushBuffer(PublishGuard, &FlushDeferred)
	else
		KL_FlushBuffer(, &FlushDeferred)

	Focus := MetricsFocusCache.state
	if !(Focus.hwnd is Integer) || Focus.hwnd != SourceHwnd
		return _KL_EmptyPreparedLlmJournal()
	try {
		if MF_ShouldFilter() || MF_ShouldFilterFor(Focus.process_name, Focus.title)
			return _KL_EmptyPreparedLlmJournal()
	} catch as Err {
		throw Error("LLM output privacy reclassification failed: " . Err.Message)
	}

	AllPredictions := Descriptor.Get("all_predictions", "")
	if !(AllPredictions is Array)
		AllPredictions := [Prediction]
	else
		AllPredictions := AllPredictions.Clone()
	ChosenIndex := Descriptor.Get("chosen_index", 1)
	if !(ChosenIndex is Integer)
		ChosenIndex := 1
	Deletes := Descriptor.Get("deletes", 0)
	if !(Deletes is Integer)
		Deletes := 0
	Deletes := Max(0, Deletes)
	LogicalLength := KLW_StringToLogicalCharacters(Prediction).Length
	Timestamp := KL_NowTimestamp()
	Entries := []
	if Descriptor.Get("include_suggested", false) {
		Entries.Push(Map(
			"type", "llm_suggested", "timestamp", Timestamp,
			"app", Focus.process_name, "title", Focus.title,
			"count", AllPredictions.Length
		))
	}
	Entries.Push(Map(
		"type", "llm_accepted", "timestamp", Timestamp,
		"app", Focus.process_name, "title", Focus.title,
		"prediction", Prediction, "all_predictions", AllPredictions,
		"chosen_index", ChosenIndex, "deletes", Deletes,
		"deleted_text", Descriptor.Get("deleted_text", ""),
		"net_saved_chars", LogicalLength - Deletes,
		"context", KLWConst.LLM_ACCEPTED_METRICS_SOURCE
	))
	return Map(
		"entries", Entries,
		"lifecycle_generation", Keylogger.lifecycle_generation,
		"privacy", _KL_CaptureLlmJournalPrivacy()
	)
}

KL_CommitPreparedLlmOutputJournal(Token) {
	if !A_IsCritical
		throw Error("LLM output journal commit requires a Critical transaction.")
	if !(Token is Map)
		return false
	Entries := Token.Get("entries", "")
	if !(Entries is Array) || Entries.Length = 0
		return true
	if (!Keylogger.initialized || Keylogger._shutting_down || A_IsSuspended
			|| Token.Get("lifecycle_generation", -1) != Keylogger.lifecycle_generation
			|| !_KL_LlmJournalPrivacyStillCurrent(Token.Get("privacy", 0)))
		return false

	for _, Entry in Entries {
		Entry["_event_id"] := KL_AllocEventId()
		Keylogger._pending_entries.Push(Entry)
	}
	return true
}

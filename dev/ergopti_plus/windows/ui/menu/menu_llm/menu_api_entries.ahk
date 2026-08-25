; ui/menu/menu_llm/menu_api_entries.ahk

; ==============================================================================
; MODULE: LLM Tray — Remote API entries
; DESCRIPTION:
; Manages the user-defined list of remote API endpoints (OpenAI, Anthropic,
; Google Gemini, OpenAI-compatible). When backend = "api", the model picker
; becomes an "API endpoints" picker built from this list. Includes the
; create/edit dialog flow, the JSON persistence layer (api_entries.json
; alongside config.toml), DPAPI token encryption, and complete schema
; validation before publication.
;
; FEATURES & RATIONALE:
; 1. Separate JSON file: the array-of-maps schema would be mangled by the
;    project's flat-TOML writer; api_entries.json sidesteps the round-trip.
; 2. Full JSON parse: the shared recursive parser preserves braces and escaped
;    strings while rejecting malformed, non-array, partial, or trailing input.
; 3. DPAPI token encryption: tokens land in api_entries.json prefixed with
;    ``dpapi:`` so the loader can detect encrypted blobs; legacy plaintext
;    entries get encrypted on the first save after this build lands.
; 4. Token validation round-trip: after every save, hit the provider's
;    /models endpoint and surface success/failure via TrayTip so the user
;    finds out NOW (not mid-typing).
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ API Entries Submenu =======
; ======================================
; ======================================

; Build the "API endpoints" submenu shown when backend == "api". When the user
; has no entries yet, the menu carries a single greyed-out hint plus the
; "+ Add" action so the next click takes them straight to the entry dialog.
_LLM_Menu_BuildApiEntriesMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_model", (*) => _LLM_Menu_ApiEntriesRows())
	return m
}

; The same list as row DATA. It stands in for the model picker's rows when the
; backend is remote, which is why it renders under that same list id.
_LLM_Menu_ApiEntriesRows() {
	global _LLM_Menu
	Rows := []
	entries := _LLM_Menu["api_entries"]
	if (Type(entries) != "Array" or entries.Length == 0) {
		Rows.Push(Map("label", t("menu.llm.api_no_entry")))
	} else {
		active_id := _LLM_Menu.Has("api_entry_id") ? _LLM_Menu["api_entry_id"] : ""
		for entry in entries {
			id    := _LLM_MenuApiEntryGet(entry, "Id",       "")
			name  := _LLM_MenuApiEntryGet(entry, "Name",     "(unnamed)")
			prov  := _LLM_MenuApiEntryGet(entry, "Provider", "")
			model := _LLM_MenuApiEntryGet(entry, "Model",    "")
			suffix := (model != "" and prov != "") ? "  —  " . prov . " / " . model
				: (model != "") ? "  —  " . model
				: (prov  != "") ? "  —  " . prov
				: ""
			Rows.Push(Map(
				"label",   name . suffix,
				"checked", (id == active_id),
				"action",  _LLM_Menu_MakeSelectApiEntryHandler(entry)))
		}
	}
	Rows.Push(Map("separator", true))
	Rows.Push(Map("label", t("menu.llm.api_add_entry"), "action", (*) => _LLM_Menu_PromptApiEntry("")))
	if (Type(entries) == "Array" and entries.Length > 0) {
		Rows.Push(Map(
			"label",  t("menu.llm.api_edit_entry"),
			"action", (*) => _LLM_Menu_PromptApiEntry(_LLM_Menu["api_entry_id"])))
		Rows.Push(Map(
			"label",  t("menu.llm.api_remove_entry"),
			"action", (*) => _LLM_Menu_RemoveActiveApiEntry()))
	}
	return Rows
}

_LLM_MenuApiEntryGet(Entry, Key, Default := "") {
	if (Entry is Map) {
		return Entry.Has(Key) ? Entry[Key] : Default
	}
	try {
		return Entry.%Key%
	} catch {
		return Default
	}
}

_LLM_Menu_SelectApiEntry(Entry) {
	EntryId := _LLM_MenuApiEntryGet(Entry, "Id", "")
	if !(EntryId is String) || EntryId == ""
		return false
	return LLM_Menu_CommitMutation("the active LLM API entry",
		(Candidate) => _LLM_Menu_SelectApiEntryCandidate(Candidate, EntryId),
		_LLM_Menu_ApplyApiEntriesCommitted)
}

_LLM_Menu_SelectApiEntryCandidate(Candidate, EntryId) {
	if !(Candidate is Map) || !Candidate.Has("api_entries")
			|| !(Candidate["api_entries"] is Array)
			|| !_LLM_Menu_ApiEntryIdsAreUnique(Candidate["api_entries"])
		return false
	if (_LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], EntryId) != 1)
		return false
	Candidate["api_entry_id"] := EntryId
	return true
}


_LLM_Menu_ApiEntryIdCount(Entries, EntryId) {
	if !(Entries is Array) || !(EntryId is String) || EntryId == ""
		return 0
	Matches := 0
	for Entry in Entries {
		if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId
			Matches += 1
	}
	return Matches
}


_LLM_Menu_ApiEntryIdsAreUnique(Entries) {
	if !(Entries is Array)
		return false
	Seen := Map()
	for Entry in Entries {
		EntryId := _LLM_MenuApiEntryGet(Entry, "Id", "")
		if !(EntryId is String) || Trim(EntryId) == "" || Seen.Has(EntryId)
			return false
		Seen[EntryId] := true
	}
	return true
}





; ==========================================
; ==========================================
; ======= 2/ Create/Edit Dialog Flow =======
; ==========================================
; ==========================================

; Open the create/edit dialog for an API entry. When ``EditId`` is empty, the
; dialog creates a new entry; otherwise it loads the matching record and
; updates it in place. The dialog stays InputBox-driven (one field per call)
; so it works on the AHK v2 baseline with no custom Gui — same UX as the
; existing single-field prompts the menu already uses.
_LLM_Menu_BuildApiProviderChoices(providers) {
	choices := ""
	for providerId, descriptor in providers {
		if !(descriptor is Map) or !descriptor.Has("Label") or Type(descriptor["Label"]) != "String"
			throw Error("API provider catalogue published an invalid menu descriptor: " . providerId)
		choices .= providerId . " (" . descriptor["Label"] . "), "
	}
	return RTrim(choices, ", ")
}


_LLM_Menu_PromptApiEntry(EditId) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_Menu_PromptApiEntry(EditId)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu, LLM_API_PROVIDERS
	existing := ""
	if (EditId != "") {
		for e in _LLM_Menu["api_entries"] {
			if (_LLM_MenuApiEntryGet(e, "Id", "") == EditId) {
				existing := e
				break
			}
		}
	}

	; Step 1 — friendly name.
	def_name := existing != "" ? _LLM_MenuApiEntryGet(existing, "Name", "") : ""
	ib := InputBox(t("menu.llm.api_prompt_name"), t("menu.llm.api_dialog_title"),
		"w420 h130", def_name)
	if (ib.Result != "OK" or Trim(ib.Value) == "")
		return
	new_name := Trim(ib.Value)

	; Step 2 — provider id.
	provider_choices := _LLM_Menu_BuildApiProviderChoices(LLM_API_PROVIDERS)
	def_provider := existing != "" ? _LLM_MenuApiEntryGet(existing, "Provider", "openai") : "openai"
	ib := InputBox(
		Format(t("menu.llm.api_prompt_provider"), provider_choices),
		t("menu.llm.api_dialog_title"), "w520 h150", def_provider)
	if (ib.Result != "OK")
		return
	provider_id := Trim(ib.Value)
	if !LLM_API_PROVIDERS.Has(provider_id)
		provider_id := "openai_compat"
	; The coerced fallback is not guaranteed to exist: when api_providers.json is
	; missing, corrupt or has a malformed entry, api_remote.ahk resets
	; LLM_API_PROVIDERS to an empty Map — the backend is silently disabled but
	; "api" is still offered in the menu. Indexing an empty Map THROWS in AHK v2,
	; so this path crashed instead of explaining itself.
	if !LLM_API_PROVIDERS.Has(provider_id) {
		try LoggerError("LLM.menu",
			"Cannot add an API entry: the provider catalogue is empty (api_providers.json failed to load).")
		try MsgBox(t("menu.llm.api_providers_unavailable"), t("menu.llm.api_dialog_title"), "Iconx")
		return
	}
	provider := LLM_API_PROVIDERS[provider_id]

	; Step 3 — base URL (prefilled with the provider default).
	def_url := existing != "" ? _LLM_MenuApiEntryGet(existing, "BaseUrl", "") : provider["BaseUrl"]
	ib := InputBox(t("menu.llm.api_prompt_url"), t("menu.llm.api_dialog_title"),
		"w520 h130", def_url)
	if (ib.Result != "OK")
		return
	new_url := Trim(ib.Value)

	; Step 4 — token. InputBox does not natively mask, so we use the Hide
	; flag (HIDE) so the cleartext doesn't sit on screen / clipboard.
	def_token := existing != "" ? _LLM_MenuApiEntryGet(existing, "Token", "") : ""
	ib := InputBox(t("menu.llm.api_prompt_token"), t("menu.llm.api_dialog_title"),
		"w520 h130 Password", def_token)
	if (ib.Result != "OK")
		return
	new_token := ib.Value   ; do NOT Trim — leading/trailing chars are part of the secret

	; Step 5 — model.
	def_model := existing != "" ? _LLM_MenuApiEntryGet(existing, "Model", "") : provider["DefaultModel"]
	ib := InputBox(t("menu.llm.api_prompt_model"), t("menu.llm.api_dialog_title"),
		"w420 h130", def_model)
	if (ib.Result != "OK" or Trim(ib.Value) == "")
		return
	new_model := Trim(ib.Value)

	; Persist.
	new_entry := Map(
		"Id",       existing != "" ? _LLM_MenuApiEntryGet(existing, "Id", _LLM_Menu_NewApiId()) : _LLM_Menu_NewApiId(),
		"Name",     new_name,
		"Provider", provider_id,
		"BaseUrl",  new_url,
		"Token",    new_token,
		"Model",    new_model
	)
	Committed := LLM_Menu_CommitApiEntriesMutation(
		(existing != "") ? "the LLM API-entry edit"
			: "the LLM API-entry creation",
		(Candidate) => _LLM_Menu_UpsertApiEntryCandidate(Candidate,
			new_entry, EditId), _LLM_Menu_ApplyApiEntriesCommitted)
	if !Committed
		return false

	; Token validation: hit the provider's /models endpoint once with the
	; freshly-saved credentials so the user finds out NOW (with an explicit
	; TrayTip) instead of mid-typing with an empty tooltip and no idea why.
	; This MUST be async: the synchronous LLM_RemoteIsReady ran a blocking
	; WinHTTP GET on the main thread, freezing the whole driver (and dropping
	; the user's next keystrokes via LowLevelHooksTimeout) for up to 2 s when
	; the BaseUrl was unreachable. LLM_RemoteIsReady_Async polls instead, so
	; the save path returns immediately and the result is surfaced from the
	; poll callback once it resolves.
	ValidationOwner := LLM_AuxBegin("api_validation:" . new_entry["Id"], Map(
		"backend", "api",
		"endpoint", new_entry["BaseUrl"],
		"identity", new_entry["Id"]))
	try LLM_RemoteIsReady_Async(new_entry,
		_LLM_Menu_MakeApiValidationHandler(new_name, new_entry["Id"],
			ValidationOwner), ValidationOwner)
	catch as Err {
		LLM_AuxFinish(ValidationOwner)
		try LoggerError("LLM", "Remote API validation dispatch failed: {1}.", Err.Message)
	}
	return true
}

_LLM_Menu_UpsertApiEntryCandidate(Candidate, NewEntry, EditId) {
	if !(Candidate is Map) || !Candidate.Has("api_entries")
			|| !(Candidate["api_entries"] is Array)
			|| !_LLM_Menu_ApiEntryIdsAreUnique(Candidate["api_entries"])
			|| !_LLM_Menu_ApiEntryFieldsAreSafe(NewEntry)
			|| Trim(NewEntry["Id"]) == ""
		return false
	if EditId != "" {
		if (_LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], EditId) != 1)
			return false
		if (NewEntry["Id"] != EditId
				&& _LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], NewEntry["Id"]) != 0)
			return false
		for Index, Entry in Candidate["api_entries"] {
			if _LLM_MenuApiEntryGet(Entry, "Id", "") == EditId {
				Candidate["api_entries"][Index] := LLM_Menu_DeepClone(NewEntry)
				Candidate["api_entry_id"] := NewEntry["Id"]
				return true
			}
		}
		return false
	}
	if (_LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], NewEntry["Id"]) != 0)
		return false
	Candidate["api_entries"].Push(LLM_Menu_DeepClone(NewEntry))
	Candidate["api_entry_id"] := NewEntry["Id"]
	return true
}

; Builds the async validation callback for an API save. The stable entry id and
; exact auxiliary owner prevent a later edit/delete/backend change from
; relabelling or publishing this completion.
_LLM_Menu_MakeApiValidationHandler(Name, EntryId, Owner) {
	return (reachable) => _LLM_Menu_OnApiValidationDone(
		reachable, Name, EntryId, Owner)
}

_LLM_Menu_OnApiValidationDone(reachable, Name, EntryId, Owner, NotifyFn := 0) {
	global _LLM_Menu
	PreviousCritical := Critical("On")
	try {
		if !LLM_AuxIsCurrent(Owner) || A_IsSuspended
			return false
		if !(_LLM_Menu is Map) || !_LLM_Menu.Get("enabled", false)
				|| _LLM_Menu.Get("backend", "") != "api"
			return false
		Matches := 0
		CurrentName := Name
		for Entry in _LLM_Menu.Get("api_entries", []) {
			if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId {
				Matches += 1
				CurrentName := _LLM_MenuApiEntryGet(Entry, "Name", Name)
			}
		}
		if Matches != 1 || !LLM_AuxFinish(Owner)
			return false
		if HasMethod(NotifyFn, "Call") {
			NotifyFn.Call(reachable ? true : false, CurrentName)
		} else if reachable {
			TrayTip(StrReplace(t("menu.llm.api_validated_body"), "%s", CurrentName),
				t("menu.llm.api_validated_title"), "Iconi")
		} else {
			TrayTip(StrReplace(t("menu.llm.api_unreachable_body"), "%s", CurrentName),
				t("menu.llm.api_unreachable_title"), "Icon!")
		}
		return true
	} finally Critical(PreviousCritical)
}

_LLM_Menu_RemoveActiveApiEntry() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_Menu_RemoveActiveApiEntry()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	active_id := _LLM_Menu["api_entry_id"]
	if (active_id == "")
		return
	; Confirm before destroying the entry — the saved token is gone for
	; good once we delete it. Worth one extra click, especially because
	; the user is one stray click away in a small menu.
	active_entry := ""
	for e in _LLM_Menu["api_entries"] {
		if (_LLM_MenuApiEntryGet(e, "Id", "") == active_id) {
			active_entry := e
			break
		}
	}
	entry_name := _LLM_MenuApiEntryGet(active_entry, "Name", active_id)
	confirm := MsgBox(
		StrReplace(t("menu.llm.api_remove_confirm_body"), "%s", entry_name),
		t("menu.llm.api_remove_confirm_title"),
		"4 48"  ; Yes/No + warning icon
	)
	if (confirm != "Yes")
		return
	return LLM_Menu_CommitApiEntriesMutation("the LLM API-entry removal",
		(Candidate) => _LLM_Menu_RemoveApiEntryCandidate(Candidate, active_id),
		_LLM_Menu_ApplyApiEntriesCommitted)
}

_LLM_Menu_RemoveApiEntryCandidate(Candidate, EntryId) {
	if !(Candidate is Map) || !Candidate.Has("api_entries")
			|| !(Candidate["api_entries"] is Array)
			|| !_LLM_Menu_ApiEntryIdsAreUnique(Candidate["api_entries"])
			|| _LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], EntryId) != 1
		return false
	Kept := []
	Removed := 0
	for Entry in Candidate["api_entries"] {
		if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId {
			Removed += 1
			continue
		}
		Kept.Push(Entry)
	}
	if (Removed != 1)
		return false
	Candidate["api_entries"] := Kept
	Candidate["api_entry_id"] := (Kept.Length > 0)
		? _LLM_MenuApiEntryGet(Kept[1], "Id", "")
		: ""
	return true
}

; Heuristic: does the active model name suggest a built-in chain-of-thought
; ("thinking" / "reasoning" / DeepSeek's -r1 suffix)? Mirrors HS's
; ui/menu/menu_llm/models_manager.lua is_thinking check so both drivers
; flag the same model set without a shared metadata table.
_LLM_Menu_IsThinkingModel(model) {
	if (model == "")
		return false
	lower := StrLower(model)
	return InStr(lower, "-r1") > 0
		or InStr(lower, "thinking") > 0
		or InStr(lower, "reasoning") > 0
}

_LLM_Menu_NewApiId() {
	; Tick-based id keeps it monotonic without pulling a UUID lib. Collisions
	; would only happen on two adds within the same millisecond — vanishingly
	; unlikely from a user-driven dialog flow.
	static Sequence := 0
	Sequence += 1
	return "api_" . A_TickCount . "_" . Sequence
}





; ====================================
; ====================================
; ======= 3/ Persistence Layer =======
; ====================================
; ====================================

; Path of the JSON file holding the user's API entries. Lives next to the
; main config.toml so removing the whole config folder wipes API entries
; with everything else. Kept separate from config.toml because the schema
; is a nested array-of-maps that the project's flat-TOML writer would
; mangle.
_LLM_Menu_ApiEntriesPath() {
	global ConfigurationFile
	if !IsSet(ConfigurationFile) or ConfigurationFile == ""
		return ""
	SplitPath(ConfigurationFile, , &ParentDir)
	return ParentDir . "\api_entries.json"
}

_LLM_Menu_ApiEntryFieldsAreSafe(Entry) {
	if !(Entry is Map)
		return false
	for Field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"] {
		if !Entry.Has(Field) || !(Entry[Field] is String)
				|| !_LLMRemote_ConfigScalarIsSafe(Entry[Field])
			return false
	}
	return true
}

; Parses and validates the complete persisted image before any row becomes
; visible. A malformed sibling invalidates the whole authority: publishing a
; prefix would make selection and credential identity depend on parser order.
_LLM_Menu_ParseAndValidateApiEntries(Raw, Providers := unset, DecryptFn := 0) {
	global LLM_API_PROVIDERS
	if !IsSet(Providers)
		Providers := LLM_API_PROVIDERS
	Result := Map("ok", false, "entries", [], "reason", "")
	try Parsed := JsonParse(Raw)
	catch as Err {
		Result["reason"] := "invalid JSON: " . Err.Message
		return Result
	}
	if !(Parsed is Array) {
		Result["reason"] := "the top-level value is not an array"
		return Result
	}
	if !(Providers is Map) {
		Result["reason"] := "the provider catalogue is unavailable"
		return Result
	}
	SeenIds := Map()
	RequiredFields := ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
	for Index, Entry in Parsed {
		if !(Entry is Map) {
			Result["reason"] := "entry " . Index . " is not an object"
			return Result
		}
		for Field in RequiredFields {
			if !Entry.Has(Field) || !(Entry[Field] is String) {
				Result["reason"] := "entry " . Index
					. " has a missing or non-string " . Field . " field"
				return Result
			}
			if !_LLMRemote_ConfigScalarIsSafe(Entry[Field]) {
				Result["reason"] := "entry " . Index
					. " has a control character in " . Field
				return Result
			}
		}
		EntryId := Entry["Id"]
		if Trim(EntryId) == "" {
			Result["reason"] := "entry " . Index . " has an empty Id"
			return Result
		}
		if SeenIds.Has(EntryId) {
			Result["reason"] := "duplicate API entry id '" . EntryId . "'"
			return Result
		}
		ProviderId := Entry["Provider"]
		if Trim(ProviderId) == "" || !Providers.Has(ProviderId) {
			Result["reason"] := "entry " . Index
				. " names unknown provider '" . ProviderId . "'"
			return Result
		}
		Candidate := Map()
		for Field in RequiredFields
			Candidate[Field] := Entry[Field]
		try Candidate["Token"] := HasMethod(DecryptFn, "Call")
			? DecryptFn.Call(Entry["Token"])
			: LLM_ApiToken_Decrypt(Entry["Token"])
		catch as Err {
			Result["reason"] := "entry " . Index
				. " token decryption failed: " . Err.Message
			return Result
		}
		if !(Candidate["Token"] is String) {
			Result["reason"] := "entry " . Index
				. " token decryption returned a non-string value"
			return Result
		}
		if !_LLMRemote_ConfigScalarIsSafe(Candidate["Token"]) {
			Result["reason"] := "entry " . Index
				. " has a control character in decrypted Token"
			return Result
		}
		SeenIds[EntryId] := true
		Result["entries"].Push(Candidate)
	}
	Result["ok"] := true
	return Result
}


_LLM_Menu_ReportApiEntriesLoadFailure(Reason, ReportFn := 0) {
	if HasMethod(ReportFn, "Call") {
		try ReportFn.Call(Reason)
		catch as Err
			try LoggerError("LLM", "API-entry load reporter failed: {1}.", Err.Message)
		return false
	}
	try LoggerError("LLM", "Rejected api_entries.json: {1}.", Reason)
	return false
}


; Read api_entries.json on startup and publish only one completely validated
; authority. A missing file is normal first-run state; unreadable or corrupt
; files are reported and retained byte-for-byte for recovery.
_LLM_Menu_LoadApiEntries(ReadFn := 0, ReportFn := 0, DecryptFn := 0,
		Providers := unset) {
	global _LLM_Menu, LLM_API_PROVIDERS
	if !IsSet(Providers)
		Providers := LLM_API_PROVIDERS
	path := _LLM_Menu_ApiEntriesPath()
	if (path == "" or !FileExist(path))
		return true
	try {
		raw := HasMethod(ReadFn, "Call") ? ReadFn.Call(path)
			: FileRead(path, "UTF-8")
	} catch as Err {
		return _LLM_Menu_ReportApiEntriesLoadFailure(
			"the file could not be read: " . Err.Message, ReportFn)
	}
	Parsed := _LLM_Menu_ParseAndValidateApiEntries(raw, Providers, DecryptFn)
	if !Parsed["ok"]
		return _LLM_Menu_ReportApiEntriesLoadFailure(Parsed["reason"], ReportFn)
	entries := Parsed["entries"]
	_LLM_Menu["api_entries"] := entries
	; Re-anchor the active id only if it still exists; otherwise pick the
	; first entry so a corrupted ``api_entry_id`` does not leave the user
	; with "no active entry" while entries exist on disk.
	active := _LLM_Menu.Has("api_entry_id") ? _LLM_Menu["api_entry_id"] : ""
	if (active != "") {
		found := false
		for e in entries {
			if (e["Id"] == active) {
				found := true
				break
			}
		}
		if !found
			active := ""
	}
	if (active == "" and entries.Length > 0)
		active := entries[1]["Id"]
	_LLM_Menu["api_entry_id"] := active
	return true
}

; Builds the exact api_entries.json image for a detached menu candidate. Token
; encryption therefore happens before the WAL captures either new target; no
; CRUD action ever writes this sibling store independently of config.toml.
_LLM_Menu_SerializeApiEntries(MenuState, EncryptFn := 0) {
	if !(MenuState is Map) || !MenuState.Has("api_entries")
			|| !(MenuState["api_entries"] is Array)
		return false
	entries := MenuState["api_entries"]
	lines := []
	for e in entries {
		fields := []
		for field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"] {
			val := _LLM_MenuApiEntryGet(e, field, "")
			if !(val is String)
				return false
			if (field == "Token" and val != "") {
				val := HasMethod(EncryptFn, "Call")
					? EncryptFn.Call(val) : LLM_ApiToken_Encrypt(val)
				if !(val is String)
					return false
			}
			fields.Push('"' . field . '":"' . _LLM_MenuApiJsonEscape(val) . '"')
		}
		lines.Push("{" . _LLM_MenuJoin(fields, ",") . "}")
	}
	return "[" . _LLM_MenuJoin(lines, ",`n  ") . "]"
}

; Legacy one-file seam retained for focused serializer/write tests only. User
; CRUD actions must use LLM_Menu_CommitApiEntriesMutation so config.toml and
; api_entries.json cannot split. Unlike the former best-effort writer, every
; failure now has a strict false result.
_LLM_Menu_PersistApiEntries(MenuState := 0, WriterFn := 0) {
	PreviousCritical := Critical("Off")
	try return _LLM_Menu_PersistApiEntriesNonCritical(MenuState, WriterFn)
	finally Critical(PreviousCritical)
}

_LLM_Menu_PersistApiEntriesNonCritical(MenuState, WriterFn) {
	global _LLM_Menu
	if !(MenuState is Map)
		MenuState := _LLM_Menu
	path := _LLM_Menu_ApiEntriesPath()
	if (path == "")
		return false
	body := _LLM_Menu_SerializeApiEntries(MenuState)
	if !(body is String)
		return false
	if HasMethod(WriterFn, "Call") {
		try Written := WriterFn.Call(path, body)
		catch as e {
			try LoggerError("LLM", "Failed to persist API entries to '{1}': {2}", path, e.Message)
			return false
		}
		if (Written is Integer) && Written == 1
			return true
		try LoggerError("LLM", "Failed to persist API entries to '{1}': the writer refused the image.", path)
		return false
	}
	; Ensure the parent directory exists before writing — first run on a
	; freshly-checked-out repo would otherwise hit ENOENT.
	SplitPath(path, , &parent)
	if (parent != "" and !DirExist(parent))
		try DirCreate(parent)
	try {
		tmp := path . ".tmp"
		try FileDelete(tmp)
		FileAppend(body, tmp, "UTF-8")
		; FileMove with overwrite=1 is atomic within the same volume — avoids a
		; zero-byte window between FileDelete and FileAppend on crash/power-loss.
		FileMove(tmp, path, 1)
		return true
	} catch as e {
		try LoggerError("LLM", "Failed to persist API entries to '{1}': {2}", path, e.Message)
		return false
	}
}





; ===============================
; ===============================
; ======= 4/ JSON Helpers =======
; ===============================
; ===============================

_LLM_MenuJoin(arr, sep) {
	out := ""
	for i, v in arr
		out .= (i > 1 ? sep : "") . v
	return out
}

_LLM_MenuApiJsonEscape(s) {
	s := StrReplace(s, "\",  "\\")
	s := StrReplace(s, '"',  '\"')
	s := StrReplace(s, "`n", "\n")
	s := StrReplace(s, "`r", "\r")
	s := StrReplace(s, "`t", "\t")
	return s
}

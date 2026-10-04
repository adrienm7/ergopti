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
; 5. Automatic names: every entry reads <provider>/<model>, told apart by host
;    then order when two share it (_shared/lua/llm/api_entry_names.lua, which
;    this file ports). The user no longer types a name (2026-09-30).
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
		Names := _LLM_Menu_ApiEntryNameList(entries)
		for Index, entry in entries {
			id   := _LLM_MenuApiEntryGet(entry, "Id",   "")
			Rows.Push(Map(
				"label",   Names[Index],
				"checked", (id == active_id),
				"action",  _LLM_Menu_MakeSelectApiEntryHandler(entry)))
		}
	}
	; Add sits before the separator so creating an entry is one glance
	; away; the separator only appears with the management rows, never
	; dangling when no entry exists.
	Rows.Push(Map("label", t("menu.llm.api_add_entry"), "action", (*) => _LLM_Menu_PromptApiEntry("")))
	if (Type(entries) == "Array" and entries.Length > 0) {
		; Management rows: most frequent first, destructive delete last.
		Rows.Push(Map("separator", true))
		Commands := Map("api_test_active", (*) => _LLM_Menu_TestActiveApiEntry(),
			"api_remove_active", (*) => _LLM_Menu_RemoveActiveApiEntry())
		Getters := Map("llm_api_active_ready", _LLM_Menu_ActiveApiCommandsReady)
		for Declaration in _MR_GetMenuDef("llm_api_active_commands") {
			; Keep the existing native Edit action immediately before removal.
			if Declaration["id"] == "api_remove_active"
				Rows.Push(Map(
					"label",  t("menu.llm.api_edit_entry"),
					"action", (*) => _LLM_Menu_PromptApiEntry(_LLM_Menu["api_entry_id"])))
			Row := MenuRenderer_CommandRow("llm_api_active_commands", Declaration["id"], Commands, Getters)
			if Row is Map
				Rows.Push(Row)
		}
	}
	return Rows
}

/**
 * Reads the existing active API owner before a retained menu command runs.
 * @returns {Boolean} Whether the current entry is available to the configuration command.
 */
_LLM_Menu_ActiveApiCommandsReady() {
	global _LLM_Menu
	if !_LLM_Menu.Has("api_entry_id") || !(_LLM_Menu["api_entry_id"] is String)
			|| _LLM_Menu["api_entry_id"] == ""
			|| !_LLM_Menu.Has("api_entries") || !(_LLM_Menu["api_entries"] is Array)
		return false
	return _LLM_Menu_ApiEntryIdCount(_LLM_Menu["api_entries"], _LLM_Menu["api_entry_id"]) == 1
}

; The host an entry sends to, with its port, lowercase: "https://api.x.ai/v1"
; gives "api.x.ai". Port of api_entry_names.lua's M.host.
; @param {String} Url The resolved base URL.
; @returns {String} The host, "" when the URL names none.
_LLM_ApiEntryHost(Url) {
	if !(Url is String)
		return ""
	Rest := Trim(Url, " `t`r`n")
	Rest := RegExReplace(Rest, "^[A-Za-z][A-Za-z0-9+.-]*://")
	Rest := RegExReplace(Rest, "^[^/?#@]*@")
	RegExMatch(Rest, "^[^/?#]*", &Found)
	return StrLower(Found[0])
}

; The automatic names of resolved entries, in their order: <provider>/<model>,
; with the host and then the order added where two entries share one. Port of
; api_entry_names.lua's M.names, pinned by api_entry_names_vectors.json.
; @param {Array} Resolved Maps of "provider", "model" and "base_url", resolved
;     as the entries' requests are sent.
; @returns {Array} One name per entry.
_LLM_ApiEntryNames(Resolved) {
	Bases := [], Uses := Map()
	for Entry in Resolved {
		Base := Entry["provider"] . "/" . Entry["model"]
		Bases.Push(Base)
		Uses[Base] := Uses.Get(Base, 0) + 1
	}
	Names := [], Seen := Map()
	for Index, Entry in Resolved {
		Name := Bases[Index]
		if (Uses[Name] > 1) {
			Host := _LLM_ApiEntryHost(Entry["base_url"])
			Key := Name . "`n" . Host
			Seen[Key] := Seen.Get(Key, 0) + 1
			Qualifier := Host
			if (Seen[Key] > 1)
				Qualifier .= ((Qualifier != "") ? ", " : "") . Seen[Key]
			if (Qualifier != "")
				Name .= " (" . Qualifier . ")"
		}
		Names.Push(Name)
	}
	return Names
}

; One entry as its requests are sent: the provider's model and base URL stand
; in for empty fields. The stored Name is never read.
; @param {Map} Entry API entry record.
; @returns {Map} "provider", "model" and "base_url".
_LLM_Menu_ResolveApiEntry(Entry) {
	global LLM_API_PROVIDERS
	ProviderId := _LLM_MenuApiEntryGet(Entry, "Provider", "")
	Descriptor := ((LLM_API_PROVIDERS is Map) && LLM_API_PROVIDERS.Has(ProviderId)
		&& (LLM_API_PROVIDERS[ProviderId] is Map)) ? LLM_API_PROVIDERS[ProviderId] : Map()
	Model := _LLM_MenuApiEntryGet(Entry, "Model", "")
	if (Model == "")
		Model := Descriptor.Get("DefaultModel", "")
	BaseUrl := _LLM_MenuApiEntryGet(Entry, "BaseUrl", "")
	if (BaseUrl == "")
		BaseUrl := Descriptor.Get("BaseUrl", "")
	return Map("provider", ProviderId, "model", Model, "base_url", BaseUrl)
}

; The automatic name of every entry, in the list's order.
; @param {Array} Entries API entry records.
; @returns {Array} One name per entry.
_LLM_Menu_ApiEntryNameList(Entries) {
	Resolved := []
	if (Entries is Array) {
		for Entry in Entries
			Resolved.Push(_LLM_Menu_ResolveApiEntry(Entry))
	}
	return _LLM_ApiEntryNames(Resolved)
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

; Asks whether to probe a just-created entry end to end. Existing locale
; strings only (no new keys): the action label as question, Yes/No buttons.
; Headless-safe: the stubbed MsgBox declines.
; @returns {Boolean} True when the user confirmed.
_LLM_Menu_AskTestNewApiEntry() {
	try return Ui_MsgBox(t("menu.llm.api_test_entry"),
		t("menu.llm.api_window_title"), "YesNo Icon?") == "Yes"
	catch
		return false
}

; Open the create/edit dialog for an API entry. When ``EditId`` is empty, the
; dialog creates a new entry; otherwise it loads the matching record and
; updates it in place. The dialog stays InputBox-driven (one field per call)
; so it works on the AHK v2 baseline with no custom Gui — same UX as the
; existing single-field prompts the menu already uses. It asks no name: the
; entry is named after its provider and model.
; @param {Map} providers Provider id -> descriptor, as the catalogue publishes.
; @param {Array} order The ids in the catalogue's provider_order; 0 lists the
;     Map's own order.
_LLM_Menu_BuildApiProviderChoices(providers, order := 0) {
	choices := ""
	ids := []
	if (order is Array) {
		for providerId in order {
			if !providers.Has(providerId)
				throw Error("API provider order names a provider the catalogue lacks: " . providerId)
			ids.Push(providerId)
		}
	} else {
		for providerId in providers
			ids.Push(providerId)
	}
	for providerId in ids {
		descriptor := providers[providerId]
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
	global _LLM_Menu, LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER, LLM_LOCAL_API_SERVERS
	existing := ""
	if (EditId != "") {
		for e in _LLM_Menu["api_entries"] {
			if (_LLM_MenuApiEntryGet(e, "Id", "") == EditId) {
				existing := e
				break
			}
		}
	}

	; Step 1 — provider id.
	provider_choices := _LLM_Menu_BuildApiProviderChoices(LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER)
	def_provider := existing != "" ? _LLM_MenuApiEntryGet(existing, "Provider", "openai") : "openai"
	ib := Ui_InputBox(
		Format(t("menu.llm.api_prompt_provider"), provider_choices),
		t("menu.llm.api_window_title"), "w520 h150", def_provider)
	if (ib.Result != "OK")
		return
	if LLM_API_PROVIDERS.Count == 0 {
		try LoggerError("LLM.menu",
			"Cannot add an API entry: the provider catalogue is empty (api_providers.json failed to load).")
		try Ui_MsgBox(t("menu.llm.api_providers_unavailable"), t("menu.llm.api_window_title"), "Iconx")
		return
	}
	if !_LLM_Menu_TryProviderPrompt(ib.Result, ib.Value,
			LLM_API_PROVIDERS, &provider_id)
		return
	provider := LLM_API_PROVIDERS[provider_id]

	; Step 2 — base URL (prefilled with the provider default).
	def_url := existing != "" ? _LLM_MenuApiEntryGet(existing, "BaseUrl", "") : provider["BaseUrl"]
	ib := Ui_InputBox(t("menu.llm.api_prompt_url"), t("menu.llm.api_window_title"),
		"w520 h130", def_url)
	if (ib.Result != "OK")
		return
	new_url := Trim(ib.Value)

	; Step 3 — token. InputBox does not natively mask, so we use the Hide
	; flag (HIDE) so the cleartext doesn't sit on screen / clipboard.
	def_token := existing != "" ? _LLM_MenuApiEntryGet(existing, "Token", "") : ""
	KeyPrompt := LocalServerAuthTokenAllowed(provider_id, "", LLM_LOCAL_API_SERVERS)
		? Format(t("dialog.local_servers.key_prompt"), provider["Label"]) : t("menu.llm.api_prompt_token")
	ib := Ui_InputBox(KeyPrompt, t("menu.llm.api_window_title"),
		"w520 h130 Password", def_token)
	if (ib.Result != "OK")
		return
	new_token := ib.Value   ; do NOT Trim — leading/trailing chars are part of the secret

	; Step 4 — model.
	def_model := existing != "" ? _LLM_MenuApiEntryGet(existing, "Model", "") : provider["DefaultModel"]
	ib := Ui_InputBox(t("menu.llm.api_prompt_model"), t("menu.llm.api_window_title"),
		"w420 h130", def_model)
	if !_LLM_Menu_TryRequiredPrompt(ib.Result, ib.Value, &new_model)
		return

	; Persist. Name holds the automatic name only because builds before
	; 2026-10 refuse an entry without one; no build reads it any more.
	new_entry := Map(
		"Id",       existing != "" ? _LLM_MenuApiEntryGet(existing, "Id", _LLM_Menu_NewApiId()) : _LLM_Menu_NewApiId(),
		"Name",     provider_id . "/" . new_model,
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
	new_name := _LLM_Menu_ApiEntryDisplayName(new_entry)

	; Creation only: offer the full end-to-end probe on the just-saved
	; entry, so a bad token or model surfaces here with its server message
	; instead of mid-typing. A declined offer keeps the save. The entry is
	; named: a decisions entry does not become the active one.
	if (EditId == "") {
		try {
			if _LLM_Menu_AskTestNewApiEntry()
				_LLM_Menu_TestActiveApiEntry(0, new_entry["Id"])
		} catch as AskErr {
			try LoggerWarn("LLM", "Post-creation API test skipped: {1}.",
				AskErr.Message)
		}
	}

	; Token validation: hit the provider's /models endpoint once with the
	; freshly-saved credentials so the user finds out NOW (with an explicit
	; TrayTip) instead of mid-typing with an empty tooltip and no idea why.
	; This MUST be async: the synchronous LLM_RemoteIsReady ran a blocking
	; WinHTTP GET on the main thread, freezing the whole driver (and dropping
	; the user's next keystrokes via LowLevelHooksTimeout) for up to 2 s when
	; the BaseUrl was unreachable. LLM_RemoteIsReady_Async polls instead, so
	; the save path returns immediately and the result is surfaced from the
	; poll callback once it resolves.
	if !LLM_RemoteHasReadyPing(provider_id) {
		try LoggerInfo("LLM", "API entry '{1}' saved: {2} has no reachability ping, the Test action probes it.",
			new_name, provider_id)
		return true
	}
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
				if _LLM_Menu_ApiEntryTakesActive(Candidate, NewEntry, EditId)
					Candidate["api_entry_id"] := NewEntry["Id"]
				return true
			}
		}
		return false
	}
	if (_LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], NewEntry["Id"]) != 0)
		return false
	TakesActive := _LLM_Menu_ApiEntryTakesActive(Candidate, NewEntry, "")
	Candidate["api_entries"].Push(LLM_Menu_DeepClone(NewEntry))
	if TakesActive
		Candidate["api_entry_id"] := NewEntry["Id"]
	return true
}

; Tells whether a saved entry becomes the active one, the prediction backend's.
; A decisions entry (TypeSafe's Jev) only lends its key to the agent's System 1
; and cannot answer a prediction: it leaves another active entry in place.
; @param {Map} Candidate The menu candidate, before the entry is added.
; @param {Map} NewEntry The saved entry.
; @param {String} EditId The edited entry's id, "" for a creation.
; @returns {Boolean}
_LLM_Menu_ApiEntryTakesActive(Candidate, NewEntry, EditId) {
	if (LLM_RemoteProviderFormat(NewEntry["Provider"]) != "decisions")
		return true
	Current := Candidate.Get("api_entry_id", "")
	if !(Current is String) || Current == "" || Current == EditId
		return true
	return _LLM_Menu_ApiEntryIdCount(Candidate["api_entries"], Current) != 1
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
		if !(_LLM_Menu is Map) || _LLM_Menu.Get("backend", "") != "api"
			return false
		Matches := 0
		CurrentName := Name
		for Entry in _LLM_Menu.Get("api_entries", []) {
			if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId {
				Matches += 1
				CurrentName := _LLM_Menu_ApiEntryDisplayName(Entry)
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
	entry_name := (active_entry != "") ? _LLM_Menu_ApiEntryDisplayName(active_entry) : active_id
	confirm := Ui_MsgBox(
		t("menu.llm.api_remove_confirm_body"),
		StrReplace(t("menu.llm.api_remove_confirm_title"), "%s", entry_name),
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





; The probe gets its own longer budget: a 30 s prediction timeout cannot
; survive a cold model load, and with a cancellable progress the user — not
; the clock — decides when to give up.
global LLM_API_TEST_TIMEOUT_MS := 120000
; At most one probe progress; a Map without "entry" means nothing is showing.
global _LLM_Menu_ApiTestProgress := Map()

; Pure label for the probe progress: entry name, elapsed whole seconds, and
; the budget — the user sees the limit, never an open-ended wait.
_LLM_Menu_ApiTestProgressText(Name, ElapsedMs, BudgetMs) {
	return Name . " — " . (ElapsedMs // 1000) . " s / "
		. (BudgetMs // 1000) . " s"
}

; Shows the cancellable probe progress immediately at click time. The window
; is modeless (the request runs on timers) with a pulse bar, a live elapsed
; label and a Cancel button. Everything UI is try-wrapped: headless or not,
; the state map is always set so Hide/Cancel stay consistent.
_LLM_Menu_ApiTestProgressShow(EntryId, Name) {
	global _LLM_Menu_ApiTestProgress, LLM_API_TEST_TIMEOUT_MS
	_LLM_Menu_ApiTestProgressHide()
	State := Map("entry", EntryId, "name", Name, "req_id", 0,
		"owner", "", "start", A_TickCount, "budget", LLM_API_TEST_TIMEOUT_MS)
	_LLM_Menu_ApiTestProgress := State
	try {
		Worker := Gui_Create("", t("menu.llm.api_window_title"))
		State["label"] := Worker.Add("Text", "w300",
			_LLM_Menu_ApiTestProgressText(Name, 0, State["budget"]))
		State["bar"] := Worker.Add("Progress", "w300 h16 Range0-100", 0)
		CancelBtn := Worker.Add("Button", "w300", t("common.cancel"))
		CancelBtn.OnEvent("Click",
			(*) => _LLM_Menu_ApiTestProgressCancel())
		Worker.Show("AutoSize Center")
		State["gui"] := Worker
		; Named callback (not a closure) so the fast-timer inventory can pin
		; this 150 ms pulse by name; the tick itself reads the global state.
		SetTimer(_LLM_Menu_ApiTestProgressTick, 150)
	} catch as Err {
		try LoggerWarn("LLM", "API test progress unavailable: {1}.",
			Err.Message)
	}
	return true
}

; Progress tick: fills the bar with the elapsed share of the budget and
; refreshes the label. Never throws into the timer thread; a missing state
; just stops meaning anything.
_LLM_Menu_ApiTestProgressTick(NowTick?) {
	global _LLM_Menu_ApiTestProgress
	if !(_LLM_Menu_ApiTestProgress is Map)
		|| !_LLM_Menu_ApiTestProgress.Has("entry")
		return
	State := _LLM_Menu_ApiTestProgress
	Elapsed := TickElapsed(State["start"], NowTick?)
	Budget := State.Get("budget", 0)
	if State.Has("label")
		try State["label"].Text := _LLM_Menu_ApiTestProgressText(
			State["name"], Elapsed, Budget)
	; Determinate bar: elapsed share of the budget, pinned at full.
	if State.Has("bar")
		try State["bar"].Value := (Budget > 0)
			? Min(100, (Elapsed * 100) // Budget) : 0
}

; Hides the probe progress if one is showing. Silent and total: timer off,
; window destroyed, state cleared.
; @return boolean True when something was showing.
_LLM_Menu_ApiTestProgressHide() {
	global _LLM_Menu_ApiTestProgress
	if !(_LLM_Menu_ApiTestProgress is Map)
		|| !_LLM_Menu_ApiTestProgress.Has("entry")
		return false
	State := _LLM_Menu_ApiTestProgress
	try SetTimer(_LLM_Menu_ApiTestProgressTick, 0)
	if State.Has("gui")
		try State["gui"].Destroy()
	_LLM_Menu_ApiTestProgress := Map()
	return true
}

; User Cancel: aborts the in-flight request, finishes the owner so a late
; completion stays silent, hides the progress. Closing the window IS the
; feedback — no popup for an action the user just chose.
; @return boolean True when a probe was showing.
_LLM_Menu_ApiTestProgressCancel() {
	global _LLM_Menu_ApiTestProgress
	if !(_LLM_Menu_ApiTestProgress is Map)
		|| !_LLM_Menu_ApiTestProgress.Has("entry")
		return false
	State := _LLM_Menu_ApiTestProgress
	ReqId := State.Get("req_id", 0)
	if IsInteger(ReqId) && ReqId > 0
		try LLM_RemoteCancelAsync(ReqId)
	Owner := State.Get("owner", "")
	if Owner != ""
		try LLM_AuxFinish(Owner)
	Name := State.Get("name", "")
	_LLM_Menu_ApiTestProgressHide()
	try LoggerInfo("LLM", "API test for '{1}' cancelled by the user.", Name)
	return true
}





; ======================================
; ======================================
; ======= 2.5/ Test active entry =======
; ======================================
; ======================================

; Surfaces one probe verdict through the injectable seam in tests and through
; a blocking MsgBox in production. A TrayTip proved too easy to miss — a
; clicked Test action must always end in a visible verdict, success or not.
; @return boolean True once the verdict was handed to the seam or MsgBox.
_LLM_Menu_ApiTestSurface(Title, Body, Icon, Ok, NotifyFn := 0) {
	if HasMethod(NotifyFn, "Call") {
		try NotifyFn.Call(Ok, Map("title", Title, "body", Body))
		return true
	}
	try Ui_MsgBox(Body, Title, Icon)
	return true
}

; Sends the shared minimal probe (api_providers.json test_request, verbatim)
; to the active entry and surfaces the verdict. Unlike the save-time /models
; ping this proves the full path: credentials, model id and body format.
; Token never reaches a log or a popup — only the entry name, latency and a
; short reply excerpt travel.
;
; @param NotifyFn function|nil Optional test seam receiving (ok, detail-map).
;   When absent every outcome (refusal, dispatch failure, completion) goes to
;   a blocking MsgBox, never a TrayTip.
; @param EntryId string The entry to probe, "" for the active one.
; @return boolean True when a probe was dispatched.
;
; A Backboard entry sends one message with the same probe; a decisions entry
; (not a chat model) asks api_providers.json's decisions_test questions and
; succeeds when answers come back.
_LLM_Menu_TestActiveApiEntry(NotifyFn := 0, EntryId := "") {
	global _LLM_Menu, LLM_REMOTE_TEST_REQUEST, LLM_REMOTE_KIND_API_TEST,
		LLM_API_TEST_TIMEOUT_MS, LLM_REMOTE_DECISIONS_TEST
	active_id := (EntryId != "") ? EntryId
		: (_LLM_Menu.Has("api_entry_id") ? _LLM_Menu["api_entry_id"] : "")
	entry := ""
	if (active_id != "" && _LLM_Menu.Has("api_entries")
			&& (_LLM_Menu["api_entries"] is Array)) {
		for e in _LLM_Menu["api_entries"] {
			if (_LLM_MenuApiEntryGet(e, "Id", "") == active_id) {
				entry := e
				break
			}
		}
	}
	if (entry == "") {
		_LLM_Menu_ApiTestSurface(t("menu.llm.api_dialog_title"),
			t("menu.llm.api_no_entry"), "Iconx", false, NotifyFn)
		try LoggerWarn("LLM", "API test refused: no active entry selected.")
		return false
	}
	if !(LLM_REMOTE_TEST_REQUEST is Map) || (LLM_REMOTE_TEST_REQUEST.Count == 0) {
		_LLM_Menu_ApiTestSurface(t("menu.llm.api_dialog_title"),
			t("menu.llm.api_providers_unavailable"), "Iconx", false, NotifyFn)
		try LoggerError("LLM", "API test refused: shared test-request spec unavailable.")
		return false
	}
	; Snapshot plain strings so a mid-flight edit cannot relabel this result.
	snapshot := Map()
	for Field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"]
		snapshot[Field] := _LLM_MenuApiEntryGet(entry, Field, "")
	if !_LLM_Menu_ApiEntryFieldsAreSafe(snapshot) {
		_LLM_Menu_ApiTestSurface(t("menu.llm.api_dialog_title"),
			t("menu.llm.api_no_entry"), "Iconx", false, NotifyFn)
		try LoggerError("LLM", "API test refused: active entry failed field validation.")
		return false
	}
	IsDecisions := LLM_RemoteProviderFormat(snapshot["Provider"]) == "decisions"
	if IsDecisions && (!(LLM_REMOTE_DECISIONS_TEST is Map) || LLM_REMOTE_DECISIONS_TEST.Count == 0) {
		_LLM_Menu_ApiTestSurface(t("menu.llm.api_dialog_title"),
			t("menu.llm.api_providers_unavailable"), "Iconx", false, NotifyFn)
		try LoggerError("LLM", "API test refused: shared decisions probe unavailable.")
		return false
	}
	spec := LLM_REMOTE_TEST_REQUEST
	EntryId := snapshot["Id"]
	Name := _LLM_Menu_ApiEntryDisplayName(entry)
	Owner := ""
	try Owner := LLM_AuxBegin("api_test:" . EntryId, Map(
		"backend", "api",
		"endpoint", snapshot["BaseUrl"],
		"identity", EntryId))
	catch as Err {
		try LoggerError("LLM", "API test owner acquisition failed: {1}.", Err.Message)
		return false
	}
	StartedTick := A_TickCount
	; Immediate visible feedback at click time; the Cancel button and the
	; request id are attached below once dispatch owns them.
	_LLM_Menu_ApiTestProgressShow(EntryId, Name)
	_LLM_Menu_ApiTestProgress["owner"] := Owner
	OnSucc := (Text, Usage) => _LLM_Menu_OnApiTestDone(true, Text,
		EntryId, Name, StartedTick, Owner, NotifyFn)
	OnFail := (Info := "") => _LLM_Menu_OnApiTestDone(false, "",
		EntryId, Name, StartedTick, Owner, NotifyFn, Info)
	; Logged before dispatch, not after: if the click reaches this function
	; there is always exactly one line proving it, so a silent menu click can
	; be told apart from a handler failure. No token, no prompt content.
	try LoggerInfo("LLM", "API test dispatched for '{1}' (model {2}).",
		Name, snapshot["Model"])
	try {
		; Tag the reservation with the owned-probe kind so the engine's
		; keystroke cancels (ResetPredictions, CancelInflight) spare it, and
		; give the probe its own longer budget for cold models.
		if IsDecisions {
			Resolved := _LLMRemoteResolveEntry(snapshot)
			if !(Resolved is Map)
				throw Error("the entry has no usable key, address or model")
			ReqId := LLM_RemoteDecisions_Async(Resolved, LLM_REMOTE_DECISIONS_TEST["state"],
				LLM_REMOTE_DECISIONS_TEST["questions"],
				(Answers, Usage := "") => OnSucc(LLM_RemoteFormats_Encode(Answers), Usage),
				OnFail, LLM_REMOTE_KIND_API_TEST, LLM_API_TEST_TIMEOUT_MS)
		} else {
			ReqId := LLM_RemoteGenerate_Async(snapshot, spec["system_prompt"],
				spec["user_text"], spec["temperature"], OnSucc, OnFail, "",
				spec["max_tokens"], LLM_REMOTE_KIND_API_TEST,
				LLM_API_TEST_TIMEOUT_MS)
		}
		_LLM_Menu_ApiTestProgress["req_id"] := ReqId
	} catch as Err {
		try LLM_AuxFinish(Owner)
		try LoggerError("LLM", "API test dispatch failed: {1}.", Err.Message)
		_LLM_Menu_ApiTestProgressHide()
		Tip := _LLM_Menu_ApiTestTip(false, Name, 0, "")
		_LLM_Menu_ApiTestSurface(Tip["title"], Tip["body"], "Icon!", false, NotifyFn)
		return false
	}
	; A synchronously failed dispatch already ran the completion above: never
	; leave a progress behind it.
	if !LLM_AuxIsCurrent(Owner)
		_LLM_Menu_ApiTestProgressHide()
	return true
}

; Builds the user-visible verdict triple without touching UI or logs, so the
; mapping is unit-testable headlessly. Mirrors the validation flow wording.
; @param Info Map|nil Optional failure info (reason/status/message): the
;   provider's own verdict is appended so a 402 quota refusal never reads as
;   a generic unreachable.
; @return Map { ok, title, body }
_LLM_Menu_ApiTestTip(Ok, Name, Ms, Text, Info := "") {
	if (Ok && Text is String && Text != "") {
		Excerpt := StrLen(Text) > 120 ? SubStr(Text, 1, 120) . "..." : Text
		return Map("ok", true,
			"title", t("menu.llm.api_test_ok_title"),
			"body", Format(t("menu.llm.api_test_ok_body"), Name, Ms, Excerpt))
	}
	Body := StrReplace(t("menu.llm.api_unreachable_body"), "%s", Name)
	ServerLine := _LLM_Menu_ApiTestServerLine(Info)
	if (ServerLine != "")
		Body .= "`n" . ServerLine
	return Map("ok", false,
		"title", t("menu.llm.api_unreachable_title"),
		"body", Body)
}

; Renders the provider's own verdict as a language-neutral bracketed line, so
; no locale key is needed for server English plus a status code.
; @return string "" when there is nothing to show.
_LLM_Menu_ApiTestServerLine(Info) {
	if !(Info is Map)
		return ""
	Status := (Info.Has("status") && Info["status"] is Number)
		? Integer(Info["status"]) : 0
	Msg := (Info.Has("message") && Info["message"] is String)
		? Trim(Info["message"]) : ""
	if (Msg == "")
		return ""
	return (Status > 0) ? Format("[{1}] {2}", Status, Msg) : Msg
}

; Publishes one probe completion. Stale results (entry changed or deleted
; mid-flight, driver suspended) are discarded silently like the validation
; flow — a late verdict must never relabel another entry.
; @return boolean True when the verdict was surfaced.
_LLM_Menu_OnApiTestDone(Ok, Text, EntryId, Name, StartedTick, Owner,
		NotifyFn := 0, Info := "", NowTick?) {
	global _LLM_Menu, _LLM_Menu_ApiTestProgress
	; The progress belongs to this Owner reference: hide it before every
	; exit, including stale and suspended ones, so no window ever lingers.
	; A newer probe owns its own progress and is never touched here.
	if ((_LLM_Menu_ApiTestProgress is Map)
		&& _LLM_Menu_ApiTestProgress.Has("owner")
		&& _LLM_Menu_ApiTestProgress["owner"] == Owner)
		_LLM_Menu_ApiTestProgressHide()
	if !LLM_AuxIsCurrent(Owner) || A_IsSuspended
		return false
	Matches := 0
	if (_LLM_Menu is Map) && _LLM_Menu.Has("api_entries")
			&& (_LLM_Menu["api_entries"] is Array) {
		for e in _LLM_Menu["api_entries"] {
			if (_LLM_MenuApiEntryGet(e, "Id", "") == EntryId)
				Matches += 1
		}
	}
	if (Matches != 1 || !LLM_AuxFinish(Owner))
		return false
	Ms := TickElapsed(StartedTick, NowTick?)
	Tip := _LLM_Menu_ApiTestTip(Ok, Name, Ms, Text, Info)
	_LLM_Menu_ApiTestSurface(Tip["title"], Tip["body"],
		Tip["ok"] ? "Iconi" : "Icon!", Tip["ok"], NotifyFn)
	if (Tip["ok"]) {
		try LoggerInfo("LLM", "API test for '{1}' succeeded in {2} ms ({3} reply chars).",
			Name, Ms, StrLen(Text))
	} else {
		ServerLine := _LLM_Menu_ApiTestServerLine(Info)
		try LoggerError("LLM", "API test for '{1}' failed after {2} ms — check the token, URL and model.{3}",
			Name, Ms, ServerLine == "" ? "" : " Server said: " . ServerLine)
	}
	return true
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
; Name stays a required field so a file this build writes still loads in the
; builds before 2026-10; its value, a name the user typed in those builds, is
; never read: every row shows the automatic name.
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

; Unknown entry fields cannot be serialized losslessly by this six-field writer.
; Refuse replacement rather than interpreting future fields or losing their bytes.
_LLM_Menu_ApiEntriesFieldsOwned(Entry) {
	if !(Entry is Map)
		return false
	for Field in Entry {
		if !(Field is String) || !RegExMatch(Field, "^(Id|Name|Provider|BaseUrl|Token|Model)$")
			return false
	}
	return _LLM_Menu_ApiEntryFieldsAreSafe(Entry)
}

_LLM_Menu_ApiSourceOwned(Raw) {
	global LLM_API_PROVIDERS
	try Entries := JsonParse(Raw)
	catch
		return false
	if !(Entries is Array) || !_LLM_Menu_ApiEntryIdsAreUnique(Entries)
		return false
	for Entry in Entries {
		if !_LLM_Menu_ApiEntriesFieldsOwned(Entry)
				|| !LLM_API_PROVIDERS.Has(Entry["Provider"])
			return false
	}
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
		if !_LLM_Menu_ApiEntriesFieldsOwned(e)
			return false
		fields := []
		for field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"] {
			val := _LLM_MenuApiEntryGet(e, field, "")
			if !(val is String)
				return false
			if (field == "Token" and val != "") {
				try val := HasMethod(EncryptFn, "Call")
					? EncryptFn.Call(val) : LLM_ApiToken_Encrypt(val)
				catch as Err {
					try LoggerError("LLM", "API-token encryption raised: {1}.", Err.Message)
					return false
				}
				if !(val is String) || !LLM_ApiToken_IsValidEnvelope(val) {
					try LoggerError("LLM",
						"API-entry serialization refused an unencrypted token.")
					return false
				}
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
		if !FSWriteDurable(tmp, body)
			throw Error("API-entry stage write was incomplete")
		if !FSUtf8ExactMatches(tmp, body)
			throw Error("API-entry stage bytes did not verify")
		if !FSAtomicMoveReplace(tmp, path)
			throw Error("API-entry stage could not be published")
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
	return JsonStringContents(s)
}

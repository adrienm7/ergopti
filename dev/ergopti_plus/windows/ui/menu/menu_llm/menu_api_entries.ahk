; ui/menu/menu_llm/menu_api_entries.ahk

; ==============================================================================
; MODULE: LLM Tray — Remote API entries
; DESCRIPTION:
; Manages the user-defined list of remote API endpoints (OpenAI, Anthropic,
; Google Gemini, OpenAI-compatible). When backend = "api", the model picker
; becomes an "API endpoints" picker built from this list. Includes the
; create/edit dialog flow, the JSON persistence layer (api_entries.json
; alongside config.toml), DPAPI token encryption, and the brace-aware JSON
; splitter required to survive tokens that contain literal braces.
;
; FEATURES & RATIONALE:
; 1. Separate JSON file: the array-of-maps schema would be mangled by the
;    project's flat-TOML writer; api_entries.json sidesteps the round-trip.
; 2. State-aware JSON splitter: regex-based ``\{[^{}]*\}`` truncates entries
;    when a token or URL contains literal braces. The custom scanner tracks
;    string boundaries and escape sequences so braces inside strings don't
;    count.
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
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_SelectApiEntryCandidate(Candidate, EntryId) {
	if !(Candidate is Map) || !(Candidate["api_entries"] is Array)
		return false
	for Entry in Candidate["api_entries"] {
		if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId {
			Candidate["api_entry_id"] := EntryId
			return true
		}
	}
	return false
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
	provider_choices := ""
	for k, v in LLM_API_PROVIDERS {
		provider_choices .= k . " (" . v["Label"] . "), "
	}
	provider_choices := RTrim(provider_choices, ", ")
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
			new_entry, EditId), _LLM_Menu_ApplyStandardCommitted)
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
	try LLM_RemoteIsReady_Async(new_entry, _LLM_Menu_MakeApiValidationHandler(new_name))
	return true
}

_LLM_Menu_UpsertApiEntryCandidate(Candidate, NewEntry, EditId) {
	if !(Candidate is Map) || !(Candidate["api_entries"] is Array)
			|| !(NewEntry is Map) || !NewEntry.Has("Id")
		return false
	if EditId != "" {
		for Index, Entry in Candidate["api_entries"] {
			if _LLM_MenuApiEntryGet(Entry, "Id", "") == EditId {
				Candidate["api_entries"][Index] := LLM_Menu_DeepClone(NewEntry)
				Candidate["api_entry_id"] := NewEntry["Id"]
				return true
			}
		}
		return false
	}
	for Entry in Candidate["api_entries"] {
		if _LLM_MenuApiEntryGet(Entry, "Id", "") == NewEntry["Id"]
			return false
	}
	Candidate["api_entries"].Push(LLM_Menu_DeepClone(NewEntry))
	Candidate["api_entry_id"] := NewEntry["Id"]
	return true
}

; Builds the async validation callback for an API save. Captured ``Name`` is
; bound at save time so a later edit/save does not relabel an in-flight TrayTip.
; Kept as a factory (not an inline closure) so the captured value is explicit
; and the save path reads as a single non-blocking dispatch.
_LLM_Menu_MakeApiValidationHandler(Name) {
	return (reachable) => _LLM_Menu_OnApiValidationDone(reachable, Name)
}

_LLM_Menu_OnApiValidationDone(reachable, Name) {
	if (reachable) {
		TrayTip(StrReplace(t("menu.llm.api_validated_body"), "%s", Name),
			t("menu.llm.api_validated_title"), "Iconi")
	} else {
		TrayTip(StrReplace(t("menu.llm.api_unreachable_body"), "%s", Name),
			t("menu.llm.api_unreachable_title"), "Icon!")
	}
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
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_RemoveApiEntryCandidate(Candidate, EntryId) {
	if !(Candidate is Map) || !(Candidate["api_entries"] is Array)
		return false
	Kept := []
	Removed := false
	for Entry in Candidate["api_entries"] {
		if _LLM_MenuApiEntryGet(Entry, "Id", "") == EntryId {
			Removed := true
			continue
		}
		Kept.Push(Entry)
	}
	if !Removed
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
	return "api_" . A_TickCount
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

; Read api_entries.json on startup and populate the tray state. Silent on
; missing file (first-run user) and on parse failure (corrupt file) — both
; cases just leave the user with an empty entries list, which the UI handles
; gracefully via the "+ Add an API…" affordance.
_LLM_Menu_LoadApiEntries() {
	global _LLM_Menu
	path := _LLM_Menu_ApiEntriesPath()
	if (path == "" or !FileExist(path))
		return
	try {
		raw := FileRead(path, "UTF-8")
	} catch {
		return
	}
	entries := []
	; Split the array into top-level object blocks via a state-aware scanner
	; (NOT a regex like ``{[^{}]*}``). A token that happens to contain a
	; literal ``{`` or ``}`` would silently truncate one entry and shift the
	; rest by one — a regression that's invisible until a user pastes an
	; OAuth bearer token containing those characters.
	for obj_str in _LLM_Menu_SplitJsonObjects(raw) {
		obj := Map()
		for field in ["Id", "Name", "Provider", "BaseUrl", "Token", "Model"] {
			if RegExMatch(obj_str, '"' . field . '"\s*:\s*"((?:[^"\\]|\\.)*)"', &fm) {
				obj[field] := _LLM_MenuApiJsonUnescape(fm[1])
			} else {
				obj[field] := ""
			}
		}
		; Decrypt the token field on load so callers always see cleartext.
		; LLM_ApiToken_Decrypt is a no-op on legacy unencrypted values
		; (any string without the ``dpapi:`` prefix), so existing configs
		; keep working unchanged until the next persist re-encrypts.
		if (obj["Token"] != "")
			obj["Token"] := LLM_ApiToken_Decrypt(obj["Token"])
		if (obj["Id"] != "")
			entries.Push(obj)
	}
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

/**
 * Splits a JSON array text into its top-level ``{...}`` object substrings,
 * tracking string boundaries and backslash escapes so a literal ``{`` or
 * ``}`` inside a token / URL never trips the split. Used by
 * _LLM_Menu_LoadApiEntries.
 *
 * @param {string} raw - Raw file contents (typically the contents of api_entries.json).
 * @returns {Array} Array of substrings, each one a complete ``{...}`` block.
 */
_LLM_Menu_SplitJsonObjects(raw) {
	objects := []
	n := StrLen(raw)
	i := 1
	while (i <= n) {
		; Skip ahead to the next opening brace that's NOT inside a string.
		start := 0
		j := i
		in_str := false
		escape := false
		while (j <= n) {
			c := SubStr(raw, j, 1)
			if escape {
				escape := false
			} else if (c == "\") {
				escape := true
			} else if (c == '"') {
				in_str := !in_str
			} else if (!in_str and c == "{") {
				start := j
				break
			}
			j += 1
		}
		if (start == 0)
			break
		; Scan from ``start`` to the matching close brace, tracking depth
		; and string boundaries so braces inside strings don't count.
		depth := 0
		in_str := false
		escape := false
		k := start
		end_at := 0
		while (k <= n) {
			c := SubStr(raw, k, 1)
			if escape {
				escape := false
			} else if (c == "\") {
				escape := true
			} else if (c == '"') {
				in_str := !in_str
			} else if (!in_str) {
				if (c == "{") {
					depth += 1
				} else if (c == "}") {
					depth -= 1
					if (depth == 0) {
						end_at := k
						break
					}
				}
			}
			k += 1
		}
		if (end_at == 0)
			break   ; Malformed input — stop rather than loop forever.
		objects.Push(SubStr(raw, start, end_at - start + 1))
		i := end_at + 1
	}
	return objects
}

_LLM_MenuApiJsonUnescape(s) {
	; Two-pass with a placeholder so an escaped backslash (``\\``) doesn't
	; trick the subsequent passes. The naive ordering ``\n → newline ;
	; \\ → \`` mis-handled input like ``\\n`` (escaped backslash + literal
	; n): the first pass found ``\n`` inside ``\\n`` and consumed the
	; backslash, leaving ``\<newline>`` instead of ``\n``. The placeholder
	; is a Private-Use-Area codepoint that never appears in valid text.
	PH := Chr(0xE000)
	s := StrReplace(s, "\\", PH)
	s := StrReplace(s, "\n", "`n")
	s := StrReplace(s, "\r", "`r")
	s := StrReplace(s, "\t", "`t")
	s := StrReplace(s, '\"', '"')
	s := StrReplace(s, PH,   "\")
	return s
}

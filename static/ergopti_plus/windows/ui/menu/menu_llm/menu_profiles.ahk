; ui/menu/menu_llm/menu_profiles.ahk

; ==============================================================================
; MODULE: LLM Tray — Profile management
; DESCRIPTION:
; Owns the Profile submenu (built-ins + user-defined), the per-app profile
; overrides menu, the user-profile CRUD flow (create / edit / clone built-in),
; the auto-detect heuristic that picks a profile from the active model's
; parameter count, and the Ctrl+1…Ctrl+9 global hotkeys that switch the
; active profile from any app.
;
; FEATURES & RATIONALE:
; 1. Auto-detect heuristic: completion-style → "raw"; ≥4B params →
;    "batch_advanced"; ≥2B → "advanced"; everything else → "basic". Mirrors
;    HS's get_recommended_profile_info so the two drivers agree.
; 2. Manual override disengages auto-detect: when the user explicitly picks a
;    non-recommended profile, the auto-toggle flips off so the next model
;    switch doesn't silently overwrite their choice.
; 3. HotIf-gated Ctrl+<n>: the hotkeys only register when the feature is on,
;    so the OS never intercepts the keystroke when LLM is off — keystrokes
;    pass through naturally to the active app (browsers, IDEs, …).
; 4. Per-app overrides via lazy lookup: WinGetProcessName fires at click
;    time, not at menu-build time, so the override always reflects the
;    actually-focused app.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk





; ==========================================
; ==========================================
; ======= 1/ Profile Submenu Builder =======
; ==========================================
; ==========================================

/**
 * Returns the human-readable label for a profile ID.
 * Checks user profiles first, then falls back to i18n built-in labels.
 * @param {string} id - Profile ID.
 * @returns {string} Display label.
 */
LLM_Menu_GetProfileLabel(id) {
	global _LLM_Menu
	n := _LLM_Menu["n_predictions"]
	s := (n > 1) ? "s" : ""

	; Check user profiles
	for p in _LLM_Menu[ConfigLeaf.USER_PROFILES] {
		if (p.Has("id") && p["id"] == id)
			return p.Has("label") ? p["label"] : id
	}

	; Built-in profile labels: every built-in owns llm.profile.<id>.label; only
	; the batch one uses the {n}/{s} placeholders, which the others lack.
	if LLM_Option_IsBuiltinProfileId(id)
		return StrReplace(StrReplace(t("llm.profile." . id . ".label"), "{n}", n), "{s}", s)
	return id
}

/**
 * The prompts a binding can run, as the AI menu lists them: the built-ins in
 * menu order, then the user's custom profiles.
 * @returns {Array} Maps with "value" (the profile ID) and "label".
 */
LLM_Menu_PromptChoices() {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER
	Choices := []
	for Id in LLM_PROFILE_BUILTIN_ORDER
		Choices.Push(Map("value", Id, "label", LLM_Menu_GetProfileLabel(Id)))
	for Profile in _LLM_Menu[ConfigLeaf.USER_PROFILES] {
		if !(Profile is Map) || !Profile.Has("id")
			continue
		Choices.Push(Map("value", Profile["id"],
			"label", LLM_Menu_GetProfileLabel(Profile["id"])))
	}
	return Choices
}

/**
 * The prompt list the native parameter prompt shows: one "<id> — <label>" line
 * per available prompt, the ID being what the user types.
 * @returns {String}
 */
LLM_Menu_PromptChoicesText() {
	Text := ""
	for Choice in LLM_Menu_PromptChoices()
		Text .= (Text == "" ? "" : "`n") . Choice["value"] . " — " . Choice["label"]
	return Text
}

/**
 * Returns ``Label`` unchanged the first time it is used in a menu, then
 * " #2", " #3"… suffixed for each further use, and records the use in ``Seen``.
 *
 * Mirrors the disambiguator personal hotstring sections already use
 * (``_HS_BuildDisambiguatedSectionLabels``): the suffix is a bare digit, so no
 * i18n string is needed and the common unique case renders exactly as before.
 *
 * @param {Map}    Seen  - Per-menu occurrence counter, one per menu being built.
 * @param {string} Label - Candidate row label.
 * @returns {string} A label unique within that menu.
 */
_LLM_Menu_UniqueMenuLabel(Seen, Label) {
	; Reserve actual outputs too: a free-text name may already equal a suffix.
	static UsedKey := {}
	if !Seen.Has(UsedKey) {
		Used := Map()
		; AHK Menu.Add matches labels without regard to case.
		Used.CaseSense := false
		Seen[UsedKey] := Used
	}
	Used := Seen[UsedKey]
	Ordinal := (Seen.Has(Label) ? Seen[Label] : 0) + 1
	Candidate := Ordinal > 1 ? Label . " #" . Ordinal : Label
	while Used.Has(Candidate) {
		Ordinal := Max(2, Ordinal + 1)
		Candidate := Label . " #" . Ordinal
	}
	Seen[Label] := Ordinal
	Used[Candidate] := true
	return Candidate
}

/**
 * Builds the profile selection submenu with built-in and user profiles.
 * @returns {Menu} Populated profile submenu.
 */
LLM_Menu_BuildProfileMenu() {
	m := Menu()
	MenuRenderer_FillFromList(m, "llm_menu", "llm_profile", (*) => _LLM_Menu_ProfileRows())
	return m
}

/**
 * Row data for the profile submenu.
 * @returns {Array|false} Declared built-ins, user profiles, the CRUD rows, the
 *                  auto-detect toggle and the per-app overrides submenu.
 */
_LLM_Menu_ProfileRows() {
	global _LLM_Menu
	; Row labels must be unique WITHIN this menu: AHK v2's Menu.Add with an
	; already-present label modifies the existing item in place instead of
	; appending, so a second row carrying the same text silently overwrites the
	; first one's wrapper and RegisterMenuItem then rebinds the single surviving
	; id to the newcomer. The first profile becomes unselectable and the
	; checkmark paints on the wrong row. That is true of the renderer's Add as
	; much as of a hand-written one, so the guard belongs here. Nothing
	; guarantees uniqueness: a user profile's label is free text, and the
	; "(Ctrl+n)" hint that happens to separate the early ones is empty past
	; LLM_PROFILE_HOTKEY_LIMIT, so two profiles both named "Perso" collide from
	; the sixth one onward (duplicate-user-profile-label-menu-collapse).
	seen_labels := Map()
	FrameState := Map()
	PausedFn := (*) => A_IsSuspended
	return _LLM_Menu_GuardConfigRows(MenuRenderer_TemplateRows("llm_profile_windows_frame", Map(
		MenuCommand.LLM_PROFILE_CREATE, LLM_Menu_PromptCreateProfile,
		MenuCommand.LLM_PROFILE_CLONE, LLM_Menu_CloneActiveBuiltinProfile,
		MenuCommand.LLM_PROFILE_AUTO_DETECT, (*) => _LLM_Menu_ToggleAutoProfile()), Map(
		"llm_profile_custom_present", _LLM_Menu_ProfileCustomPresent.Bind(FrameState),
		"llm_profile_clone_present", _LLM_Menu_ProfileClonePresent,
		"llm_profile_auto_detect_checked", () => _LLM_Menu[ConfigLeaf.AUTO_PROFILE_FOR_MODEL],
		"llm_profile_create_ready", _LLM_Menu_CreateProfileReady.Bind(PausedFn),
		"llm_profile_clone_ready", _LLM_Menu_CreateProfileReady.Bind(PausedFn)), Map(
		"llm_profile_builtin_rows", _LLM_Menu_ProfileBuiltinRows.Bind(seen_labels),
		"llm_profile_custom_rows", _LLM_Menu_ProfileCustomRows.Bind(seen_labels, FrameState),
		"llm_profile_app_overrides", _LLM_Menu_PerAppProfileRows)))
}

; Native data reads occur only when the shared frame reaches each provider.
_LLM_Menu_ProfileBuiltinRows(SeenLabels) {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER
	Rows := []
	for id in LLM_PROFILE_BUILTIN_ORDER {
		base_label := LLM_Menu_GetProfileLabel(id)
		hint := LLM_Menu_GetProfileHotkeyHint(id)
		label := (hint != "") ? base_label . "  (" . hint . ")" : base_label
		Rows.Push(Map(
			"label",   _LLM_Menu_UniqueMenuLabel(SeenLabels, label),
			"checked", (id == _LLM_Menu["profile_id"]),
			"action",  _LLM_Menu_MakeSetProfileHandler(id)))
	}
	return Rows
}

_LLM_Menu_ProfileCustomPresent(FrameState) {
	global _LLM_Menu
	user_profiles := _LLM_Menu[ConfigLeaf.USER_PROFILES]
	FrameState[ConfigLeaf.USER_PROFILES] := user_profiles
	return user_profiles.Length > 0
}

_LLM_Menu_ProfileCustomRows(SeenLabels, FrameState) {
	global _LLM_Menu
	Rows := []
	user_profiles := FrameState[ConfigLeaf.USER_PROFILES]
	for p in user_profiles {
		pid         := p.Has("id") ? p["id"] : ""
		base_plabel := p.Has("label") ? p["label"] : pid
		hint := LLM_Menu_GetProfileHotkeyHint(pid)
		plabel := (hint != "") ? base_plabel . "  (" . hint . ")" : base_plabel
		Rows.Push(Map(
			"label",   _LLM_Menu_UniqueMenuLabel(SeenLabels, plabel),
			"checked", (pid == _LLM_Menu["profile_id"]),
			"action",  _LLM_Menu_MakeUserProfileClickHandler(p)))
	}
	return Rows
}

_LLM_Menu_ProfileClonePresent() {
	global _LLM_Menu
	active_id := _LLM_Menu["profile_id"]
	return LLM_Option_IsBuiltinProfileId(active_id)
}





; ============================================
; ============================================
; ======= 2/ Per-App Overrides Submenu =======
; ============================================
; ============================================

/**
 * Row data for the per-app profile overrides submenu.
 * @returns {Array} The « override the active app » row, then one row per
 *                  existing override, each clearing it on click.
 */
_LLM_Menu_PerAppProfileRows() {
	global _LLM_Menu
	overrides := _LLM_Menu[ConfigLeaf.APP_PROFILE_OVERRIDES]
	; "Override active app with the currently-selected profile". Lazy
	; closure so WinGetProcessName fires when the user clicks, not when
	; the menu is built.
	Rows := []
	if (overrides is Map and overrides.Count > 0) {
		; List each override: "slack → informel"  + click clears it.
		for app_name, profile_id in overrides {
			Rows.Push(Map(
				"label",  app_name . "  →  " . LLM_Menu_GetProfileLabel(profile_id),
				"action", _LLM_Menu_MakeClearOverrideHandler(app_name)))
		}
	}
	Rows := MenuRenderer_TemplateRows("llm_profile_app_override_frame", Map(
		MenuCommand.LLM_PROFILE_OVERRIDE_ACTIVE_APP, (*) => _LLM_Menu_AddOverrideForActiveApp()),
		Map("llm_profile_overrides_present", () => overrides is Map && overrides.Count > 0),
		Map("llm_profile_override_rows", () => Rows))
	if !(Rows is Array)
		throw Error("Declared per-application profile controls were refused.")
	return Rows
}

_LLM_Menu_AddOverrideForActiveApp() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _LLM_Menu_AddOverrideForActiveApp()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	app := ""
	try app := WinGetProcessName("A")
	app := LLM_AppIdentity_Normalize(app)
	if (app == "")
		return false
	return LLM_Menu_CommitMutation("the active-application profile override",
		(Candidate) => _LLM_Menu_SetOverrideCandidate(Candidate, app),
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_SetOverrideCandidate(Candidate, AppName) {
	if !(Candidate is Map)
			|| !(Candidate[ConfigLeaf.APP_PROFILE_OVERRIDES] is Map)
		return false
	Candidate[ConfigLeaf.APP_PROFILE_OVERRIDES][AppName] := Candidate["profile_id"]
	return true
}

_LLM_Menu_ClearOverrideFor(app_name) {
	global _LLM_Menu
	overrides := _LLM_Menu[ConfigLeaf.APP_PROFILE_OVERRIDES]
	if !(overrides is Map) or !overrides.Has(app_name)
		return false
	return LLM_Menu_CommitMutation("the application profile override removal",
		(Candidate) => _LLM_Menu_ClearOverrideCandidate(Candidate, app_name),
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_ClearOverrideCandidate(Candidate, AppName) {
	Overrides := Candidate[ConfigLeaf.APP_PROFILE_OVERRIDES]
	if !(Overrides is Map) || !Overrides.Has(AppName)
		return false
	Overrides.Delete(AppName)
	return true
}

_LLM_Menu_ToggleAutoProfile() {
	return LLM_Menu_CommitMutation("the automatic LLM profile setting",
		_LLM_Menu_ToggleAutoProfileCandidate, _LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_ToggleAutoProfileCandidate(Candidate) {
	Candidate[ConfigLeaf.AUTO_PROFILE_FOR_MODEL] := !Candidate[ConfigLeaf.AUTO_PROFILE_FOR_MODEL]
	if Candidate[ConfigLeaf.AUTO_PROFILE_FOR_MODEL]
		LLM_Menu_AutoApplyProfileForModel(Candidate)
	return true
}





; ====================================
; ====================================
; ======= 3/ User Profile CRUD =======
; ====================================
; ====================================

_LLM_Menu_ProfilePorts(Port) {
	if !((Port is Integer) && Port == 0) && !(Port is Map)
		throw TypeError("Profile dialogs require an optional native port Map.")
	return Port is Map ? Port : Map()
}

_LLM_Menu_ProfileSourceIdentity(Source) {
	global ConfigurationFile, _LLM_Menu, Features
	return Source is Map && Source.Get("path", 0) is String
		&& Source.Get("content", 0) is String && Source.Get("present", -1) is Integer
		&& (Source["present"] == 0 || Source["present"] == 1)
		&& Source.Get("menu", 0) is Map && Source.Get("features", 0) is Map
		&& ConfigurationFile == Source["path"] && _LLM_Menu == Source["menu"] && Features == Source["features"]
}

_LLM_Menu_CaptureProfileSource() {
	global ConfigurationFile, _LLM_Menu, Features
	if !IsSet(ConfigurationFile) || !(ConfigurationFile is String) || ConfigurationFile == ""
			|| !IsSet(_LLM_Menu) || !(_LLM_Menu is Map) || !IsSet(Features) || !(Features is Map)
		return false
	Source := Map("path", ConfigurationFile, "menu", _LLM_Menu, "features", Features, "present", 0, "content", "")
	if !ConfigFullStateCanPersist() || !_LLM_Menu_ProfileSourceIdentity(Source)
		return false
	try {
		Source["present"] := FSStrictExists(Source["path"])
		if !_LLM_Menu_ProfileSourceIdentity(Source)
			return false
		Source["content"] := Source["present"] ? FSConfigReadUtf8Exact(Source["path"]) : ""
	} catch
		return false
	if !_LLM_Menu_ProfileClaimSnapshot(Source)
		return false
	return _LLM_Menu_ProfileSourceProjectionMatches(Source) ? Source : false
}

; Freeze only persisted RAM while claiming the source. No parser, file reader,
; logger or native UI call runs under this bounded memory-only transaction.
_LLM_Menu_ProfileClaimSnapshot(Source) {
	global _LLM_Menu_ApiPrivateAuthorityGeneration
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_ProfileSourceIdentity(Source) || !Source["features"].Has("llm")
			return false
		Keys := [], MenuSnapshot := Map()
		for Group in _LLM_Menu_PersistedFieldGroups()
			for Key in Group {
				Keys.Push(Key)
				if Source["menu"].Has(Key)
					MenuSnapshot[Key] := _HSDeepCloneMap(Source["menu"][Key])
			}
		MenuSnapshot["api_entries"] := _HSDeepCloneMap(Source["menu"].Get("api_entries", []))
		Source["menu_keys"] := Keys
		Source["menu_snapshot"] := MenuSnapshot
		Source["features_snapshot"] := Map("llm", _HSDeepCloneMap(Source["features"]["llm"]))
		Source["api_authority"] := _LLM_Menu_ApiPrivateAuthorityGeneration
		Source["snapshot_ready"] := 1
		return true
	} catch
		return false
	finally Critical(PreviousCritical)
}

; Runtime dependency failure mutates enabled in place; API restore mutates id
; in place. Compare the frozen persisted values and existing API authority,
; rather than accepting their unchanged enclosing Map identities.
_LLM_Menu_ProfileSourceBound(Source) {
	global _LLM_Menu_ApiPrivateAuthorityGeneration
	PreviousCritical := Critical("On")
	try {
		if !_LLM_Menu_ProfileSourceIdentity(Source) || Source.Get("snapshot_ready", 0) != 1
				|| _LLM_Menu_ApiPrivateAuthorityGeneration != Source["api_authority"]
				|| !Source["features"].Has("llm")
				|| !ManifestValuesEqual(Source["features"]["llm"], Source["features_snapshot"]["llm"])
			return false
		for Key in Source["menu_keys"] {
			if Source["menu"].Has(Key) != Source["menu_snapshot"].Has(Key)
				return false
			if Source["menu_snapshot"].Has(Key)
					&& !ManifestValuesEqual(Source["menu"][Key], Source["menu_snapshot"][Key])
				return false
		}
		return true
	} catch
		return false
	finally Critical(PreviousCritical)
}

_LLM_Menu_ProfilePreparePublication(Source, CandidateMenu) {
	return _LLM_Menu_ProfileSourceBound(Source) ? Source : false
}

; The existing publication port rechecks the same memory receipt after native
; durability, so a later in-place runtime failure is never overwritten either.
_LLM_Menu_ProfilePublishCandidate(Source, CandidateFeatures, CandidateMenu, PreparedSource) {
	global Features
	if PreparedSource != Source || !_LLM_Menu_ProfileSourceBound(Source) {
		_LLM_Menu_ProfileRetainPublication(Source)
		return false
	}
	; The profile owns only the LLM subtree. Rebase its acknowledged result
	; over the current other roots instead of publishing their older clone.
	PublishedFeatures := Features.Clone()
	PublishedFeatures["llm"] := CandidateFeatures["llm"]
	Published := _LLM_Menu_PublishCandidate(PublishedFeatures, CandidateMenu)
	if Published is Integer && Published == 1
		Source["published"] := 1
	return Published
}

_LLM_Menu_ProfileRetainPublication(Source) {
	; Called only after this source's genuine native ACK. Existing terminal
	; ownership remains held through failure reporting and this session seal.
	TOML_RefuseWrites(Source["path"], "durable LLM profile publication was retired; restart required")
	Source["publication_withdrawn"] := 1
}

_LLM_Menu_ProfileNotifyFailure(Source, NotifyFn, Message, Options) {
	if Source.Get("native_ack", 0) == 1 {
		; Also cover a native profile-owner commit refusal before our publisher
		; is invoked. This records actual durability, never a fabricated ACK.
		if Source.Get("published", 0) != 1
			_LLM_Menu_ProfileRetainPublication(Source)
		Message := t("onboarding.done.restart_required")
		Options := Options.Clone()
		Options["title"] := t("menu.llm.profiles")
		Options["level"] := "warning"
	}
	return HasMethod(NotifyFn, "Call") ? NotifyFn.Call(Message, Options) : NotifierSend(Message, Options)
}

; Collect exactly the LLM projection the full-save owner would persist. Keeping
; its feature walk and private menu collector avoids a second setting list.
_LLM_Menu_ProfileProjectionUpdates(FeatureState, MenuState) {
	if !(FeatureState is Map) || !FeatureState.Has("llm") || !(FeatureState["llm"] is Map)
		throw Error("The LLM profile source requires its persisted feature state.")
	; Master gates project layout/shortcuts/hotstrings only; the full-save
	; owner retains this same LLM subtree without a gate transformation.
	Snapshot := Map("llm", _HSDeepCloneMap(FeatureState["llm"]))
	if !_LLM_Menu_SyncToFeatures(Snapshot, MenuState)
		throw Error("The LLM profile source cannot project an incomplete menu state.")
	Updates := []
	_CollectFeatureUpdates(Updates, "llm", Snapshot["llm"])
	_LLM_Menu_AppendOwnedPersistedUpdates(Updates, MenuState)
	return _ConfigKeepOutdatedEntries(_ConfigLastRowWins(_ConfigSparseUpdates(Updates)))
}

; A fresh physical receipt cannot authorize replacing any persisted LLM leaf
; from stale RAM. Defaults resolve absent leaves without blessing a new file.
_LLM_Menu_ProfileSourceProjectionMatches(Source) {
	if !_LLM_Menu_ProfileSourceBound(Source)
		return false
	try {
		Snapshot := ConfigTomlDecodeSnapshot(Source["content"])
		Document := Snapshot.Document
		RawRows := Map()
		RawRows.CaseSense := "On"
		for Row in Snapshot.Rows
			RawRows[_TOML_ConfigPathName(_TOML_ConfigPath(Row.Section, Row.Key))] := Row
		Updates := _ConfigPrepareTypedUpdates(_LLM_Menu_ProfileProjectionUpdates(Source["features_snapshot"], Source["menu_snapshot"]))
		for Update in Updates {
			Parts := _TOML_ConfigPath(Update.Section, Update.Key)
			Path := _TOML_ConfigPathName(Parts)
			Read := _TOML_DocumentLookup(Document, Parts)
			if Read["blocked"]
				return false
			Deleting := Update.HasOwnProp("Delete") && Update.Delete == 1
			if !Read["found"] || Deleting
				Default := _ConfigPrepareTypedUpdates([{Section: Update.Section, Key: Update.Key,
					Value: _LLM_Menu_ProfileProjectionDefault(Path)}])[1].Value
			Physical := Read["found"] ? Read["value"] : Default
			Live := Deleting ? Default : Update.Value
			if Read["found"] && Live is TOML_Bool && Physical is Integer {
				if !RawRows.Has(Path)
					return false
				Raw := RawRows[Path]
				; Only the canonical loader's exact bare 0/1 compatibility is
				; admitted. Quoted, signed and floating spellings stay distinct.
				if !TomlConfigValueMatchesManifest(Update.Section, Update.Key, Raw.Value,
						&ExpectedType, TOML_StripInlineComment(Raw.Raw)) || ExpectedType != "boolean"
					return false
				Physical := TOML_Bool(Raw.Value)
			}
			if !_LLM_Menu_ProfileProjectionValueMatches(Path, Physical, Live, Document, Source["menu_snapshot"])
				return false
		}
		return _LLM_Menu_ProfileSourceBound(Source)
	} catch
		return false
}

_LLM_Menu_ProfileProjectionValueMatches(Path, Physical, Live, Document, MenuState) {
	if Path == "llm.api_entry_id" && Physical is String && Physical == _LLM_Menu_DefaultApiEntryId() {
		if !(Live is String) || !(MenuState.Get("api_entries", 0) is Array)
			return false
		return _LLM_Menu_ResolveApiEntryId(MenuState["api_entries"], Physical) == Live
	}
	if Path == ConfigKey.LLM_DISPLAY_STREAMING {
		if !(Physical is TOML_Bool) || !(Live is TOML_Bool)
			return false
		Backend := _TOML_DocumentLookup(Document, ["llm", "models", "selected"])
		if Backend["blocked"]
			return false
		BackendValue := Backend["found"] ? Backend["value"] : ManifestDefaultFor(ConfigKey.LLM_MODELS_SELECTED)
		return BackendValue is String && !!LLM_EffectiveStreaming(BackendValue, Physical.Value) == !!Live.Value
	}
	if Path == "llm.ollama_port" && LLM_Option_IsStockOllamaPort(Physical)
		Physical := _LLM_Menu_ProfileProjectionDefault(Path)
	if Path == ConfigKey.LLM_TRIGGER_DISABLED_APPS || Path == ConfigKey.LLM_AGENT_DISABLED_APPS {
		PhysicalApps := LLM_Option_NormalizeStringArray(Physical, true)
		LiveApps := LLM_Option_NormalizeStringArray(Live, true)
		return PhysicalApps is Array && LiveApps is Array && TOML_SameValue(PhysicalApps, LiveApps)
	}
	if Path == ConfigKey.LLM_USER_PROFILES {
		PhysicalProfiles := _LLM_Menu_DeserializeUserProfiles(Physical)
		LiveProfiles := _LLM_Menu_DeserializeUserProfiles(Live)
		if !(PhysicalProfiles is Array) || !(LiveProfiles is Array)
			return false
		return _LLM_Menu_SerializeUserProfiles(PhysicalProfiles) == _LLM_Menu_SerializeUserProfiles(LiveProfiles)
	}
	if Path == ConfigKey.LLM_NAVIGATION_NAV_MODIFIERS || Path == ConfigKey.LLM_NAVIGATION_VAL_MODIFIERS {
		PhysicalModifiers := _LLM_Menu_ModifiersArrayToString(Physical)
		LiveModifiers := _LLM_Menu_ModifiersArrayToString(Live)
		return PhysicalModifiers is String && LiveModifiers is String && PhysicalModifiers == LiveModifiers
	}
	if Path == ConfigKey.LLM_APP_PROFILE_OVERRIDES {
		; Compare the complete JSON, retaining unknown fields which the runtime
		; app-map decoder intentionally cannot carry into its reduced Map.
		PhysicalRows := _LLM_Menu_ProfileOverrideEnvelope(Physical)
		LiveRows := _LLM_Menu_ProfileOverrideEnvelope(Live)
		return PhysicalRows is Array && LiveRows is Array && TOML_SameValue(PhysicalRows, LiveRows)
	}
	return TOML_SameValue(Physical, Live)
}

_LLM_Menu_ProfileOverrideEnvelope(Payload) {
	if !(Payload is String)
		return false
	if Payload == "" || Payload == "_"
		return []
	if SubStr(Payload, 1, 3) !== "v1:"
		return false
	try {
		Bytes := CryptoBase64Decode(SubStr(Payload, 4))
		Rows := JsonParse(StrGet(Bytes, Bytes.Size, "UTF-8"))
		return Rows is Array ? Rows : false
	} catch
		return false
}

; Foreign-owner leaves use their own canonical initial values; only manifest
; leaves have a ManifestDefaultFor contract. Resolve these only when needed.
_LLM_Menu_ProfileProjectionDefault(Path) {
	global LLM_Defaults
	if Path == "llm.api_entry_id"
		return _LLM_Menu_DefaultApiEntryId()
	if Path == "llm.ollama_port" {
		if !IsSet(LLM_Defaults) || !(LLM_Defaults is Map) || !LLM_Defaults.Has("llm_ollama_owned_port")
			throw Error("The owned Ollama port default is unavailable.")
		return LLM_Defaults["llm_ollama_owned_port"]
	}
	return ManifestDefaultFor(Path)
}

_LLM_Menu_WriteProfileSource(Source, Path, Updates) {
	if !_LLM_Menu_ProfileSourceBound(Source) || !_LLM_Menu_ProfileSourceProjectionMatches(Source) || !(Path == Source["path"])
		return false
	; Even an injected collector cannot grant the profile ownership of other
	; preferences. Canonical paths reject quoted/dotted aliases outside llm.
	for Update in Updates {
		Parts := _TOML_ConfigPath(Update.Section, Update.Key)
		if Parts.Length < 2 || Parts[1] !== "llm"
			return false
	}
	; The native writer retains this exact pre-dialog image through stage and
	; replacement; a fresh schema admission must not adopt later external edits.
	Committed := TOML_ConfigBatchWrite(Path, Updates, [],
		_LLM_Menu_ProfileSourceBound.Bind(Source), Source["content"], Source["present"])
	if Committed is Integer && Committed == 1
		Source["native_ack"] := 1
	return Committed
}

/**
 * Shows a context sub-menu style dialog for a user profile (use / edit / delete).
 * AHK has no native submenu on the fly; we show a MsgBox with button choices.
 * @param {Map} profile - The user profile Map object.
 */
LLM_Menu_OnUserProfileClick(profile, Port := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_OnUserProfileClick(profile, Port)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	Options := _LLM_Menu_ProfilePorts(Port)
	Source := _LLM_Menu_CaptureProfileSource()
	if !(Source is Map)
		return ConfigReportPersistenceFailure("the custom LLM profile action", Options.Get("notify", 0),
			"the opening configuration source is unavailable")
	ConfirmFn := Options.Get("confirm", Ui_MsgBox)
	pid    := profile.Has("id")    ? profile["id"]    : ""
	plabel := profile.Has("label") ? profile["label"] : pid

	choice := ConfirmFn.Call(
		t("menu.profiles.use_profile") . "`n"
		. t("menu.profiles.edit_profile") . "`n"
		. t("menu.profiles.delete_profile"),
		plabel,
		"3 32"  ; Yes/No/Cancel buttons + question icon
	)

	if (choice == "Yes") {
		; Use this profile through the same opening image as the management dialog.
		LLM_Menu_CommitMutation("the LLM profile selection",
			(Candidate) => _LLM_Menu_SetProfileCandidate(Candidate, pid),
			Options.Get("apply", _LLM_Menu_ApplyManualProfileCommitted),
			_LLM_Menu_WriteProfileSource.Bind(Source), _LLM_Menu_ProfileNotifyFailure.Bind(Source, Options.Get("notify", 0)),
			Options.Get("acquire", 0), Options.Get("settle", 0), Options.Get("collect", _LLM_Menu_ProfileProjectionUpdates),
		_LLM_Menu_ProfilePreparePublication.Bind(Source), _LLM_Menu_ProfilePublishCandidate.Bind(Source))
	} else if (choice == "No") {
		; Edit this profile
		LLM_Menu_PromptEditProfile(profile, Port, Source)
	} else if (choice == "Cancel") {
		confirm := ConfirmFn.Call(t("menu.profiles.delete_profile") . " ?", plabel, "4 48")
		if (confirm == "Yes") {
			return LLM_Menu_CommitMutation("the custom LLM profile removal",
				(Candidate) => _LLM_Menu_DeleteProfileCandidate(Candidate, pid),
				Options.Get("apply", _LLM_Menu_ApplyProfileCommitted),
				_LLM_Menu_WriteProfileSource.Bind(Source), _LLM_Menu_ProfileNotifyFailure.Bind(Source, Options.Get("notify", 0)),
				Options.Get("acquire", 0), Options.Get("settle", 0), Options.Get("collect", _LLM_Menu_ProfileProjectionUpdates),
		_LLM_Menu_ProfilePreparePublication.Bind(Source), _LLM_Menu_ProfilePublishCandidate.Bind(Source))
		}
	}
	return true
}

_LLM_Menu_DeleteProfileCandidate(Candidate, ProfileId) {
	if !(Candidate is Map) || !(ProfileId is String) || ProfileId == ""
			|| !Candidate.Has(ConfigLeaf.USER_PROFILES)
			|| !(Candidate[ConfigLeaf.USER_PROFILES] is Array)
			|| !Candidate.Has("profile_id")
			|| !(Candidate["profile_id"] is String)
		return false
	Profiles := Candidate[ConfigLeaf.USER_PROFILES]
	SeenIds := Map()
	MatchIndex := 0
	for Index, Profile in Profiles {
		if !(Profile is Map) || !Profile.Has("id")
				|| !(Profile["id"] is String) || Profile["id"] == ""
			return false
		Id := Profile["id"]
		if SeenIds.Has(Id)
			return false
		SeenIds[Id] := true
		if Id == ProfileId
			MatchIndex := Index
	}
	if MatchIndex == 0
		return false

	OverrideKeys := []
	Overrides := 0
	if Candidate.Has(ConfigLeaf.APP_PROFILE_OVERRIDES) {
		Overrides := Candidate[ConfigLeaf.APP_PROFILE_OVERRIDES]
		if !(Overrides is Map)
			return false
		for AppName, OverrideId in Overrides {
			if OverrideId == ProfileId
				OverrideKeys.Push(AppName)
		}
	}

	Profiles.RemoveAt(MatchIndex)
	if Candidate["profile_id"] == ProfileId
		Candidate["profile_id"] := "basic"
	if Overrides is Map {
		for AppName in OverrideKeys
			Overrides.Delete(AppName)
	}
	return true
}

_LLM_Menu_PruneOrphanProfileOverrides(MenuState) {
	global LLM_PROFILE_BUILTIN_ORDER
	if !(MenuState is Map) || !MenuState.Has(ConfigLeaf.APP_PROFILE_OVERRIDES)
			|| !(MenuState[ConfigLeaf.APP_PROFILE_OVERRIDES] is Map)
			|| !MenuState.Has(ConfigLeaf.USER_PROFILES)
			|| !(MenuState[ConfigLeaf.USER_PROFILES] is Array)
		return false
	Valid := Map()
	for Id in LLM_PROFILE_BUILTIN_ORDER
		Valid[Id] := true
	for Profile in MenuState[ConfigLeaf.USER_PROFILES] {
		if !(Profile is Map) || !Profile.Has("id")
				|| !(Profile["id"] is String) || Profile["id"] == ""
			return false
		Valid[Profile["id"]] := true
	}
	OrphanKeys := []
	for AppName, ProfileId in MenuState[ConfigLeaf.APP_PROFILE_OVERRIDES] {
		if !(ProfileId is String) || !Valid.Has(ProfileId)
			OrphanKeys.Push(AppName)
	}
	for AppName in OrphanKeys
		MenuState[ConfigLeaf.APP_PROFILE_OVERRIDES].Delete(AppName)
	return OrphanKeys.Length > 0
}

_LLM_Menu_NormalizeStoredUserProfiles(Profiles) {
	if !(Profiles is Array)
		return false
	Out := []
	Seen := Map()
	Allowed := Map(
		"id", true,
		"label", true,
		"system_single", true,
		"system_multi", true,
		"system_multi_template", true,
		"raw_prompt", true,
		"batch", true,
		"stop_sequences", true)
	for Profile in Profiles {
		if !(Profile is Map)
			return false
		for Key in ["id", "label", "system_single", "system_multi"] {
			if !Profile.Has(Key) || !(Profile[Key] is String)
					|| (Key == "id" && Profile[Key] == "")
				return false
		}
		if Seen.Has(Profile["id"])
			return false
		if !Profile.Has("batch") || !(Profile["batch"] is Integer)
				|| (Profile["batch"] != 0 && Profile["batch"] != 1)
			return false
		Copy := Map()
		for Key, Value in Profile {
			if !(Key is String) || !Allowed.Has(Key)
				return false
			if (Key == "stop_sequences") {
				if !(Value is Array)
					return false
				Sequences := []
				for Sequence in Value {
					if !(Sequence is String) || Sequence == ""
						return false
					Sequences.Push(Sequence)
				}
				Copy[Key] := Sequences
				continue
			}
			if (Key == "batch") {
				Copy[Key] := Value == 1
				continue
			}
			if !(Value is String)
				return false
			Copy[Key] := Value
		}
		Seen[Copy["id"]] := true
		Out.Push(Copy)
	}
	return Out
}

_LLM_Menu_SerializeUserProfiles(Profiles) {
	Profiles := _LLM_Menu_NormalizeStoredUserProfiles(Profiles)
	if !(Profiles is Array)
		return false
	Rows := []
	for Profile in Profiles {
		Fields := []
		for Key in ["id", "label", "system_single", "system_multi"] {
			Value := Profile[Key]
			Fields.Push('"' . Key . '":"' . _LLM_MenuApiJsonEscape(Value) . '"')
		}
		for Key in ["system_multi_template", "raw_prompt"] {
			if Profile.Has(Key)
				Fields.Push('"' . Key . '":"'
					. _LLM_MenuApiJsonEscape(Profile[Key]) . '"')
		}
		Fields.Push('"batch":' . (Profile["batch"] ? "true" : "false"))
		if Profile.Has("stop_sequences") {
			SequenceFields := []
			for Sequence in Profile["stop_sequences"]
				SequenceFields.Push('"' . _LLM_MenuApiJsonEscape(Sequence) . '"')
			Fields.Push('"stop_sequences":[' . _LLM_MenuJoin(SequenceFields, ",") . ']')
		}
		Rows.Push("{" . _LLM_MenuJoin(Fields, ",") . "}")
	}
	return "v1:" . CryptoBase64EncodeUtf8("[" . _LLM_MenuJoin(Rows, ",") . "]")
}

_LLM_Menu_DeserializeUserProfiles(Payload) {
	; The empty string is the declared neutral value of llm.user_profiles (its
	; manifest default, written by the neutral config template): no user
	; profile, as the Linux codec reads it (profile_registry_codec.lua).
	if (Payload is String) && Payload == ""
		return []
	if !(Payload is String) || SubStr(Payload, 1, 3) != "v1:"
		return false
	try Bytes := CryptoBase64Decode(SubStr(Payload, 4))
	catch
		return false
	try Parsed := JsonParse(StrGet(Bytes, Bytes.Size, "UTF-8"))
	catch
		return false
	if !(Parsed is Array)
		return false
	return _LLM_Menu_NormalizeStoredUserProfiles(Parsed)
}

_LLM_Menu_SerializeAppProfileOverrides(Overrides) {
	if !(Overrides is Map)
		return false
	; The declared neutral value (app_profile_overrides_vectors.json "encode").
	if Overrides.Count == 0
		return ""
	Rows := []
	for AppName, ProfileId in Overrides {
		if LLM_AppIdentity_Normalize(AppName) !== AppName || !(ProfileId is String) || ProfileId == ""
			return false
		Rows.Push('{"app":"' . _LLM_MenuApiJsonEscape(AppName)
			. '","profile":"' . _LLM_MenuApiJsonEscape(ProfileId) . '"}')
	}
	return "v1:" . CryptoBase64EncodeUtf8("[" . _LLM_MenuJoin(Rows, ",") . "]")
}

_LLM_Menu_DeserializeAppProfileOverrides(Payload) {
	if !(Payload is String)
		return false
	if Payload == "" || Payload == "_"
		return Map()
	if SubStr(Payload, 1, 3) !== "v1:"
		return false
	try Bytes := CryptoBase64Decode(SubStr(Payload, 4))
	catch
		return false
	try Parsed := JsonParse(StrGet(Bytes, Bytes.Size, "UTF-8"))
	catch
		return false
	if !(Parsed is Array)
		return false
	Decoded := Map()
	for Row in Parsed {
		if !(Row is Map) || !Row.Has("app") || !Row.Has("profile")
				|| LLM_AppIdentity_Normalize(Row["app"]) !== Row["app"]
				|| !(Row["profile"] is String) || Row["profile"] == ""
				|| StrLen(Row["profile"]) > 256 || Decoded.Has(Row["app"])
			return false
		Decoded[Row["app"]] := Row["profile"]
	}
	return Decoded
}

_LLM_Menu_ApplyProfileCommitted(*) {
	_LLM_Menu_ApplyStandardCommitted()
	return true
}

; Reuses the native pause owner for the drawn row and retained callbacks.
_LLM_Menu_CreateProfileReady(PausedFn) {
	try {
		Paused := PausedFn.Call()
		return (Paused is Integer) && Paused == 0
	} catch
		return false
}

_LLM_Menu_CreateProfileRow(OpenFn, PausedFn := 0) {
	if (PausedFn is Integer) && PausedFn == 0
		PausedFn := (*) => A_IsSuspended
	return MenuRenderer_CommandRow("llm_profile_commands", MenuCommand.LLM_PROFILE_CREATE,
		Map(MenuCommand.LLM_PROFILE_CREATE, OpenFn),
		Map("llm_profile_create_ready", _LLM_Menu_CreateProfileReady.Bind(PausedFn)))
}

/**
 * Builds the declared clone command through the existing native profile pause owner.
 * @param {Func} OpenFn - Existing transactional clone operation.
 * @param {Func|Integer} PausedFn - Exact native pause reader, or 0 for the live owner.
 * @returns {Map} Native provider row with retained-command admission.
 */
_LLM_Menu_CloneProfileRow(OpenFn, PausedFn := 0) {
	if (PausedFn is Integer) && PausedFn == 0
		PausedFn := (*) => A_IsSuspended
	return MenuRenderer_CommandRow("llm_profile_commands", MenuCommand.LLM_PROFILE_CLONE,
		Map(MenuCommand.LLM_PROFILE_CLONE, OpenFn),
		Map("llm_profile_clone_ready", _LLM_Menu_CreateProfileReady.Bind(PausedFn)))
}

/**
 * Opens the native multiline profile fallback and retains explicit cancellation.
 * InputBox creates a single-line Edit even when its dialog is tall.
 * @param {string} Prompt - Already translated body above the native Edit.
 * @param {string} Title - Brandless caption passed through WindowTitle.
 * @param {string} Options - Width, height and optional timeout, as w520 h320 T5.
 * @param {string} Default - Exact initial prompt text, including line breaks.
 * @returns {object} Result (OK, Cancel or Timeout) and entered Value.
 */
_LLM_Menu_ProfilePromptInput(Prompt, Title, Options := "", Default := "") {
	if Trim(RegExReplace(Options, "i)(?:^|\s)(?:[wh]\d+|t(?:\d+(?:\.\d*)?|\.\d+))(?=\s|$)", "")) != ""
		throw ValueError("The native profile prompt requires only width, height and timeout options.")
	Width := RegExMatch(Options, "i)(?:^|\s)w(\d+)(?=\s|$)", &Match) ? Integer(Match[1]) : 520
	Height := RegExMatch(Options, "i)(?:^|\s)h(\d+)(?=\s|$)", &Match) ? Integer(Match[1]) : 320
	Timeout := RegExMatch(Options, "i)(?:^|\s)t(\d+(?:\.\d*)?|\.\d+)(?=\s|$)", &Match) ? Number(Match[1]) : 0
	if Width < 240 || Height < 180 || Timeout < 0 || Timeout > 2147483
		throw ValueError("The native profile prompt dimensions or timeout are outside their supported bounds.")
	Dialog := Gui("", WindowTitle(Title))
	Receipt := {Result: "Cancel", Value: Default}
	Finished := false
	TimeoutFn := Finish.Bind("Timeout")
	try {
		Dialog.SetFont("s10", "Segoe UI")
		Dialog.AddText("x12 y12 w" . (Width - 24) . " h36", Prompt)
		Editor := Dialog.AddEdit("x12 y54 w" . (Width - 24) . " h" . (Height - 106)
			. " Multi WantReturn VScroll Limit0", Default)
		Dialog.AddButton("x" . (Width - 204) . " y" . (Height - 40) . " w90 Default", t("button.ok"))
			.OnEvent("Click", Finish.Bind("OK"))
		Dialog.AddButton("x+12 yp w90", t("button.cancel")).OnEvent("Click", Finish.Bind("Cancel"))
		Dialog.OnEvent("Close", Finish.Bind("Cancel"))
		Dialog.OnEvent("Escape", Finish.Bind("Cancel"))
		Hwnd := Dialog.Hwnd
		Dialog.Show("w" . Width . " h" . Height)
		if !Finished {
			if Timeout > 0
				SetTimer(TimeoutFn, -Max(1, Round(Timeout * 1000)))
			WinWaitClose("ahk_id " . Hwnd)
		}
		return Receipt
	} finally {
		SetTimer(TimeoutFn, 0)
		try Dialog.Destroy()
	}

	Finish(Status, *) {
		if Finished
			return
		Receipt.Value := Editor.Value
		Receipt.Result := Status
		Finished := true
		Dialog.Destroy()
	}
}

/**
 * Opens InputBox dialogs to create a new user profile (label + prompt).
 */
LLM_Menu_PromptCreateProfile(Port := 0) {
	if A_IsSuspended
		return false
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptCreateProfile(Port)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	Options := _LLM_Menu_ProfilePorts(Port)
	Source := _LLM_Menu_CaptureProfileSource()
	if !(Source is Map)
		return ConfigReportPersistenceFailure("the custom LLM profile creation", Options.Get("notify", 0),
			"the opening configuration source is unavailable")
	if A_IsSuspended
		return false
	InputFn := Options.Get("input", Ui_InputBox)
	PromptInputFn := Options.Get("prompt_input", Options.Has("input") ? InputFn : _LLM_Menu_ProfilePromptInput)

	; Prefer the shared WebView2 editor (identical rich UI to macOS). Falls back
	; to the native InputBox wizard below when the WebView2 runtime is absent.
	if _PromptEdWeb_TryOpen(0, Source)
		return

	; Step 1: label
	ib_label := InputFn.Call(t("menu.profiles.prompt_label"), t("menu.profiles.create_profile"), "w450 h120")
	if !_LLM_Menu_TryRequiredPrompt(ib_label.Result, ib_label.Value, &plabel)
		return

	if A_IsSuspended
		return false

	; Step 2: system prompt, including native pasted line breaks
	ib_prompt := PromptInputFn.Call(t("menu.profiles.prompt_system_single"), t("menu.profiles.create_profile"), "w520 h320")
	if (ib_prompt.Result != "OK")
		return
	system_single := ib_prompt.Value

	if A_IsSuspended
		return false

	; Generate a unique ID from the label
	pid := "user_" . LLM_Menu_Slugify(plabel) . "_" . A_TickCount

	new_profile := Map(
		"id",            pid,
		"label",         plabel,
		"system_single", system_single,
		"system_multi",  "",
		"batch",         false
	)

	return LLM_Menu_CommitMutation("the custom LLM profile creation",
		(Candidate) => _LLM_Menu_AddProfileCandidate(Candidate, new_profile),
		Options.Get("apply", _LLM_Menu_ApplyProfileCommitted),
		_LLM_Menu_WriteProfileSource.Bind(Source), _LLM_Menu_ProfileNotifyFailure.Bind(Source, Options.Get("notify", 0)),
		Options.Get("acquire", 0), Options.Get("settle", 0), Options.Get("collect", _LLM_Menu_ProfileProjectionUpdates),
		_LLM_Menu_ProfilePreparePublication.Bind(Source), _LLM_Menu_ProfilePublishCandidate.Bind(Source))
}

_LLM_Menu_AddProfileCandidate(Candidate, Profile) {
	if !(Candidate[ConfigLeaf.USER_PROFILES] is Array) || !(Profile is Map)
		return false
	Candidate[ConfigLeaf.USER_PROFILES].Push(LLM_Menu_DeepClone(Profile))
	Candidate["profile_id"] := Profile["id"]
	return true
}

/**
 * Opens InputBox dialogs to edit an existing user profile in place.
 * @param {Map} profile - The user profile to edit.
 */
LLM_Menu_PromptEditProfile(profile, Port := 0, OpeningSource := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptEditProfile(profile, Port, OpeningSource)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	Options := _LLM_Menu_ProfilePorts(Port)
	Source := OpeningSource is Map ? OpeningSource : _LLM_Menu_CaptureProfileSource()
	if !(Source is Map) || !_LLM_Menu_ProfileSourceBound(Source)
		return ConfigReportPersistenceFailure("the custom LLM profile edit", Options.Get("notify", 0),
			"the opening configuration source is unavailable")
	InputFn := Options.Get("input", Ui_InputBox)
	PromptInputFn := Options.Get("prompt_input", Options.Has("input") ? InputFn : _LLM_Menu_ProfilePromptInput)
	pid := profile.Has("id") ? profile["id"] : ""

	; Prefer the shared WebView2 editor (identical rich UI to macOS). Falls back
	; to the native InputBox wizard below when the WebView2 runtime is absent.
	if _PromptEdWeb_TryOpen(profile, Source)
		return

	ib_label := InputFn.Call(t("menu.profiles.prompt_label"), t("menu.profiles.edit_profile"), "w450 h120",
		profile.Has("label") ? profile["label"] : "")
	if !_LLM_Menu_TryRequiredPrompt(ib_label.Result, ib_label.Value, &new_label)
		return

	ib_prompt := PromptInputFn.Call(t("menu.profiles.prompt_system_single"), t("menu.profiles.edit_profile"), "w520 h320",
		profile.Has("system_single") ? profile["system_single"] : "")
	if (ib_prompt.Result != "OK")
		return

	return LLM_Menu_CommitMutation("the custom LLM profile edit",
		(Candidate) => _LLM_Menu_EditProfileCandidate(Candidate, pid,
			new_label, ib_prompt.Value), Options.Get("apply", _LLM_Menu_ApplyProfileCommitted),
		_LLM_Menu_WriteProfileSource.Bind(Source), _LLM_Menu_ProfileNotifyFailure.Bind(Source, Options.Get("notify", 0)),
		Options.Get("acquire", 0), Options.Get("settle", 0), Options.Get("collect", _LLM_Menu_ProfileProjectionUpdates),
		_LLM_Menu_ProfilePreparePublication.Bind(Source), _LLM_Menu_ProfilePublishCandidate.Bind(Source))
}

_LLM_Menu_EditProfileCandidate(Candidate, ProfileId, Label, Prompt) {
	for Profile in Candidate[ConfigLeaf.USER_PROFILES] {
		if (Profile.Has("id") && Profile["id"] == ProfileId) {
			Profile["label"] := Label
			Profile["system_single"] := Prompt
			return true
		}
	}
	return false
}

/**
 * Clones the currently-active built-in profile into a new user profile
 * pre-filled with the built-in's prompt, then opens the edit dialog so
 * the user can tweak it. The new profile inherits the built-in label
 * with a "(copy)" suffix and a fresh id so it never collides with the
 * source. Used by the "Cloner ce profil par défaut…" menu entry which
 * is the supported way to customise a built-in's system prompt.
 */
LLM_Menu_CloneActiveBuiltinProfile() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_CloneActiveBuiltinProfile()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	src_id := _LLM_Menu["profile_id"]
	; Pull the source profile from the live registry — covers the case
	; where the user re-loaded profiles.json without restarting.
	src_profile := LLM_GetActiveProfile(src_id, _LLM_Menu[ConfigLeaf.USER_PROFILES])
	if !IsObject(src_profile)
		return
	src_label := LLM_Menu_GetProfileLabel(src_id)
	new_id    := "user_" . LLM_Menu_Slugify(src_label) . "_" . A_TickCount
	new_label := src_label . " " . t("menu.profiles.copy_suffix")
	new_profile := Map(
		"id",                    new_id,
		"label",                 new_label,
		"system_single",         src_profile.Has("system_single")         ? src_profile["system_single"]         : "",
		"system_multi",          src_profile.Has("system_multi")          ? src_profile["system_multi"]          : "",
		"system_multi_template", src_profile.Has("system_multi_template") ? src_profile["system_multi_template"] : "",
		"batch",                 src_profile.Has("batch") and src_profile["batch"] == true
	)
	Committed := LLM_Menu_CommitMutation("the built-in LLM profile clone",
		(Candidate) => _LLM_Menu_AddProfileCandidate(Candidate, new_profile),
		_LLM_Menu_ApplyProfileCommitted)
	if !Committed
		return false
	; Immediately open the edit dialog so the user lands directly into
	; what they wanted: a customisable copy of the built-in prompt.
	LLM_Menu_PromptEditProfile(new_profile)
	return true
}

/**
 * Converts a label string into a safe ASCII slug for use as a profile ID.
 * @param {string} label - Source label.
 * @returns {string} Slugified string (lowercase alphanumeric + underscores).
 */
LLM_Menu_Slugify(label) {
	slug := RegExReplace(StrLower(label), "[^a-z0-9]+", "_")
	slug := Trim(slug, "_")
	return (slug == "") ? "profile" : slug
}





; ============================================
; ============================================
; ======= 4/ Auto-detect Profile/Model =======
; ============================================
; ============================================

/**
 * Returns the recommended profile id for a given model display name.
 * Mirrors the HS get_recommended_profile_info heuristic (ui/menu/menu_llm/init.lua):
 *   - completion-style models           → "raw"
 *   - params ≥ LLM_PROFILE_BATCH_PARAMS_B (4B) → "batch_advanced"
 *   - params ≥ LLM_PROFILE_ADVANCED_PARAMS_B (2B) → "advanced"
 *   - everything else (small models)    → "basic"
 *
 * Falls back to "basic" when the model is unknown so the menu never lands
 * on an undefined profile id.
 *
 * @param {string} model - Display name as stored in models.json.
 * @returns {string} One of "raw" | "basic" | "advanced" | "batch_advanced".
 */
LLM_RecommendProfileForModel(model) {
	global LLM_PROFILE_ADVANCED_PARAMS_B, LLM_PROFILE_BATCH_PARAMS_B
	if (model == "")
		return "basic"
	info := LLM_GetModelInfo(model)
	if (info["type"] == "completion")
		return "raw"
	; MoE models: the "active" parameter count drives runtime behaviour
	; much more than "total", so we gate the thresholds on the active count
	; — falls back to total when active is missing.
	effective := info.Has("active_b") && info["active_b"] > 0 ? info["active_b"] : info["params_b"]
	if (effective >= LLM_PROFILE_BATCH_PARAMS_B)
		return "batch_advanced"
	if (effective >= LLM_PROFILE_ADVANCED_PARAMS_B)
		return "advanced"
	return "basic"
}

/**
 * Applies the recommended profile for the active model, if the user has
 * enabled auto-detection. No-op when the recommended profile already
 * matches the current one. Returns the (possibly new) profile id so the
 * caller can refresh the menu in a single roundtrip.
 *
 * @returns {string} Profile id in effect after the call.
 */
LLM_Menu_AutoApplyProfileForModel(MenuState) {
	if !MenuState[ConfigLeaf.AUTO_PROFILE_FOR_MODEL]
		return MenuState["profile_id"]
	recommended := LLM_RecommendProfileForModel(MenuState["model"])
	if (recommended == "" or recommended == MenuState["profile_id"])
		return MenuState["profile_id"]
	MenuState["profile_id"] := recommended
	return recommended
}





; ==================================
; ==================================
; ======= 5/ Profile Hotkeys =======
; ==================================
; ==================================

/**
 * Returns the ordered list of profile ids exposed to the Ctrl+<n>
 * hotkeys: built-ins first (raw/basic/advanced/batch_advanced/rewrite) then
 * user profiles in the order they were defined. The tone ladder profiles are
 * left out: their own actions rewrite a selection, and taking four of the
 * nine digits would leave custom profiles none. The live translations are
 * left out for the same reason: live mode runs them. Truncated to
 * LLM_PROFILE_HOTKEY_LIMIT so we don't try to register more hotkeys than
 * the user can reach on a number row.
 *
 * @returns {Array} Ordered profile id strings.
 */
LLM_Menu_GetHotkeyProfileOrder(MenuState := 0) {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT, LLM_TONE_LADDER
	global LLM_PROFILE_LIVE_TRANSLATIONS
	State := MenuState is Map ? MenuState : _LLM_Menu
	if !(State is Map) || !State.Has(ConfigLeaf.USER_PROFILES)
			|| !(State[ConfigLeaf.USER_PROFILES] is Array)
		return []
	SkippedIds := Map()
	for ToneId in LLM_TONE_LADDER
		SkippedIds[ToneId] := true
	for TranslationId in LLM_PROFILE_LIVE_TRANSLATIONS
		SkippedIds[TranslationId] := true
	out := []
	for _, id in LLM_PROFILE_BUILTIN_ORDER {
		if SkippedIds.Has(id)
			continue
		out.Push(id)
		if (out.Length >= LLM_PROFILE_HOTKEY_LIMIT)
			return out
	}
	for p in State[ConfigLeaf.USER_PROFILES] {
		if !(p is Map) or !p.Has("id")
			continue
		out.Push(p["id"])
		if (out.Length >= LLM_PROFILE_HOTKEY_LIMIT)
			return out
	}
	return out
}

_LLM_Menu_ProfileCandidateIds(MenuState) {
	global LLM_PROFILE_BUILTIN_ORDER
	if !(MenuState is Map) || !MenuState.Has(ConfigLeaf.USER_PROFILES)
			|| !(MenuState[ConfigLeaf.USER_PROFILES] is Array)
		return 0
	Ids := Map()
	for Id in LLM_PROFILE_BUILTIN_ORDER {
		if !(Id is String) || Id == "" || Ids.Has(Id)
			return 0
		Ids[Id] := true
	}
	for Profile in MenuState[ConfigLeaf.USER_PROFILES] {
		if !(Profile is Map) || !Profile.Has("id")
				|| !(Profile["id"] is String) || Profile["id"] == ""
				|| Ids.Has(Profile["id"])
			return 0
		Ids[Profile["id"]] := true
	}
	return Ids
}

; Attributes a profile-owner preparation refusal, then returns the 0 the callers
; already expect. Throttled by the logger's own identical-line suppression, which
; matters because a wedged receipt reaches this path on every service tick.
; @param Reason {String} Which invariant refused, in the caller's own words.
; @returns {Integer} Always 0 — the refusal sentinel this function's callers test.
_LLM_Menu_RefuseProfileOwnerCandidate(Reason) {
	try LoggerError("LLM",
		"Profile hotkey owner preparation refused: {1}.", Reason)
	return 0
}

_LLM_Menu_PrepareProfileOwnerCandidate(CandidateMenu,
		AllowLifecycleResume := false) {
	global _LLM_Menu_ProfileHotkeyOwner
	if !(_LLM_Menu_ProfileHotkeyOwner is Map)
			|| !_LLM_Menu_ProfileHotkeyOwner.Get("native", false)
		return Map("changed", false)
	Plan := _LLM_Menu_ProfileHotkeyOwner.Get("plan", 0)
	Order := LLM_Menu_GetHotkeyProfileOrder(CandidateMenu)
	CandidateIds := _LLM_Menu_ProfileCandidateIds(CandidateMenu)
	; Every refusal below produced the same bare 0, and its caller turned that
	; into one indistinguishable sentence. Three branches can fail here for
	; unrelated reasons, so a field log could say only THAT the preparation was
	; refused, never which invariant broke. Name the branch
	; (llm-profile-receipt-retry-livelock).
	if !(Plan is Array) || !(CandidateIds is Map)
		return _LLM_Menu_RefuseProfileOwnerCandidate(!(Plan is Array)
			? "the published hotkey plan is not an Array"
			: "the candidate profile ids are malformed or contain a duplicate")
	Enabled := CandidateMenu.Get("enabled", false) ? 1 : 0
	; Retired profile owners may still retain suppressed receipts after the
	; active surface was disabled or otherwise remained byte-identical. Validate
	; every retained token before taking the no-op path.
	if !LLM_NavEventOwner_ProfileCandidateIsAdmissible(CandidateIds)
		return _LLM_Menu_RefuseProfileOwnerCandidate(
			"a retained owner holds a pending receipt for a profile the candidate "
			. "no longer defines")
	if LLM_NavEventOwner_ProfileSurfaceMatches(Order, Enabled)
		return Map("changed", false)
	Transaction := LLM_NavEventOwner_BeginProfileSwap(
		Plan, Order, Enabled, CandidateIds, 0, AllowLifecycleResume)
	if !(Transaction is Map)
		return _LLM_Menu_RefuseProfileOwnerCandidate(
			"the native owner refused the profile hotkey swap")
	Transaction["changed"] := true
	return Transaction
}

_LLM_Menu_CommitProfileOwnerCandidate(Transaction) {
	if !(Transaction is Map)
		return false
	if !Transaction.Get("changed", false)
		return true
	return LLM_NavEventOwner_CommitProfileSwap(Transaction)
}

_LLM_Menu_AbortProfileOwnerCandidate(Transaction) {
	if !(Transaction is Map) || !Transaction.Get("changed", false)
		return true
	return LLM_NavEventOwner_AbortProfileSwap(Transaction)
}

_LLM_Menu_PublishCurrentNativeProfileOwner(
		AllowLifecycleResume := false) {
	global _LLM_Menu, _LLM_Menu_ProfileHotkeyOwner
	if !(_LLM_Menu_ProfileHotkeyOwner is Map)
			|| !_LLM_Menu_ProfileHotkeyOwner.Get("native", false)
		return true
	if !IsSet(_LLM_Menu) || !(_LLM_Menu is Map)
		return false
	Transaction := _LLM_Menu_PrepareProfileOwnerCandidate(
		_LLM_Menu, AllowLifecycleResume)
	return Transaction is Map
		&& _LLM_Menu_CommitProfileOwnerCandidate(Transaction)
}

/**
 * Looks up the Ctrl+<n> label for a given profile id, or "" when the
 * profile is not in the hotkey range. Used by LLM_Menu_BuildProfileMenu
 * to append "(Ctrl+1)" / "(Ctrl+2)" hints next to each row so the user
 * sees the binding without having to read the docs.
 *
 * @param {string} id - Profile id (built-in or user-defined).
 * @returns {string} "Ctrl+<n>" or "" when the profile is unbound.
 */
LLM_Menu_GetProfileHotkeyHint(id) {
	for i, pid in LLM_Menu_GetHotkeyProfileOrder() {
		if (pid == id)
			return "Ctrl+" . i
	}
	return ""
}

; Stable BoundFunc used as the HotIf predicate for all Ctrl+<n> profile
; bindings. Allocating it once at module load means every call to
; LLM_Menu_BindProfileHotkeys reuses the SAME function reference. AHK v2
; keyed HotIf contexts on the function reference: a fresh lambda on each call
; would create a new context, orphaning the previous bindings and leaking them.
global _LLM_PROFILE_HOTKEY_PRED := _LLM_Menu_IsProfileHotkeyActive.Bind()
; Published only after all fixed Ctrl+digit variants exist and the dynamic
; HotIf context has been reset. Partially-created native variants remain inert
; because their stable predicate refuses while this owner is absent.
global _LLM_Menu_ProfileHotkeyOwner := 0
global _LLM_Menu_ProfileHotkeyFailureCount := 0
global _LLM_PROFILE_HOTKEY_STATUS_READY := 1
global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED := -1
global _LLM_PROFILE_HOTKEY_RETRY_LIMIT := 3

/**
 * Registers Ctrl+1 … Ctrl+9 globally so the user can switch profiles from
 * any focused app. Production keeps those AHK variants inert and publishes the
 * same fixed physical plan to the native event owner. Each admitted receipt
 * retains its immutable profile order until exact completion. Test seams may
 * still exercise the legacy callbacks without installing the native hook.
 */
LLM_Menu_BindProfileHotkeys(HotkeyFn := 0, HotIfFn := 0, LogFn := 0,
		ResetFn := 0, SelectFn := 0, KeyResolverFn := 0) {
	global _LLM_PROFILE_HOTKEY_PRED, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_PROFILE_HOTKEY_STATUS_READY
	global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	global _LLM_PROFILE_HOTKEY_RETRY_LIMIT
	UseNativeOwner := !HasMethod(HotkeyFn, "Call")
		&& !HasMethod(HotIfFn, "Call")
		&& !HasMethod(ResetFn, "Call")
		&& !HasMethod(SelectFn, "Call")
		&& !HasMethod(KeyResolverFn, "Call")
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_BindProfileHotkeys(HotkeyFn, HotIfFn, LogFn,
			ResetFn, SelectFn, KeyResolverFn)
		finally Critical(InheritedCritical)
	}
	if (_LLM_Menu_ProfileHotkeyOwner is Map) {
		return _LLM_Menu_ProfileHotkeyOwnerReady()
			? _LLM_PROFILE_HOTKEY_STATUS_READY
			: _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	}
	if !HasMethod(HotkeyFn, "Call")
		HotkeyFn := _LLM_Menu_ProfileNativeHotkey
	if !HasMethod(HotIfFn, "Call")
		HotIfFn := _LLM_Menu_ProfileNativeHotIf
	if !HasMethod(ResetFn, "Call")
		ResetFn := _LLM_Menu_ProfileNativeHotIf
	if !HasMethod(SelectFn, "Call")
		SelectFn := _LLM_Menu_ProfileNativeSelect
	KeyResolverFn := _LLM_Menu_HotkeyKeyResolverSnapshot(KeyResolverFn)
	CandidatePlan := HasMethod(KeyResolverFn, "Call")
		? _LLM_Menu_BuildProfileHotkeyPlan(SelectFn, KeyResolverFn) : false

	PreviousCritical := Critical("On")
	OpenAttempted := false
	Succeeded := false
	FailureDetail := ""
	ResetFailure := 0
	TerminalStatus := 0
	try {
		try {
			if !(CandidatePlan is Array)
				throw Error("Profile hotkey physical ownership could not be resolved")
			OpenAttempted := true
			HotIfFn.Call(_LLM_PROFILE_HOTKEY_PRED)
			for Entry in CandidatePlan
				HotkeyFn.Call(Entry["native_spec"], Entry["callback"], "On")
			Succeeded := true
		} catch as e {
			FailureDetail := "Profile hotkey transaction failed: " . e.Message
		} finally {
			if OpenAttempted {
				try _LLM_Menu_ProfileCloseHotIf(HotIfFn, ResetFn)
				catch as e {
					ResetFailure := e
					Succeeded := false
					FailureDetail := e.Message
				}
			}
			if Succeeded && !UseNativeOwner {
				_LLM_Menu_ProfileHotkeyFailureCount := 0
				_LLM_Menu_ProfileHotkeyOwner := Map(
					"ready", true, "degraded", false,
					"native", false, "plan", CandidatePlan)
				TerminalStatus := _LLM_PROFILE_HOTKEY_STATUS_READY
			} else if !Succeeded && !IsObject(ResetFailure) {
				_LLM_Menu_ProfileHotkeyFailureCount := Min(
					_LLM_Menu_ProfileHotkeyFailureCount + 1,
					_LLM_PROFILE_HOTKEY_RETRY_LIMIT)
				if (_LLM_Menu_ProfileHotkeyFailureCount
						>= _LLM_PROFILE_HOTKEY_RETRY_LIMIT) {
					_LLM_Menu_ProfileHotkeyOwner := Map(
						"ready", false, "degraded", true, "plan", [])
					TerminalStatus := _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
				}
			}
		}
	} finally Critical(PreviousCritical)
	if IsObject(ResetFailure) {
		_LLM_Menu_LogProfileHotkeyFailure(FailureDetail, LogFn)
		throw TrayRootFatalContextError(ResetFailure.Message, -1,
			ResetFailure.Extra)
	}
	if Succeeded && UseNativeOwner {
		NativePublished := _LLM_Menu_ActivateInitialNativeProfileOwner(
			CandidatePlan)
		PreviousCritical := Critical("On")
		try {
			if NativePublished {
				_LLM_Menu_ProfileHotkeyFailureCount := 0
				_LLM_Menu_ProfileHotkeyOwner := Map(
					"ready", true, "degraded", false,
					"native", true, "plan", CandidatePlan)
				TerminalStatus := _LLM_PROFILE_HOTKEY_STATUS_READY
			} else {
				_LLM_Menu_ProfileHotkeyFailureCount := Min(
					_LLM_Menu_ProfileHotkeyFailureCount + 1,
					_LLM_PROFILE_HOTKEY_RETRY_LIMIT)
				if (_LLM_Menu_ProfileHotkeyFailureCount
						>= _LLM_PROFILE_HOTKEY_RETRY_LIMIT) {
					_LLM_Menu_ProfileHotkeyOwner := Map(
						"ready", false, "degraded", true,
						"native", false, "plan", [])
					TerminalStatus := _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
				}
			}
		} finally Critical(PreviousCritical)
		if !NativePublished
			FailureDetail := "Profile hotkey native ownership was refused"
	}
	if (TerminalStatus == _LLM_PROFILE_HOTKEY_STATUS_DEGRADED) {
		_LLM_Menu_LogProfileHotkeyFailure(FailureDetail, LogFn)
		return _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	}
	return TerminalStatus
}

_LLM_Menu_ActivateInitialNativeProfileOwner(Plan) {
	global _LLM_Menu
	if !IsSet(_LLM_Menu) || !(_LLM_Menu is Map)
		return false
	Order := LLM_Menu_GetHotkeyProfileOrder(_LLM_Menu)
	CandidateIds := _LLM_Menu_ProfileCandidateIds(_LLM_Menu)
	if !(CandidateIds is Map)
		return false
	Enabled := _LLM_Menu.Get("enabled", false) ? 1 : 0
	if !LLM_NavEventOwner_ProfileCandidateIsAdmissible(CandidateIds)
		return false
	if LLM_NavEventOwner_ProfileSurfaceMatches(Order, Enabled)
		return true
	Transaction := LLM_NavEventOwner_BeginProfileSwap(
		Plan, Order, Enabled, CandidateIds)
	return Transaction is Map
		&& LLM_NavEventOwner_CommitProfileSwap(Transaction)
}

_LLM_Menu_ProfileNativeHotkey(Args*) {
	Hotkey(Args*)
}

_LLM_Menu_ProfileNativeHotIf(Args*) {
	HotIf(Args*)
}

_LLM_Menu_ProfileNativeSelect(ProfileId) {
	return LLM_Menu_SetProfile(ProfileId)
}

_LLM_Menu_BuildProfileHotkeyPlan(SelectFn := 0, KeyResolverFn := 0) {
	global LLM_PROFILE_HOTKEY_LIMIT
	if !HasMethod(SelectFn, "Call")
		SelectFn := _LLM_Menu_ProfileNativeSelect
	Plan := []
	loop LLM_PROFILE_HOTKEY_LIMIT {
		Index := A_Index
		Plan.Push(Map("spec", "^" . Index,
			"profile_idx", Index,
			"callback", _LLM_Menu_MakeProfileHotkey(Index, SelectFn)))
	}
	if !_LLM_Menu_AttachPlanPhysicalIdentities(Plan, KeyResolverFn)
		return false
	return Plan
}

_LLM_Menu_ProfileCloseHotIf(HotIfFn, ResetFn) {
	Loop 2 {
		try {
			HotIfFn.Call()
			return true
		} catch {
		}
	}
	try {
		ResetFn.Call()
		return true
	} catch as e {
		throw Error("Profile HotIf reset could not be proven", -1, e.Message)
	}
}

_LLM_Menu_LogProfileHotkeyFailure(Message, LogFn := 0) {
	if HasMethod(LogFn, "Call") {
		try LogFn.Call(Message)
		return
	}
	try LoggerError("LLM", "Profile hotkey registration failed: {1}.",
		Message)
}

_LLM_Menu_ProfileHotkeyOwnerReady() {
	global _LLM_Menu_ProfileHotkeyOwner, LLM_PROFILE_HOTKEY_LIMIT
	Owner := _LLM_Menu_ProfileHotkeyOwner
	if !(Owner is Map)
		return false
	Ready := Owner.Get("ready", false)
	Degraded := Owner.Get("degraded", false)
	Plan := Owner.Get("plan", 0)
	if !((Ready is Integer) && Ready == 1
			&& (Degraded is Integer) && Degraded == 0
			&& (Plan is Array) && Plan.Length == LLM_PROFILE_HOTKEY_LIMIT)
		return false
	SeenNative := Map()
	SeenPhysical := Map()
	Loop Plan.Length {
		Index := A_Index
		if !Plan.Has(Index)
			return false
		Entry := Plan[Index]
		if !(Entry is Map)
				|| Entry.Get("spec", "") != "^" . Index
				|| !(Entry.Get("profile_idx", 0) is Integer)
				|| Entry.Get("profile_idx", 0) != Index
				|| !_LLM_Menu_PlanEntryDescriptorIsValid(Entry)
				|| !HasMethod(Entry.Get("callback", 0), "Call")
			return false
		NativeId := Entry["native_id"]
		PhysicalId := Entry["physical_id"]
		if SeenNative.Has(NativeId) || SeenPhysical.Has(PhysicalId)
			return false
		SeenNative[NativeId] := true
		SeenPhysical[PhysicalId] := true
	}
	return true
}

_LLM_Menu_ProfileHotkeyRetryPending() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	return !(_LLM_Menu_ProfileHotkeyOwner is Map)
		&& _LLM_Menu_ProfileHotkeyFailureCount > 0
}

/**
 * Predicate used by ``HotIf`` to decide whether the Ctrl+<n> bindings are
 * active. True only when the LLM tray reports enabled AND the concrete
 * Ctrl+digit index maps to a configured profile. An ineligible variant lets
 * Windows deliver the original physical event to the next eligible owner (or
 * the app) unchanged. Cross-surface collisions are tracked separately.
 */
_LLM_Menu_ProfileHotkeyIndex(ThisHotkey) {
	Identity := _LLM_Menu_NavNativeIdentity(ThisHotkey)
	if Identity == ""
		return 0
	global _LLM_Menu_ProfileHotkeyOwner
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_Menu_ProfileHotkeyOwner is Map)
			return 0
		Plan := _LLM_Menu_ProfileHotkeyOwner.Get("plan", 0)
		if !(Plan is Array)
			return 0
		for Entry in Plan {
			if Entry is Map && Entry.Get("native_id", "") == Identity {
				Index := Entry.Get("profile_idx", 0)
				return (Index is Integer) && Index >= 1 && Index <= 9
					? Index : 0
			}
		}
		return 0
	} finally Critical(PreviousCritical)
}

_LLM_Menu_IsProfileHotkeyActive(ThisHotkey := "") {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Menu_ProfileHotkeyOwner
	if !_LLM_Menu_Loaded || !_LLM_Menu_ProfileHotkeyOwnerReady()
		return false
	; Production variants are registration-only compatibility shells. The native
	; hook owns the physical event and emits an immutable profile receipt instead.
	if _LLM_Menu_ProfileHotkeyOwner.Get("native", false)
		return false
	if !IsSet(_LLM_Menu) or !_LLM_Menu["enabled"]
		return false
	Index := _LLM_Menu_ProfileHotkeyIndex(ThisHotkey)
	if !Index
		return false
	Order := LLM_Menu_GetHotkeyProfileOrder()
	if (Index > Order.Length)
		return false
	; Yield only when the published navigation owner has the exact same variant.
	; A broad tooltip-visible gate would swallow Ctrl+digits while navigation uses
	; Alt or Shift; AHK passes the concrete hotkey name to this predicate.
	if LLM_Menu_NavOwnsSpec(ThisHotkey)
		return false
	return true
}

/**
 * Builds the compatibility closure assigned to a Ctrl+<n> shortcut. Production
 * disarms it after native ownership publishes; injected registration tests keep
 * the legacy dynamic route available without installing a system hook.
 */
_LLM_Menu_MakeProfileHotkey(idx, SelectFn := 0) {
	if !HasMethod(SelectFn, "Call")
		SelectFn := _LLM_Menu_ProfileNativeSelect
	return (*) => _LLM_Menu_OnProfileHotkey(idx, SelectFn)
}

_LLM_Menu_OnProfileHotkey(idx, SelectFn := 0) {
	global _LLM_Menu_ProfileHotkeyOwner
	if (_LLM_Menu_ProfileHotkeyOwner is Map)
			&& _LLM_Menu_ProfileHotkeyOwner.Get("native", false)
		return false
	; The predicate owns only in-range digits. Recheck because the separate
	; HotIf callback thread can observe a newer profile order; never synthesize a
	; replacement chord here because that would not be native pass-through.
	if !(idx is Integer) || idx < 1
		return false
	Order := LLM_Menu_GetHotkeyProfileOrder()
	if (idx > Order.Length)
		return false
	if !HasMethod(SelectFn, "Call")
		SelectFn := _LLM_Menu_ProfileNativeSelect
	return SelectFn.Call(Order[idx])
}

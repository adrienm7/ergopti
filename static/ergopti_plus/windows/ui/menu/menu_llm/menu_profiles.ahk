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
	for p in _LLM_Menu["user_profiles"] {
		if (p.Has("id") && p["id"] == id)
			return p.Has("label") ? p["label"] : id
	}

	; Built-in profile labels
	if (id == "raw")
		return t("llm.profile.raw.label")
	if (id == "basic")
		return t("llm.profile.basic.label")
	if (id == "advanced")
		return t("llm.profile.advanced.label")
	if (id == "batch_advanced")
		return StrReplace(StrReplace(t("llm.profile.batch_advanced.label"), "{n}", n), "{s}", s)
	return id
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
	Seen[Label] := (Seen.Has(Label) ? Seen[Label] : 0) + 1
	return (Seen[Label] > 1) ? (Label . " #" . Seen[Label]) : Label
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
 * @returns {Array} Built-in profiles, user profiles, the CRUD rows, the
 *                  auto-detect toggle and the per-app overrides submenu.
 */
_LLM_Menu_ProfileRows() {
	global _LLM_Menu
	Rows := []

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

	; Section header: built-in profiles
	Rows.Push(Map("label", t("menu.profiles.header_default_profiles")))

	for id in ["raw", "basic", "advanced", "batch_advanced"] {
		base_label := LLM_Menu_GetProfileLabel(id)
		hint := LLM_Menu_GetProfileHotkeyHint(id)
		label := (hint != "") ? base_label . "  (" . hint . ")" : base_label
		Rows.Push(Map(
			"label",   _LLM_Menu_UniqueMenuLabel(seen_labels, label),
			"checked", (id == _LLM_Menu["profile_id"]),
			"action",  _LLM_Menu_MakeSetProfileHandler(id)))
	}

	; Section: user profiles
	user_profiles := _LLM_Menu["user_profiles"]
	if (user_profiles.Length > 0) {
		Rows.Push(Map("separator", true))
		Rows.Push(Map("label", t("menu.profiles.header_custom_profiles")))

		for p in user_profiles {
			pid         := p.Has("id") ? p["id"] : ""
			base_plabel := p.Has("label") ? p["label"] : pid
			hint := LLM_Menu_GetProfileHotkeyHint(pid)
			plabel := (hint != "") ? base_plabel . "  (" . hint . ")" : base_plabel
			Rows.Push(Map(
				"label",   _LLM_Menu_UniqueMenuLabel(seen_labels, plabel),
				"checked", (pid == _LLM_Menu["profile_id"]),
				"action",  _LLM_Menu_MakeUserProfileClickHandler(p)))
		}
	}

	Rows.Push(Map("separator", true))
	Rows.Push(Map(
		"label",  t("menu.profiles.create_profile"),
		"action", (*) => LLM_Menu_PromptCreateProfile()))

	; "Clone active built-in" — exposes the built-in system prompt for
	; editing without requiring the user to type it from scratch. The
	; built-in profiles in profiles.json are read-only by design (they're
	; shared across drivers and any local edit would be overwritten on
	; the next driver update); cloning them into a user profile is the
	; supported way to customise their prompts.
	active_id := _LLM_Menu["profile_id"]
	is_builtin := (active_id == "raw" or active_id == "basic" or active_id == "advanced" or active_id == "batch_advanced")
	if is_builtin {
		Rows.Push(Map(
			"label",  t("menu.profiles.clone_builtin"),
			"action", (*) => LLM_Menu_CloneActiveBuiltinProfile()))
	}

	; Auto-detect toggle: when ON, switching model in the model submenu also
	; re-picks the matching profile based on the params count. Mirrors the
	; HS get_recommended_profile_info path so the two drivers agree on what
	; profile each model should run with by default.
	Rows.Push(Map("separator", true))
	Rows.Push(Map(
		"label",   t("menu.profiles.auto_detect"),
		"checked", _LLM_Menu["auto_profile_for_model"],
		"action",  (*) => _LLM_Menu_ToggleAutoProfile()))

	; Per-app profile overrides — the rows list the current ones; the focused
	; app is read at click time, not here.
	Rows.Push(Map("separator", true))
	Rows.Push(Map(
		"label", t("menu.profiles.per_app_overrides"),
		"items", _LLM_Menu_PerAppProfileRows()))
	return Rows
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
	overrides := _LLM_Menu["app_profile_overrides"]
	; "Override active app with the currently-selected profile". Lazy
	; closure so WinGetProcessName fires when the user clicks, not when
	; the menu is built.
	Rows := [Map(
		"label",  t("menu.profiles.override_active_app_with_current"),
		"action", (*) => _LLM_Menu_AddOverrideForActiveApp())]
	if (overrides is Map and overrides.Count > 0) {
		Rows.Push(Map("separator", true))
		; List each override: "slack → informel"  + click clears it.
		for app_name, profile_id in overrides {
			Rows.Push(Map(
				"label",  app_name . "  →  " . LLM_Menu_GetProfileLabel(profile_id),
				"action", _LLM_Menu_MakeClearOverrideHandler(app_name)))
		}
	}
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
	try app := StrLower(WinGetProcessName("A"))
	app := RegExReplace(app, "\.exe$", "")
	if (app == "")
		return false
	return LLM_Menu_CommitMutation("the active-application profile override",
		(Candidate) => _LLM_Menu_SetOverrideCandidate(Candidate, app),
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_SetOverrideCandidate(Candidate, AppName) {
	if !(Candidate is Map)
			|| !(Candidate["app_profile_overrides"] is Map)
		return false
	Candidate["app_profile_overrides"][AppName] := Candidate["profile_id"]
	return true
}

_LLM_Menu_ClearOverrideFor(app_name) {
	global _LLM_Menu
	overrides := _LLM_Menu["app_profile_overrides"]
	if !(overrides is Map) or !overrides.Has(app_name)
		return false
	return LLM_Menu_CommitMutation("the application profile override removal",
		(Candidate) => _LLM_Menu_ClearOverrideCandidate(Candidate, app_name),
		_LLM_Menu_ApplyStandardCommitted)
}

_LLM_Menu_ClearOverrideCandidate(Candidate, AppName) {
	Overrides := Candidate["app_profile_overrides"]
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
	Candidate["auto_profile_for_model"] := !Candidate["auto_profile_for_model"]
	if Candidate["auto_profile_for_model"]
		LLM_Menu_AutoApplyProfileForModel(Candidate)
	return true
}





; ====================================
; ====================================
; ======= 3/ User Profile CRUD =======
; ====================================
; ====================================

/**
 * Shows a context sub-menu style dialog for a user profile (use / edit / delete).
 * AHK has no native submenu on the fly; we show a MsgBox with button choices.
 * @param {Map} profile - The user profile Map object.
 */
LLM_Menu_OnUserProfileClick(profile) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_OnUserProfileClick(profile)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	pid    := profile.Has("id")    ? profile["id"]    : ""
	plabel := profile.Has("label") ? profile["label"] : pid

	choice := MsgBox(
		t("menu.profiles.use_profile") . "`n"
		. t("menu.profiles.edit_profile") . "`n"
		. t("menu.profiles.delete_profile"),
		plabel,
		"3 32"  ; Yes/No/Cancel buttons + question icon
	)

	if (choice == "Yes") {
		; Use this profile
		LLM_Menu_SetProfile(pid)
	} else if (choice == "No") {
		; Edit this profile
		LLM_Menu_PromptEditProfile(profile)
	} else if (choice == "Cancel") {
		confirm := MsgBox(t("menu.profiles.delete_profile") . " ?", plabel, "4 48")
		if (confirm == "Yes") {
			return LLM_Menu_CommitMutation("the custom LLM profile removal",
				(Candidate) => _LLM_Menu_DeleteProfileCandidate(Candidate, pid),
				_LLM_Menu_ApplyProfileCommitted)
		}
	}
	return true
}

_LLM_Menu_DeleteProfileCandidate(Candidate, ProfileId) {
	if !(Candidate is Map) || !(ProfileId is String) || ProfileId == ""
			|| !Candidate.Has("user_profiles")
			|| !(Candidate["user_profiles"] is Array)
			|| !Candidate.Has("profile_id")
			|| !(Candidate["profile_id"] is String)
		return false
	Profiles := Candidate["user_profiles"]
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
	if Candidate.Has("app_profile_overrides") {
		Overrides := Candidate["app_profile_overrides"]
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
	if !(MenuState is Map) || !MenuState.Has("app_profile_overrides")
			|| !(MenuState["app_profile_overrides"] is Map)
			|| !MenuState.Has("user_profiles")
			|| !(MenuState["user_profiles"] is Array)
		return false
	Valid := Map("raw", true, "basic", true, "advanced", true, "batch_advanced", true)
	for Profile in MenuState["user_profiles"] {
		if !(Profile is Map) || !Profile.Has("id")
				|| !(Profile["id"] is String) || Profile["id"] == ""
			return false
		Valid[Profile["id"]] := true
	}
	OrphanKeys := []
	for AppName, ProfileId in MenuState["app_profile_overrides"] {
		if !(ProfileId is String) || !Valid.Has(ProfileId)
			OrphanKeys.Push(AppName)
	}
	for AppName in OrphanKeys
		MenuState["app_profile_overrides"].Delete(AppName)
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
	Rows := []
	for AppName, ProfileId in Overrides {
		if !(AppName is String) || AppName == "" || !(ProfileId is String) || ProfileId == ""
			return false
		Rows.Push('{"app":"' . _LLM_MenuApiJsonEscape(AppName)
			. '","profile":"' . _LLM_MenuApiJsonEscape(ProfileId) . '"}')
	}
	return "v1:" . CryptoBase64EncodeUtf8("[" . _LLM_MenuJoin(Rows, ",") . "]")
}

_LLM_Menu_DeserializeAppProfileOverrides(Payload) {
	if !(Payload is String)
		return false
	if SubStr(Payload, 1, 3) != "v1:" {
		; Strict migration reader for the legacy app=profile;... representation.
		Decoded := Map()
		for Pair in StrSplit(Payload, ";") {
			Pair := Trim(Pair)
			if Pair == ""
				continue
			Parts := StrSplit(Pair, "=", , 2)
			if Parts.Length != 2 || Parts[1] == "" || Parts[2] == "" || Decoded.Has(Parts[1])
				return false
			Decoded[Parts[1]] := Parts[2]
		}
		return Decoded
	}
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
				|| !(Row["app"] is String) || Row["app"] == ""
				|| !(Row["profile"] is String) || Row["profile"] == ""
				|| Decoded.Has(Row["app"])
			return false
		Decoded[Row["app"]] := Row["profile"]
	}
	return Decoded
}

_LLM_Menu_ApplyProfileCommitted(*) {
	_LLM_Menu_ApplyStandardCommitted()
	return true
}

/**
 * Opens InputBox dialogs to create a new user profile (label + prompt).
 */
LLM_Menu_PromptCreateProfile() {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptCreateProfile()
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu

	; Prefer the shared WebView2 editor (identical rich UI to macOS). Falls back
	; to the native InputBox wizard below when the WebView2 runtime is absent.
	if _PromptEdWeb_TryOpen(0)
		return

	; Step 1: label
	ib_label := InputBox(t("menu.profiles.prompt_label"), t("menu.profiles.create_profile"), "w450 h120")
	if (ib_label.Result != "OK" || Trim(ib_label.Value) == "")
		return
	plabel := Trim(ib_label.Value)

	; Step 2: system prompt (multi-line via Edit control)
	ib_prompt := InputBox(t("menu.profiles.prompt_system_single"), t("menu.profiles.create_profile"), "w520 h320")
	if (ib_prompt.Result != "OK")
		return
	system_single := ib_prompt.Value

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
		_LLM_Menu_ApplyProfileCommitted)
}

_LLM_Menu_AddProfileCandidate(Candidate, Profile) {
	if !(Candidate["user_profiles"] is Array) || !(Profile is Map)
		return false
	Candidate["user_profiles"].Push(LLM_Menu_DeepClone(Profile))
	Candidate["profile_id"] := Profile["id"]
	return true
}

/**
 * Opens InputBox dialogs to edit an existing user profile in place.
 * @param {Map} profile - The user profile to edit.
 */
LLM_Menu_PromptEditProfile(profile) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LLM_Menu_PromptEditProfile(profile)
		finally Critical(InheritedCritical)
	}
	global _LLM_Menu
	pid := profile.Has("id") ? profile["id"] : ""

	; Prefer the shared WebView2 editor (identical rich UI to macOS). Falls back
	; to the native InputBox wizard below when the WebView2 runtime is absent.
	if _PromptEdWeb_TryOpen(profile)
		return

	ib_label := InputBox(t("menu.profiles.prompt_label"), t("menu.profiles.edit_profile"), "w450 h120",
		profile.Has("label") ? profile["label"] : "")
	if (ib_label.Result != "OK")
		return
	new_label := Trim(ib_label.Value)
	if (new_label == "")
		return

	ib_prompt := InputBox(t("menu.profiles.prompt_system_single"), t("menu.profiles.edit_profile"), "w520 h320",
		profile.Has("system_single") ? profile["system_single"] : "")
	if (ib_prompt.Result != "OK")
		return

	return LLM_Menu_CommitMutation("the custom LLM profile edit",
		(Candidate) => _LLM_Menu_EditProfileCandidate(Candidate, pid,
			new_label, ib_prompt.Value), _LLM_Menu_ApplyProfileCommitted)
}

_LLM_Menu_EditProfileCandidate(Candidate, ProfileId, Label, Prompt) {
	for Profile in Candidate["user_profiles"] {
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
	src_profile := LLM_GetActiveProfile(src_id, _LLM_Menu["user_profiles"])
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
	if !MenuState["auto_profile_for_model"]
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
 * hotkeys: built-ins first (raw/basic/advanced/batch_advanced) then user
 * profiles in the order they were defined. Truncated to
 * LLM_PROFILE_HOTKEY_LIMIT so we don't try to register more hotkeys than
 * the user can reach on a number row.
 *
 * @returns {Array} Ordered profile id strings.
 */
LLM_Menu_GetHotkeyProfileOrder() {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	out := []
	for _, id in LLM_PROFILE_BUILTIN_ORDER {
		out.Push(id)
		if (out.Length >= LLM_PROFILE_HOTKEY_LIMIT)
			return out
	}
	for p in _LLM_Menu["user_profiles"] {
		if !(p is Map) or !p.Has("id")
			continue
		out.Push(p["id"])
		if (out.Length >= LLM_PROFILE_HOTKEY_LIMIT)
			return out
	}
	return out
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
 * any focused app. The surface is immutable: every callback resolves the
 * current profile order at fire time. Therefore one retained readiness owner
 * is sufficient — retries overwrite the same nine variants and publication
 * happens only after the complete pass and a proven HotIf reset.
 */
LLM_Menu_BindProfileHotkeys(HotkeyFn := 0, HotIfFn := 0, LogFn := 0,
		ResetFn := 0, SelectFn := 0, KeyResolverFn := 0) {
	global _LLM_PROFILE_HOTKEY_PRED, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_PROFILE_HOTKEY_STATUS_READY
	global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	global _LLM_PROFILE_HOTKEY_RETRY_LIMIT
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
	TriggerConflict := CandidatePlan is Array
		? _LLM_Menu_RuntimeTriggerPlanCollision(CandidatePlan, KeyResolverFn)
		: Map("ok", false, "identity", "")

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
			if !TriggerConflict["ok"]
				throw Error("Profile hotkey collision ownership is malformed")
			if TriggerConflict["identity"] != ""
				throw Error("Profile hotkey chord is owned by the prediction trigger")
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
			if Succeeded {
				_LLM_Menu_ProfileHotkeyFailureCount := 0
				_LLM_Menu_ProfileHotkeyOwner := Map(
					"ready", true, "degraded", false,
					"plan", CandidatePlan)
				TerminalStatus := _LLM_PROFILE_HOTKEY_STATUS_READY
			} else if !IsObject(ResetFailure) {
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
	if (TerminalStatus == _LLM_PROFILE_HOTKEY_STATUS_DEGRADED) {
		_LLM_Menu_LogProfileHotkeyFailure(FailureDetail, LogFn)
		return _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	}
	return TerminalStatus
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
	global _LLM_Menu, _LLM_Menu_Loaded
	if !_LLM_Menu_Loaded || !_LLM_Menu_ProfileHotkeyOwnerReady()
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
 * Builds the closure assigned to a Ctrl+<n> shortcut. The closure resolves
 * the active profile order each time it fires (not at registration time)
 * so new user profiles created after boot are reachable without a reload.
 */
_LLM_Menu_MakeProfileHotkey(idx, SelectFn := 0) {
	if !HasMethod(SelectFn, "Call")
		SelectFn := _LLM_Menu_ProfileNativeSelect
	return (*) => _LLM_Menu_OnProfileHotkey(idx, SelectFn)
}

_LLM_Menu_OnProfileHotkey(idx, SelectFn := 0) {
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

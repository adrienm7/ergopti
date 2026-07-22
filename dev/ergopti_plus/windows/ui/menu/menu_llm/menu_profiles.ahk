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





; ============================================
; ==========================================
; ======= 1/ Profile Submenu Builder =======
; ==========================================
; ============================================

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
 * Builds the profile selection submenu with built-in and user profiles.
 * @returns {Menu} Populated profile submenu.
 */
LLM_Menu_BuildProfileMenu() {
	global _LLM_Menu
	m := Menu()

	; Section header: built-in profiles
	header_builtin := t("menu.profiles.header_default_profiles")
	m.Add(header_builtin, (*) => 0)
	m.Disable(header_builtin)

	for id in ["raw", "basic", "advanced", "batch_advanced"] {
		base_label := LLM_Menu_GetProfileLabel(id)
		hint := LLM_Menu_GetProfileHotkeyHint(id)
		label := (hint != "") ? base_label . "  (" . hint . ")" : base_label
		RegisterMenuItem(m, label, _LLM_Menu_MakeSetProfileHandler(id))
		if (id == _LLM_Menu["profile_id"])
			m.Check(label)
	}

	; Section: user profiles
	user_profiles := _LLM_Menu["user_profiles"]
	if (user_profiles.Length > 0) {
		m.Add()
		header_custom := t("menu.profiles.header_custom_profiles")
		m.Add(header_custom, (*) => 0)
		m.Disable(header_custom)

		for p in user_profiles {
			pid        := p.Has("id") ? p["id"] : ""
			base_plabel := p.Has("label") ? p["label"] : pid
			hint := LLM_Menu_GetProfileHotkeyHint(pid)
			plabel := (hint != "") ? base_plabel . "  (" . hint . ")" : base_plabel
			RegisterMenuItem(m, plabel, _LLM_Menu_MakeUserProfileClickHandler(p))
			if (pid == _LLM_Menu["profile_id"])
				m.Check(plabel)
		}
	}

	m.Add()
	RegisterMenuItem(m, t("menu.profiles.create_profile"), (*) => LLM_Menu_PromptCreateProfile())

	; "Clone active built-in" — exposes the built-in system prompt for
	; editing without requiring the user to type it from scratch. The
	; built-in profiles in profiles.json are read-only by design (they're
	; shared across drivers and any local edit would be overwritten on
	; the next driver update); cloning them into a user profile is the
	; supported way to customise their prompts.
	active_id := _LLM_Menu["profile_id"]
	is_builtin := (active_id == "raw" or active_id == "basic" or active_id == "advanced" or active_id == "batch_advanced")
	if is_builtin {
		clone_label := t("menu.profiles.clone_builtin")
		RegisterMenuItem(m, clone_label, (*) => LLM_Menu_CloneActiveBuiltinProfile())
	}

	; Auto-detect toggle: when ON, switching model in the model submenu also
	; re-picks the matching profile based on the params count. Mirrors the
	; HS get_recommended_profile_info path so the two drivers agree on what
	; profile each model should run with by default.
	m.Add()
	auto_label := t("menu.profiles.auto_detect")
	RegisterMenuItem(m, auto_label, (*) => _LLM_Menu_ToggleAutoProfile())
	if _LLM_Menu["auto_profile_for_model"]
		m.Check(auto_label)

	; Per-app profile overrides submenu — list current ones + "Override
	; active app with active profile" / "Clear override for active app".
	; The submenu opens lazily so we re-read the focused app each time.
	m.Add()
	per_app_menu := _LLM_Menu_BuildPerAppProfileMenu()
	m.Add(t("menu.profiles.per_app_overrides"), per_app_menu)
	return m
}





; ============================================
; ============================================
; ======= 2/ Per-App Overrides Submenu =======
; ============================================
; ============================================

_LLM_Menu_BuildPerAppProfileMenu() {
	global _LLM_Menu
	sm := Menu()
	overrides := _LLM_Menu["app_profile_overrides"]
	; "Override active app with the currently-selected profile". Lazy
	; closure so WinGetProcessName fires when the user clicks, not when
	; the menu is built.
	RegisterMenuItem(sm, t("menu.profiles.override_active_app_with_current"),
		(*) => _LLM_Menu_AddOverrideForActiveApp())
	if (overrides is Map and overrides.Count > 0) {
		sm.Add()
		; List each override: "slack → informel"  + click clears it.
		for app_name, profile_id in overrides {
			label := app_name . "  →  " . LLM_Menu_GetProfileLabel(profile_id)
			RegisterMenuItem(sm, label, _LLM_Menu_MakeClearOverrideHandler(app_name))
		}
	}
	return sm
}

_LLM_Menu_AddOverrideForActiveApp() {
	global _LLM_Menu
	app := ""
	try app := StrLower(WinGetProcessName("A"))
	app := RegExReplace(app, "\.exe$", "")
	if (app == "")
		return
	_LLM_Menu["app_profile_overrides"][app] := _LLM_Menu["profile_id"]
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

_LLM_Menu_ClearOverrideFor(app_name) {
	global _LLM_Menu
	overrides := _LLM_Menu["app_profile_overrides"]
	if !(overrides is Map) or !overrides.Has(app_name)
		return
	overrides.Delete(app_name)
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

_LLM_Menu_ToggleAutoProfile() {
	global _LLM_Menu
	_LLM_Menu["auto_profile_for_model"] := !_LLM_Menu["auto_profile_for_model"]
	; Re-evaluate immediately on enable so the next prediction uses the
	; recommended profile without waiting for the user to switch model.
	if _LLM_Menu["auto_profile_for_model"]
		LLM_Menu_AutoApplyProfileForModel()
	LLM_Menu_SaveConfig()
	LLM_Menu_Build()
}





; ========================================
; ====================================
; ======= 3/ User Profile CRUD =======
; ====================================
; ========================================

/**
 * Shows a context sub-menu style dialog for a user profile (use / edit / delete).
 * AHK has no native submenu on the fly; we show a MsgBox with button choices.
 * @param {Map} profile - The user profile Map object.
 */
LLM_Menu_OnUserProfileClick(profile) {
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
			for i, p in _LLM_Menu["user_profiles"] {
				if (p.Has("id") && p["id"] == pid) {
					_LLM_Menu["user_profiles"].RemoveAt(i)
					break
				}
			}
			if (_LLM_Menu["profile_id"] == pid)
				_LLM_Menu["profile_id"] := "basic"
			LLM_Menu_SaveConfig()
			LLM_Engine_Init(LLM_Menu_BuildOpts())
			LLM_Menu_Build()
			if IsSet(LLM_Menu_BindProfileHotkeys)
				(LLM_Menu_BindProfileHotkeys)()
		}
	}
}

/**
 * Opens InputBox dialogs to create a new user profile (label + prompt).
 */
LLM_Menu_PromptCreateProfile() {
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

	_LLM_Menu["user_profiles"].Push(new_profile)
	_LLM_Menu["profile_id"] := pid
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
}

/**
 * Opens InputBox dialogs to edit an existing user profile in place.
 * @param {Map} profile - The user profile to edit.
 */
LLM_Menu_PromptEditProfile(profile) {
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

	; Update in the array in place
	for i, p in _LLM_Menu["user_profiles"] {
		if (p.Has("id") && p["id"] == pid) {
			_LLM_Menu["user_profiles"][i]["label"]         := new_label
			_LLM_Menu["user_profiles"][i]["system_single"] := ib_prompt.Value
			break
		}
	}
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
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
	_LLM_Menu["user_profiles"].Push(new_profile)
	_LLM_Menu["profile_id"] := new_id
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_Build()
	; Immediately open the edit dialog so the user lands directly into
	; what they wanted: a customisable copy of the built-in prompt.
	LLM_Menu_PromptEditProfile(new_profile)
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





; ==============================================
; ============================================
; ======= 4/ Auto-detect Profile/Model =======
; ============================================
; ==============================================

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
LLM_Menu_AutoApplyProfileForModel() {
	global _LLM_Menu
	if !_LLM_Menu["auto_profile_for_model"]
		return _LLM_Menu["profile_id"]
	recommended := LLM_RecommendProfileForModel(_LLM_Menu["model"])
	if (recommended == "" or recommended == _LLM_Menu["profile_id"])
		return _LLM_Menu["profile_id"]
	_LLM_Menu["profile_id"] := recommended
	LLM_Menu_SaveConfig()
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	return recommended
}





; ===================================
; ==================================
; ======= 5/ Profile Hotkeys =======
; ==================================
; ===================================

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

/**
 * Registers Ctrl+1 … Ctrl+9 globally so the user can switch profiles from
 * any focused app. Idempotent — calling this on every menu rebuild is safe
 * because AHK's ``Hotkey`` API replaces an existing binding when the same
 * key triple is re-registered. The hotkey only fires when the LLM feature
 * is enabled (paused / disabled scripts still get the bare Ctrl+<n> their
 * apps expect).
 */
LLM_Menu_BindProfileHotkeys() {
	global LLM_PROFILE_HOTKEY_LIMIT, _LLM_PROFILE_HOTKEY_PRED
	; Stable predicate — same BoundFunc every call so AHK reuses the context
	HotIf(_LLM_PROFILE_HOTKEY_PRED)
	loop LLM_PROFILE_HOTKEY_LIMIT {
		idx := A_Index
		key := "^" . idx
		try Hotkey(key, _LLM_Menu_MakeProfileHotkey(idx), "On")
	}
	HotIf  ; reset
}

/**
 * Predicate used by ``HotIf`` to decide whether the Ctrl+<n> bindings are
 * active. True only when the LLM tray reports enabled AND there is at
 * least one configured profile to map onto — otherwise the keystroke
 * falls through to the active app unchanged.
 */
_LLM_Menu_IsProfileHotkeyActive() {
	global _LLM_Menu
	if !IsSet(_LLM_Menu) or !_LLM_Menu["enabled"]
		return false
	order := LLM_Menu_GetHotkeyProfileOrder()
	return order.Length > 0
}

/**
 * Builds the closure assigned to a Ctrl+<n> shortcut. The closure resolves
 * the active profile order each time it fires (not at registration time)
 * so new user profiles created after boot are reachable without a reload.
 */
_LLM_Menu_MakeProfileHotkey(idx) {
	return (*) => _LLM_Menu_OnProfileHotkey(idx)
}

_LLM_Menu_OnProfileHotkey(idx) {
	; The HotIf predicate already guarantees the LLM is enabled and at
	; least one profile is configured. We still guard against an out-of-
	; range idx (user has fewer profiles than the bound 1..9) by sending
	; the bare keystroke through so the app's own Ctrl+<n> handler runs.
	order := LLM_Menu_GetHotkeyProfileOrder()
	if (idx < 1 or idx > order.Length) {
		Send "^" . idx
		return
	}
	LLM_Menu_SetProfile(order[idx])
}

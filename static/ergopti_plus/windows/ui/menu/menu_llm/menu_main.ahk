; ui/menu/menu_llm/menu_main.ahk

; ==============================================================================
; MODULE: LLM Tray — Main Menu Orchestrator
; DESCRIPTION:
; Top-level builder that assembles every sub-menu (backend, model, profile,
; predictions count, trigger, generation, display, navigation) into the
; persistent ``_LLM_Menu_Handle`` object. Reads state from ``_LLM_Menu`` and
; delegates each submenu to its own builder defined in the menu_<topic>.ahk
; companion modules.
;
; FEATURES & RATIONALE:
; 1. Persistent menu object: the AHK v2 ``Menu`` instance is reused across
;    rebuilds so the canonical tray position is preserved.
; 2. Health-dot prefix: backend reachability is reflected via the 🟢/🔴 prefix
;    on the model entry, painted from the most recent async probe result.
; 3. Warning row: surfaces a missing Ollama install with a re-install click
;    target — without this, a missing daemon was completely silent.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Top-Level Menu Construction =======
; ==============================================
; ==============================================

global _LLM_MenuBuildCoordinator := 0

_LLM_Menu_IsSuspended(*) {
	return A_IsSuspended
}

_LLM_Menu_ReportBuildError(Err) {
	try LoggerError("LLM", "LLM menu build remains pending after failure: {1} ({2}:{3}).",
		Err.Message, Err.File, Err.Line)
}

_LLM_Menu_GetBuildCoordinator() {
	global _LLM_MenuBuildCoordinator
	PreviousCritical := Critical("On")
	try {
		if !(_LLM_MenuBuildCoordinator is LLMMenuBuildCoordinator)
			_LLM_MenuBuildCoordinator := LLMMenuBuildCoordinator(
				LLM_Menu_Build, _LLM_Menu_IsSuspended,
				_LLM_Menu_ReportBuildError)
		return _LLM_MenuBuildCoordinator
	} finally Critical(PreviousCritical)
}

LLM_Menu_RequestBuild(Reason := "unspecified") {
	return _LLM_Menu_GetBuildCoordinator().Request(Reason)
}

LLM_Menu_ServiceBuilds() {
	return _LLM_Menu_GetBuildCoordinator().Service()
}

; An LLM repaint replaces only its detached submenu. Re-project the complete
; root through the generation fence, but retain every sibling submenu already
; built by InitSubMenus. The generic root worker invalidates and rebuilds those
; siblings, including a recursive personal/extensions scan that the LLM state
; cannot affect.
_LLM_Menu_PublishRoot(PublishAuthorizeFn) {
	try LoggerDebug("LLM",
		"Publishing IA submenu through retained root projection.")
	return initMenu(PublishAuthorizeFn)
}

/**
 * Builds the IA submenu rows (toggle, warning, settings, about) into a new
 * detached Menu and returns it — no publish, no root rebuild, no tray touch.
 * initMenu builds IA inline at boot through this; LLM_Menu_Build uses it for
 * staged replacements. One row-construction site: the two must never drift.
 * The global handle is pointed at the staged menu during construction (row
 * builders write through it) and restored before return, so the call has no
 * publish side effects.
 * @returns {Menu} Staged submenu with all rows.
 */
LLM_Menu_BuildSubmenu() {
	global _LLM_Menu, _LLM_Menu_Handle
	SavedHandle := (IsSet(_LLM_Menu_Handle) && IsObject(_LLM_Menu_Handle)) ? _LLM_Menu_Handle : ""
	StagedHandle := Menu()
	_LLM_Menu_Handle := StagedHandle
	try {
	_tStaged := A_TickCount

	; Enable / Disable toggle. The checked state MUST reflect
	; ``_LLM_Menu["enabled"]`` alone — that's the user's intent. We keep a
	; separate ``_llm_is_operational`` flag (enabled AND active-backend ready)
	; for the health dot below, because we still want a visual cue when the user
	; has flipped the toggle ON but the selected backend is not usable yet.
	; Previously the checkbox itself used _llm_is_operational, so clicking
	; ON while Ollama was missing left the toggle visually OFF — the user
	; thought the click did nothing.
	; Probe deps ONCE, guarded: when the feature is off at boot the deps
	; subsystem may not be ready to answer, and an unguarded throw here used to
	; abort the whole build BEFORE the toggle was added — leaving the IA submenu
	; empty, with no visible control to switch the feature back on.
	_deps_ready := false
	try _deps_ready := LLM_Deps_IsReady()
	_backend_ready := false
	try _backend_ready := _LLM_Menu_BackendIsReadyForUse()
	_llm_is_operational := (_LLM_Menu["enabled"] && _backend_ready)

	; Mirror the macOS menu (ui/menu/menu_llm/init.lua is_disabled): when the
	; feature is OFF, render the FULL menu unchanged but grey out every settings
	; row — only the enable toggle stays live so the user can always turn the
	; feature back on.
	_disabled := !_LLM_Menu["enabled"]

	Commands := _LLM_ScopeCommands()
	Commands["llm_toggle"] := LLM_Menu_OnToggle
	StateGetters := _LLM_Menu_StateGetters()
	WarningRows := []
	if (_LLM_Menu["enabled"] and _LLM_Menu["backend"] == "ollama" and !_deps_ready) {
		LoggerInfo("LLM", "Tray: showing 'Ollama not installed' warning row.")
		WarningRows := MenuRenderer_TemplateRows("llm_install_warning_frame",
			Map("llm_install_warning", _LLM_Menu_OnWarningInstallClick), Map(), Map())
		if !(WarningRows is Array)
			throw Error("Declared backend installation warning was refused.")
	}

	; ── Settings rows ────────────────────────────────────────────────────────
	; Row ORDER and the disabled-when-off POLICY come from the shared menu manifest
	; (_shared/modules/menu/menu_manifest.json, key llm_menu), so the Windows and
	; macOS IA menus can never drift again (a greying mismatch between them was the
	; bug this prevents).
	; The per-row native label + submenu builder are dispatched by id inside
	; _LLM_Menu_EmitRow — those must stay native because they read Win32/tray state;
	; the spec owns only the order and the greying. backend/model carry
	; disabled_when_off=false (usable while off, so the user can configure before
	; enabling); the rest carry true (greyed while off). Conditional/native-only rows
	; (thinking-model info, the num-predictions reset, the inner separator) are
	; emitted from inside _LLM_Menu_EmitRow at their anchor row.
	_rows := _LLM_MenuLayout_Rows()
	; Diagnostic breakdown of the detached staging work. Publishing and pruning
	; happen only after every row has been successfully constructed.
	try LoggerInfo("LLM", "LLM_Menu_Build: pre-emit staging took {1} ms.", TickElapsed(_tStaged))
	try LoggerInfo("LLM", "LLM_Menu_Build: emitting {1} settings row(s) from shared spec…", _rows.Length)
	DynamicHandlers := Map(), GroupDisabled := Map()
	for _i, _row in _rows {
		RowDisabled := _row["disabled_when_off"] ? _disabled : false
		if _MR_Get(_row, "type") == "group" {
			GroupDisabled[_row["id"]] := RowDisabled
		} else {
			DynamicHandlers[_row["id"]] := _LLM_Menu_EmitCapturedRow.Bind(
				_row["id"], RowDisabled, _llm_is_operational, _MR_Get(_row, "health_dot", false), WarningRows)
		}
	}
	MenuRenderer_Build("llm_menu", "LLM", DynamicHandlers, _LLM_Menu_GroupBuilders(),
		"", Commands, StateGetters, StagedHandle, GroupDisabled)
	try LoggerInfo("LLM", "LLM_Menu_Build: settings rows emitted ({1} item(s) so far).", DllCall("GetMenuItemCount", "ptr", _LLM_Menu_Handle.Handle, "int"))
	} catch as e {
		if IsObject(SavedHandle)
			_LLM_Menu_Handle := SavedHandle
		try StagedHandle.Delete()
		throw e
	}
	if IsObject(SavedHandle)
		_LLM_Menu_Handle := SavedHandle
	return StagedHandle
}

/** Captures readers; backend availability never grants configuration write readiness. */
_LLM_Menu_StateGetters() {
	global _LLM_Menu
	return Map("llm_enabled", () => _LLM_Menu["enabled"],
		"llm_toggle_ready", () => !A_IsSuspended && ConfigFullStateCanPersist())
}

; Binding captures each row before the native renderer invokes it, avoiding loop closures.
_LLM_Menu_EmitCapturedRow(Id, Disabled, Operational, HealthDot, WarningRows, TargetMenu, CategoryName) {
	global _LLM_Menu_Handle
	if !(TargetMenu is Menu) || TargetMenu != _LLM_Menu_Handle
		throw Error("An LLM row cannot leave its detached native menu owner.")
	_LLM_Menu_EmitRow(Id, Disabled, Operational, HealthDot, WarningRows)
}

; Child builders retain genuine native Menu identities; the manifest owns the parents.
_LLM_Menu_GroupBuilders() {
	return Map("llm_trigger", LLM_Menu_BuildTriggerMenu,
		"llm_display", LLM_Menu_BuildDisplayMenu,
		"llm_navigation", LLM_Menu_BuildNavMenu,
		"llm_generation_settings", LLM_Menu_BuildGenerationMenu)
}

/**
 * Builds one detached LLM submenu candidate and submits it to the complete-root
 * coordinator. Production callers request work through LLM_Menu_RequestBuild;
 * the generation owner is the only caller of this raw build step.
 */
LLM_Menu_Build() {
	global _LLM_Menu, _LLM_Menu_Handle, _LLM_Menu_InTray
	; Never clear the published submenu before its replacement is complete. A menu
	; build can be preempted by timers and callbacks; an in-place Delete() exposed
	; an empty or partial LLM tree and silently dropped the user's next click.
	OldHandle := _LLM_Menu_Handle
	StagedHandle := ""
	Published := false
	try {
	_t0 := A_TickCount
	try LoggerInfo("LLM", "LLM_Menu_Build: building IA submenu (enabled={1}, inTray={2}).", _LLM_Menu["enabled"] ? "true" : "false", _LLM_Menu_InTray ? "true" : "false")
	StagedHandle := LLM_Menu_BuildSubmenu()
	_LLM_Menu_Handle := StagedHandle

	; The LLM builder owns only a detached child. The root coordinator attaches
	; it while publishing a complete root, so an asynchronous LLM rebuild can
	; never expose an IA-only tray or mutate a root currently being staged.
	if !RebuildTrayMenu(0, _LLM_Menu_PublishRoot, true, true)
		throw Error("tray root coordinator refused the LLM subtree")
	MenuDispatcher_PruneMenu(_LLM_Menu_Handle)
	_LLM_Menu_InTray := true
	Published := true

	; Check the parent tray entry from user intent alone, like the toggle row
	; above. Backend readiness already owns the health dot and the install
	; warning row: folding it into this checkbox left the entry visually OFF
	; while Ollama was missing although the feature was on.
	; Both branches are guarded with try: the item may not exist yet if the updater
	; build request fires before initMenu has had a chance to register it.
	if (_LLM_Menu["enabled"]) {
		try A_TrayMenu.Check(t("menu.llm.title"))
	} else {
		try A_TrayMenu.Uncheck(t("menu.llm.title"))
	}
	try LoggerInfo("LLM", "LLM_Menu_Build: IA submenu built with {1} item(s) in {2}ms.", DllCall("GetMenuItemCount", "ptr", _LLM_Menu_Handle.Handle, "int"), TickElapsed(_t0))
	} catch as e {
		; A failed staged build leaves the previous tree live. This is fail-closed
		; for output: no menu action disappears merely because a new row failed.
		if !Published {
			_LLM_Menu_Handle := OldHandle
			try StagedHandle.Delete()
		}
		throw e
	}
	return true
}




/** Supplies the actual admitted model parent around its completed native picker. */
_LLM_Menu_ModelParentRows(Receive, NativeChild, HealthPrefix, ModelCaption, Disabled) {
	if !_MR_DeclaredParentCallable(Receive)
		throw Error("The admitted model parent receiver was withdrawn.")
	Getters := Map("llm_model_health_prefix", (*) => HealthPrefix,
		"llm_model_current_caption", (*) => ModelCaption,
		"llm_model_parent_ready", (*) => !Disabled)
	Parent := Receive.Call(NativeChild, Getters)
	if !(Parent is Map) || Parent.Get("submenu", false) != NativeChild
		throw Error("Declared model parent was refused.")
	return [Parent]
}

; A refused model parent owns its unpublished picker and every returned native descendant.
; Capture descendants before removing any parent; a detached live owner must not retain callbacks.
_LLM_Menu_ReleaseModelMenu(RootMenu) {
	global _MenuDispatchOwnerHandles
	Failure := 0, Seen := Map()
	Release(Child) {
		Children := [], Handle := 0
		try {
			Handle := Child.Handle
			if Seen.Has(Handle)
				return
			Seen[Handle] := true
			Count := TrayMenuHandleItemCount(Handle)
			if Count < 0
				throw Error("The owned model menu handle is unavailable during release.")
			loop Count {
				ChildHandle := TrayMenuSubmenuHandle(Handle, A_Index - 1)
				if ChildHandle {
					OwnedChild := MenuFromHandle(ChildHandle)
					if !(OwnedChild is Menu)
						throw Error("The owned model child menu is unavailable during release.")
					Children.Push(OwnedChild)
				}
			}
		} catch as ErrorInfo {
			if !Failure
				Failure := ErrorInfo
		}
		for OwnedChild in Children
			Release(OwnedChild)
		try {
			try Child.Delete()
			finally {
				if Handle && TrayMenuHandleItemCount(Handle) == 0
					&& _MenuDispatchOwnerHandles.Has(Handle)
					_MenuDispatchOwnerHandles.Delete(Handle)
				MenuDispatcher_PruneMenu(Child)
			}
		} catch as ErrorInfo {
			if !Failure
				Failure := ErrorInfo
		}
	}
	Release(RootMenu)
	if Failure
		throw Failure
}




; =====================================================
; ===== 1.1) Shared-spec-driven settings row emit =====
; =====================================================

/**
 * Returns the ordered settings-row list for this platform from the shared menu
 * manifest (_shared/modules/menu/menu_manifest.json, key ``llm_menu``) — the
 * SINGLE SOURCE OF TRUTH shared with the macOS renderer so the two IA menus can
 * never drift in row order or greying policy. Cached after the first read (the
 * manifest is static for the session).
 *
 * The rows used to live in a SECOND shared file of their own
 * (_shared/modules/llm/menu_layout.json); one menu therefore had two shared
 * descriptions, and the manifest's ``llm_menu`` key described a menu only Linux
 * drew. Reading the manifest here is what collapses the two back into one.
 *
 * Rows carrying a ``platforms`` restriction that excludes "ahk" — Linux's two
 * inline lists — are filtered out exactly as every other manifest-driven menu
 * filters them.
 *
 * Falls back to a built-in mirror if the manifest is missing/corrupt so the menu
 * always renders; the built-in list is pinned to the manifest by the
 * cross-platform contract test (tests/meta/test_llm_menu_layout_shared.ahk), so
 * it cannot drift.
 * @returns {Array} Array of Maps, each with "id" (string) and "disabled_when_off" (bool).
 */
_LLM_MenuLayout_Rows() {
	static _cache := ""
	if (_cache != "")
		return _cache
	rows := _LLM_MenuLayout_Fallback()
	try {
		Declared := _MR_GetMenuDef("llm_menu")
		Filtered := []
		for _, Entry in Declared {
			; Separators and Linux's inline lists are not settings rows: this
			; dispatch emits a native submenu per id, and only the declared
			; ``dynamic`` and declared ``group`` rows have one.
			if (Entry is Map && _MR_IsForAhk(Entry) && (_MR_Get(Entry, "type", "") == "dynamic" || _MR_Get(Entry, "type", "") == "group"))
				Filtered.Push(Entry)
		}
		if (Filtered.Length > 0)
			rows := Filtered
		else
			try LoggerWarn("LLM", "menu_manifest.json 'llm_menu' yielded no Windows row — using built-in fallback order.")
	} catch as e {
		try LoggerWarn("LLM", "menu_manifest.json load failed ({1}) — using built-in fallback order.", e.Message)
	}
	_cache := rows
	return rows
}

/**
 * Built-in fallback for the shared layout — mirrors the manifest's ``llm_menu``
 * row order and disabled-when-off policy. Pinned to the manifest by the contract
 * test so the two never diverge; exists only so a missing/corrupt manifest still
 * yields a menu.
 * @returns {Array} The canonical settings-row list.
 */
_LLM_MenuLayout_Fallback() {
	return [
		Map("id", "llm_backend",             "disabled_when_off", false, "health_dot", false),
		Map("id", "llm_model",               "disabled_when_off", false, "health_dot", true),
		Map("id", "llm_profile",             "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_trigger",             "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_generation_settings", "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_display",             "disabled_when_off", true,  "health_dot", false),
		Map("id", "llm_navigation",          "disabled_when_off", true,  "health_dot", false)
	]
}

/**
 * Emits one settings row by its shared-spec id. The spec (_LLM_MenuLayout_Rows)
 * owns the ORDER and the `disabled` flag; this dispatch owns the platform-native
 * label formatting and submenu construction (which read Win32/tray state and so
 * cannot live in shared data). Conditional native-only rows that have no shared
 * entry — the thinking-model info row and the separator after the profile row —
 * are emitted here at their anchor row to preserve menu order.
 * @param {String}  id                  Row id from the manifest's llm_menu.
 * @param {Boolean} disabled            Greying flag already resolved from the spec policy.
 * @param {Boolean} llm_is_operational  Enabled AND deps ready — gates the health dot.
 * @param {Boolean} has_health_dot      The row's declared health_dot flag. Which row
 *                                      carries the dot is the manifest's call, not this
 *                                      file's, so macOS cannot end up dotting another row.
 */
_LLM_Menu_EmitRow(id, disabled, llm_is_operational, has_health_dot := false, CapturedWarningRows := unset) {
	global _LLM_Menu, _LLM_Menu_Handle
	switch id {
	case "llm_backend":
		WarningRows := IsSet(CapturedWarningRows) ? CapturedWarningRows : []
		; This nonpublished structural witness admits the genuine native-caption contract.
		; It is never a selected backend datum and never reaches the actual native UI.
		AdmissionChild := Menu()
		try ParentAdmission := MenuRenderer_GroupRow("llm_backend_parent_ahk", "llm_backend_parent", AdmissionChild,
			Map("llm_backend_parent_caption", (*) => "structural admission", "llm_backend_parent_ready", (*) => !disabled))
		finally {
			try AdmissionChild.Delete()
			finally MenuDispatcher_PruneMenu(AdmissionChild)
		}
		if !(ParentAdmission is Map) || ParentAdmission.Get("submenu", false) != AdmissionChild
			throw Error("Declared backend parent frame was refused.")
		Admission := _LLM_Menu_BackendFrameAdmission(WarningRows)
		if !(Admission is Map)
			throw Error("Declared backend parent frame was refused.")
		BackendCaption := _LLM_Menu_BackendRowLabel()
		BackendMenu := LLM_Menu_BuildBackendMenu()
		try {
			BackendRows := _LLM_Menu_BackendParentRows(BackendMenu, BackendCaption, disabled, WarningRows)
			if !(BackendRows is Array)
				throw Error("Declared backend parent frame was withdrawn.")
			MenuRenderer_AppendRows(_LLM_Menu_Handle, "llm_menu", "llm_backend_parent_frame_ahk", BackendRows)
		} catch as Err {
			BackendMenu.Delete()
			MenuDispatcher_PruneMenu(BackendMenu)
			throw Err
		}
	case "llm_model":
		; Build the submenu, fire the async probes (backend health + installed-tags
		; list), then prefix the label with the cached backend-health dot (🟢
		; reachable / 🔴 down / "" when off) — mirrors HS's build_model_item
		; health_dot block. BOTH probes are non-blocking and paint on the next pass:
		; the submenu reads only the in-memory caches, never a synchronous /api/tags
		; or reachability round-trip, so opening the tray can never freeze the thread.
		ReceiveModel := MenuRenderer_GroupReceiver("llm_model_parent_ahk", "llm_model")
		if !ReceiveModel
			throw Error("Declared model parent admission was refused.")
		model_menu := LLM_Menu_BuildModelMenu()
		try {
			; Force past the idle gate: this row is only painted while the tray menu is
			; actually being built, i.e. for a user looking at it right now, so the dot
			; must refresh even when A_TimeIdlePhysical claims the machine has been
			; unattended. That counter only notices the tray click because AHK's mouse
			; hook happens to be installed (nav_layer.ahk declares wheel hotkeys) — far
			; too incidental a dependency to hang the on-demand refresh on. The 3 s
			; throttle inside the helper is NOT bypassed, so a rebuild storm still costs
			; a single ping.
			_LLM_Menu_FireHealthProbe(true)
			_LLM_Menu_FireInstalledTagsProbe()
			last_status := _LLM_Menu.Has("last_health_status") ? _LLM_Menu["last_health_status"] : ""
			health_dot := (has_health_dot && llm_is_operational)
				? ((last_status == "ok") ? "🟢 " : (last_status == "ko") ? "🔴 " : "")
				: ""
			; The shown model follows the active backend (an API entry's model
			; with backend api, never the preserved Ollama slot) — the
			; thinking-model row below must agree with the same text.
			model_shown := _LLM_Menu_ModelDisplayText()
			ModelRows := _LLM_Menu_ModelParentRows(ReceiveModel, model_menu, health_dot, model_shown, disabled)
			MenuRenderer_AppendRows(_LLM_Menu_Handle, "llm_menu", "llm_model_parent_ahk", ModelRows)
		} catch as Err {
			try _LLM_Menu_ReleaseModelMenu(model_menu)
			catch as CleanupError
				try LoggerError("LLM", "Model menu cleanup failed after parent refusal: {1}", CleanupError.Message)
			throw Err
		}
		; Thinking-model info row — conditional, native-only (mirrors HS thinking-info).
		if _LLM_Menu_IsThinkingModel(model_shown) {
			InfoRows := MenuRenderer_TemplateRows("llm_thinking_info", Map(), Map(), Map())
			if !(InfoRows is Array)
				throw Error("Declared thinking-model information was refused.")
			MenuRenderer_AppendRows(_LLM_Menu_Handle, "llm_menu", "llm_thinking_info", InfoRows)
		}
	case "llm_profile":
		; Admit the actual boundary and whole frame before building the native child.
		BoundaryRows := MenuRenderer_TemplateRows("llm_after_profile_boundary", Map(), Map(), Map())
		Admission := MenuRenderer_TemplateRows("llm_profile_parent_frame_ahk", Map(), Map(),
			Map("llm_profile_parent_rows", (*) => []))
		if !(BoundaryRows is Array) || BoundaryRows.Length != 1 || !BoundaryRows[1].Get("separator", false)
			|| !(Admission is Array) || Admission.Length != 1 || !Admission[1].Get("separator", false)
			throw Error("Declared profile parent frame was refused.")
		; Admit the separate genuine parent before profile data or child construction.
		; An empty scalar is valid for the existing translated prefix contract.
		AdmissionChild := Menu()
		try ParentAdmission := MenuRenderer_GroupRow("llm_profile_parent_ahk", "llm_profile_parent", AdmissionChild,
			Map("llm_profile_parent_caption", (*) => "", "llm_profile_parent_ready", (*) => !disabled))
		finally {
			try AdmissionChild.Delete()
			finally MenuDispatcher_PruneMenu(AdmissionChild)
		}
		if !(ParentAdmission is Map) || ParentAdmission.Get("submenu", false) != AdmissionChild
			throw Error("Declared profile parent frame was refused.")
		ProfileCaption := LLM_Menu_GetProfileLabel(_LLM_Menu["profile_id"])
		ProfileMenu := LLM_Menu_BuildProfileMenu()
		try {
			ProfileRows := _LLM_Menu_ProfileParentRows(ProfileMenu, ProfileCaption, disabled)
			if !(ProfileRows is Array) || ProfileRows.Length != 2
				throw Error("Declared profile parent frame was withdrawn.")
			MenuRenderer_AppendRows(_LLM_Menu_Handle, "llm_menu", "llm_profile_parent_frame_ahk", ProfileRows)
		} catch as Err {
			ProfileMenu.Delete()
			MenuDispatcher_PruneMenu(ProfileMenu)
			throw Err
		}
	case "llm_trigger":
		if !MenuRenderer_AppendGroup(_LLM_Menu_Handle, "llm_menu", "llm_trigger",
			Map("llm_trigger", LLM_Menu_BuildTriggerMenu), disabled)
			throw Error("Declared LLM group 'llm_trigger' was refused.")
	case "llm_generation_settings":
		if !MenuRenderer_AppendGroup(_LLM_Menu_Handle, "llm_menu", "llm_generation_settings",
			Map("llm_generation_settings", LLM_Menu_BuildGenerationMenu), disabled)
			throw Error("Declared LLM group 'llm_generation_settings' was refused.")
	case "llm_display":
		if !MenuRenderer_AppendGroup(_LLM_Menu_Handle, "llm_menu", "llm_display",
			Map("llm_display", LLM_Menu_BuildDisplayMenu), disabled)
			throw Error("Declared LLM group 'llm_display' was refused.")
	case "llm_navigation":
		if !MenuRenderer_AppendGroup(_LLM_Menu_Handle, "llm_menu", "llm_navigation",
			Map("llm_navigation", LLM_Menu_BuildNavMenu), disabled)
			throw Error("Declared LLM group 'llm_navigation' was refused.")
	default:
		try LoggerWarn("LLM", "_LLM_Menu_EmitRow: unknown row id '{1}' in the shared menu manifest — skipped.", id)
	}
}

; The terminal owner preserves credential stores and explicit consent. The AI
; menu offers the restore alone: its « Tout effacer » row was retired.
_LLM_ScopeCommands(Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	return Map("scope_restore", (*) => _LLM_ApplyScope("recommended", OwnedOptions))
}

_LLM_ApplyScope(Mode, Options) {
	CandidateOptions := Options.Clone()
	CandidateOptions["supplement"] := _LLM_Menu_ScopeResetOperations
	return ConfigScopeApply("llm", Mode, Map(), CandidateOptions)
}

; Keeps native profile contents and handle identity while the shared frame owns placement.
_LLM_Menu_ProfileParentRows(NativeChild, Caption, Disabled) {
	Root := _MR_GetManifestRoot()
	ParentDefinition := Root.Get("llm_profile_parent_ahk", false)
	FrameDefinition := Root.Get("llm_profile_parent_frame_ahk", false)
	BoundaryDefinition := Root.Get("llm_after_profile_boundary", false)
	Getters := Map("llm_profile_parent_caption", (*) => Caption,
		"llm_profile_parent_ready", (*) => !Disabled)
	Parent := MenuRenderer_GroupRow("llm_profile_parent_ahk", "llm_profile_parent", NativeChild, Getters)
	if !(Parent is Map)
		return false
	ParentRows := [Parent]
	Rows := MenuRenderer_TemplateRows("llm_profile_parent_frame_ahk", Map(), Map(),
		Map("llm_profile_parent_rows", (*) => ParentRows))
	if !(Rows is Array) || Rows.Length != 2 || _MR_GetManifestRoot() != Root
		|| Root.Get("llm_profile_parent_ahk", false) != ParentDefinition
		|| Root.Get("llm_profile_parent_frame_ahk", false) != FrameDefinition
		|| Root.Get("llm_after_profile_boundary", false) != BoundaryDefinition
		return false
	return Rows
}

; Captured warning state is native data; its actual callback and shared caption stay paired.
_LLM_Menu_BackendFrameAdmission(WarningRows) {
	if !(WarningRows is Array) || WarningRows.Length > 1 || (WarningRows.Length == 1 && !WarningRows.Has(1))
		return false
	Present := WarningRows.Length == 1
	if Present && (!(WarningRows[1] is Map) || !WarningRows[1].Has("label")
		|| !WarningRows[1].Has("action") || !HasMethod(WarningRows[1]["action"], "Call")
		|| WarningRows[1].Has("submenu") || WarningRows[1].Get("separator", false))
		return false
	Root := _MR_GetManifestRoot(), Definitions := Map()
	for Key in ["llm_backend_parent_frame_ahk", "llm_backend_warning_rows_ahk", "llm_install_warning_frame"]
		Definitions[Key] := Root.Get(Key, false)
	; A nonpublished current-declaration witness validates caption/readiness even when absent.
	; Captured guarded records, not this new witness action, reach the typed list.
	Witness := MenuRenderer_CommandRow("llm_install_warning_frame", "llm_install_warning",
		Map("llm_install_warning", _LLM_Menu_OnWarningInstallClick), Map())
	if !(Witness is Map) || (Present && WarningRows[1]["label"] != Witness["label"])
		return false
	Rows := MenuRenderer_TemplateRows("llm_backend_parent_frame_ahk", Map(), Map(),
		Map("llm_backend_parent_rows", (*) => [], "llm_backend_warning_rows", (*) => WarningRows))
	if !(Rows is Array) || Rows.Length != WarningRows.Length || _MR_GetManifestRoot() != Root
		|| (Present && Rows[1] != WarningRows[1])
		return false
	for Key, Definition in Definitions
		if Root.Get(Key, false) != Definition
			return false
	return Map("warning_rows", WarningRows, "present", Present)
}

; The complete declared frame owns warning placement and the finished native parent.
_LLM_Menu_BackendParentRows(NativeChild, Caption, Disabled, WarningRows) {
	Root := _MR_GetManifestRoot()
	ParentDefinition := Root.Get("llm_backend_parent_ahk", false)
	FrameDefinition := Root.Get("llm_backend_parent_frame_ahk", false)
	WarningDefinition := Root.Get("llm_install_warning_frame", false)
	WarningRowsDefinition := Root.Get("llm_backend_warning_rows_ahk", false)
	Admission := _LLM_Menu_BackendFrameAdmission(WarningRows)
	if !(Admission is Map)
		return false
	Getters := Map("llm_backend_parent_caption", (*) => Caption,
		"llm_backend_parent_ready", (*) => !Disabled,
		"llm_backend_warning_present", (*) => Admission["present"])
	Parent := MenuRenderer_GroupRow("llm_backend_parent_ahk", "llm_backend_parent", NativeChild, Getters)
	if !(Parent is Map)
		return false
	ParentRows := [Parent]
	Rows := MenuRenderer_TemplateRows("llm_backend_parent_frame_ahk", Map(), Getters,
		Map("llm_backend_parent_rows", (*) => ParentRows,
			"llm_backend_warning_rows", (*) => Admission["warning_rows"]))
	if !(Rows is Array) || Rows.Length != (Admission["present"] ? 2 : 1) || _MR_GetManifestRoot() != Root
		|| Root.Get("llm_backend_parent_ahk", false) != ParentDefinition
		|| Root.Get("llm_backend_parent_frame_ahk", false) != FrameDefinition
		|| Root.Get("llm_install_warning_frame", false) != WarningDefinition
		|| Root.Get("llm_backend_warning_rows_ahk", false) != WarningRowsDefinition
		return false
	return Rows
}

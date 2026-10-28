; ui/menu/menu_llm/menu_models.ahk

; ==============================================================================
; MODULE: LLM Tray — Model Labels and Model Transactions
; DESCRIPTION:
; What the AI menu's model button and the model selector page share on Windows:
; the backend list, the label of the active model or API entry, the closure
; factories the settings rows use, and the Ollama pull and delete transactions
; the page runs for a model.
;
; FEATURES & RATIONALE:
; 1. The menu builds no model list: the Backend chooser, the model picker and
;    the API entries moved to the model selector page on 2026-10-27
;    (ui/model_browser/init.ahk), which runs these same transactions.
; 2. Per-iteration closure factories: a for-loop captures via ``_LLM_Menu_Make*``
;    factories rather than ``captured := value`` because AHK v2 closure scopes
;    are per-call, not per-iteration.
; ==============================================================================

#Requires AutoHotkey v2.0

; The backend catalogue belongs beside its only reader, so definitions-only
; includes build the same menu as the resident driver without the tray bootstrap.
; API uses the shared remote-provider catalogue; MLX remains macOS-only.
global LLM_MENU_BACKEND_OPTIONS := ["ollama", "api"]

; Delay before the menu is rebuilt after launching an `ollama pull` in its own
; terminal. Long enough that a small model has usually finished and the green
; "installed" dot appears on the first glance back at the tray; short enough that
; the user is unlikely to have opened the menu again before it fires. It is a
; cosmetic refresh, not a correctness deadline — the dot also updates on the next
; health probe — so it is deliberately NOT tied to LLM_HEALTH_PROBE_THROTTLE_MS,
; which happens to hold the same number for an unrelated reason.
global LLM_MENU_POST_PULL_REBUILD_MS := 3000





; ===============================
; ===============================
; ======= 1/ Model Labels =======
; ===============================
; ===============================

/**
 * What an option names: its label before the first em dash, trimmed, or the
 * whole label when it has none.
 * @param {String} Label An option label.
 * @returns {String} Such as "API 🌐".
 */
_LLM_Menu_OptionHead(Label) {
	Dash := InStr(Label, "—")
	return Trim(Dash ? SubStr(Label, 1, Dash - 1) : Label)
}

/**
 * Display name for one API entry: its automatic name, <provider>/<model> with
 * the model its requests use, told apart from the menu's other entries as the
 * entry list tells it. A name the user typed in an earlier build is not read.
 * @param {Map} Entry API entry record.
 * @returns {String} Such as "cerebras/qwen-3.8-27b".
 */
_LLM_Menu_ApiEntryDisplayName(Entry) {
	global _LLM_Menu
	Entries := (_LLM_Menu is Map) ? _LLM_Menu.Get("api_entries", []) : []
	Id := _LLM_MenuApiEntryGet(Entry, "Id", "")
	if ((Entries is Array) && (Id != "")) {
		for Index, Listed in Entries {
			if (_LLM_MenuApiEntryGet(Listed, "Id", "") == Id)
				return _LLM_Menu_ApiEntryNameList(Entries)[Index]
		}
	}
	return _LLM_Menu_ApiEntryNameList([Entry])[1]
}

/**
 * Text for the model parent row. With backend api the Ollama slot is stale
 * by design — it is preserved so switching back restores it — so the row
 * shows the selected entry instead, never the leftover tag.
 * @returns {String} Model id, provider default, or "".
 */
_LLM_Menu_ModelDisplayText() {
	global _LLM_Menu
	if !(_LLM_Menu is Map)
		return ""
	if (_LLM_Menu.Get("backend", "") == "api") {
		ActiveId := _LLM_Menu.Has("api_entry_id") ? _LLM_Menu["api_entry_id"] : ""
		if ((ActiveId != "") && _LLM_Menu.Has("api_entries")
			&& (_LLM_Menu["api_entries"] is Array)) {
		for E in _LLM_Menu["api_entries"] {
			if (_LLM_MenuApiEntryGet(E, "Id", "") == ActiveId)
				return _LLM_Menu_ApiEntryDisplayName(E)
		}
		}
		return ""
	}
	return _LLM_Menu.Get("model", "")
}

/**
 * The model text of the tray's model button. With backend api it names the
 * provider by its display name (api_providers.json), then the model its
 * requests use: "OpenAI/gpt-4o-mini". The page lists entries by their
 * automatic name; the button stays short.
 * @returns {String} Empty when no model or entry is active.
 */
_LLM_Menu_ModelCaptionText() {
	global _LLM_Menu, LLM_API_PROVIDERS
	if !(_LLM_Menu is Map) || (_LLM_Menu.Get("backend", "") != "api")
		return _LLM_Menu_ModelDisplayText()
	ActiveId := _LLM_Menu.Get("api_entry_id", "")
	Entries := _LLM_Menu.Has("api_entries") && (_LLM_Menu["api_entries"] is Array) ? _LLM_Menu["api_entries"] : []
	for E in Entries {
		if (ActiveId == "") || (_LLM_MenuApiEntryGet(E, "Id", "") != ActiveId)
			continue
		Provider := _LLM_MenuApiEntryGet(E, "Provider", "")
		if !(LLM_API_PROVIDERS is Map) || !LLM_API_PROVIDERS.Has(Provider)
			return ""
		Label := LLM_API_PROVIDERS[Provider]["Label"]
		Model := _LLM_MenuApiEntryGet(E, "Model", "")
		if (Model == "")
			Model := LLM_API_PROVIDERS[Provider]["DefaultModel"]
		return Model == "" ? Label : Label . "/" . Model
	}
	return ""
}





; ====================================
; ====================================
; ======= 2/ Closure Factories =======
; ====================================
; ====================================

; AHK v2 closes over outer-scope variables by reference. Inside a for-loop,
; assigning to a temp variable (``captured := value``) does NOT create a
; new closure scope per iteration — every closure would see the LAST loop
; value. The IIFE-style factory below wraps the captured value in a fresh
; function parameter, which IS scoped per call and therefore safe.

_LLM_Menu_MakeSetNHandler(n) {
	return (name, pos, menu) => LLM_Menu_SetN(n)
}

_LLM_Menu_MakeSetProfileHandler(id) {
	return (name, pos, menu) => LLM_Menu_SetProfile(id)
}

_LLM_Menu_MakeUserProfileClickHandler(p) {
	return (name, pos, menu) => LLM_Menu_OnUserProfileClick(p)
}

_LLM_Menu_MakeClearOverrideHandler(app_name) {
	return (*) => _LLM_Menu_ClearOverrideFor(app_name)
}





; =====================================
; =====================================
; ======= 3/ Model Transactions =======
; =====================================
; =====================================

/**
 * Launches ``ollama pull <tag>`` in a visible cmd window so the user gets
 * real-time download progress directly in the terminal. Resolves the Ollama
 * tag from the catalogue display name first — identical to the warmup path.
 * After the window closes the tray menu is rebuilt so the green dot appears.
 *
 * @param {string} name - Catalogue display name (e.g. "Qwen 2.5 3B").
 */
_LLM_Menu_PullModel(name, IsTag := false, BaseUrl := "", RunFn := 0, ScheduleFn := 0) {
	global LLM_MENU_POST_PULL_REBUILD_MS, LLM_OLLAMA_BASE_URL
	tag := IsTag ? name : LLM_ResolveOllamaTag(name)
	if (tag == "") {
		Ui_MsgBox(StrReplace(t("menu.llm.ollama_model_hint"), "%s", name), t("menu.llm.download_model"), "16")
		return false
	}
	if !(tag is String) || !RegExMatch(tag, "^[A-Za-z0-9_./:-]+$")
		return false
	global _LLM_ManagedBootstrap
	Flow := _LLM_ManagedBootstrap
	if !HasMethod(RunFn, "Call") && Flow is OllamaManagedBootstrap && Flow.Runtime.HasOwner() {
		if BaseUrl != "" && BaseUrl != LLM_OLLAMA_BASE_URL && BaseUrl != Flow.Target["origin"]
			return false
		OnDone := HasMethod(ScheduleFn, "Call")
			? (*) => ScheduleFn.Call(LLM_Menu_RequestBuild.Bind("managed_post_pull"), -LLM_MENU_POST_PULL_REBUILD_MS)
			: LLM_Menu_RequestBuild.Bind("managed_post_pull")
		return Flow.PullModel(tag, OnDone)
	}
	if BaseUrl == ""
		BaseUrl := LLM_OLLAMA_BASE_URL
	if BaseUrl != LLM_OLLAMA_BASE_URL || !RegExMatch(BaseUrl, "^http://localhost:[0-9]+$")
		return false
	; Open a persistent cmd window so the download progress (layer-by-layer
	; progress bars) is fully visible. /k keeps it open after completion so
	; the user can confirm the download succeeded before closing.
	Command := 'cmd.exe /k set "OLLAMA_HOST=' . BaseUrl . '"&& ollama pull "' . tag . '"'
	try {
		if HasMethod(RunFn, "Call") {
			if RunFn.Call(Command) != true
				return false
		} else
			Run(Command, , "")
	} catch as Err {
		try LoggerWarn("LLM.menu", "Ollama download launch failed: {1}.", Err.Message)
		return false
	}
	; Rebuild after a short delay so the green dot appears once Ollama finishes
	; (the user will close the window manually; this just keeps the menu fresh
	; if they glance at it again while the terminal is still open).
	if HasMethod(ScheduleFn, "Call")
		ScheduleFn.Call(LLM_Menu_RequestBuild.Bind("post_pull"), -LLM_MENU_POST_PULL_REBUILD_MS)
	else
		SetTimer(LLM_Menu_RequestBuild.Bind("post_pull"), -LLM_MENU_POST_PULL_REBUILD_MS)
	return true
}

/**
 * Confirms the delete with the user, then drops the Ollama-side model cache
 * through the async curl-child DELETE /api/delete pattern (mirrors
 * LLM_OllamaListModels_Async — F24). The tray rebuild happens in the
 * completion callback so it never fires before the daemon actually answers.
 */
_LLM_Menu_PromptDeleteCachedModel(name, ConfirmFn := Ui_MsgBox, TransportPort := 0) {
	global _LLM_Menu
	MenuOwner := _LLM_Menu
	if A_IsSuspended || !(MenuOwner is Map) || MenuOwner.Get("backend", "") != "ollama"
		return false
	tag := LLM_ResolveOllamaTag(name)
	if (tag == "")
		return false
	; The question authorizes this daemon and this request, not a replacement
	; selected while the native modal loop is pumping lifecycle callbacks.
	Custody := LLM_OllamaCaptureOriginCustody()
	Owner := _LLM_Menu_BeginOllamaAux("menu_delete:" . tag, tag, Custody)
	HandedOff := false
	try {
		title := t("menu.llm.delete_model_title")
		body := StrReplace(t("menu.llm.delete_model_body"), "%s", name)
		if !_LLM_Menu_DeleteConfirmationCurrent(Owner, MenuOwner)
			return false
		choice := ConfirmFn.Call(body, title, "YesNo Icon!")
		if choice != "Yes" || !_LLM_Menu_DeleteConfirmationCurrent(Owner, MenuOwner)
			return false
		_LLM_Menu_RecordDeleteReconcile(Owner, name, tag)
		try LLM_OllamaDeleteModel_Async(tag,
			(ok) => _LLM_Menu_OnDeleteCachedModelDone(name, tag, ok, Owner), TransportPort, Owner)
		catch
			return false
		HandedOff := true
		return true
	} finally {
		if !HandedOff || !LLM_OllamaOriginCustodyCurrent(Custody, Owner["endpoint"]) {
			_LLM_Menu_ClearDeleteReconcile(Owner)
			_LLM_AuxRetireOwner(Owner, true)
		}
	}
}

_LLM_Menu_DeleteConfirmationCurrent(Owner, MenuOwner) {
	global _LLM_Menu
	return !A_IsSuspended && _LLM_Menu == MenuOwner
		&& _LLM_Menu_DeleteOwnerIsCurrent(Owner)
		&& LLM_OllamaOriginCustodyCurrent(Owner["origin_custody"], Owner["endpoint"])
		&& !A_IsSuspended && _LLM_Menu == MenuOwner
		&& _LLM_Menu_DeleteOwnerIsCurrent(Owner)
}

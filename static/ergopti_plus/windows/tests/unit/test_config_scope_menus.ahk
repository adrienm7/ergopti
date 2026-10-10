; tests/unit/test_config_scope_menus.ahk

; Menu callbacks exercise real files and reload refusal through the scope owner.
; Shared rows stay unmodified until host parity. This fixture exercises the real
; renderer and dispatch with the agreed command IDs and existing locale keys.
_ScopeTestRenderCommand(TargetMenu, MenuKey, Id, Commands) {
	LabelKey := Id == "scope_clear" ? "common.clear_to_system" : "common.restore_recommended"
	Item := Map("type", "command", "id", Id, "command", Id, "i18n", LabelKey)
	return _MR_RenderCommand(TargetMenu, Item, MenuKey, Commands, Map())
}

_ScopeMenuCommandsCase(Scope, Factory, MenuKey, Modes := ["recommended", "clear"]) {
	global _MenuDispatchCallbacks
	Source := '[layout]`nergopti_base = true`nemulated_layout = "ergol"`n[category_enabled]`nlayout = true`n[llm]`nenabled = true`nollama_port = 12345`napi_entry_id = "saved-api"`nunknown_user = "keep"`n[llm.navigation]`nnav_modifiers = ["Alt"]`n[llm.trigger]`ndisabled_apps = ["private-app"]`n[llm.generation]`nmin_words = 99`n[metrics]`nenabled = true`nmetrics_enabled = true`nwpm_widget_visible = true`n[private]`ncredential = "keep"`n[user]`nunknown = "keep"`n'
	Fixture := _ScopeOwnerFixture(Source)
	Source := Fixture.source
	Assert(FSWriteDurable(Fixture.path, Source))
	Refusal := 0, Bundle := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Commands := %Factory%(Fixture.options)
		if Modes.Length == 1
			Assert(!Commands.Has("scope_clear"), MenuKey . " offers the restore alone")
		for Mode in Modes {
			Fixture.options["stamp"] := Mode
			Id := Mode == "clear" ? "scope_clear" : "scope_restore"
			Rendered := Menu()
			try {
				AssertEqual(1, _ScopeTestRenderCommand(Rendered, MenuKey, Id, Commands))
				AssertEqual(1, TrayMenuItemCount(Rendered), "the scope command must be a real menu item")
				ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
				Assert(_MenuDispatchCallbacks.Has(ItemId))
				Receipt := (_MenuDispatchCallbacks[ItemId])()
				AssertEqual(Receipt["status"], "pending")
				Parsed := TOML_ParseFreshFile(Fixture.path)
				AssertEqual(Parsed["private"]["credential"], "keep")
				AssertEqual(Parsed["user"]["unknown"], "keep")
				AssertEqual(Parsed["llm"]["unknown_user"], "keep", "an unknown key inside the scope remains user-owned")
				if Scope == "llm" {
					for Key in ["ollama_port", "api_entry_id"]
						Assert(!Parsed["llm"].Has(Key), "the LLM owner must remove its foreign override " . Key)
					Assert(!Parsed["llm.navigation"].Has("nav_modifiers"))
					Assert(!Parsed["llm.trigger"].Has("disabled_apps"))
					Assert(!Parsed["llm.generation"].Has("min_words"), "the manifest recommendation is sparse at its default")
				} else {
					AssertEqual(Parsed["llm"]["ollama_port"], 12345)
					AssertEqual(Parsed["llm"]["api_entry_id"], "saved-api")
				}
				if Scope == "keyboard_layout" {
					AssertEqual(Parsed["llm"]["enabled"], true)
					AssertEqual(Parsed["metrics"]["enabled"], true)
					if Mode == "clear"
						Assert(!Parsed["layout"].Has("ergopti_base"))
					else
						AssertEqual(Parsed["layout"]["ergopti_base"], ManifestRecommendedFor("layout.ergopti_base"))
				} else {
					AssertEqual(Parsed["layout"]["emulated_layout"], "ergol")
					if Mode == "clear"
						Assert(!Parsed[Scope].Has("enabled"), "clear removes explicit consent with its scope")
					else
						AssertEqual(Parsed[Scope]["enabled"], true, "restore preserves existing consent")
				}
				Refusal.Call("native close refused")
				AssertEqual(Receipt["status"], "refused")
				AssertEqual(FSReadUtf8Exact(Fixture.path), Source)
			} finally Rendered.Delete()
		}
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("config-scope-menu: layout commands publish only their scope and recover refusal",
	_ScopeMenuCommandsCase.Bind("keyboard_layout", "_LAY_ScopeCommands", "layout_menu"))
Test("config-scope-menu: LLM commands preserve credentials and recover refusal",
	_ScopeMenuCommandsCase.Bind("llm", "_LLM_ScopeCommands", "llm_menu", ["recommended"]))
; The restore alone: the maintainer retired the Metrics clear on 2026-09-30.
Test("config-scope-menu: metrics restore preserves consent, recovers refusal, and has no clear",
	_ScopeMenuCommandsCase.Bind("metrics", "_MET_ScopeCommands", "metrics_menu", ["recommended"]))

_ScopeMenuAbsentConsent() {
	for Factory in ["_LLM_ScopeCommands", "_MET_ScopeCommands"] {
		Scope := Factory == "_LLM_ScopeCommands" ? "llm" : "metrics"
		Source := '[private]`ncredential = "keep"`n'
		Fixture := _ScopeOwnerFixture(Source)
		Source := Fixture.source
		Assert(FSWriteDurable(Fixture.path, Source))
		Refusal := 0, Bundle := 0
		Launch(_Success, Borrowed, Refused) {
			Bundle := Borrowed
			Refusal := Refused
			return true
		}
		Fixture.options["reload"] := Launch
		try {
			Receipt := (%Factory%(Fixture.options)["scope_restore"])()
			AssertEqual(Receipt["status"], "pending")
			Parsed := TOML_ParseFreshFile(Fixture.path)
			Assert(!Parsed.Has(Scope) || !Parsed[Scope].Has("enabled"), "recommendations cannot grant absent consent")
			Refusal.Call("native close refused")
			AssertEqual(FSReadUtf8Exact(Fixture.path), Source)
		} finally {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
Test("config-scope-menu: recommendations never create LLM or metrics consent", _ScopeMenuAbsentConsent)

; ai-menu-no-clear. The AI menu showed « Tout effacer (comportement du
; système) » under its switch, which leaves nothing the system would do in
; the AI's place; the maintainer retired it on 2026-09-30. The declaration and
; the command factory both lose it, while the restore row stays.
_ScopeMenuLlmHasNoClear() {
	Commands := _LLM_ScopeCommands()
	Assert(Commands.Has("scope_restore"), "the AI menu keeps its restore command")
	AssertFalse(Commands.Has("scope_clear"), "the AI menu registers no clear command")
	Declared := _MR_GetMenuDef("llm_menu")
	Assert(Declared is Array && Declared.Length > 0, "the AI menu declaration must be readable")
	Restores := 0
	for Row in Declared {
		Id := _MR_Get(Row, "id", "")
		AssertFalse(Id == "scope_clear", "the AI menu declares no clear row")
		AssertFalse(_MR_Get(Row, "i18n", "") == "common.clear_to_system",
			"no AI row reads the clear label")
		if Id == "scope_restore"
			Restores += 1
	}
	AssertEqual(1, Restores, "the AI menu declares its restore row once")
}
Test("ai-menu-no-clear: the AI menu declares and registers the restore alone", _ScopeMenuLlmHasNoClear)

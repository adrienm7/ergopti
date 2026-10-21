; static/ergopti_plus/windows/tests/unit/platform/remap/key_combinations/test_key_combination_semantic_scope.ahk

; Actual boot, menu command, writer and rollback share one independently authored
; current-schema image. Only launching the replacement process is injected.
_KCT_SemanticScopeSource(Shape) {
	Taps := 'space_then_enter = "caps_word"`nleft_alt_then_caps_lock = "open_url"`nfuture_pair = "keep"`n'
	Holds := 'space_then_enter = "ctrl"`nfuture_pair = "keep"`n'
	Parameters := 'combination__left_alt_then_caps_lock__open_url = "https://pair.test"`n'
		. 'combination__space_then_enter__open_url = "https://custom.test"`n'
		. 'combination__future_pair__open_url = "foreign-pair"`n'
		. 'Combination__space_then_enter__open_url = "foreign-case"`n'
		. 'combination__space_then_enter__OPEN_URL = "foreign-action"`n'
		. 'keyboard__win_b__open_url = "foreign-domain"`n'
	switch Shape {
		case "dotted":
			Source := StrReplace(RTrim(Taps, "`n"), "`n", "`nshortcuts.key_combination_taps.")
			Source := "shortcuts.key_combination_taps." . Source . "`n"
		case "inline":
			Source := 'shortcuts.key_combination_taps = { space_then_enter = "caps_word", '
				. 'left_alt_then_caps_lock = "open_url", future_pair = "keep" }`n'
		case "quoted":
			Source := '["shortcuts"."key_combination_taps"]`n' . Taps
		default: throw ValueError("Unknown combination source shape")
	}
	if Shape == "quoted"
		Source .= '["shortcuts"."key_combination_holds"]`n' . Holds . '["action_parameters"]`n' . Parameters
	else {
		Source .= "shortcuts.key_combination_holds." . StrReplace(RTrim(Holds, "`n"), "`n", "`nshortcuts.key_combination_holds.") . "`n"
		Source .= "action_parameters." . StrReplace(RTrim(Parameters, "`n"), "`n", "`naction_parameters.") . "`n"
	}
	return Source . '[shortcuts.keyboard]`nwin_b = "copy"`n[category_enabled]`nkey_combinations = false`nshortcuts = false`n'
		. '["shortcuts.key_combination_taps"]`nspace_then_enter = "literal-dot-owner" # preserve exact foreign namespace`n'
		. '[private]`ntext = "001" # preserve exact foreign bytes`n'
}

_KCT_SemanticScope(Shape, Mode) {
	_KCT_With(Map(), Map(), Run)
	Run() {
		global _KeyCombinationScanNames, _KeyCombinationKeysByScanName
		global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
		global _MenuDispatchOwnerHandles, _MenuDispatchTokenCounter
		global _ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache
		Saved := { scans: _KeyCombinationScanNames, keys: _KeyCombinationKeysByScanName,
			callbacks: _MenuDispatchCallbacks, fires: _MenuDispatchLastFire, tokens: _MenuDispatchTokens,
			owners: _MenuDispatchOwnerHandles, counter: _MenuDispatchTokenCounter }
		Fixture := 0, Rendered := 0, Bundle := 0, Refusal := 0
		Launch(_Success, Borrowed, Refused) {
			Bundle := Borrowed, Refusal := Refused
			return true
		}
		try {
			Fixture := _ScopeOwnerFixture(_KCT_SemanticScopeSource(Shape))
			Cache := ParseConfigTomlFile(Fixture.path)
			AssertEqual("caps_word", Cache["shortcuts.key_combination_taps"]["space_then_enter"])
			AssertEqual("ctrl", Cache["shortcuts.key_combination_holds"]["space_then_enter"])
			AssertEqual("https://pair.test", Cache["action_parameters"]["combination__left_alt_then_caps_lock__open_url"])
			KeyCombinationsReadConfig(Cache)
			AssertEqual("caps_word", KeyCombinationTapOf("space_then_enter"), "the authored custom tap really loads")
			AssertEqual("ctrl", KeyCombinationHoldOf("space_then_enter"), "the authored custom hold really loads")
			AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "boot and runtime loading preserve the original syntax")
			; Disk inventory must work independently of the previously loaded maps.
			KeyCombinationsReadConfig(Map())
			_MenuDispatchCallbacks := Saved.callbacks.Clone(), _MenuDispatchLastFire := Saved.fires.Clone()
			_MenuDispatchTokens := Saved.tokens.Clone(), _MenuDispatchOwnerHandles := Saved.owners.Clone()
			Fixture.options["reload"] := Launch
			Rendered := Menu()
			Id := Mode == "recommended" ? "scope_restore" : "scope_clear"
			AssertEqual(1, MenuRenderer_AppendCommand(Rendered, "key_combinations_group", Id,
				_SC_KeyCombinationCommands(Fixture.options)))
			ItemId := DllCall("GetMenuItemID", "ptr", Rendered.Handle, "int", 0, "uint")
			Receipt := (_MenuDispatchCallbacks[ItemId])()
			AssertEqual("pending", Receipt["status"], "the real scope writer reaches replacement handoff")
			AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
			After := FSReadUtf8Exact(Fixture.path)
			Snapshot := ConfigTomlDecodeSnapshot(After), Document := Snapshot.Document
			Taps := Document["shortcuts"]["key_combination_taps"]
			Holds := Document["shortcuts"]["key_combination_holds"]
			AssertFalse(Taps.Has("space_then_enter"), "the fresh custom tap is removed")
			AssertFalse(Holds.Has("space_then_enter"), "the fresh custom hold is removed")
			for PairId, Action in Map("alt_gr_then_left_alt", "ctrl_backspace", "alt_gr_then_caps_lock", "ctrl_delete",
				"left_alt_then_caps_lock", "caps_word")
				AssertEqual(Mode == "recommended" ? Action : "none", Taps.Get(PairId, "none"), PairId)
			Params := Document["action_parameters"]
			AssertFalse(Params.Has("combination__left_alt_then_caps_lock__open_url"))
			AssertFalse(Params.Has("combination__space_then_enter__open_url"))
			for Key, Value in Map("combination__future_pair__open_url", "foreign-pair",
				"Combination__space_then_enter__open_url", "foreign-case",
				"combination__space_then_enter__OPEN_URL", "foreign-action", "keyboard__win_b__open_url", "foreign-domain")
				AssertEqual(Value, Params[Key], "unowned parameter remains exact: " . Key)
			AssertEqual("keep", Taps["future_pair"])
			AssertEqual("keep", Holds["future_pair"])
			AssertEqual("copy", Document["shortcuts"]["keyboard"]["win_b"])
			AssertEqual(false, Snapshot.Cache["category_enabled"]["shortcuts"])
			AssertEqual(Mode == "recommended", Snapshot.Cache["category_enabled"].Get("key_combinations",
				ManifestDefaultFor("category_enabled.key_combinations")), "clear preserves the disabled group switch")
			AssertContains(After, '["shortcuts.key_combination_taps"]`nspace_then_enter = "literal-dot-owner" # preserve exact foreign namespace')
			AssertContains(After, 'text = "001" # preserve exact foreign bytes')
			KeyCombinationsReadConfig(Snapshot.Cache)
			AssertEqual("none", KeyCombinationTapOf("space_then_enter"), "the removed tap cannot return on reload")
			AssertEqual("none", KeyCombinationHoldOf("space_then_enter"), "the removed hold cannot return on reload")
			Refusal.Call("native close refused")
			AssertEqual("refused", Receipt["status"])
			AssertTrue(FSUtf8ExactMatches(Fixture.path, Fixture.source), "late refusal restores all source forms exactly")
		} finally {
			if Rendered is Menu
				Rendered.Delete()
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			_KeyCombinationScanNames := Saved.scans, _KeyCombinationKeysByScanName := Saved.keys
			_MenuDispatchCallbacks := Saved.callbacks, _MenuDispatchLastFire := Saved.fires
			_MenuDispatchTokens := Saved.tokens, _MenuDispatchOwnerHandles := Saved.owners
			_MenuDispatchTokenCounter := Saved.counter
			if Fixture is Object {
				for Store in [_ConfigTomlSnapshots, _ParseTomlCache, _TomlFileCache] {
					if Store.Has(Fixture.path)
						Store.Delete(Fixture.path)
				}
				_ScopeOwnerCleanup(Fixture)
			}
		}
	}
}
for _KCT_SemanticShape in ["dotted", "inline", "quoted"]
	for _KCT_SemanticMode in ["clear", "recommended"]
		Test("key combinations: " . _KCT_SemanticShape . " " . _KCT_SemanticMode . " clears admitted custom slots (key-combination-semantic-scope)",
			_KCT_SemanticScope.Bind(_KCT_SemanticShape, _KCT_SemanticMode))

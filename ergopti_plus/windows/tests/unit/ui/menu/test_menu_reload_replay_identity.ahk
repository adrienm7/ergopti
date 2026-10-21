; tests/unit/ui/menu/test_menu_reload_replay_identity.ahk

; ==============================================================================
; MODULE: Reload Replay Across Locale and Current-Value Changes
; DESCRIPTION:
; The actual shared renderer, native menus, dispatcher, hand-off file and startup
; drain must retain the requested action independently of translated captions.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRRI_Command(Fixture, Who, Value, *) {
	Fixture.Runs.Push({Who: Who, Value: Value})
	return "ran"
}

_MRRI_Declared(Fixture, Who, Kind, Current, Lazy := false) {
	global _MenuPopulationBuilding, _MenuPopulationPublished, _MenuDispatchTokens
	Population := Lazy ? MenuPopulation() : false
	if Population is MenuPopulation
		Fixture.Populations.Push(Population)
	_MenuPopulationBuilding := Population
	try {
		if Kind == "command" || Kind == "count" {
			Commands := Map("script_control_toggle", _MRRI_Command.Bind(Fixture, Who, "toggle"),
				"scope_restore", _MRRI_Command.Bind(Fixture, Who, "restore"),
				"scope_clear", _MRRI_Command.Bind(Fixture, Who, "clear"))
			Sub := MenuRenderer_Build("script_control_group", "ScriptControl", Map(), Map(),
				Map("script_control_shortcuts", (*) => []), Commands, Map("script_control_enabled", (*) => true))
			Handle := Sub.Handle, Position := 1
		} else {
			Sub := MenuRenderer_Build("caps_word_auto_off_group", "Shortcuts", Map(), Map(),
				Map("caps_word_terminators", (*) => [], "caps_word_pointer_kinds", (*) => []),
				Map("caps_word_idle_timeout", _MRRI_Command.Bind(Fixture, Who)),
				Map("shortcuts.caps_word.idle_timeout_seconds", (*) => Current))
			Handle := DllCall("GetSubMenu", "Ptr", Sub.Handle, "Int", 0, "Ptr"), Position := 1
		}
		Root := Menu()
		Parent := Kind == "count"
			? MenuRenderer_GroupRow("top_level", "hotstrings", Sub, Map("hotstrings_enabled", (*) => true,
				"hotstrings_parent_total", (*) => Current, "hotstrings_parent_count_present", (*) => true))
			: MenuRenderer_GroupRow("top_level", "shortcuts", Sub, Map("shortcuts_enabled", (*) => true))
		AssertTrue(Parent is Map)
		AssertEqual(1, MenuRenderer_AppendRows(Root, "replay fixture", "declared parent", [Parent]))
		Fixture.Menus.Push(Sub, Root)
		_MenuPopulationPublished := Population
		return {Root: Root, Sub: Sub, Handle: Handle, Position: Position, Population: Population}
	} finally _MenuPopulationBuilding := false
}

_MRRI_Build(Fixture, Who, Code, Kind, Current := 0, Lazy := false) {
	return _TBSF_WithLocale(Code, _MRRI_Declared.Bind(Fixture, Who, Kind, Current, Lazy))
}

_MRRI_Hold(Fixture, Tray) {
	global _MenuReloadReplayRoot, _MenuDispatchCallbacks, _MenuDispatchTokens
	_MenuReloadReplayRoot := Tray.Root
	if Tray.Population is MenuPopulation
		Tray.Population.Complete(Tray.Handle, "the user opened the predecessor's picker")
	ItemId := DllCall("GetMenuItemID", "Ptr", Tray.Handle, "Int", Tray.Position, "UInt")
	AssertTrue(_MenuDispatchCallbacks.Has(ItemId))
	Identity := {ItemId: ItemId, Token: _MenuDispatchTokens[ItemId]}
	Path := MenuReloadReplay_PathOf(ItemId)
	_MRR_ReloadPending()
	AssertEqual("", MenuCommandRun(_MenuDispatchCallbacks[ItemId], [], 0, () => false,
		_MRR_Arm.Bind(Fixture), Identity))
	AssertEqual(0, Fixture.Runs.Length, "the predecessor does not apply the queued config action")
	AssertTrue(MenuReloadReplay_Publish(Fixture.File))
	_MRR_RunArmed(Fixture)
	_MRR_ReloadEnded()
	return Path
}

_MRRI_Replay(OldLocale, NewLocale, Kind, ChangedValue, Lazy, Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRRI_Build(Fixture, "old", OldLocale, Kind, 0, Lazy)
	OldPath := _MRRI_Hold(Fixture, Old)
	New := _MRRI_Build(Fixture, "new", NewLocale, Kind, ChangedValue ? 5 : 0, Lazy)
	_MenuReloadReplayRoot := New.Root
	if OldLocale != NewLocale
		AssertFalse(OldPath[1] == _MenuReloadReplayLabel(New.Root.Handle, 0), "the actual shipped translations differ")
	if ChangedValue {
		if Kind == "count" {
			AssertTrue(InStr(OldPath[1], "(0)") > 0, "the predecessor carries its actual declared count")
			AssertTrue(InStr(_MenuReloadReplayLabel(New.Root.Handle, 0), "(5)") > 0, "the successor carries the changed actual count")
		} else
			AssertFalse(OldPath[2] == _MenuReloadReplayLabel(New.Sub.Handle, 0), "the actual choice caption changed with its saved value")
	}
	Unrelated := 0
	if Lazy {
		Rows := [Map("label", "first", "action", NoAction), Map("label", "unrelated pending", "action", NoAction,
			"replay_id", "unrelated")]
		Unrelated := New.Population.Create(Rows, "unrelated", 1)
		Fixture.Menus.Push(Unrelated)
		New.Root.Add("Unrelated", Unrelated)
		AssertTrue(New.Population.Pending.Has(Unrelated.Handle))
		AssertTrue(New.Population.Pending.Has(New.Handle), "the desired choice is not registered until replay completes its picker")
	}
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertEqual(1, Paths.Length)
	_MRR_SuccessorDrains(Fixture, Paths)
	AssertEqual(1, Fixture.Runs.Length, "the successor executes the exact queued command once across captions")
	AssertEqual("new", Fixture.Runs[1].Who)
	AssertEqual(Kind == "choice" ? 1 : "restore", Fixture.Runs[1].Value, "the requested choice survives, not the newly selected value")
	if Lazy {
		AssertFalse(New.Population.Pending.Has(New.Handle))
		AssertTrue(New.Population.Pending.Has(Unrelated.Handle), "replay must not populate unrelated pickers")
	}
}

_MRRI_Context(Fixture, Name, Who, Caption := "") {
	if Caption == "" {
		Commands := Map("hotstring_category_enable_all", _MRRI_Command.Bind(Fixture, Who, "enable"),
			"hotstring_category_disable_all", _MRRI_Command.Bind(Fixture, Who, "disable"))
		Sub := MenuRenderer_Build("hotstring_category_menu", "Hotstrings", Map(), Map(),
			Map("hotstring_category_file", (*) => [], "hotstring_category_sections", (*) => []), Commands, Map())
		Fixture.Menus.Push(Sub)
		return {Menu: Sub, Name: Name}
	}
	Commands := Map("scope_restore", _MRRI_Command.Bind(Fixture, Who, "restore"))
	Row := MenuRenderer_CommandRow("script_control_group", "scope_restore", Commands)
	if Caption != ""
		Row["label"] := Caption
	Sub := Menu()
	AssertEqual(1, MenuRenderer_AppendRows(Sub, "replay fixture", "restore", [Row]))
	Fixture.Menus.Push(Sub)
	return {Menu: Sub, Name: Name}
}

_MRRI_Duplicates(MoveContext, Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRRI_Context(Fixture, "File A", "old")
	Root := Menu(), Root.Add(Old.Name, Old.Menu), Fixture.Menus.Push(Root)
	OldPath := _MRRI_Hold(Fixture, {Root: Root, Handle: Old.Menu.Handle, Position: 0, Population: false})
	AssertEqual("LFile A", OldPath.ReplayContext[1], "a reusable child Build cannot erase the file owner")
	NewA := _MRRI_Context(Fixture, MoveContext ? "File C" : "File A", "new A")
	NewB := _MRRI_Context(Fixture, MoveContext ? "File D" : "File B", "new B")
	NextRoot := Menu(), NextRoot.Add(NewA.Name, NewA.Menu), NextRoot.Add(NewB.Name, NewB.Menu)
	Fixture.Menus.Push(NextRoot), _MenuReloadReplayRoot := NextRoot
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertEqual(!MoveContext, MenuReloadReplay_Run(Paths[1], _MRR_Notify.Bind(Fixture)) == "ran")
	AssertEqual(MoveContext ? 0 : 1, Fixture.Runs.Length, "a repeated declaration requires its exact original context")
	if !MoveContext {
		AssertEqual("new A", Fixture.Runs[1].Who)
		AssertEqual("enable", Fixture.Runs[1].Value)
	}
	AssertEqual(MoveContext ? 1 : 0, Fixture.Notices.Length)
}

_MRRI_ReusedCaption(Fixture) {
	global _MenuReloadReplayRoot, _MenuDispatchTokens
	Old := _MRRI_Context(Fixture, "Features", "old", "Same caption")
	Root := Menu(), Root.Add(Old.Name, Old.Menu), Fixture.Menus.Push(Root)
	_MRRI_Hold(Fixture, {Root: Root, Handle: Old.Menu.Handle, Position: 0, Population: false})
	Id := _MenuItemIdAtPosition(Old.Menu, 0), Token := _MenuDispatchTokens[Id]
	Wrong := MenuRenderer_CommandRow("script_control_group", "scope_clear",
		Map("scope_clear", _MRRI_Command.Bind(Fixture, "wrong", "clear")))
	Wrong["label"] := "Same caption"
	AssertEqual(1, MenuRenderer_AppendRows(Old.Menu, "replay fixture", "clear", [Wrong]))
	AssertEqual(Id, _MenuItemIdAtPosition(Old.Menu, 0), "native Menu.Add reused the same command ID")
	AssertTrue(Token != _MenuDispatchTokens[Id], "the replacement owns a new registration token")
	_MenuReloadReplayRoot := Root
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertFalse(MenuReloadReplay_Run(Paths[1], _MRR_Notify.Bind(Fixture)), "a vanished identity cannot fall back to another action at its old label")
	AssertEqual(0, Fixture.Runs.Length)
	AssertEqual(1, Fixture.Notices.Length)
}

_MRRI_Feature(Fixture) {
	global _MenuReloadReplayRoot
	OldRow := MenuRowWithLabel("shortcuts.uppercase", "Uppercase (3)", "Shortcuts")
	AssertTrue(OldRow is Map)
	OldRow["action"] := _MRRI_Command.Bind(Fixture, "old", "uppercase")
	Old := Menu(), Root := Menu()
	AssertEqual(1, MenuRenderer_AppendRows(Old, "features", "shortcuts.uppercase", [OldRow]))
	Root.Add("Shortcuts", Old), Fixture.Menus.Push(Old, Root)
	_MRRI_Hold(Fixture, {Root: Root, Handle: Old.Handle, Position: 0, Population: false})
	NewRow := MenuRowWithLabel("shortcuts.uppercase", "Majuscules (8)", "Shortcuts")
	AssertTrue(NewRow is Map)
	NewRow["action"] := _MRRI_Command.Bind(Fixture, "new", "uppercase")
	New := Menu(), NewRoot := Menu()
	AssertEqual(1, MenuRenderer_AppendRows(New, "features", "shortcuts.uppercase", [NewRow]))
	NewRoot.Add("Shortcuts", New), Fixture.Menus.Push(New, NewRoot), _MenuReloadReplayRoot := NewRoot
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertEqual("ran", MenuReloadReplay_Run(Paths[1], _MRR_Notify.Bind(Fixture)))
	AssertEqual(1, Fixture.Runs.Length)
	AssertEqual("new", Fixture.Runs[1].Who)
	AssertEqual("uppercase", Fixture.Runs[1].Value, "the feature path owns replay, not its supplied caption or count")
}

_MRRI_MissingContext(Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRRI_Context(Fixture, "File A", "old")
	Root := Menu(), Root.Add(Old.Name, Old.Menu), Fixture.Menus.Push(Root)
	_MRRI_Hold(Fixture, {Root: Root, Handle: Old.Menu.Handle, Position: 0, Population: false})
	Other := _MRRI_Context(Fixture, "File B", "wrong")
	NewRoot := Menu(), NewRoot.Add(Other.Name, Other.Menu), Fixture.Menus.Push(NewRoot)
	_MenuReloadReplayRoot := NewRoot
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertFalse(MenuReloadReplay_Run(Paths[1], _MRR_Notify.Bind(Fixture)), "one remaining declaration cannot adopt another file's command")
	AssertEqual(0, Fixture.Runs.Length)
	AssertEqual(1, Fixture.Notices.Length)
}

_MRRI_Disabled(Ancestor, Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRRI_Context(Fixture, "Features", "old")
	Root := Menu(), Root.Add(Old.Name, Old.Menu), Fixture.Menus.Push(Root)
	_MRRI_Hold(Fixture, {Root: Root, Handle: Old.Menu.Handle, Position: 0, Population: false})
	if Ancestor
		Root.Disable("Features")
	else
		Old.Menu.Disable("1&")
	_MenuReloadReplayRoot := Root
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertFalse(MenuReloadReplay_Run(Paths[1], _MRR_Notify.Bind(Fixture)), "the current native row and every parent must remain enabled")
	AssertEqual(0, Fixture.Runs.Length)
	AssertEqual(1, Fixture.Notices.Length)
}

_MRRI_AliasContext(Fixture) {
	global _MenuReloadReplayRoot
	Old := _MRRI_Context(Fixture, "File A", "old")
	Root := Menu(), Root.Add("File A", Old.Menu), Root.Add("File B", Old.Menu), Fixture.Menus.Push(Root)
	AssertEqual(DllCall("GetSubMenu", "Ptr", Root.Handle, "Int", 0, "Ptr"),
		DllCall("GetSubMenu", "Ptr", Root.Handle, "Int", 1, "Ptr"), "the native menu really has two aliases of the same child")
	Path := _MRRI_Hold(Fixture, {Root: Root, Handle: Old.Menu.Handle, Position: 0, Population: false})
	AssertEqual("File A", Path[1], "the captured route is the first native alias")
	Next := _MRRI_Context(Fixture, "File A", "new")
	NewRoot := Menu(), NewRoot.Add("File B", Next.Menu), NewRoot.Add("File A", Next.Menu), Fixture.Menus.Push(NewRoot)
	_MenuReloadReplayRoot := NewRoot
	Paths := MenuReloadReplay_Consume(Fixture.File, _MRR_Notify.Bind(Fixture))
	AssertEqual("ran", MenuReloadReplay_Run(Paths[1], _MRR_Notify.Bind(Fixture)),
		"visiting another alias first cannot hide the retained exact route")
	AssertEqual(1, Fixture.Runs.Length)
	AssertEqual("new", Fixture.Runs[1].Who)
}

_MRRI_InvalidIdentity(Fixture) {
	global MENU_RELOAD_REPLAY_SCHEMA
	Schema := JsonStringLiteral(MENU_RELOAD_REPLAY_SCHEMA)
	for Command in ['{"labels":["A"],"identity":"","context":[]}', '{"labels":["A"],"identity":1,"context":[]}',
		'{"labels":["A"],"identity":"x","context":[],"extra":1}', '{"labels":1,"identity":"x","context":[]}',
		'{"labels":["A"],"identity":"x"}', '{"labels":["A"],"identity":"x","context":["extra"]}',
		'{"labels":["A","B"],"identity":"x","context":[1]}']
		_MRR_InvalidCase(Fixture, '{"schema":' . Schema . ',"commands":[' . Command . ']}', "invalid canonical identity")
}

Test("menu replay identity: English to French retains a declared config action (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Replay.Bind("en", "fr", "command", false, false)))
Test("menu replay identity: French to English retains a declared config action (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Replay.Bind("fr", "en", "command", false, false)))
Test("menu replay identity: a saved choice changes its parent caption without losing the next choice (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Replay.Bind("en", "en", "choice", true, false)))
Test("menu replay identity: locale and saved choice changes preserve the chosen value (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Replay.Bind("en", "fr", "choice", true, false)))
Test("menu replay identity: only the requested deferred picker completes across a locale change (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Replay.Bind("en", "fr", "choice", true, true)))
Test("menu replay identity: repeated declarations retain their exact context (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Duplicates.Bind(false)))
Test("menu replay identity: ambiguous moved contexts refuse without guessing (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Duplicates.Bind(true)))
Test("menu replay identity: a recycled native row cannot impersonate the old action (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_ReusedCaption))
Test("menu replay identity: malformed canonical commands are consumed and reported (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_InvalidIdentity))

Test("menu replay identity: a feature retains its canonical path across supplied captions (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Feature))

Test("menu replay identity: a missing file context cannot select the sole other file (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_MissingContext))
Test("menu replay identity: a disabled current action is refused (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Disabled.Bind(false)))
Test("menu replay identity: a disabled current ancestor is refused (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Disabled.Bind(true)))

Test("menu replay identity: a shared native submenu retains its route after parent reordering (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_AliasContext))

Test("menu replay identity: a declared hotstring count and locale change retain the action (menu-replay-canonical-identity)",
	(*) => _MRR_Run(_MRRI_Replay.Bind("en", "fr", "count", true, false)))

; tests/unit/ui/menu/test_manifest_menu_declared_groups.ahk

; ==============================================================================
; MODULE: Manifest Menu Declared Parents and Affixes
; DESCRIPTION:
; Declared parents keep their native Menu children and checked predicates,
; the physical TapHold and affix captions are read once from their EN/FR
; source, and the personal directory separates an admitted empty tree from
; a refused one.
; ==============================================================================

#Requires AutoHotkey v2.0





Test("declared parent: real and empty Menu children retain their native handles", _GR_NativeChildren)
Test("declared parent: checked predicates read once and keep the existing Boolean contract", _GR_CheckedPolicy)
Test("declared parent: withdrawn, foreign, ambiguous and nonnative children refuse", _GR_Refusals)

; Installs an independent declaration while retaining the actual physical manifest owner.
_GR_WithDeclaredParent(Body) {
	Root := _MR_GetManifestRoot(), Key := "_test_finished_group_parent"
	Present := Root.Has(Key), Previous := Present ? Root[Key] : false
	try {
		Root[Key] := [Map("type", "group", "id", "parent", "i18n", "menu.global.language",
			"checked_when", ["enabled"])]
		Body.Call(Key, Root)
	} finally {
		if Present
			Root[Key] := Previous
		else
			Root.Delete(Key)
	}
}

_GR_NativeChildren() {
	_GR_WithDeclaredParent((Key, Root) => _GR_CheckChildren(Key, Root))
}

_GR_CheckChildren(Key, Root) {
	Child := Menu(), Parent := Menu(), Calls := Map("count", 0)
	try {
		Child.Add("Native child", (*) => Calls["count"] += 1)
		Row := MenuRenderer_GroupRow(Key, "parent", Child, Map("enabled", () => false))
		AssertTrue(Row is Map, "the genuine declared group must project")
		AssertTrue(Row["submenu"] == Child, "the finished Menu is retained by identity")
		AssertEqual(t("menu.global.language"), Row["label"])
		AssertFalse(Row.Has("items"), "the finished subtree is not provider data")
		AssertEqual(1, _MR_RenderRows(Parent, [Row], Key, 1))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"))
		AssertEqual(0, Calls["count"], "projection and rendering do not run the native child")
		Empty := Menu()
		try {
			EmptyRow := MenuRenderer_GroupRow(Key, "parent", Empty, Map("enabled", () => false))
			AssertTrue(EmptyRow["submenu"] == Empty, "a genuine empty native subtree remains valid")
			AssertEqual(0, TrayMenuItemCount(Empty))
		} finally Empty.Delete()
	} finally {
		try Parent.Delete()
		finally {
			MenuDispatcher_PruneMenu(Parent)
			Child.Delete()
		}
	}
}

_GR_CheckedPolicy() {
	_GR_WithDeclaredParent((Key, Root) => _GR_CheckStates(Key, Root))
}

_GR_CheckStates(Key, Root) {
	Child := Menu()
	try {
		for State in [true, false] {
			Reads := Map("count", 0)
			Getter := _GR_ReadState.Bind(Reads, State)
			Row := MenuRenderer_GroupRow(Key, "parent", Child, Map("enabled", Getter))
			AssertEqual(State, Row["checked"])
			AssertEqual(1, Reads["count"], "the declared singleton getter runs once")
			AssertEqual(State, MenuRenderer_ResolveCheckedWhen(Key, "parent", Map("enabled", Getter)))
		}
		Root[Key][1].Delete("checked_when")
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child).Has("checked"))
	} finally Child.Delete()
}

_GR_ReadState(Reads, State) {
	Reads["count"] += 1
	return State
}

_GR_Refusals() {
	_GR_WithDeclaredParent((Key, Root) => _GR_CheckRefusals(Key, Root))
}

_GR_CheckRefusals(Key, Root) {
	Child := Menu(), Reads := Map("count", 0)
	Getters := Map("enabled", _GR_ReadState.Bind(Reads, true))
	try {
		AssertFalse(MenuRenderer_GroupRow(Key, "missing", Child, Getters))
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Map(), Getters))
		Root[Key][1]["platforms"] := ["hs"]
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters))
		Root[Key][1].Delete("platforms")
		Root[Key].Push(Root[Key][1])
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters))
		Root[Key].Pop()
		Root[Key][1]["type"] := "command"
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters))
		Root[Key][1]["type"] := "GROUP"
		AssertFalse(MenuRenderer_GroupRow(Key, "parent", Child, Getters), "canonical group kind remains case-exact")
		AssertEqual(0, Reads["count"], "refused declarations never call state readers")
	} finally Child.Delete()
}

; The Tap-Hold hold row was this physical caption group until it opened the
; shared action picker (2026-10-22); the agent's System 1 row is the next one
; Windows and Linux share.
Test("declared parent: physical captions read once and retain EN/FR literal data", _GR_PhysicalCaptions)

_GR_PhysicalCaptions() {
	global _I18nCache, _I18nCacheLoaded, _SharedDir
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Child := Menu()
	try {
		for Code in ["en", "fr"] {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Code . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Reads := Map("count", 0)
			Getters := Map("agent_system_backend_current_caption", _GR_ReadCaption.Bind(Reads, "12% / 🦀"))
			Row := MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child, Getters)
			AssertTrue(Row is Map, "the physical canonical caption group must project")
			AssertEqual(StrReplace(_I18nCache["menu.agent.system1"], "{1}", "12% / 🦀"), Row["label"])
			AssertEqual(1, Reads["count"])
			AssertTrue(Row["submenu"] == Child)
			AssertFalse(MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child, Map()))
			AssertFalse(MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child,
				Map("agent_system_backend_current_caption", (*) => 17)))
			AssertTrue(MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child, Getters) is Map,
				"explicit repair restores the genuine source-selected caption")
		}
		AssertFalse(MenuRenderer_GroupRow(Map(), "agent_system1", Child, Map()))
		AssertFalse(MenuRenderer_GroupRow("agent_linux_system1_frame", Map(), Child, Map()))
	} finally {
		try Child.Delete()
		finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

_GR_ReadCaption(Reads, Value) {
	Reads["count"] += 1
	return Value
}

Test("declared parent: authentic physical group captions retain getter and Menu identity", _GR_PhysicalCaptionPolicy)

_GR_PhysicalCaptionPolicy() {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Child := Menu()
	try {
		for Language, Expected in Map("en", "⚡ System 1 (fast): 12% / 🦀", "fr", "⚡ Système 1 (rapide) : 12% / 🦀") {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Calls := Map("count", 0)
			Getter := _MM_InertCaptionCount.Bind(Calls, "12% / 🦀")
			AssertFalse(MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child, Map()),
				"the published caption requires its actual named native getter")
			Row := MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child,
				Map("agent_system_backend_current_caption", Getter))
			AssertTrue(Row is Map)
			AssertEqual(Expected, Row["label"], "handwritten complete caption with literal native percent")
			AssertEqual(1, Calls["count"], "the genuine physical caption getter is read once")
			AssertTrue(Row["submenu"] == Child, "the genuine empty Menu is not rebuilt")
			AssertFalse(MenuRenderer_GroupRow("agent_linux_system1_frame", "agent_system1", Child,
				Map("agent_system_backend_current_caption", (*) => 7)), "nonstrings cannot become parent captions")
		}
	} finally {
		try Child.Delete()
		finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

Test("declared affixes: physical EN/FR source, current command and same native group", _DA_PhysicalRows)
Test("declared affixes: invalid source refuses before native child builder", _DA_InvalidGroupSource)

_DA_WithPhysicalFrame(Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Root := _MR_GetManifestRoot(), Key := "_test_command_group_affix"
	Present := Root.Has(Key), Previous := Present ? Root[Key] : false
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\command_group_caption_layouts.json", "UTF-8"))
	try {
		Root[Key] := Corpus["rows"]
		for Language in ["en", "fr"] {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Body.Call(Key, Root, Corpus, Language)
		}
	} finally {
		try {
			if Present
				Root[Key] := Previous
			else
				Root.Delete(Key)
		} finally {
			if HadCache
				_I18nCache := PreviousCache
			else
				_I18nCache := unset
			if HadLoaded
				_I18nCacheLoaded := PreviousLoaded
			else
				_I18nCacheLoaded := unset
		}
	}
}

_DA_PhysicalRows() {
	_DA_WithPhysicalFrame(_DA_CheckRows)
}

_DA_CheckRows(Key, Root, Corpus, Language) {
	Counts := Map("caption", 0, "command", 0, "child", 0), Pause := Map("value", false)
	Child := Menu(), Parent := Menu()
	Getters := Map("personal_default_label", _DA_ReadCaption.Bind(Counts, Corpus["value"]),
		"personal_shortcut_label", _DA_ReadCaption.Bind(Counts, Corpus["value"]),
		"enabled", () => false, "not_paused", () => !Pause["value"])
	Action := _DA_RunCommand.Bind(Counts)
	Commands := Map("personal_legacy_shortcut", Action, "shortcut_suffix", Action)
	try {
		Group := MenuRenderer_GroupRow(Key, "personal_default_parent", Child, Getters)
		AssertTrue(Group is Map)
		AssertEqual(Corpus["expected"][Language][1], Group["label"])
		AssertTrue(Group["submenu"] == Child)
		AssertEqual(false, Group["checked"])
		Command := MenuRenderer_CommandRow(Key, "personal_legacy_shortcut", Commands, Getters)
		AssertEqual(Corpus["expected"][Language][2], Command["label"])
		AssertEqual(2, Counts["caption"], "selected actual data getters are evaluated once")
		AssertEqual(0, Counts["command"])
		Rows := MenuRenderer_TemplateRows(Key, Commands, Getters,
			Map("personal_default_parent", [], "default_suffix", []))
		for Index, Row in Rows
			AssertEqual(Corpus["expected"][Language][Index], Row["label"])
		AssertEqual(6, Counts["caption"], "template does not reevaluate an explicit command caption")
		AssertEqual(0, Counts["command"])
		AssertEqual("native-result", Command["action"].Call())
		Pause["value"] := true
		AssertFalse(Command["action"].Call(), "retained native callback rechecks the original pause readiness")
		AssertEqual(1, Counts["command"])
		Pause["value"] := false
		Counts["caption"] := 0
		MenuRenderer_Build(Key, "Hotstrings", Map(),
			Map("personal_default_parent", _DA_BuildChild.Bind(Counts, Child), "default_suffix", _DA_BuildChild.Bind(Counts, Child)),
			Map(), Commands, Getters, Parent)
		AssertEqual(4, Counts["caption"])
		AssertEqual(2, Counts["child"])
		AssertEqual(4, TrayMenuItemCount(Parent))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"))
		AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 2, "ptr"))
	} finally {
		try Parent.Delete()
		finally {
			MenuDispatcher_PruneMenu(Parent)
			Child.Delete()
		}
	}
}

_DA_ReadCaption(Counts, Value) {
	Counts["caption"] += 1
	return Value
}

_DA_RunCommand(Counts, *) {
	Counts["command"] += 1
	return "native-result"
}

_DA_BuildChild(Counts, Child) {
	Counts["child"] += 1
	return Child
}

_DA_InvalidGroupSource() {
	_DA_WithPhysicalFrame(_DA_CheckRefusedSource)
}

_DA_CheckRefusedSource(Key, Root, Corpus, Language) {
	Counts := Map("caption", 0, "child", 0), Child := Menu(), Parent := Menu()
	Rows := Root[Key], PreviousKey := Rows[1]["i18n"]
	try {
		Root[Key] := [Rows[1]]
		Rows[1]["i18n"] := "future.unowned_caption"
		Getters := Map("personal_default_label", _DA_ReadCaption.Bind(Counts, Corpus["value"]))
		AssertFalse(MenuRenderer_GroupRow(Key, "personal_default_parent", Child, Getters))
		MenuRenderer_Build(Key, "Hotstrings", Map(),
			Map("personal_default_parent", _DA_BuildChild.Bind(Counts, Child)), Map(), Map(), Getters, Parent)
		AssertEqual(0, Counts["caption"])
		AssertEqual(0, Counts["child"], "unowned source refuses before calling a genuine native child builder")
		AssertEqual(0, TrayMenuItemCount(Parent))
	} finally {
		Rows[1]["i18n"] := PreviousKey
		Root[Key] := Rows
		try Parent.Delete()
		finally {
			MenuDispatcher_PruneMenu(Parent)
			Child.Delete()
		}
	}
}

; The optional flag is preflight admission only. It does not certify dispatch publication.
_MM_PersonalAppendAdmissionSeparatesEmptyAndRefused() {
	global _MenuDispatchCallbacks
	Root := _MR_GetManifestRoot(), Key := "hotstring_personal_directory_frame"
	AssertTrue(Root is Map && Root.Has(Key), "the genuine complete directory declaration exists")
	SavedDefinition := Root[Key], Native := Menu(), Calls := Map("actions", 0)
	Callback := (*) => Calls["actions"] += 1
	try {
		AssertEqual(1, RegisterMenuItem(Native, "Existing personal destination", Callback))
		Handle := Native.Handle, Before := TrayMenuItemCount(Native)
		BeforeCallbacks := _MenuDispatchCallbacks.Clone()
		Getters := Map("personal_folder_file_boundary", (*) => false)
		EmptyChildren := Map("personal_folders", (*) => [], "personal_files", (*) => [])
		Admitted := "old caller value"
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters, EmptyChildren, &Admitted))
		AssertTrue(Admitted, "a genuine complete empty provider tree is admitted without claiming native publication")
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters, EmptyChildren), "the existing five-argument count remains zero")
		AssertEqual(Handle, Native.Handle)
		AssertEqual(Before, TrayMenuItemCount(Native), "an admitted empty directory changes no native item")
		Root.Delete(Key)
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters, EmptyChildren, &Admitted))
		AssertFalse(Admitted, "withdrawal is distinguished from the same valid empty count")
		AssertEqual(Before, TrayMenuItemCount(Native))
		Root[Key] := SavedDefinition
		Child := Map("label", "Hand supplied child", "action", Callback)
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Map(), Getters,
			Map("personal_folders", (*) => [], "personal_files", (*) => [Child, false]), &Admitted))
		AssertFalse(Admitted, "a malformed later child refuses the whole tree before earlier siblings draw")
		AssertEqual(Before, TrayMenuItemCount(Native))
		AssertEqual(Handle, Native.Handle)
		AssertEqual(0, Calls["actions"], "preflight and empty/refused append do not invoke callbacks")
		AssertEqual(BeforeCallbacks.Count, _MenuDispatchCallbacks.Count)
		for Id, Previous in BeforeCallbacks
			AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Previous,
				"all original native callback identities remain exact")
	} finally {
		Root[Key] := SavedDefinition
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("personal directory: admitted empty versus withdrawn or malformed whole native tree", _MM_PersonalAppendAdmissionSeparatesEmptyAndRefused)

; tests/unit/ui/menu/test_manifest_menu_captions.ahk

; ==============================================================================
; MODULE: Manifest Menu Caption Rendering
; DESCRIPTION:
; Literal command prefixes, the shared Magic trigger rows, layout caption
; values and numbered captions keep their original translations and literal
; native captions, and refuse malformed sources whole.
; ==============================================================================

#Requires AutoHotkey v2.0





; Literal command decoration is admitted before native getters or menu publication.
_CLP_WithPhysicalFrame(Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Root := _MR_GetManifestRoot(), Key := "_test_command_literal_prefix", Legacy := Key . "_legacy"
	HadKey := Root.Has(Key), Previous := HadKey ? Root[Key] : false
	HadLegacy := Root.Has(Legacy), PreviousLegacy := HadLegacy ? Root[Legacy] : false
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\command_literal_prefixes.json", "UTF-8"))
	try {
		for Language in ["en", "fr"] {
			Root[Key] := Corpus["rows"]
			Root[Legacy] := [Corpus["legacy"]]
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Body.Call(Key, Legacy, Root, Corpus, Language)
		}
	} finally {
		try {
			if HadKey
				Root[Key] := Previous
			else if Root.Has(Key)
				Root.Delete(Key)
			if HadLegacy
				Root[Legacy] := PreviousLegacy
			else if Root.Has(Legacy)
				Root.Delete(Legacy)
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

_CLP_PhysicalRows() {
	_CLP_WithPhysicalFrame(_CLP_CheckRows)
}

_CLP_CheckRows(Key, Legacy, Root, Corpus, Language) {
	Counts := Map("caption", 0, "command", 0), Native := Menu(), SavedRows := Root[Key]
	Action := _DA_RunCommand.Bind(Counts), Commands := Map("legacy", Action)
	for Item in Corpus["rows"]
		Commands[Item["id"]] := Action
	Getters := Map("detail", _DA_ReadCaption.Bind(Counts, Corpus["value"]))
	try {
		for Index, Item in Corpus["rows"] {
			Row := MenuRenderer_CommandRow(Key, Item["id"], Commands, Getters)
			AssertTrue(Row is Map)
			AssertEqual(Corpus["expected"][Language][Index], Row["label"])
		}
		AssertEqual(2, Counts["caption"])
		AssertEqual(0, Counts["command"])
		Rows := MenuRenderer_TemplateRows(Key, Commands, Getters, Map())
		AssertEqual(7, Rows.Length, "all seven independent caption vectors remain in the canonical data tree")
		for Index, Row in Rows
			AssertEqual(Corpus["expected"][Language][Index], Row["label"])
		AssertEqual(4, Counts["caption"], "the final explicit caption is prefixed exactly once")
		LegacyRows := MenuRenderer_TemplateRows(Legacy, Commands, Getters, Map())
		AssertEqual(Corpus["legacy_expected"][Language], LegacyRows[1]["label"], "legacy caption overwrite keeps literal indentation")
		AssertEqual(5, Counts["caption"])
		Selected := MenuRenderer_CommandRow(Key, "indented", Commands, Getters)
		AssertEqual("native-result", Selected["action"].Call())
		AssertEqual(1, Counts["command"])
		; Equal labels update an existing AHK item. Isolate each unchanged hand vector.
		NativeCount := 0
		for Index, Caption in Corpus["expected"][Language] {
			Root[Key] := [Corpus["rows"][Index]]
			MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(), Commands, Getters, Native)
			AssertEqual(1, TrayMenuItemCount(Native), "each original declaration publishes exactly one native caption")
			NativeCount += TrayMenuItemCount(Native)
			AssertEqual(Caption, _CLP_NativeCaption(Native, 1))
			try Native.Delete()
			finally MenuDispatcher_PruneMenu(Native)
		}
		AssertEqual(7, NativeCount)
		AssertEqual(7, Counts["caption"])
		AssertEqual(1, Counts["command"], "native construction does not deliver commands")
	} finally {
		Root[Key] := SavedRows
		try Native.Delete()
		finally {
			try MenuDispatcher_PruneMenu(Native)
			finally Native := unset
		}
	}
}

_CLP_NativeCaption(Native, Position) {
	BufferValue := Buffer(1024, 0)
	Length := DllCall("GetMenuStringW", "ptr", Native.Handle, "uint", Position - 1,
		"ptr", BufferValue.Ptr, "int", 512, "uint", 0x400, "int")
	return StrGet(BufferValue.Ptr, Length, "UTF-16")
}

_CLP_Refusal() {
	_CLP_WithPhysicalFrame(_CLP_CheckRefusedPrefix)
}

_CLP_CheckRefusedPrefix(Key, Legacy, Root, Corpus, Language) {
	global JSON_NULL, _MenuDispatchCallbacks
	Native := Menu(), Counts := Map("caption", 0, "command", 0)
	Action := _DA_RunCommand.Bind(Counts), Commands := Map()
	for Item in Corpus["rows"]
		Commands[Item["id"]] := Action
	Getters := Map("detail", _DA_ReadCaption.Bind(Counts, Corpus["value"]))
	OriginalRows := Root[Key], OriginalPrefix := OriginalRows[6]["label_prefix"]
	try {
		AssertEqual(1, RegisterMenuItem(Native, "Existing caller-owned destination", Action))
		Handle := Native.Handle, Before := TrayMenuItemCount(Native), PreviousCallbacks := _MenuDispatchCallbacks.Clone()
		for Prefix in [false, 7, Map(), JSON_NULL, "`n", "`t", Chr(0x7F), Chr(0xD800), Chr(0xDC00)] {
			OriginalRows[6]["label_prefix"] := Prefix
			AssertFalse(MenuRenderer_CommandRow(Key, "affix", Commands, Getters))
			AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
			Admitted := true
			AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Commands, Getters, Map(), &Admitted))
			AssertFalse(Admitted, "malformed later command refuses the whole native append before drawing")
			AssertEqual(Before, TrayMenuItemCount(Native))
			AssertEqual(Handle, Native.Handle)
			AssertEqual(0, Counts["caption"])
			AssertEqual(0, Counts["command"])
		}
		OriginalRows[6]["label_prefix"] := OriginalPrefix
		for Kind in ["check", "group", "label", "section_header", "list", "---", "choice"] {
			Root[Key] := [Map("type", Kind, "id", "foreign", "i18n", "menu.hotstrings.magic_key_reset", "label_prefix", "")]
			AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
		}
		Root.Delete(Key)
		AssertFalse(MenuRenderer_CommandRow(Key, "affix", Commands, Getters))
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Commands, Getters, Map(), &Admitted))
		AssertFalse(Admitted)
		AssertEqual(Before, TrayMenuItemCount(Native))
		AssertEqual(PreviousCallbacks.Count, _MenuDispatchCallbacks.Count)
		for Id, Callback in PreviousCallbacks
			AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Callback)
	} finally {
		OriginalRows[6]["label_prefix"] := OriginalPrefix
		Root[Key] := OriginalRows
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}

_CLP_DisabledStandIn() {
	_CLP_WithPhysicalFrame(_CLP_CheckDisabledStandIn)
}

_CLP_CheckDisabledStandIn(Key, Legacy, Root, Corpus, Language) {
	Native := Menu(), Counts := Map("caption", 0, "command", 0), SourceRow := Root[Key][6]
	HadDisabled := SourceRow.Has("disabled_when"), PreviousDisabled := HadDisabled ? SourceRow["disabled_when"] : false
	HadReason := SourceRow.Has("disabled_reason_key"), PreviousReason := HadReason ? SourceRow["disabled_reason_key"] : false
	try {
		Root[Key] := [SourceRow]
		SourceRow["disabled_when"] := ["ready"]
		SourceRow["disabled_reason_key"] := "menu.hotstrings.personal_file_unavailable"
		Getters := Map("detail", _DA_ReadCaption.Bind(Counts, Corpus["value"]), "ready", (*) => false)
		Commands := Map("affix", _DA_RunCommand.Bind(Counts))
		Row := MenuRenderer_CommandRow(Key, "affix", Commands, Getters)
		AssertEqual(Corpus["expected"][Language][6], Row["label"])
		AssertTrue(Row["disabled"])
		AssertFalse(Row.Has("action"))
		MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(), Commands, Getters, Native)
		AssertEqual(Corpus["disabled_expected"][Language], _CLP_NativeCaption(Native, 1))
		AssertEqual(0, Counts["command"])
	} finally {
		if HadDisabled
			SourceRow["disabled_when"] := PreviousDisabled
		else
			SourceRow.Delete("disabled_when")
		if HadReason
			SourceRow["disabled_reason_key"] := PreviousReason
		else
			SourceRow.Delete("disabled_reason_key")
		Root[Key] := Corpus["rows"]
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}

Test("literal command prefixes: hand EN/FR selected, template, legacy and actual native images", _CLP_PhysicalRows)
Test("literal command prefixes: typed Unicode and whole-append refusal preserve exact native target", _CLP_Refusal)
Test("literal command prefixes: disabled-reason stand-ins retain final caption and no action", _CLP_DisabledStandIn)

_CLP_PlatformStandIn() {
	_CLP_WithPhysicalFrame(_CLP_CheckPlatformStandIn)
}

_CLP_CheckPlatformStandIn(Key, Legacy, Root, Corpus, Language) {
	Native := Menu(), Counts := Map("caption", 0, "command", 0), SourceRow := Root[Key][3]
	HadPlatforms := SourceRow.Has("platforms"), PreviousPlatforms := HadPlatforms ? SourceRow["platforms"] : false
	HadUnavailable := SourceRow.Has("unavailable"), PreviousUnavailable := HadUnavailable ? SourceRow["unavailable"] : false
	HadReason := SourceRow.Has("reason_key"), PreviousReason := HadReason ? SourceRow["reason_key"] : false
	try {
		Root[Key] := [SourceRow]
		SourceRow["platforms"] := ["hs"]
		SourceRow["unavailable"] := "grey"
		SourceRow["reason_key"] := "menu.hotstrings.personal_file_unavailable"
		Commands := Map("indented", _DA_RunCommand.Bind(Counts))
		MenuRenderer_Build(Key, "Hotstrings", Map(), Map(), Map(), Commands, Map(), Native)
		Expected := Corpus["expected"][Language][3] . " — " . (Language == "en" ? "Unavailable" : "Indisponible")
		AssertEqual(Expected, _CLP_NativeCaption(Native, 1))
		AssertEqual(1, TrayMenuItemCount(Native))
		AssertEqual(0, Counts["command"])
	} finally {
		if HadPlatforms
			SourceRow["platforms"] := PreviousPlatforms
		else
			SourceRow.Delete("platforms")
		if HadUnavailable
			SourceRow["unavailable"] := PreviousUnavailable
		else
			SourceRow.Delete("unavailable")
		if HadReason
			SourceRow["reason_key"] := PreviousReason
		else
			SourceRow.Delete("reason_key")
		Root[Key] := Corpus["rows"]
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("literal command prefixes: platform-grey stand-in keeps the final native caption", _CLP_PlatformStandIn)

Test("shared Magic trigger rows retain native character and captions", _MTF_Captions)
Test("shared Magic trigger rows refuse withdrawn or malformed frame", _MTF_Refusal)

_MTF_Captions() {
	_CLP_WithPhysicalFrame(_MTF_CaptionRows)
}

_MTF_CaptionRows(Key, Legacy, Root, Corpus, Language) {
	global ScriptInformation
	HadInformation := IsSet(ScriptInformation)
	Prior := HadInformation ? ScriptInformation : false
	ScriptInformation := HadInformation ? Prior.Clone() : Map()
	try {
		for Character in ["★", "§"] {
			ScriptInformation["MagicKey"] := Character
			Rows := _HS_MagicKeyRows()
			AssertTrue(Rows is Array, "the actual Windows Magic provider returns row data")
			AssertEqual(Rows.Length, 1, "Windows retains one Magic editor row and no reset")
			Expected := Language = "en" ? "Magic key: " . Character : "Touche magique : " . Character
			AssertEqual(Rows[1]["label"], Expected, "actual native provider caption follows the independent image")
			AssertTrue(Rows[1].Get("action", false) is Func, "actual Magic editor callback remains bound")
			Built := Menu()
			try {
				AssertEqual(MenuRenderer_AppendRows(Built, "hotstrings_magic_trigger_frame", "magic_key_config_native", Rows), 1, "the real renderer consumes one genuine provider row")
				AssertEqual(DllCall("GetMenuItemCount", "Ptr", Built.Handle, "Int"), 1, "actual Win32 row count remains one")
				AssertEqual(_CLP_NativeCaption(Built, 1), Expected, "actual Win32 label retains exact translated character")
			} finally {
				try Built.Delete()
				finally MenuDispatcher_PruneMenu(Built)
			}
		}
	} finally {
		if HadInformation
			ScriptInformation := Prior
		else
			ScriptInformation := unset
	}
}

_MTF_Refusal() {
	_CLP_WithPhysicalFrame(_MTF_RefusedRows)
}

_MTF_RefusedRows(Key, Legacy, Root, Corpus, Language) {
	global ScriptInformation
	HadInformation := IsSet(ScriptInformation)
	Prior := HadInformation ? ScriptInformation : false
	try {
		ScriptInformation := HadInformation ? Prior.Clone() : Map()
		ScriptInformation["MagicKey"] := "★"
		Root := _MR_GetManifestRoot()
		Frame := Root.Get("hotstrings_magic_trigger_frame", false)
		AssertTrue(Frame is Array, "the genuine compiled Magic frame is present")
		Getter := Frame[1].Get("caption_getter", "")
		try {
			Root.Delete("hotstrings_magic_trigger_frame")
			AssertEqual(_HS_MagicKeyRows().Length, 0, "withdrawn source exposes no Magic editor action")
			Root["hotstrings_magic_trigger_frame"] := Frame
			Frame[1]["caption_getter"] := "unowned_magic_value"
			AssertEqual(_HS_MagicKeyRows().Length, 0, "missing genuine value getter refuses the entire provider")
			Frame[1]["caption_getter"] := Getter
			AssertEqual(_HS_MagicKeyRows().Length, 1, "exact source repair restores the original native provider")
		} finally {
			Root["hotstrings_magic_trigger_frame"] := Frame
			Frame[1]["caption_getter"] := Getter
		}
	} finally {
		if HadInformation
			ScriptInformation := Prior
		else
			ScriptInformation := unset
	}
}

; Ordered original-format values and OS/user record captions share one literal contract.
_LVC_WithFixture(Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Root := _MR_GetManifestRoot(), Key := "_test_layout_caption_values"
	HadKey := Root.Has(Key), Previous := HadKey ? Root[Key] : false
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	try {
		for Language in ["en", "fr"] {
			Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\layout_caption_values.json", "UTF-8"))
			Corpus["rows"][2]["platforms"] := ["ahk"]
			Root[Key] := Corpus["rows"]
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Language . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			Calls := Map("captions", 0, "commands", 0)
			Getters := Map("ready", (*) => true, "selected", (*) => true)
			for Name, Value in Corpus["values"]
				Getters[Name] := _LVC_ReadCaption.Bind(Calls, Value)
			Commands := Map("upgrade", _LVC_NativeResult.Bind(Calls), "native", _LVC_NativeResult.Bind(Calls))
			Body.Call(Key, Root, Corpus, Language, Getters, Commands, Calls)
		}
	} finally {
		if HadKey
			Root[Key] := Previous
		else if Root.Has(Key)
			Root.Delete(Key)
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

; This fixture owns the plural counter; legacy decoration readers own a different singular one.
_LVC_ReadCaption(Calls, Value) {
	Calls["captions"] += 1
	return Value
}

_LVC_NativeResult(Calls, *) {
	Calls["commands"] += 1
	return "native-terminal"
}

_LVC_OriginalCaptions(Key, Root, Corpus, Language, Getters, Commands, Calls) {
	Selected := MenuRenderer_CommandRow(Key, "upgrade", Commands, Getters)
	AssertTrue(Selected is Map)
	AssertEqual(Corpus["expected"][Language][1], Selected["label"])
	Record := MenuRenderer_CheckRow(Key, "native", Commands, Getters)
	AssertTrue(Record is Map)
	AssertEqual(Corpus["expected"][Language][2], Record["label"])
	AssertTrue(Record["checked"])
	Rows := MenuRenderer_TemplateRows(Key, Commands, Getters, Map())
	AssertTrue(Rows is Array)
	AssertEqual(2, Rows.Length)
	for Index, Row in Rows
		AssertEqual(Corpus["expected"][Language][Index], Row["label"])
	Native := Menu()
	try {
		Admitted := false
		AssertEqual(2, MenuRenderer_AppendTemplate(Native, Key, Commands, Getters, Map(), &Admitted))
		AssertTrue(Admitted)
		for Index, Expected in Corpus["expected"][Language]
			AssertEqual(StrReplace(Expected, "&", "&&"), _CLP_NativeCaption(Native, Index), "raw Win32 transport doubles each literal ampersand; frozen DATA captions stay unchanged")
		AssertEqual(0, Calls["commands"])
		AssertEqual("native-terminal", Rows[1]["action"].Call())
		AssertEqual(1, Calls["commands"])
	} finally {
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("layout caption values: independent original translations and native literal captions", (*) => _LVC_WithFixture(_LVC_OriginalCaptions))

_LVC_RefuseVector(Mode, Key, Root, Corpus, Language, Getters, Commands, Calls) {
	Item := Root[Key][1]
	switch Mode {
		case "empty": Item["caption_getters"] := []
		case "sparse": Item["caption_getters"] := ["scope", , "latest"]
		case "map": Item["caption_getters"] := Map("name", "scope")
		case "wrong_name": Item["caption_getters"] := [false]
		case "missing_getter": Getters.Delete("old")
		case "scalar": Item["caption_getter"] := "scope"
		case "layout": Item["caption_layout"] := "prefix", Item["caption_joiner"] := ""
		case "boolean": Getters["old"] := (*) => false
		case "map_value": Getters["old"] := (*) => Map()
	}
	AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
	AssertEqual(0, Calls["commands"])
}
for _LVC_Mode in ["empty", "sparse", "map", "wrong_name", "missing_getter", "scalar", "layout", "boolean", "map_value"]
	Test("layout caption values: refuses " . _LVC_Mode . " vector before publication", _LVC_WithFixture.Bind(_LVC_RefuseVector.Bind(_LVC_Mode)))

_LVC_RefuseNative(Mode, Key, Root, Corpus, Language, Getters, Commands, Calls) {
	Item := Root[Key][2]
	switch Mode {
		case "translation": Item["i18n"] := "menu.layout.title"
		case "decoration": Item["caption_layout"] := "prefix", Item["caption_joiner"] := ""
		case "empty": Getters["native"] := (*) => ""
		case "boolean": Getters["native"] := (*) => false
		case "map": Getters["native"] := (*) => Map()
		case "control": Getters["native"] := (*) => "Native`nCaption"
		case "surrogate": Getters["native"] := (*) => Chr(0xD800)
	}
	AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
	AssertEqual(0, Calls["commands"])
}
for _LVC_Mode in ["translation", "decoration", "empty", "boolean", "map", "control", "surrogate"]
	Test("layout native caption: refuses " . _LVC_Mode . " without invented translation", _LVC_WithFixture.Bind(_LVC_RefuseNative.Bind(_LVC_Mode)))

_LVC_NativeGroup(Key, Root, Corpus, Language, Getters, Commands, Calls) {
	global _I18nMissWarned
	Root[Key].Push(Map("type", "group", "id", "native_parent", "caption_source", "native", "caption_getter", "native", "unavailable", "hide"))
	Child := Menu()
	HadMissWarnings := IsSet(_I18nMissWarned)
	PreviousMissWarnings := HadMissWarnings ? _I18nMissWarned : false
	OwnedMissWarnings := Map("independent retained warning", true)
	try {
		_I18nMissWarned := OwnedMissWarnings
		Child.Add("actual native child", (*) => false)
		Parent := MenuRenderer_GroupRow(Key, "native_parent", Child, Getters)
		AssertTrue(_I18nMissWarned == OwnedMissWarnings, "actual native GroupRow retains the owned miss-warning map")
		AssertFalse(OwnedMissWarnings.Has(""), "a genuine native caption never requests an empty translation key")
		AssertEqual(1, OwnedMissWarnings.Count, "valid native caption does not register a translation warning")
		AssertTrue(OwnedMissWarnings["independent retained warning"], "unrelated prior warning data remains exact")
		AssertTrue(Parent is Map)
		AssertEqual(Corpus["expected"][Language][2], Parent["label"])
		AssertTrue(Parent["submenu"] == Child, "the declared parent retains the exact genuine finished Menu")
		Rows := MenuRenderer_TemplateRows(Key, Commands, Getters, Map("native_parent", [Map("label", "actual native child", "action", (*) => false)]))
		AssertTrue(Rows is Array)
		AssertEqual(Corpus["expected"][Language][2], Rows[3]["label"])
		AssertEqual(0, Calls["commands"])
		AssertFalse(OwnedMissWarnings.Has(""), "genuine template materialization also avoids an empty translation warning")
		AssertEqual(1, OwnedMissWarnings.Count)
	} finally {
		try {
			try Child.Delete()
			finally MenuDispatcher_PruneMenu(Child)
		} finally {
			_I18nMissWarned := HadMissWarnings ? PreviousMissWarnings : unset
		}
	}
}
Test("layout native parent: retains genuine Menu identity and literal caption", (*) => _LVC_WithFixture(_LVC_NativeGroup))

_LVC_RefuseNativeGroup(Mode, Key, Root, Corpus, Language, Getters, Commands, Calls) {
	Item := Map("type", "group", "id", "native_parent", "caption_source", "native", "caption_getter", "native", "unavailable", "hide")
	Root[Key].Push(Item)
	switch Mode {
		case "missing": Getters.Delete("native")
		case "map": Getters["native"] := (*) => Map()
		case "control": Getters["native"] := (*) => "Native`nCaption"
		case "surrogate": Getters["native"] := (*) => Chr(0xD800)
		case "translation": Item["i18n"] := "menu.layout.title"
		case "layout": Item["caption_layout"] := "prefix", Item["caption_joiner"] := ""
		case "foreign": Item["caption_source"] := "foreign"
		case "command": Item["type"] := "command"
	}
	Child := Menu()
	try {
		AssertFalse(MenuRenderer_GroupRow(Key, "native_parent", Child, Getters))
		AssertEqual(0, Calls["commands"])
	} finally {
		try Child.Delete()
		finally MenuDispatcher_PruneMenu(Child)
	}
}
for _LVC_Mode in ["missing", "map", "control", "surrogate", "translation", "layout", "foreign", "command"]
	Test("layout native parent: refuses " . _LVC_Mode . " before publication", _LVC_WithFixture.Bind(_LVC_RefuseNativeGroup.Bind(_LVC_Mode)))

_LVC_HiddenRows(Key, Root, Corpus, Language, Getters, Commands, Calls) {
	for Item in Root[Key] {
		Item["platforms"] := ["hs"]
		Item["unavailable"] := "hide"
	}
	Rows := MenuRenderer_TemplateRows(Key, Map(), Map(), Map())
	AssertTrue(Rows is Array)
	AssertEqual(0, Rows.Length)
}
Test("layout caption values: other-driver hidden rows need no native owners", (*) => _LVC_WithFixture(_LVC_HiddenRows))

_LVC_DisabledCaption(Key, Root, Corpus, Language, Getters, Commands, Calls) {
	Item := Root[Key][1]
	Item["disabled_when"] := ["available"]
	Item["disabled_reason_key"] := "platform_reason.layout_bundle_and_menubar_are_macos"
	Getters["available"] := (*) => false
	Selected := MenuRenderer_CommandRow(Key, "upgrade", Commands, Getters)
	AssertTrue(Selected is Map)
	AssertEqual(Corpus["expected"][Language][1], Selected["label"], "selected provider data keeps the original formatted caption before the native reason owner")
	AssertTrue(Selected["disabled"])
	AssertEqual(0, Calls["commands"])
}
Test("layout caption values: disabled selected rows retain original native values", (*) => _LVC_WithFixture(_LVC_DisabledCaption))

; A throwing vector reader refuses before any native publication, as on Lua.
_LVC_ThrowingVectorGetter(*) {
	throw Error("actual ordered caption reader refused")
}

_LVC_RefuseThrowingVector(Key, Root, Corpus, Language, Getters, Commands, Calls) {
	Getters["old"] := _LVC_ThrowingVectorGetter
	AssertFalse(MenuRenderer_CommandRow(Key, "upgrade", Commands, Getters))
	AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
	Native := Menu()
	try {
		Native.Add("existing independent destination", _LVC_NativeResult.Bind(Calls))
		Handle := Native.Handle, Before := TrayMenuItemCount(Native)
		Admitted := true
		AssertEqual(0, MenuRenderer_AppendTemplate(Native, Key, Commands, Getters, Map(), &Admitted))
		AssertFalse(Admitted)
		AssertEqual(Handle, Native.Handle)
		AssertEqual(Before, TrayMenuItemCount(Native))
		AssertEqual("existing independent destination", _CLP_NativeCaption(Native, 1))
		AssertEqual(0, Calls["commands"], "throwing caption admission never delivers a native command")
	} finally {
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("layout caption values: throwing vector reader refuses with zero native writes", (*) => _LVC_WithFixture(_LVC_RefuseThrowingVector))

; Genuine full Build group rendering must retain literal native transport and child identity.
_LVC_GroupNativeChild(Calls, Child, *) {
	Calls["children"] += 1
	return Child
}

_LVC_FullGroupTransport(Mode, Key, Root, Corpus, Language, Getters, Commands, Calls) {
	global _I18nCache, _I18nMissWarned
	Item := Map("type", "group", "id", "actual_group", "checked_when", ["selected"])
	; These raw expected strings are independent Win32 transport goldens, not renderer output.
	switch Mode {
		case "native":
			Item["caption_source"] := "native", Item["caption_getter"] := "native"
			Item["platforms"] := ["ahk"], Item["unavailable"] := "hide"
			Expected := "Native 100%s &&&& 🦀"
		case "vector":
			Item["i18n"] := "contract.layout.group", Item["caption_getters"] := ["native"]
			_I18nCache["contract.layout.group"] := "Vector %s / %% &"
			Expected := "Vector Native 100%s &&&& 🦀 / % &&"
		case "numbered":
			Item["i18n"] := "contract.layout.group", Item["caption_getter"] := "native", Item["caption_format"] := "numbered"
			_I18nCache["contract.layout.group"] := "Numbered {1} / 50% &"
			Expected := "Numbered Native 100%s &&&& 🦀 / 50% &&"
		case "legacy scalar":
			Item["i18n"] := "contract.layout.group", Item["caption_getter"] := "native"
			_I18nCache["contract.layout.group"] := "Legacy %s & scalar"
			Expected := "Legacy %s & scalar"
		default:
			throw Error("unowned full group transport scenario")
	}
	Root[Key] := [Item]
	Calls["children"] := 0
	Child := Menu(), Parent := Menu()
	HadMissWarnings := IsSet(_I18nMissWarned)
	PreviousMissWarnings := HadMissWarnings ? _I18nMissWarned : false
	OwnedMissWarnings := Map("independent retained warning", true)
	try {
		_I18nMissWarned := OwnedMissWarnings
		Child.Add("actual independent native child", _LVC_NativeResult.Bind(Calls))
		ChildHandle := Child.Handle
		Rendered := MenuRenderer_Build(Key, "Layout", Map(),
			Map("actual_group", _LVC_GroupNativeChild.Bind(Calls, Child)), Map(), Map(), Getters,
			Parent, Map("actual_group", true))
		AssertTrue(_I18nMissWarned == OwnedMissWarnings, "actual full group Build retains the owned miss-warning map")
		AssertFalse(OwnedMissWarnings.Has(""), "a valid native group never translates an empty key")
		AssertEqual(1, OwnedMissWarnings.Count, "actual native/typed/legacy group adds no missing-translation warning")
		AssertTrue(OwnedMissWarnings["independent retained warning"], "unrelated warning data remains exact")
		AssertTrue(Rendered == Parent, "the actual existing native target retains object identity")
		AssertEqual(1, TrayMenuItemCount(Parent))
		AssertEqual(Expected, _CLP_NativeCaption(Parent, 1), "actual full group route uses the independent raw transport golden")
		AssertEqual(1, Calls["children"], "the genuine child Menu builder is called exactly once")
		AssertEqual(ChildHandle, Child.Handle)
		AssertEqual(ChildHandle, DllCall("GetSubMenu", "ptr", Parent.Handle, "int", 0, "ptr"), "the exact finished native child is attached")
		AssertEqual("actual independent native child", _CLP_NativeCaption(Child, 1))
		State := DllCall("GetMenuState", "ptr", Parent.Handle, "uint", 0, "uint", 0x400, "uint")
		AssertTrue(State != 0xFFFFFFFF, "the actual native parent state can be read")
		AssertTrue((State & 3) != 0, "Disable addresses the same escaped caption")
		AssertTrue((State & 8) != 0, "Check addresses the same escaped caption")
		AssertEqual(0, Calls["commands"], "group rendering never delivers the native child command")
		if Mode == "legacy scalar"
			AssertEqual(0, Calls["captions"], "the unspecified legacy group keeps its prior scalar getter behavior")
	} finally {
		try {
			try Parent.Delete()
			finally {
				MenuDispatcher_PruneMenu(Parent)
				try Child.Delete()
				finally MenuDispatcher_PruneMenu(Child)
			}
		} finally {
			_I18nMissWarned := HadMissWarnings ? PreviousMissWarnings : unset
		}
	}
}
for _LVC_GroupMode in ["native", "vector", "numbered", "legacy scalar"]
	Test("layout full native group: preserves " . _LVC_GroupMode . " transport and real child identity",
		_LVC_WithFixture.Bind(_LVC_FullGroupTransport.Bind(_LVC_GroupMode)))

; Pure numbered-caption policy fixtures use the real renderer/cache ports, never backend ownership.
_NC_WithFrame(Format, Body) {
	global _I18nCache, _I18nCacheLoaded, _I18nActiveCacheIdentity
	Root := _MR_GetManifestRoot(), Key := "_test_numbered_caption"
	HadKey := Root.Has(Key), Previous := HadKey ? Root[Key] : false
	HadCache := IsSet(_I18nCache), PreviousCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), PreviousLoaded := HadLoaded ? _I18nCacheLoaded : false
	HadIdentity := IsSet(_I18nActiveCacheIdentity), PreviousIdentity := HadIdentity ? _I18nActiveCacheIdentity : false
	try {
		Root[Key] := [Map("type", "command", "id", "native_action", "i18n", "contract.numbered",
			"caption_getter", "native_value", "caption_format", "numbered")]
		_I18nCache := Map("contract.numbered", Format), _I18nCacheLoaded := true
		_I18nActiveCacheIdentity := false
		Calls := Map("commands", 0)
		Commands := Map("native_action", _NC_NativeResult.Bind(Calls))
		Getters := Map("native_value", (*) => "Native% $& {1}")
		Body.Call(Key, Root, Getters, Commands, Calls)
	} finally {
		if HadKey
			Root[Key] := Previous
		else if Root.Has(Key)
			Root.Delete(Key)
		_I18nCache := HadCache ? PreviousCache : unset
		_I18nCacheLoaded := HadLoaded ? PreviousLoaded : unset
		_I18nActiveCacheIdentity := HadIdentity ? PreviousIdentity : unset
	}
}

_NC_NativeResult(Calls, *) {
	Calls["commands"] += 1
	return "native-terminal"
}

_NC_LiteralCaption(Expected, Empty, Key, Root, Getters, Commands, Calls) {
	if Empty
		Getters["native_value"] := (*) => ""
	Selected := MenuRenderer_CommandRow(Key, "native_action", Commands, Getters)
	AssertTrue(Selected is Map)
	AssertEqual(Expected, Selected["label"])
	Rows := MenuRenderer_TemplateRows(Key, Commands, Getters, Map())
	AssertTrue(Rows is Array)
	AssertEqual(Expected, Rows[1]["label"])
	Native := Menu()
	try {
		AssertEqual(1, MenuRenderer_AppendRows(Native, Key, "native_action", Rows))
		; The unchanged native menu syntax doubles literal ampersands.
		AssertEqual(StrReplace(Expected, "&", "&&"), _CTC_LabelAt(Native, 0))
		AssertEqual(0, Calls["commands"])
		AssertEqual("native-terminal", Rows[1]["action"].Call())
		AssertEqual(1, Calls["commands"])
	} finally {
		try Native.Delete()
		finally MenuDispatcher_PruneMenu(Native)
	}
}
Test("numbered caption: literal native percent/ampersand/braces", _NC_WithFrame.Bind("Caption {1}",
	_NC_LiteralCaption.Bind("Caption Native% $& {1}", false)))
Test("numbered caption: repeated scalar with literal percent format", _NC_WithFrame.Bind("50% %s {1} / {1}",
	_NC_LiteralCaption.Bind("50% %s Native% $& {1} / Native% $& {1}", false)))
Test("numbered caption: original empty model result", _NC_WithFrame.Bind("Empty ({1})", _NC_LiteralCaption.Bind("Empty ()", true)))

_NC_BadFormat(Key, Root, Getters, Commands, Calls) {
	AssertFalse(MenuRenderer_CommandRow(Key, "native_action", Commands, Getters))
	AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
	AssertEqual(0, Calls["commands"])
}
for _NC_Format in ["Caption", "Caption {2}", "Caption {1} {2}", "Caption {{1}}", "Caption {1", "Caption {1}}"]
	Test("numbered caption: refuses unsupported grammar " . _NC_Format, _NC_WithFrame.Bind(_NC_Format, _NC_BadFormat))

_NC_BadOwner(Mode, Key, Root, Getters, Commands, Calls) {
	Item := Root[Key][1]
	switch Mode {
		case "foreign mode": Item["caption_format"] := "foreign"
		case "vector": Item["caption_getters"] := ["native_value"]
		case "affix": Item["caption_layout"] := "suffix", Item["caption_joiner"] := " "
		case "native source": Item["caption_source"] := "native"
		case "prefix": Item["label_prefix"] := "!"
		case "missing getter": Getters.Delete("native_value")
		case "wrong value": Getters["native_value"] := (*) => Map()
		case "throws": Getters["native_value"] := _NC_ThrowingGetter
		case "control": Getters["native_value"] := (*) => "bad`nvalue"
		case "invalid utf16": Getters["native_value"] := (*) => Chr(0xD800)
	}
	AssertFalse(MenuRenderer_CommandRow(Key, "native_action", Commands, Getters))
	AssertFalse(MenuRenderer_TemplateRows(Key, Commands, Getters, Map()))
	AssertEqual(0, Calls["commands"])
}
_NC_ThrowingGetter(*) {
	throw Error("native caption reader refused")
}
for _NC_Mode in ["foreign mode", "vector", "affix", "native source", "prefix", "missing getter", "wrong value", "throws", "control", "invalid utf16"]
	Test("numbered caption: refuses " . _NC_Mode . " ownership", _NC_WithFrame.Bind("Caption {1}", _NC_BadOwner.Bind(_NC_Mode)))

_NC_Parent(Key, Root, Getters, Commands, Calls) {
	Item := Root[Key][1], Item["type"] := "group", Item["id"] := "native_parent"
	Child := Menu()
	try {
		Child.Add("existing native child", (*) => false)
		Row := MenuRenderer_GroupRow(Key, "native_parent", Child, Getters)
		AssertTrue(Row is Map)
		AssertEqual("50% %s Native% $& {1} / Native% $& {1}", Row["label"])
		Assert(Row["submenu"] == Child, "the actual completed child keeps its native identity")
		Raw := [Map("label", "existing native child")]
		Rows := MenuRenderer_TemplateRows(Key, Map(), Getters, Map("native_parent", Raw))
		AssertTrue(Rows is Array)
		Assert(Rows[1]["items"] == Raw, "the actual child data retains its identity")
		AssertEqual(0, Calls["commands"])
	} finally {
		try Child.Delete()
		finally MenuDispatcher_PruneMenu(Child)
	}
}
Test("numbered caption: exact genuine parent handoff", _NC_WithFrame.Bind("50% %s {1} / {1}", _NC_Parent))

_NC_Default(Expected, Key, Root, Getters, Commands, Calls) {
	Root[Key][1].Delete("caption_format")
	Rows := MenuRenderer_TemplateRows(Key, Commands, Getters, Map())
	AssertTrue(Rows is Array)
	AssertEqual(Expected, Rows[1]["label"])
	AssertEqual(0, Calls["commands"])
}
Test("numbered caption: unchanged default percent formatter", _NC_WithFrame.Bind("Value %s / %%", _NC_Default.Bind("Value Native% $& {1} / %")))
Test("numbered caption: unchanged default literal numbered text", _NC_WithFrame.Bind("Caption {1}", _NC_Default.Bind("Caption {1}")))

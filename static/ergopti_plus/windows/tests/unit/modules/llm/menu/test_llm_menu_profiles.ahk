; tests/unit/modules/llm/menu/test_llm_menu_profiles.ahk

; ==============================================================================
; MODULE: LLM Menu Profile Commands
; DESCRIPTION:
; Create and Clone keep native pause and editor refusal, the navigation
; child declaration and the profile headings follow the shared presentation,
; and the complete profile frame is drawn natively.
; ==============================================================================

#Requires AutoHotkey v2.0





_LMT_ProfileCreateCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_create_command.json"))
	Assert(Corpus is Map, "the independent profile command corpus must be readable")
	return Corpus
}

_LMT_ProfileCreatePaused(Seen) {
	return Seen["paused"]
}

_LMT_ProfileCreateOpen(Seen) {
	Seen["opens"] += 1
	return Seen["result"]
}

_LMT_SharedCreateProfileCommand() {
	Corpus := _LMT_ProfileCreateCorpus()
	Seen := Map("paused", 0, "opens", 0, "result", 1)
	Row := _LLM_Menu_CreateProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
		_LMT_ProfileCreatePaused.Bind(Seen))
	Assert(Row is Map, "the native profile owner must consume the declared row")
	AssertEqual(t(Corpus["i18n"]), Row["label"])
	AssertEqual(1, Row["action"].Call())
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 1
	AssertEqual(false, Row["action"].Call(), "a held callback rechecks the exact pause owner")
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 0
	Seen["result"] := 0
	AssertEqual(0, Row["action"].Call(), "native editor refusal must remain refusal")
	AssertEqual(2, Seen["opens"])
	for Unknown in ["0", "false", Map(), 2] {
		Seen["paused"] := Unknown
		AssertEqual(false, Row["action"].Call(), "unknown pause receipts cannot open an editor")
		AssertEqual(2, Seen["opens"])
	}
}
Test("LLM profiles: shared Create command keeps native pause and editor refusal", _LMT_SharedCreateProfileCommand)

_LMT_SharedCreateProfileLabelOwner() {
	global _MM_MANIFEST_ROOT_CACHE
	Corpus := _LMT_ProfileCreateCorpus()
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the actual manifest must be loaded before mutation")
	Declaration := Root[Corpus["section"]][1]
	AssertEqual(Corpus["id"], Declaration["id"])
	AssertEqual(Corpus["ready"], Declaration["disabled_when"][1])
	SavedKey := Declaration["i18n"]
	try {
		Declaration["i18n"] := "button.cancel"
		Seen := Map("paused", 0, "opens", 0, "result", 1)
		Row := _LLM_Menu_CreateProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
			_LMT_ProfileCreatePaused.Bind(Seen))
		AssertEqual(t("button.cancel"), Row["label"], "the declaration alone owns the native label")
		AssertEqual(1, Row["action"].Call())
		AssertEqual(1, Seen["opens"])
	} finally Declaration["i18n"] := SavedKey
}
Test("LLM profiles: actual Create provider follows a changed shared label", _LMT_SharedCreateProfileLabelOwner)

_LMT_ProfileCloneCorpus() {
	global _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_clone_command.json"))
	Assert(Corpus is Map, "the independent Clone command corpus must be readable")
	return Corpus
}

_LMT_SharedCloneProfileCommand() {
	Corpus := _LMT_ProfileCloneCorpus()
	Seen := Map("paused", 0, "opens", 0, "result", 1)
	Row := _LLM_Menu_CloneProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
		_LMT_ProfileCreatePaused.Bind(Seen))
	Assert(Row is Map, "the real native Clone row owner must consume its declaration")
	AssertEqual(t(Corpus["i18n"]), Row["label"])
	AssertEqual(1, Row["action"].Call())
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 1
	AssertEqual(false, Row["action"].Call(), "held Clone callbacks re-read the exact pause owner")
	AssertEqual(1, Seen["opens"])
	Seen["paused"] := 0
	Seen["result"] := 0
	AssertEqual(0, Row["action"].Call(), "transactional clone refusal stays refusal")
	AssertEqual(2, Seen["opens"])
	for Unknown in ["0", "false", Map(), 2] {
		Seen["paused"] := Unknown
		AssertEqual(false, Row["action"].Call(), "unknown pause receipts cannot reach the clone owner")
		AssertEqual(2, Seen["opens"])
	}
}
Test("LLM profiles: shared Clone command retains native pause and refusal", _LMT_SharedCloneProfileCommand)

_LMT_SharedCloneProfileLabelOwner() {
	Corpus := _LMT_ProfileCloneCorpus()
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the actual manifest must be initialized before controlled mutation")
	Declaration := 0
	for Row in Root[Corpus["section"]] {
		if StrCompare(Row["id"], Corpus["id"], true) == 0
			Declaration := Row
	}
	Assert(Declaration is Map, "the native Clone declaration must be present")
	AssertEqual(Corpus["ready"], Declaration["disabled_when"][1])
	SavedKey := Declaration["i18n"]
	try {
		Declaration["i18n"] := "button.cancel"
		Seen := Map("paused", 0, "opens", 0, "result", 1)
		Row := _LLM_Menu_CloneProfileRow(_LMT_ProfileCreateOpen.Bind(Seen),
			_LMT_ProfileCreatePaused.Bind(Seen))
		AssertEqual(t("button.cancel"), Row["label"], "the actual shared declaration owns the native Clone label")
		AssertEqual(1, Row["action"].Call())
		AssertEqual(1, Seen["opens"])
	} finally Declaration["i18n"] := SavedKey
}
Test("LLM profiles: actual Clone row follows a changed shared declaration", _LMT_SharedCloneProfileLabelOwner)

_LMT_SharedNavigationDeclarationOwner() {
	global _LLM_Menu, _SharedDir
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\llm_navigation_rows.json"))
	Root := _MR_GetManifestRoot()
	SavedDefinitions := Root["llm_navigation_rows"]
	Previous := _LMT_InstallFixture()
	try {
		AssertEqual(2, SavedDefinitions.Length)
		for Index, Expected in Corpus["rows"] {
			AssertEqual(Expected["id"], SavedDefinitions[Index]["id"])
			AssertEqual(Expected["type"], SavedDefinitions[Index]["type"])
			AssertEqual(Expected["i18n"], SavedDefinitions[Index]["i18n"])
		}
		_LLM_Menu["nav_modifiers"] := ""
		_LLM_Menu["val_modifiers"] := ""
		for Vector in Corpus["prediction_ranges"] {
			_LLM_Menu["n_predictions"] := Vector["count"]
			Rows := _LLM_Menu_NavRows()
			AssertEqual(2, Rows.Length)
			AssertEqual(t("menu.llm.nav_label") . " — " . t("menu.llm.arrows_only"), Rows[1]["label"])
			AssertEqual(StrReplace(t("menu.llm.val_label"), "%s", Vector["range"]) . " — " . t("menu.llm.digits_only"), Rows[2]["label"])
			AssertEqual(Vector["disabled"], Rows[1]["disabled"])
			AssertEqual(Vector["disabled"], Rows[2]["disabled"])
			Assert(HasMethod(Rows[1]["action"], "Call"))
			Built := LLM_Menu_BuildNavMenu()
			try {
				AssertEqual(Rows[1]["label"], _CTC_LabelAt(Built, 0))
				AssertEqual(Rows[2]["label"], _CTC_LabelAt(Built, 1))
			} finally _CTC_ReleaseMenu(Built)
		}
		Changed := [SavedDefinitions[2].Clone(), SavedDefinitions[1].Clone()]
		Changed[1]["i18n"] := "button.cancel"
		Root["llm_navigation_rows"] := Changed
		Rows := _LLM_Menu_NavRows()
		AssertEqual(StrReplace(t("button.cancel"), "%s", "1-0") . " — " . t("menu.llm.digits_only"), Rows[1]["label"])
		AssertEqual(t("menu.llm.nav_label") . " — " . t("menu.llm.arrows_only"), Rows[2]["label"])
		Root["llm_navigation_rows"] := []
		AssertEqual(0, _LLM_Menu_NavRows().Length, "absence is never repaired by native fallback rows")
		Changed[1]["i18n"] := 2
		Root["llm_navigation_rows"] := Changed
		AssertEqual(1, _LLM_Menu_NavRows().Length)
	} finally {
		Root["llm_navigation_rows"] := SavedDefinitions
		_LMT_RestoreFixture(Previous)
	}
	AssertTrue(Root["llm_navigation_rows"] == SavedDefinitions, "the exact canonical cache identity is restored")
}
Test("LLM navigation: actual child declaration owns label order presence and native prompts", _LMT_SharedNavigationDeclarationOwner)

; Fixed headings use the real provider, declared row materializer, and Win32 menu.
_LMT_ProfileHeadingsNativeOwner() {
	global _LLM_Menu, _SharedDir, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	Corpus := JsonParse(FSReadUtf8Exact(_SharedDir . "\tests\corpus\menus\profile_section_headings.json"))
	SavedBuiltin := Root["llm_profile_builtin_heading"]
	SavedCustom := Root["llm_profile_custom_heading"]
	Previous := _LMT_InstallFixture()
	try {
		for Section in ["llm_profile_builtin_heading", "llm_profile_custom_heading"] {
			Expected := Corpus["sections"][Section]
			AssertEqual(Expected.Length, Root[Section].Length)
			for Index, Row in Expected {
				for Key, Value in Row {
					if Value is Array {
						AssertEqual(Value.Length, Root[Section][Index][Key].Length)
						for Position, Platform in Value
							AssertEqual(Platform, Root[Section][Index][Key][Position])
					} else AssertEqual(Value, Root[Section][Index][Key])
				}
			}
		}
		Rows := _LLM_Menu_ProfileRows()
		AssertEqual(t("menu.profiles.header_default_profiles"), Rows[1]["label"])
		AssertTrue(Rows[1]["disabled"])
		AssertFalse(Rows[1].Has("action"))
		Built := LLM_Menu_BuildProfileMenu()
		try {
			AssertEqual(t("menu.profiles.header_default_profiles"), _CTC_LabelAt(Built, 0))
			State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
			AssertFalse(State == 0xFFFFFFFF, "the native heading state must be a real Win32 receipt")
			AssertTrue((State & 3) != 0)
			Position := _LMT_ShowAllPosition(Built, t("menu.profiles.header_custom_profiles"))
			AssertTrue(Position > 0)
			AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position - 1, "uint", 0x400, "uint") & 0x800) != 0)
			AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint") & 3) != 0)
			AssertTrue(InStr(_CTC_LabelAt(Built, Position + 1), "Live label") == 1)
		} finally _CTC_ReleaseMenu(Built)
		Changed := []
		for Row in SavedCustom
			Changed.Push(Row.Clone())
		Changed[2]["i18n"] := "button.cancel"
		Separator := Changed[1]
		Changed[1] := Changed[2]
		Changed[2] := Separator
		Root["llm_profile_custom_heading"] := Changed
		Built := LLM_Menu_BuildProfileMenu()
		try {
			Position := _LMT_ShowAllPosition(Built, t("button.cancel"))
			AssertTrue((DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position + 1, "uint", 0x400, "uint") & 0x800) != 0)
			AssertTrue(InStr(_CTC_LabelAt(Built, Position + 2), "Live label") == 1)
		} finally _CTC_ReleaseMenu(Built)
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_builtin_heading"] := SavedBuiltin
		Root["llm_profile_custom_heading"] := SavedCustom
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM profile headings: real declared source order caption disabled states and native data", _LMT_ProfileHeadingsNativeOwner)

_LMT_ProfileHeadingsMissingDeclaration() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	SavedBuiltin := Root["llm_profile_builtin_heading"]
	SavedCustom := Root["llm_profile_custom_heading"]
	Previous := _LMT_InstallFixture()
	try {
		OriginalLength := _LLM_Menu_ProfileRows().Length
		for Mode in ["missing", "empty", "invalid caption", "hidden platform"] {
			for Section, Original in Map("llm_profile_builtin_heading", SavedBuiltin, "llm_profile_custom_heading", SavedCustom) {
				if Mode == "missing" {
					Root.Delete(Section)
				} else if Mode == "empty" {
					Root[Section] := []
				} else {
					Changed := []
					for Row in Original {
						Copy := Row.Clone()
						if Mode == "invalid caption" && Copy.Has("i18n")
							Copy["i18n"] := 2
						if Mode == "hidden platform"
							Copy["platforms"] := ["hs"]
						Changed.Push(Copy)
					}
					Root[Section] := Changed
				}
			}
			Rows := _LLM_Menu_ProfileRows()
			AssertEqual(OriginalLength - 3, Rows.Length, Mode . " removes exactly the inert headings and their shared boundary")
			SawCustom := false
			for Row in Rows {
				if Row.Has("label") {
					AssertFalse(Row["label"] == t("menu.profiles.header_default_profiles"))
					AssertFalse(Row["label"] == t("menu.profiles.header_custom_profiles"))
					if InStr(Row["label"], "Live label") == 1 {
						SawCustom := true
						AssertTrue(HasMethod(Row["action"], "Call"))
					}
				}
			}
			AssertTrue(SawCustom, "native selectable profile data survives missing inert presentation")
		}
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_builtin_heading"] := SavedBuiltin
		Root["llm_profile_custom_heading"] := SavedCustom
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM profile headings: actual provider refuses missing invalid or hidden shared presentation without fallback", _LMT_ProfileHeadingsMissingDeclaration)

_LMT_ProfileHeadingsEmptyRegistry() {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	SavedCustom := Root["llm_profile_custom_heading"]
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["user_profiles"] := []
		Before := _LLM_Menu_ProfileRows()
		Root["llm_profile_custom_heading"] := [Map("type", "label", "id", "empty_registry_probe", "i18n", "button.cancel")]
		After := _LLM_Menu_ProfileRows()
		AssertEqual(Before.Length, After.Length)
		for Index, Row in After {
			if Row.Has("label") {
				AssertEqual(Before[Index]["label"], Row["label"])
				AssertFalse(Row["label"] == t("menu.profiles.header_custom_profiles"))
				AssertFalse(Row["label"] == t("button.cancel"))
			}
		}
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_custom_heading"] := SavedCustom
		_LMT_RestoreFixture(Previous)
	}
}
Test("LLM profile headings: empty native registry never materializes custom heading or boundary", _LMT_ProfileHeadingsEmptyRegistry)

; The two shared frame orders surround actual native profile data and callbacks.
_LMT_FrameAt(Rows, Label) {
	for Index, Row in Rows
		if Row.Has("label") && Row["label"] == Label
			return Index
	return 0
}
_LMT_ProfileFrameNativeOrder(Empty := false) {
	global _LLM_Menu, _SharedDir, LLM_PROFILE_BUILTIN_ORDER, _LMT_WriterCalls, _LMT_ApplyCalls
	Previous := _LMT_InstallFixture()
	Built := false
	try {
		_LLM_Menu["profile_id"] := Empty ? "user_one" : "basic"
		if Empty
			_LLM_Menu["user_profiles"] := []
		Rows := _LLM_Menu_ProfileRows()
		Assert(Rows is Array, "real native profile frame must materialize")
		AssertEqual(t("menu.profiles.header_default_profiles"), Rows[1]["label"])
		AssertTrue(Rows[1]["disabled"])
		AssertFalse(Rows[1].Has("action"))
		for Index, Id in LLM_PROFILE_BUILTIN_ORDER {
			Row := Rows[Index + 1]
			AssertTrue(InStr(Row["label"], LLM_Menu_GetProfileLabel(Id)) == 1, "unchanged native catalogue order and hint ownership")
			AssertEqual(Id == _LLM_Menu["profile_id"], Row["checked"])
			AssertTrue(HasMethod(Row["action"], "Call"))
		}
		Create := _LMT_FrameAt(Rows, t("menu.profiles.create_profile"))
		Clone := _LMT_FrameAt(Rows, t("menu.profiles.clone_builtin"))
		Auto := _LMT_FrameAt(Rows, t("menu.profiles.auto_detect"))
		Apps := _LMT_FrameAt(Rows, t("menu.profiles.per_app_overrides"))
		AssertTrue(Create > 1 && Auto > Create && Apps > Auto, "independent Windows Create/Clone then automatic-profile then per-app order")
		AssertTrue(Rows[Create - 1].Get("separator", false))
		AssertTrue(Rows[Auto - 1].Get("separator", false))
		AssertTrue(Rows[Apps - 1].Get("separator", false))
		AssertTrue(Rows[Apps]["items"] is Array && Rows[Apps]["items"].Length > 0, "actual native per-app child provider is retained")
		if Empty {
			AssertEqual(0, Clone, "custom active profile has no builtin clone")
			AssertEqual(0, _LMT_FrameAt(Rows, t("menu.profiles.header_custom_profiles")))
		} else {
			Custom := _LMT_FrameAt(Rows, t("menu.profiles.header_custom_profiles"))
			AssertEqual(LLM_PROFILE_BUILTIN_ORDER.Length + 3, Custom, "custom heading follows the complete native catalogue and its separator")
			AssertTrue(Rows[Custom - 1]["separator"])
			AssertTrue(InStr(Rows[Custom + 1]["label"], "Live label") == 1)
			AssertEqual(Create + 1, Clone, "Windows clone stays beside Create, without a Lua-only clone boundary")
		}
		AssertEqual(_LLM_Menu["auto_profile_for_model"], Rows[Auto]["checked"])
		Built := LLM_Menu_BuildProfileMenu()
		State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", 0, "uint", 0x400, "uint")
		AssertTrue(State != 0xFFFFFFFF && (State & 3) != 0, "actual Win32 menu consumes the inert frame header")
		AssertTrue(_LMT_ShowAllPosition(Built, t("menu.profiles.per_app_overrides")) > 0)
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		if Built is Menu
			_CTC_ReleaseMenu(Built)
		_LMT_RestoreFixture(Previous)
	}
}
Test("complete profile frame: actual Windows custom-builtin frame and native menu", _LMT_ProfileFrameNativeOrder.Bind(false))
Test("complete profile frame: actual Windows empty registry and conditional clone", _LMT_ProfileFrameNativeOrder.Bind(true))

_LMT_ProfileFrameMutation(Mode) {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	Saved := Root["llm_profile_windows_frame"]
	Previous := _LMT_InstallFixture()
	try {
		_LLM_Menu["profile_id"] := "basic"
		Changed := []
		for Row in Saved
			Changed.Push(Row.Clone())
		Root["llm_profile_windows_frame"] := Changed
		if Mode == "order" {
			First := Changed[1]
			Changed[1] := Changed[5]
			Changed[5] := First
		} else if Mode == "missing"
			Root.Delete("llm_profile_windows_frame")
		else if Mode == "list"
			Changed[2]["id"] := "unowned_native_slot"
		else if Mode == "presence"
			Changed[3]["present_when"] := "unowned_presence"
		else if Mode == "selector"
			Changed[5]["row_id"] := "missing"
		Rows := _LLM_Menu_ProfileRows()
		if Mode == "order" {
			Assert(Rows is Array)
			AssertEqual(t("menu.profiles.create_profile"), Rows[1]["label"], "actual provider consumes shared frame ordering")
		} else
			AssertEqual(false, Rows, "missing policy/native binding cannot fabricate a valid frame")
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root["llm_profile_windows_frame"] := Saved
		_LMT_RestoreFixture(Previous)
	}
}
for Mode in ["order", "missing", "list", "presence", "selector"]
	Test("complete profile frame: actual source mutation " . Mode, _LMT_ProfileFrameMutation.Bind(Mode))

_LMT_ProfileFrameHeldDeclaration(Command) {
	global _LLM_Menu, _LMT_WriterCalls, _LMT_ApplyCalls
	Root := _MR_GetManifestRoot()
	Previous := _LMT_InstallFixture()
	Section := Command == "auto_detect" ? "llm_profile_auto_detect_control" : "llm_profile_commands"
	Saved := Root[Section]
	try {
		_LLM_Menu["profile_id"] := "basic"
		Rows := _LLM_Menu_ProfileRows()
		Label := Command == "auto_detect" ? "menu.profiles.auto_detect" : Command == "create" ? "menu.profiles.create_profile" : "menu.profiles.clone_builtin"
		Index := _LMT_FrameAt(Rows, t(Label))
		AssertTrue(Index > 0, "actual declared command must be retained before withdrawal")
		Root.Delete(Section)
		AssertEqual(false, Rows[Index]["action"].Call(), "retained action refuses a withdrawn canonical declaration before dialog or publication")
		AssertEqual(0, _LMT_WriterCalls)
		AssertEqual(0, _LMT_ApplyCalls)
	} finally {
		Root[Section] := Saved
		_LMT_RestoreFixture(Previous)
	}
}
for Command in ["create", "clone", "auto_detect"]
	Test("complete profile frame: held native owner declaration withdrawal " . Command, _LMT_ProfileFrameHeldDeclaration.Bind(Command))

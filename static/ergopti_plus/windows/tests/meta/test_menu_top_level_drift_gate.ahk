; static/ergopti_plus/windows/tests/meta/test_menu_top_level_drift_gate.ahk

; ==============================================================================
; MODULE: Menu Top-Level Drift Gate (AHK)
; DESCRIPTION:
; Stages the tray root through the dispatcher initMenu uses and compares the
; rows it stages, separators included, with the manifest's `top_level` array
; projected for the AHK platform.
;
; WHY IT STAGES INSTEAD OF COMPARING TWO LISTS.
; This gate used to pin the manifest against a hand-typed list of tail ids,
; which alarms on a manifest edit and says nothing about the driver. The driver
; was where the drift lived: the feature rows were a fixed sequence of calls in
; initMenu, checked against the manifest only by a log line, and the rows from
; `global_actions` onward came from a loader that fell back to a hardcoded tail
; when that anchor was missing. A reordered top level, or a separator among the
; feature rows, left this tray in its old order.
;
; The builders are stubs here: each stages one row named by its id, so the
; order under test is the dispatcher's alone. The table they stand in for is
; compared with the manifest separately, in both directions, and each of its
; builders is held to the row its id names.
;
; The macOS half lives in macos/tests/meta/test_menu_top_level_drift_gate.lua,
; and tools/test/test-menu-top-level-parity.cjs holds the three builder tables
; to the same projection.
; ==============================================================================

; The bodies of every tray-root builder initMenu dispatches through, joined, for
; the source scans of other suites. initMenu stages no row itself: each
; top-level row is staged by the builder _MI_TopLevelBuilders names, so a scan of
; what the root builds reads those bodies. Read through the table rather than a
; list of names, so a builder added to the root is scanned without editing this.
; Kept here and not in test_framework.ahk: the framework is also included by
; runners that do not load menu_init.ahk, where this name would be unset.
_TrayRootBuilderBodies() {
	Out := ""
	for _, Builder in _MI_TopLevelBuilders()
		Out .= "`n" . _DriverFuncBody(Builder.Name)
	return Out
}

; Reads the shipped manifest's top_level array; throws when it cannot.
_DG_ManifestTopLevel() {
	SplitPath(A_ScriptDir, , &WinDir)
	SplitPath(WinDir, , &EpDir)
	ManifestPath := EpDir . "\_shared\modules\menu\menu_manifest.json"
	Root := JsonParse(FileRead(ManifestPath, "UTF-8"))
	Assert((Root is Map) && Root.Has("top_level") && (Root["top_level"] is Array),
		"menu_manifest.json must carry a top_level array")
	return Root["top_level"]
}

; Whether a manifest row is visible on this platform.
_DG_IsForAhk(Entry) {
	if !Entry.Has("platforms")
		return true
	for _, Platform in Entry["platforms"] {
		if (Platform == "ahk")
			return true
	}
	return false
}

; The rows this platform may see, in order, with a separator kept only between
; two rows, as the tray draws them.
_DG_ProjectForAhk(TopLevel) {
	Out := []
	for _, Entry in TopLevel {
		if !_DG_IsForAhk(Entry)
			continue
		Id := Entry["id"]
		if (Id == "---") {
			if (Out.Length > 0 && Out[Out.Length] != "---")
				Out.Push("---")
			continue
		}
		Out.Push(Id)
	}
	while (Out.Length > 0 && Out[Out.Length] == "---")
		Out.Pop()
	return Out
}

_DG_Join(Ids) {
	Out := ""
	for _, Id in Ids
		Out .= (Out == "" ? "" : ", ") . Id
	return Out
}

; A stand-in builder: stages one row labelled by its id.
_DG_StageStub(Id) {
	TrayMenuStage_Add(Id, 0)
}

; Records the staged tree instead of publishing it to the tray.
_DG_CaptureStage(Captured, DisabledTitles, Stage) {
	for _, Entry in Stage {
		if (Entry["kind"] == "check" || Entry["kind"] == "disable")
			continue
		Label := Entry["label"]
		Captured.Push(Label == "" ? "---" : (DisabledTitles.Has(Label) ? DisabledTitles[Label] : Label))
	}
	return 1
}

; Stages a top_level array through the production dispatcher with stub builders
; for every id the real table knows, and returns what was staged.
_DG_StageWithStubs(TopLevel) {
	global _TrayMenuStage, _TrayFeatureHeadLabels
	Stubs := Map()
	for Id in _MI_TopLevelBuilders()
		Stubs[Id] := _DG_StageStub.Bind(Id)
	SavedStage := _TrayMenuStage
	SavedLabels := _TrayFeatureHeadLabels
	Captured := []
	DisabledTitles := Map()
	for _, Entry in TopLevel {
		if Entry.Get("disabled", false) {
			Label := t(Entry["i18n"]) . " — " . _MR_ReasonHead(t(Entry["reason_key"]))
			DisabledTitles[Label] := Entry["id"]
		}
	}
	try {
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageTopLevel(TopLevel, Stubs)
		AssertTrue(TrayMenuStage_Publish(0, _DG_CaptureStage.Bind(Captured, DisabledTitles)))
	} finally {
		_TrayMenuStage := SavedStage
		_TrayFeatureHeadLabels := SavedLabels
	}
	return Captured
}

_DG_EveryDeclaredRowHasABuilder() {
	Declared := Map()
	for _, Id in _DG_ProjectForAhk(_DG_ManifestTopLevel()) {
		if (Id != "---")
			Declared[Id] := true
	}
	; Floors the projection: a parse that read nothing would pass vacuously.
	Assert(Declared.Count >= 10, "the manifest must declare at least ten rows for Windows, got " . Declared.Count)
	Builders := _MI_TopLevelBuilders()
	Missing := ""
	for Id in Declared {
		if !Builders.Has(Id)
			Missing .= " " . Id
	}
	Assert(Missing == "", "top-level rows declared for Windows with no builder:" . Missing)
	Orphaned := ""
	for Id in Builders {
		if !Declared.Has(Id)
			Orphaned .= " " . Id
	}
	Assert(Orphaned == "", "builders for rows the manifest does not declare for Windows:" . Orphaned)
}

_DG_ShippedManifestStagesInOrder() {
	TopLevel := _DG_ManifestTopLevel()
	AssertEqual(_DG_Join(_DG_ProjectForAhk(TopLevel)), _DG_Join(_DG_StageWithStubs(TopLevel)),
		"the tray root must stage the manifest's top level, separators included")
}

; Reversed, then a separator added right after the first row, so rows that were
; the fixed head now sit after the former tail and a separator lands where no
; fixed sequence would put one.
_DG_ReorderedManifestReordersTheRoot() {
	TopLevel := _DG_ManifestTopLevel()
	Shuffled := []
	Index := TopLevel.Length
	while (Index >= 1) {
		Shuffled.Push(TopLevel[Index])
		Index -= 1
	}
	Shuffled.InsertAt(2, Map("id", "---"))
	Expected := _DG_ProjectForAhk(Shuffled)
	Assert(Expected[1] != _DG_ProjectForAhk(TopLevel)[1], "the shuffled top level must start with a different row")
	AssertEqual(_DG_Join(Expected), _DG_Join(_DG_StageWithStubs(Shuffled)),
		"a reordered manifest must reorder the tray root, separators included")
}

; The row each top-level id stands for, as its builder spells the title. The
; order cases above stage stubs, so they prove the dispatcher's order and not
; the table: two ids swapped in _MI_TopLevelBuilders would draw the wrong rows
; in the right slots and pass them. An id missing here fails the case below, so
; a new builder has to say which row it stages.
global _DG_BUILDER_TITLES := Map(
	"keyboard_layout", 't("menu.layout.title")',
	"hotstrings",      't("menu.hotstrings.title")',
	"llm",             't("menu.llm.title")',
	"agent",           't("menu.agent.title")',
	"metrics",         't("menu.metrics.title")',
	"shortcuts",       'GetCategoryTitle("Shortcuts")',
	"tap_holds",       'GetCategoryTitle("TapHolds")',
	"gestures",        'GetCategoryTitle("Gestures")',
	"configuration",   't("menu.configuration.title")',
	"language",        't("menu.global.language")',
	"about",           't("menu.about.title")',
	"suspend",         't("menu.global.suspend")',
	"reload",          'MenuRenderer_CommandRow("top_level", "reload"',
	"quit",            'MenuRenderer_CommandRow("top_level", "quit"',
	"debug",           't("menu.debug.title")'
)

_DG_EveryBuilderStagesItsOwnRow() {
	Checked := 0
	for Id, Builder in _MI_TopLevelBuilders() {
		Assert(_DG_BUILDER_TITLES.Has(Id), "name the title the '" . Id . "' builder stages in _DG_BUILDER_TITLES")
		Body := _StripFullLineComments(_DriverFuncBody(Builder.Name))
		; The IA row is staged by LLM_Menu_Init, which owns its persistent submenu.
		if (Id == "llm")
			Body .= _StripFullLineComments(_DriverFuncBody("LLM_Menu_Init"))
		Assert(Body != "", "the '" . Id . "' builder " . Builder.Name . " must be readable")
		if Id == "keyboard_layout" || Id == "hotstrings" || Id == "shortcuts" || Id == "tap_holds" || Id == "gestures" {
			AssertTrue(_DG_DeclaredBuilderSourceValid(Id, Body, _DriverFuncBody("_MI_StageDeclaredFeature")),
				"the '" . Id . "' builder must retain its canonical title receiver and exact native child stage")
		} else {
		Assert(InStr(Body, _DG_BUILDER_TITLES[Id]) > 0,
			"the '" . Id . "' builder " . Builder.Name . " must stage the row titled " . _DG_BUILDER_TITLES[Id])
		}
		for OtherId, Title in _DG_BUILDER_TITLES {
			if (OtherId != Id)
				Assert(!InStr(Body, Title), "the '" . Id . "' builder " . Builder.Name
					. " stages the '" . OtherId . "' row (" . Title . ")")
		}
		Checked += 1
	}
	Assert(Checked >= 12, "the tray root must dispatch at least twelve builders, read " . Checked)
}

; The production root goes through the same dispatcher, over the shipped array,
; and stages nothing of its own around it.
_DG_InitMenuDispatchesTheWholeRoot() {
	Body := _StripFullLineComments(_DriverFuncBody("initMenu"))
	Assert(InStr(Body, "_MI_StageTopLevel(MenuManifest_LoadTopLevel(), _MI_TopLevelBuilders())") > 0,
		"initMenu must stage its root through _MI_StageTopLevel over the manifest's top_level")
	Assert(!RegExMatch(Body, "TrayMenuStage_Add\w*\("),
		"initMenu must not stage a top-level row outside the dispatcher")
}

Test("menu drift gate (AHK): every top-level row declared for Windows has a builder",
	_DG_EveryDeclaredRowHasABuilder)
Test("menu drift gate (AHK): the shipped manifest stages in its declared order",
	_DG_ShippedManifestStagesInOrder)
Test("menu drift gate (AHK): a reordered manifest reorders the root, separators included",
	_DG_ReorderedManifestReordersTheRoot)
Test("menu drift gate (AHK): initMenu stages its whole root through the dispatcher",
	_DG_InitMenuDispatchesTheWholeRoot)
Test("menu drift gate (AHK): every root builder stages the row its id names",
	_DG_EveryBuilderStagesItsOwnRow)

; The real dispatcher must skip the unfinished builder and stage an inert,
; localized header. It is not a feature head that resume may re-enable.
_DG_RecordNeighbor(Calls, Id) {
	Calls.Push(Id)
	TrayMenuStage_AddFeature(Id, 0)
}

_DG_AgentUnreadyDoesNotDisableNeighbors() {
	global _TrayMenuStage, _TrayFeatureHeadLabels
	Agent := false
	for _, Entry in _DG_ManifestTopLevel() {
		if Entry["id"] == "agent"
			Agent := Entry
	}
	Assert(Agent is Map, "the canonical Agent declaration must exist")
	AssertEqual(true, Agent.Get("disabled", false))
	SavedStage := _TrayMenuStage
	SavedLabels := _TrayFeatureHeadLabels
	Calls := []
	try {
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageTopLevel([Map("id", "llm"), Agent], Map(
			"llm", _DG_RecordNeighbor.Bind(Calls, "llm"),
			"agent", _DG_RecordNeighbor.Bind(Calls, "agent")))
		AssertEqual("llm", _DG_Join(Calls), "disabled Agent must not execute its builder")
		Label := t("menu.agent.title") . " — " . _MR_ReasonHead(t("menu.agent.not_ready"))
		FoundAction := false
		FoundDisable := false
		for _, Row in _TrayMenuStage {
			if Row["label"] != Label
				continue
			if Row["kind"] == "action" {
				FoundAction := true
				AssertEqual(false, Row["target"].Call(), "the disabled header has no executable Agent action")
			}
			if Row["kind"] == "disable"
				FoundDisable := true
		}
		Assert(FoundAction && FoundDisable, "Agent must retain its exact localized disabled header")
		AssertEqual("llm", _DG_Join(_TrayStageFeatureLabels(_TrayMenuStage)),
			"pause/resume may only re-enable the neighboring AI feature header")
	} finally {
		_TrayMenuStage := SavedStage
		_TrayFeatureHeadLabels := SavedLabels
	}
}

Test("Agent IA unready: real root stages an inert localized header while neighboring AI stays available",
	_DG_AgentUnreadyDoesNotDisableNeighbors)

; A declaration-driven parent has no native title literal in its builder. This
; closed source proof checks the complete reached coordinator and the complete
; borrowed-child builders, rather than exempting a helper by its name. Any new
; executable statement requires review of the read-only stage contract.
_DG_SourceLines(Source) {
	Out := ""
	for Line in StrSplit(_StripFullLineComments(Source), "`n", "`r") {
		Line := Trim(Line, " `t")
		if Line != ""
			Out .= (Out == "" ? "" : "`n") . Line
	}
	return Out
}
_DG_SourceJoin(Lines) {
	Out := ""
	for Line in Lines
		Out .= (Out == "" ? "" : "`n") . Line
	return Out
}
_DG_DeclaredStageExpected() {
	return _DG_SourceJoin([
		'_MI_StageDeclaredFeature(Receiver, Child, Getters, DisposeOnRefusal := false) {',
		'Published := false',
		'try {',
		'Row := Receiver.Call(Child, Getters)',
		'if !(Row is Map) || Row.Get("submenu", false) != Child',
		'throw Error("The canonical feature parent changed during native construction.")',
		'TrayMenuStage_AddFeature(Row["label"], Child)',
		'Published := true',
		'if Row.Get("checked", false)',
		'TrayMenuStage_Check(Row["label"])',
		'return true',
		'} finally {',
		'if DisposeOnRefusal && !Published {',
		'try Child.Delete()',
		'finally MenuDispatcher_PruneMenu(Child)',
		'}',
		'}',
		'}'])
}
_DG_DeclaredStageSourceValid(Source) {
	return _DG_SourceLines(Source) == _DG_DeclaredStageExpected()
}
_DG_DeclaredBuilderExpected(Id) {
	if Id == "keyboard_layout"
		return _DG_SourceJoin([
			'_MI_StageLayout() {',
			'Receiver := MenuRenderer_GroupReceiver("top_level", "keyboard_layout")',
			'if !Receiver',
			'throw Error("The declared keyboard_layout feature parent was refused before native construction.")',
			'LayoutListProviders := Map(',
			'"number_row_policy",      (*) => _LAY_NumberRowRows(),',
			'"custom_layouts",         (*) => _LAY_CustomLayoutRows(),',
			'"layout_features_base",   (*) => _LAY_LayoutFeatureBaseRows(),',
			'"layout_features_altgr",  (*) => _LAY_LayoutFeatureAltGrRows(),',
			'"magic_key_source",       (*) => MagicKeySourceMenuRows(),',
			')',
			'LayoutMenu  := MenuRenderer_Build("layout_menu", "Layout", "", "", LayoutListProviders,',
			'_LAY_ScopeCommands(),',
			'Map("layout_enabled", () => IsCategoryGated("Layout")))',
			'_MI_StageDeclaredFeature(Receiver, LayoutMenu, Map("layout_enabled", () => IsCategoryGated("Layout")), true)',
			'BootProfile_Mark("MENU/initMenu: layout built+added")',
			'}'])
	if Id == "hotstrings"
		return _DG_SourceJoin([
			'_MI_StageHotstrings() {',
			'Receiver := MenuRenderer_GroupReceiver("top_level", "hotstrings")',
			'if !Receiver',
			'throw Error("The declared hotstrings feature parent was refused before native construction.")',
			'HotstringsAllEnabled := IsCategoryGated("Hotstrings")',
			'_HotDynHandlers := Map()',
			'_HotParamCommands := Map(',
			'"repeat_key", ToggleRepeatKeyEnabled,',
			')',
			'_HotParamGetters := Map(',
			'"hotstrings_repeat_enabled", () => ReadFeatureStateV2("hotstrings.repeat_key_enabled").Get("enabled", false),',
			')',
			'_HotListProviders := Map(',
			'"word_expanders",                (*) => _HS_WordExpanderRows(),',
			'"magic_key_config",              (*) => _HS_MagicKeyRows(),',
			'"delays_colors",                 (*) => _HS_DelaysColorsRows(),',
			'"hotstring_categories_standard", (*) => _HS_CategoryRowsStandard(),',
			'"hotstring_categories_dynamic",  (*) => _HS_CategoryRowsDynamic(),',
			'"hotstring_languages",           (*) => _HS_LanguageRows(),',
			'"hotstring_personal",           (*) => _HS_PersonalRows(),',
			'"hotstring_extensions",          (*) => _HS_ExtensionRows(),',
			')',
			'HotstringsAllSectionsOn := _HS_AllHotstringsOn()',
			'_HotCommands := _HS_ScopeCommands()',
			'_HotCommands["hotstrings_toggle"] := MenuRenderer_CategoryGateCommand("Hotstrings")',
			'_HotCommands["hotstrings_all_sections"] := (*) => ToggleAllHotstrings(!HotstringsAllSectionsOn)',
			'_HotGetters := Map(',
			'"hotstrings_enabled",              () => IsCategoryGated("Hotstrings"),',
			'"hotstrings_all_sections_enabled", () => HotstringsAllSectionsOn,',
			')',
			'_HotGroupBuilders := Map(',
			'"hotstrings_params", (*) => MenuRenderer_Build("hotstrings_params_group", "Hotstrings", _HotDynHandlers, "", _HotListProviders, _HotParamCommands, _HotParamGetters),',
			')',
			'BootProfile_Mark("MENU/initMenu: pre-hotstrings render")',
			'HotstringsMenu := MenuRenderer_Build("hotstrings_menu", "Hotstrings", _HotDynHandlers, _HotGroupBuilders, _HotListProviders, _HotCommands, _HotGetters)',
			'BootProfile_Mark("MENU/initMenu: hotstrings menu rendered")',
			'HotstringsTotal := _HS_ComputeGrandTotal()',
			'_MI_StageDeclaredFeature(Receiver, HotstringsMenu, Map("hotstrings_enabled", () => HotstringsAllEnabled,',
			'"hotstrings_parent_total", () => HotstringsTotal, "hotstrings_parent_count_present", () => true), true)',
			'BootProfile_Mark("MENU/initMenu: hotstrings grandtotal+added")',
			'}'])
	if Id == "gestures"
		return _DG_SourceJoin([
			'_MI_StageGestures() {',
			'Receiver := MenuRenderer_GroupReceiver("top_level", "gestures")',
			'if !Receiver',
			'throw Error("The declared gestures feature parent was refused before native construction.")',
			'GesturesMenu := BuildGesturesMenu()',
			'_MI_StageDeclaredFeature(Receiver, GesturesMenu, Map("gestures_enabled", () => Features["gestures"]["enabled"]), true)',
			'}'])
	if Id != "shortcuts" && Id != "tap_holds"
		return ""
	Category := Id == "shortcuts" ? "Shortcuts" : "TapHolds"
	Missing := Id == "shortcuts" ? "Shortcuts" : "Tap-Holds"
	State := Id == "shortcuts" ? "shortcuts_enabled" : "tapholds_enabled"
	return _DG_SourceJoin([
		'_MI_Stage' . Category . '() {',
		'Receiver := MenuRenderer_GroupReceiver("top_level", "' . Id . '")',
		'if !Receiver',
		'throw Error("The declared ' . Id . ' feature parent was refused before native construction.")',
		'global SubMenus',
		'if !SubMenus.Has("' . Category . '") {',
		'try LoggerError("Menu", "The ' . Missing . ' submenu was not built — its tray row is missing.")',
		'return',
		'}',
		'_MI_StageDeclaredFeature(Receiver, SubMenus["' . Category . '"], Map("' . State . '", () => IsCategoryGated("' . Category . '")))',
		'}'])
}
_DG_DeclaredBuilderSourceValid(Id, Body, StageBody) {
	Expected := _DG_DeclaredBuilderExpected(Id)
	return Expected != "" && _DG_SourceLines(Body) == Expected && _DG_DeclaredStageSourceValid(StageBody)
}
_DG_DeclaredSourceCounterfactuals() {
	Stage := _DriverFuncBody("_MI_StageDeclaredFeature")
	AssertTrue(_DG_DeclaredStageSourceValid(Stage), "the actual reached coordinator must satisfy the complete stage-only contract")
	Mutations := [
		['Row := Receiver.Call(Child, Getters)', 'Child.Insert("Sentinel")`nRow := Receiver.Call(Child, Getters)'],
		['Published := true', 'Child.Add("Injected", (*) => 0)`nPublished := true'],
		['return true', 'Child.Delete()`nreturn true'],
		['return true', 'Child.Disable("Sentinel")`nreturn true'],
		['return true', 'MutateBorrowedChild(Child)`nreturn true'],
		['Row := Receiver.Call(Child, Getters)', 'Alias := Child`nAlias.Delete()`nRow := Receiver.Call(Child, Getters)'],
		['DisposeOnRefusal := false', 'DisposeOnRefusal := true'],
		['Row.Get("submenu", false) != Child', 'Row.Get("submenu", false) != false'],
		['TrayMenuStage_AddFeature(Row["label"], Child)', 'TrayMenuStage_AddFeature("Foreign parent", Child)']]
	Count := 0
	for Vector in Mutations {
		Changed := StrReplace(Stage, Vector[1], Vector[2])
		AssertTrue(Changed != Stage, "every source counterfactual changes actual executable stage source")
		AssertFalse(_DG_DeclaredStageSourceValid(Changed), "child mutation or an unowned parent must invalidate the read-only stage proof")
		AssertTrue(_DG_DeclaredStageSourceValid(StrReplace(Changed, Vector[2], Vector[1])), "the exact inverse restores the actual coordinator")
		Count += 1
	}
	AssertEqual(9, Count)
	for Id in ["keyboard_layout", "hotstrings", "shortcuts", "tap_holds", "gestures"] {
		Builder := _MI_TopLevelBuilders()[Id]
		Body := _DriverFuncBody(Builder.Name)
		AssertTrue(_DG_DeclaredBuilderSourceValid(Id, Body, Stage))
		AssertFalse(_DG_DeclaredBuilderSourceValid("about", Body, Stage), "a matching staging line in a foreign root builder cannot inherit this proof")
		Needle := 'MenuRenderer_GroupReceiver("top_level", "' . Id . '")'
		Wrong := StrReplace(Body, Needle, 'MenuRenderer_GroupReceiver("top_level", "foreign")')
		AssertTrue(Wrong != Body)
		AssertFalse(_DG_DeclaredBuilderSourceValid(Id, Wrong, Stage), "a swapped builder id cannot borrow another declared title")
		AssertTrue(_DG_DeclaredBuilderSourceValid(Id, StrReplace(Wrong, 'MenuRenderer_GroupReceiver("top_level", "foreign")', Needle), Stage))
		Wrong := StrReplace(Body, '_MI_StageDeclaredFeature(Receiver,', '_MI_StageDeclaredFeature(ForeignReceiver,')
		AssertTrue(Wrong != Body)
		AssertFalse(_DG_DeclaredBuilderSourceValid(Id, Wrong, Stage), "the completed child must reach its admitted receiver")
		AssertTrue(_DG_DeclaredBuilderSourceValid(Id, StrReplace(Wrong, '_MI_StageDeclaredFeature(ForeignReceiver,', '_MI_StageDeclaredFeature(Receiver,'), Stage))
		if Id == "shortcuts" || Id == "tap_holds" {
			Wrong := StrReplace(Body, ')))', ')), true)')
			AssertTrue(Wrong != Body)
			AssertFalse(_DG_DeclaredBuilderSourceValid(Id, Wrong, Stage), "a borrowed persistent child cannot be disposed on refusal")
			AssertTrue(_DG_DeclaredBuilderSourceValid(Id, StrReplace(Wrong, ')), true)', ')))'), Stage))
		}
	}
}
Test("menu drift gate (AHK): actual declared stage source rejects child and title counterfactuals",
	_DG_DeclaredSourceCounterfactuals)

; Read actual native labels, IDs and flags: a byte-identical provider row alone
; cannot prove that staging preserved its persistent native child.
_DG_ChildImage(Child) {
	Handle := Child.Handle
	AssertTrue(Handle != 0)
	Count := DllCall("GetMenuItemCount", "ptr", Handle, "int")
	Assert(Count >= 0, "the genuine native child must expose its rows")
	Image := Handle . ":" . Count
	Loop Count {
		Position := A_Index - 1
		Length := DllCall("GetMenuStringW", "ptr", Handle, "uint", Position,
			"ptr", 0, "int", 0, "uint", 0x400, "int")
		BufferValue := Buffer((Length + 1) * 2, 0)
		DllCall("GetMenuStringW", "ptr", Handle, "uint", Position,
			"ptr", BufferValue, "int", Length + 1, "uint", 0x400, "int")
		State := DllCall("GetMenuState", "ptr", Handle, "uint", Position, "uint", 0x400, "uint")
		Assert(State != 0xFFFFFFFF, "native child flags must remain readable")
		CommandId := DllCall("GetMenuItemID", "ptr", Handle, "int", Position, "uint")
		Image .= "|" . Position . ":" . CommandId . ":" . State . ":" . Length . ":" . StrGet(BufferValue, "UTF-16")
	}
	return Image
}
_DG_StageStateReceipt(Reads, Value) {
	Reads["state"] += 1
	return Value
}
_DG_StageCountReceipt(Reads, Kind, Value) {
	Reads[Kind] += 1
	return Value
}
_DG_CheckDeclaredStageLocale(Expected, Corpus) {
	global _TrayMenuStage, _TrayFeatureHeadLabels, _MenuDispatchCallbacks
	Categories := Map("keyboard_layout", "", "hotstrings", "", "shortcuts", "Shortcuts", "tap_holds", "TapHolds", "gestures", "Gestures")
	States := Map("keyboard_layout", "layout_enabled", "hotstrings", "hotstrings_enabled", "shortcuts", "shortcuts_enabled", "tap_holds", "tapholds_enabled", "gestures", "gestures_enabled")
	Child := Menu(), Calls := Map("callback", 0)
	RegisterMenuItem(Child, "Checked sentinel", (*) => Calls["callback"] += 1)
	Child.Add()
	RegisterMenuItem(Child, "Disabled sentinel", (*) => Calls["callback"] += 1)
	Child.Check("Checked sentinel"), Child.Disable("Disabled sentinel")
	AssertEqual(3, DllCall("GetMenuItemCount", "ptr", Child.Handle, "int"), "the native child starts with two actions and its separator")
	AssertTrue(DllCall("GetMenuState", "ptr", Child.Handle, "uint", 0, "uint", 0x400, "uint") & 0x8)
	AssertTrue(DllCall("GetMenuState", "ptr", Child.Handle, "uint", 2, "uint", 0x400, "uint") & 0x3)
	Image := _DG_ChildImage(Child), Registry := _MenuDispatchCallbacks, Callbacks := Registry.Clone()
	SavedStage := _TrayMenuStage, SavedLabels := _TrayFeatureHeadLabels
	try {
		for Id, Category in Categories {
			OriginalTitle := Category != "" ? GetCategoryTitle(Category) : t(Id == "keyboard_layout" ? "menu.layout.title" : "menu.hotstrings.title")
			AssertEqual(Expected[Id], OriginalTitle, "the original title obligation remains independent of the new receiver")
			Vectors := [Map("total", 0, "aggregate_available", false, "suffix", "")]
			if Id == "hotstrings" {
				Vectors := []
				for Vector in Corpus["count_cases"]
					if Vector["driver"] == "ahk"
						Vectors.Push(Vector)
				AssertEqual(2, Vectors.Length, "both independent original Windows count vectors must reach actual staging")
			}
			for Vector in Vectors {
				ExpectedLabel := Expected[Id] . Vector["suffix"]
				for Value in [false, true] {
					Loop 2 {
						_TrayMenuStage := false
						TrayMenuStage_Begin()
						Receiver := MenuRenderer_GroupReceiver("top_level", Id)
						AssertTrue(HasMethod(Receiver, "Call"), "the actual canonical parent must admit a native completed child")
						Reads := Map("state", 0, "total", 0, "present", 0)
						Getters := Map(States[Id], _DG_StageStateReceipt.Bind(Reads, Value))
						if Id == "hotstrings" {
							Getters["hotstrings_parent_total"] := _DG_StageCountReceipt.Bind(Reads, "total", Vector["total"])
							Getters["hotstrings_parent_count_present"] := _DG_StageCountReceipt.Bind(Reads, "present", Vector["aggregate_available"])
						}
						AssertTrue(_MI_StageDeclaredFeature(Receiver, Child, Getters))
						AssertEqual(1, Reads["state"])
						AssertEqual(Id == "hotstrings" ? 1 : 0, Reads["total"]), AssertEqual(Id == "hotstrings" ? 1 : 0, Reads["present"])
						AssertEqual(Value ? 2 : 1, _TrayMenuStage.Length)
						Row := _TrayMenuStage[1]
						AssertEqual("submenu", Row["kind"]), AssertEqual(ExpectedLabel, Row["label"])
						AssertTrue(Row["target"] == Child), AssertTrue(Row["feature"])
						if Value {
							AssertEqual("check", _TrayMenuStage[2]["kind"])
							AssertEqual(ExpectedLabel, _TrayMenuStage[2]["label"])
						}
						AssertEqual(Image, _DG_ChildImage(Child), "repeated actual staging preserves native handle, count, labels, IDs and flags")
						AssertTrue(_MenuDispatchCallbacks == Registry), AssertEqual(Callbacks.Count, Registry.Count)
						for CommandId, Callback in Callbacks
							AssertTrue(Registry.Has(CommandId) && Registry[CommandId] == Callback)
						AssertEqual(0, Calls["callback"], "staging must never execute a child action")
						; Withdrawal occurs after admission and before the real coordinator call.
						Root := _MR_GetManifestRoot(), Selected := false
						for Item in Root["top_level"]
							if _MR_Get(Item, "id") == Id
								Selected := Item
						AssertTrue(Selected is Map)
						OriginalTitleKey := Selected["i18n"]
						Receiver := MenuRenderer_GroupReceiver("top_level", Id)
						_TrayMenuStage := []
						try {
							Selected["i18n"] := "foreign.title"
							AssertThrows(_MI_StageDeclaredFeature.Bind(Receiver, Child, Getters),
								"a withdrawn parent cannot stage or dispose a borrowed native child")
							AssertEqual(0, _TrayMenuStage.Length)
							AssertEqual(1, Reads["state"]), AssertEqual(Id == "hotstrings" ? 1 : 0, Reads["total"])
							AssertEqual(Id == "hotstrings" ? 1 : 0, Reads["present"])
							AssertEqual(Image, _DG_ChildImage(Child), "refusal preserves every actual child row")
							AssertEqual(0, Calls["callback"])
						} finally {
							Selected["i18n"] := OriginalTitleKey
						}
					}
				}
			}
		}
	} finally {
		_TrayMenuStage := SavedStage, _TrayFeatureHeadLabels := SavedLabels
		try Child.Delete()
		finally MenuDispatcher_PruneMenu(Child)
	}
}
_DG_DeclaredStageOriginalCaptions() {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\fixed_feature_parents.json", "UTF-8"))
	AssertEqual("98572fe1a57dde86c6e8591e79112fc5400ec819", Corpus["original_sha"])
	HadCache := IsSet(_I18nCache), Cache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), Loaded := HadLoaded ? _I18nCacheLoaded : false
	Languages := 0
	try {
		for Code, Expected in Corpus["captions"] {
			_I18nCache := JsonParse(FileRead(_SharedDir . "\data\locales\" . Code . ".json", "UTF-8"))
			_I18nCacheLoaded := true
			_DG_CheckDeclaredStageLocale(Expected, Corpus)
			Languages += 1
		}
		AssertEqual(21, Languages)
	} finally {
		if HadCache
			_I18nCache := Cache
		else
			_I18nCache := unset
		if HadLoaded
			_I18nCacheLoaded := Loaded
		else
			_I18nCacheLoaded := unset
	}
}
Test("menu drift gate (AHK): actual declared receiving preserves original 21-language titles and native children",
	_DG_DeclaredStageOriginalCaptions)

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
_DG_CaptureStage(Captured, Stage) {
	for _, Entry in Stage {
		if (Entry["kind"] == "check" || Entry["kind"] == "disable")
			continue
		Captured.Push(Entry["label"] == "" ? "---" : Entry["label"])
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
	try {
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageTopLevel(TopLevel, Stubs)
		AssertTrue(TrayMenuStage_Publish(0, _DG_CaptureStage.Bind(Captured)))
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
		Assert(InStr(Body, _DG_BUILDER_TITLES[Id]) > 0,
			"the '" . Id . "' builder " . Builder.Name . " must stage the row titled " . _DG_BUILDER_TITLES[Id])
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

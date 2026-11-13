; tests/unit/layouts/test_active_layout_rows.ahk

; ==============================================================================
; MODULE: Active Layout Rows (Windows)
; DESCRIPTION:
; Layout > « Input sources »: the layouts installed for the user with the
; active one ticked, choosing another requesting it and telling a refusal, as
; macOS and Linux list and select their input sources; the layout menu stage
; provides the list the shared manifest now declares for every driver.
; ==============================================================================

#Requires AutoHotkey v2.0




_ALR_Choices() {
	return [Map("id", "0000040C", "label", "French", "hkl", 0x040C040C),
		Map("id", "A000040C", "label", "Ergopti", "hkl", 0xF0C0040C)]
}

/** The active layout is ticked and disabled; another is selectable. */
_ALR_Rows() {
	Rows := _LAY_ActiveLayoutRows(_ALR_Choices, () => "A000040C", (Id) => 1, (Message) => 0, () => true)
	AssertEqual(2, Rows.Length)
	AssertEqual("French", Rows[1]["label"])
	AssertFalse(Rows[1]["checked"], "an inactive layout is not ticked")
	AssertTrue(Rows[2]["checked"], "the active layout is ticked")
	AssertTrue(Rows[2]["disabled"], "the active layout is not chosen again")
}

/** A choice requests its layout; a refusal is told, never silent. */
_ALR_Select() {
	Selected := []
	Errors := []
	Answer := 1
	Select(Id) {
		Selected.Push(Id)
		return Answer
	}
	Tell(Message) {
		Errors.Push(Message)
	}
	Rows := _LAY_ActiveLayoutRows(_ALR_Choices, () => "A000040C", Select, Tell, () => true)
	Rows[1]["action"].Call()
	AssertEqual("0000040C", Selected[1])
	AssertEqual(0, Errors.Length, "an accepted switch tells nothing")
	Answer := false
	Rows[1]["action"].Call()
	AssertEqual(1, Errors.Length, "a refused switch is told")
	AssertEqual(t("menu.layout.select_failed"), Errors[1])
}

/** No listed layout offers the keyboard settings row instead. */
_ALR_Empty() {
	Rows := _LAY_ActiveLayoutRows(() => [], () => "", (Id) => 1, (Message) => 0, () => true)
	AssertEqual(1, Rows.Length, "the open-settings row")
}

/** The layout stage provides the list the manifest declares for Windows. */
_ALR_Wiring() {
	Body := _DriverFuncBody("_MI_StageLayout")
	Assert(Body != "", "_MI_StageLayout must exist")
	AssertContains(Body, '"active_layouts",         (*) => _LAY_ActiveLayoutRows()', "the provider is registered")
	Manifest := JsonParse(FSReadUtf8Exact(_SharedDir . "\menu\data\menu_manifest.json"))
	Found := false
	for Row in Manifest["layout_menu"]
		if (Row.Get("id", "") == "active_layouts") {
			Found := true
			AssertFalse(Row.Has("platforms"), "the list is declared for every driver")
		}
	AssertTrue(Found, "the list is declared")
}

Test("active layout rows: the active layout is ticked", _ALR_Rows)
Test("active layout rows: a choice switches and a refusal is told", _ALR_Select)
Test("active layout rows: an empty list opens the settings", _ALR_Empty)
Test("active layout rows: the layout stage provides the list", _ALR_Wiring)

; tests/unit/test_category_toggle_checkbox.ahk

; ==============================================================================
; MODULE: Category Toggle Is A Checkbox
; DESCRIPTION:
; Every feature submenu opens with its category switch, and that switch is a
; native checkbox: the row is labelled by the toggle's one `i18n` key, it is
; ticked exactly when the category is on, and it runs the command the driver
; registered for it.
;
; ROOT CAUSE ENCODED: the switch was a plain row whose label alternated between
; « ✅ … activé(s) (cliquer pour désactiver) » and « ❌ … désactivé(s) (cliquer
; pour activer) », inserted by hand with AddCategoryToggleItem in three
; submenus (Gestures, Metrics, IA) and by the renderer in the others. The state
; was only readable from the words, and each row carried two keys. The state is
; read back through GetMenuState on the rendered native menu, not through
; bookkeeping.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Native menu readers =======
; ======================================
; ======================================

; True when the row at a zero-based position carries a checkmark.
_CTC_IsChecked(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400, MF_CHECKED := 0x8
	State := DllCall("GetMenuState", "ptr", TargetMenu.Handle, "uint", Position,
		"uint", MF_BYPOSITION, "uint")
	Assert(State != 0xFFFFFFFF, "GetMenuState must find row " . Position)
	return (State & MF_CHECKED) != 0
}

; The text of the row at a zero-based position.
_CTC_LabelAt(TargetMenu, Position) {
	static MF_BYPOSITION := 0x400
	Length := DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", 0, "int", 0, "uint", MF_BYPOSITION, "int")
	Assert(Length >= 0, "GetMenuStringW must read row " . Position)
	Buffer_ := Buffer((Length + 1) * 2, 0)
	DllCall("GetMenuStringW", "ptr", TargetMenu.Handle, "uint", Position,
		"ptr", Buffer_, "int", Length + 1, "uint", MF_BYPOSITION, "int")
	return StrGet(Buffer_, "UTF-16")
}

; Frees a menu this file built, before the runner exits. The WPM rows of the
; Metrics menu hold that menu in their callbacks, which the dispatcher registry
; keeps alive: AHK then destroyed it during its exit teardown, and the runner
; ended in STATUS_HEAP_CORRUPTION after every test had passed.
_CTC_ReleaseMenu(TargetMenu) {
	TargetMenu.Delete()
	MenuDispatcher_PruneMenu(TargetMenu)
}

; How many rows of a menu carry exactly Label.
_CTC_CountLabel(TargetMenu, Label) {
	Found := 0
	loop TrayMenuItemCount(TargetMenu) {
		if (_CTC_LabelAt(TargetMenu, A_Index - 1) == Label)
			Found++
	}
	return Found
}





; ============================================
; ============================================
; ======= 2/ Every declared toggle row =======
; ============================================
; ============================================

; Every toggle the shared manifest declares for Windows, as [MenuKey, Item].
_CTC_AhkToggles() {
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the shared menu manifest must load")
	Found := []
	for Key, Value in Root {
		if !(Value is Array)
			continue
		for Item in Value {
			if (Item is Map and _MR_Get(Item, "type") == "toggle" and _MR_IsForAhk(Item))
				Found.Push([Key, Item])
		}
	}
	return Found
}

; Renders each declared toggle, alone in a probe menu, ticked and unticked.
_CTC_EveryToggleRendersAsCheckbox() {
	static PROBE_KEY := "_test_category_toggle_probe_menu"
	Root := _MR_GetManifestRoot()
	Toggles := _CTC_AhkToggles()
	Assert(Toggles.Length >= 7,
		"every Windows feature menu declares its category switch, found " . Toggles.Length)
	for Pair in Toggles {
		Key := Pair[1], Item := Pair[2]
		Assert(_MR_Get(Item, "i18n") != "", Key . " toggle must name its label with i18n")
		Assert(_MR_Get(Item, "i18n_on") == "" and _MR_Get(Item, "i18n_off") == "",
			Key . " toggle must not carry an alternating on/off label pair")
		CmdId := _MR_Get(Item, "command") != "" ? _MR_Get(Item, "command") : _MR_Get(Item, "id")
		Keys := _MR_Get(Item, "checked_when", [])
		Assert(Keys is Array and Keys.Length > 0, Key . " toggle must declare checked_when")
		for State in [true, false] {
			Getters := Map()
			for StateKey in _MR_Get(Item, "disabled_when", [])
				Getters[StateKey] := () => true
			for StateKey in Keys
				Getters[StateKey] := ((S) => () => S)(State)
			Root[PROBE_KEY] := [Item]
			try {
				Rendered := MenuRenderer_Build(PROBE_KEY, _MR_Get(Item, "category"), Map(), "", Map(),
					Map(CmdId, (*) => 0), Getters)
			} finally {
				Root.Delete(PROBE_KEY)
			}
			AssertEqual(1, TrayMenuItemCount(Rendered), Key . " toggle must render exactly one row")
			AssertEqual(t(_MR_Get(Item, "i18n")), _CTC_LabelAt(Rendered, 0),
				Key . " toggle row is labelled by its one key")
			AssertEqual(State, _CTC_IsChecked(Rendered, 0),
				Key . " toggle row must be a checkbox showing the category state")
		}
	}
}

; A toggle whose command the driver never registered is not drawn at all.
_CTC_UnregisteredToggleIsNotDrawn() {
	static PROBE_KEY := "_test_category_toggle_unregistered"
	Root := _MR_GetManifestRoot()
	Toggles := _CTC_AhkToggles()
	Assert(Toggles.Length > 0, "the manifest must declare at least one Windows toggle")
	Root[PROBE_KEY] := [Toggles[1][2]]
	try {
		Rendered := MenuRenderer_Build(PROBE_KEY, "Layout", Map(), "", Map(), Map(), Map())
	} finally {
		Root.Delete(PROBE_KEY)
	}
	AssertEqual(0, TrayMenuItemCount(Rendered),
		"a toggle with no registered command must not fall back to a generic row")
}





; ============================================
; ============================================
; ======= 3/ The builders Windows owns =======
; ============================================
; ============================================

; Gestures: the first row is the checkbox, drawn once, following gestures.enabled.
_CTC_GesturesMenuFirstRowIsCheckbox() {
	global Features
	Assert(Features.Has("gestures") and Features["gestures"].Has("enabled"),
		"the gestures feature must be loaded for this test")
	Saved := Features["gestures"]["enabled"]
	Label := t("menu.gestures.enable")
	try {
		for State in [true, false] {
			Features["gestures"]["enabled"] := State
			GMenu := BuildGesturesMenu()
			try {
				AssertEqual(Label, _CTC_LabelAt(GMenu, 0), "the gestures submenu opens with its switch")
				AssertEqual(State, _CTC_IsChecked(GMenu, 0), "the gestures switch is ticked from gestures.enabled")
				AssertEqual(1, _CTC_CountLabel(GMenu, Label), "the gestures switch is drawn once")
			} finally {
				_CTC_ReleaseMenu(GMenu)
			}
		}
	} finally {
		Features["gestures"]["enabled"] := Saved
	}
}

; Metrics: the first row is the checkbox, drawn once, following MetricsShortcuts.enabled.
_CTC_MetricsMenuFirstRowIsCheckbox() {
	global MetricsShortcuts
	Saved := MetricsShortcuts.enabled
	Label := t("menu.metrics.enable")
	try {
		for State in [true, false] {
			MetricsShortcuts.enabled := State
			MMenu := BuildMetricsMenu()
			try {
				AssertEqual(Label, _CTC_LabelAt(MMenu, 0), "the metrics submenu opens with its switch")
				AssertEqual(State, _CTC_IsChecked(MMenu, 0), "the metrics switch is ticked from the metrics state")
				AssertEqual(1, _CTC_CountLabel(MMenu, Label), "the metrics switch is drawn once")
			} finally {
				_CTC_ReleaseMenu(MMenu)
			}
		}
	} finally {
		MetricsShortcuts.enabled := Saved
	}
}

; IA: the first row is the manifest's llm_toggle, not the retired on/off labels.
_CTC_LlmMenuFirstRowIsCheckbox() {
	global _LLM_Menu, _LLM_Menu_Handle
	Saved := _LLM_Menu
	SavedHandle := (IsSet(_LLM_Menu_Handle) && IsObject(_LLM_Menu_Handle)) ? _LLM_Menu_Handle : ""
	Label := t("menu.llm.enable")
	try {
		for State in [true, false] {
			_LLM_Menu := _CTC_LlmFixture(State)
			_LLM_Menu_Handle := Menu()
			Sub := LLM_Menu_BuildSubmenu()
			AssertEqual(Label, _CTC_LabelAt(Sub, 0), "the IA submenu opens with its switch")
			AssertEqual(State, _CTC_IsChecked(Sub, 0), "the IA switch is ticked from the IA state")
			AssertEqual(1, _CTC_CountLabel(Sub, Label), "the IA switch is drawn once")
		}
	} finally {
		_LLM_Menu := Saved
		if (SavedHandle != "")
			_LLM_Menu_Handle := SavedHandle
	}
}

; The IA state the submenu builder reads, with one API entry so no probe runs.
_CTC_LlmFixture(Enabled) {
	return Map("enabled", Enabled, "backend", "api", "model", "stale-tag",
		"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
		"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500,
		"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
		"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
		"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
		"streaming", true, "show_all_at_once", true, "pred_indent", 0,
		"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
		"trigger_shortcut", "Ctrl+Space", "inline_autotype", false,
		"ollama_port", 11434, "user_profiles", [], "api_entry_id", "e1",
		"api_entries", [Map("Id", "e1", "Name", "Cerebras",
			"Provider", "cerebras", "BaseUrl", "https://b.invalid/v1",
			"Token", "sekret", "Model", "qwen-3.8-27b")])
}

; A row that opens a submenu never sends a command, so an action on it is dead:
; the renderer reports it, as the shared Lua renderer does.
_CTC_ActionOnSubtreeIsReported() {
	Lines := []
	LoggerSetTestSink((Line) => Lines.Push(Line))
	try {
		Target := Menu()
		Added := _MR_RenderRows(Target, [
			Map("label", "Probe parent", "action", (*) => 0, "items", [Map("label", "Probe child")]),
			Map("label", "Probe leaf", "action", (*) => 0)
		], "probe_list", 1)
	} finally {
		LoggerClearTestSink()
	}
	AssertEqual(2, Added, "both rows still render")
	Found := 0
	for Line in Lines {
		if (InStr(Line, "Probe parent") and InStr(Line, "both an 'action' and a subtree"))
			Found++
		Assert(!InStr(Line, "Probe leaf"), "a clickable leaf must not be reported: " . Line)
	}
	AssertEqual(1, Found, "an action on a row that opens a submenu must be reported as an error")
}

; No builder inserts a category switch by hand any more.
_CTC_NoHandBuiltCategorySwitch() {
	Src := _StripFullLineComments(_DriverSourceConcat())
	Assert(StrLen(Src) > 100000, "the driver source must be readable")
	AssertEqual(0, InStr(Src, "AddCategoryToggleItem("),
		"a category switch inserted by hand bypasses the manifest's one declaration")
}

Test("category toggle: every declared toggle renders as a checkbox with one label (category-toggle-checkbox)",
	_CTC_EveryToggleRendersAsCheckbox)
Test("category toggle: an unregistered toggle is not drawn (category-toggle-checkbox)",
	_CTC_UnregisteredToggleIsNotDrawn)
Test("category toggle: gestures submenu opens with its checkbox (category-toggle-checkbox)",
	_CTC_GesturesMenuFirstRowIsCheckbox)
Test("category toggle: metrics submenu opens with its checkbox (category-toggle-checkbox)",
	_CTC_MetricsMenuFirstRowIsCheckbox)
Test("category toggle: IA submenu opens with its checkbox (category-toggle-checkbox)",
	_CTC_LlmMenuFirstRowIsCheckbox)
Test("category toggle: no builder inserts a switch by hand (category-toggle-checkbox)",
	_CTC_NoHandBuiltCategorySwitch)
Test("category toggle: an action on a row that opens a submenu is reported (category-toggle-checkbox)",
	_CTC_ActionOnSubtreeIsReported)

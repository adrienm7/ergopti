; tests/unit/modules/shortcuts/test_keep_awake_presets.ahk

; ==============================================================================
; MODULE: Anti-Sleep Presets (Windows port)
; DESCRIPTION:
; Replays _shared/tests/corpus/keep_awake/keep_awake_presets_vectors.json,
; which the macOS and Linux suites replay through
; _shared/shortcuts/engine/keep_awake_presets.lua, through
; modules/shortcuts/keep_awake_presets.ahk.
;
; ROOT CAUSE ENCODED:
; The presets document moves between machines and OSes. A port that accepted
; an edit the shared store refuses, or chose another preset after a deletion,
; would write a document the other drivers reject or run another preset.
; ==============================================================================

#Requires AutoHotkey v2.0

_TKP_Json(Relative) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\" . Relative, "UTF-8"))
}

_TKP_Step(Doc, Step, &Reason) {
	Args := Step["args"]
	switch Step["op"] {
		case "set_active": return KeepAwakePresetsSetActive(Doc, Args[1], &Reason)
		case "set_switch": return KeepAwakePresetsSetSwitch(Doc, Args[1], Args[2], Args[3], &Reason)
		case "duplicate": return KeepAwakePresetsDuplicate(Doc, Args[1], Args[2], Args[3], &Reason)
		case "rename": return KeepAwakePresetsRename(Doc, Args[1], Args[2], &Reason)
		case "remove": return KeepAwakePresetsRemove(Doc, Args[1], &Reason)
		case "set_apps": return KeepAwakePresetsSetApps(Doc, Args[1], Args[2], Args[3], &Reason)
		case "put_target": return KeepAwakePresetsPutTarget(Doc, Args[1], Args[2], Args[3], &Reason)
		case "remove_target": return KeepAwakePresetsRemoveTarget(Doc, Args[1], Args[2], &Reason)
	}
	throw ValueError("Unknown corpus op " . Step["op"])
}

_TKP_Vector(Starters, Vector) {
	Doc := KeepAwakePresetsLoad(Starters, "")
	for Index, Step in Vector["steps"] {
		Reason := ""
		Ok := _TKP_Step(Doc, Step, &Reason)
		AssertEqual(Step["ok"], Ok ? 1 : 0, Vector["id"] . " step " . Index)
		if Step.Has("reason")
			AssertEqual(Step["reason"], Reason, Vector["id"] . " reason " . Index)
	}
	AssertEqual(Vector["expect_active"], Doc["active"], Vector["id"] . " active")
	Ids := ""
	for Preset in Doc["presets"]
		Ids .= (Ids = "" ? "" : ",") . Preset["id"]
	Expected := ""
	for Id in Vector["expect_ids"]
		Expected .= (Expected = "" ? "" : ",") . Id
	AssertEqual(Expected, Ids, Vector["id"] . " ids")
	if Vector.Has("expect_name")
		AssertEqual(Vector["expect_name"]["name"], KeepAwakePresetsGet(Doc, Vector["expect_name"]["id"])["name"],
			Vector["id"] . " name")
	AssertTrue(IsObject(KeepAwakePresetsLoad(Starters, Doc)), Vector["id"] . " the edited document reloads")
}

_TKP_Edits() {
	Corpus := _TKP_Json("tests\corpus\keep_awake\keep_awake_presets_vectors.json")
	Starters := _TKP_Json("shortcuts\data\keep_awake_presets.json")
	Checked := 0
	for Vector in Corpus["edits"] {
		_TKP_Vector(Starters, Vector)
		Checked += 1
	}
	AssertTrue(Checked >= 9, "expected the edit vectors, found " . Checked)
	Broken := KeepAwakePresetsLoad(Starters, Map("version", Starters["version"], "presets", []), &Reason)
	AssertFalse(IsObject(Broken), "a broken saved document is refused")
	AssertEqual("presets_document_invalid", Reason, "its reason")
}
Test("anti-sleep presets: the port replays every corpus edit (keep-awake-presets-vectors)", _TKP_Edits)

_TKP_Plans() {
	Corpus := _TKP_Json("tests\corpus\keep_awake\keep_awake_presets_vectors.json")
	Starters := _TKP_Json("shortcuts\data\keep_awake_presets.json")
	Defaults := _TKP_Json("shortcuts\data\auto_click_defaults.json")
	for Vector in Corpus["plans"] {
		Doc := KeepAwakePresetsLoad(Starters, "")
		Plan := KeepAwakePresetsPlan(KeepAwakePresetsGet(Doc, Vector["preset"]), Vector["os"], Vector["images_dir"],
			Vector["separator"], Defaults)
		Expect := Vector["expect"]
		AssertEqual(Expect["keep_awake"], Plan["keep_awake"], Vector["id"] . " keep_awake")
		AssertEqual(Expect["auto_click"], Plan["auto_click"], Vector["id"] . " auto_click")
		AssertEqual(Expect["allowed_apps"].Length, Plan["allowed_apps"].Length, Vector["id"] . " apps")
		AssertEqual(Expect["templates"], Plan["templates"].Length, Vector["id"] . " templates")
		AssertEqual(Expect["text_targets"], Plan["text_targets"].Length, Vector["id"] . " text targets")
	}
}
Test("anti-sleep presets: the port plans every corpus preset (keep-awake-presets-vectors)", _TKP_Plans)

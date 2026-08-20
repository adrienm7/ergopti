; static/ergopti_plus/windows/tests/unit/test_llm_menu_persistence.ahk

; ==============================================================================
; MODULE: LLM Menu Persistence Tests
; DESCRIPTION:
; Guards the tray IA menu against config regressions (menu change not written
; to config.toml on reload). Driven by _shared/modules/llm/menu_persistence_contract.json.
;
; Three layers per AHK contract entry:
;   1. Wiring: tray_key appears in ui/menu/menu_llm/persist.ahk (sync or append).
;   2. Sync: Features["llm"] path matches the sample after _LLM_Menu_SyncToFeatures.
;   3. Disk: TOML round-trip via the same collect path SaveFullConfig uses.
;
; Run (from windows/tests): AutoHotkey64.exe /ErrorStdOut run_llm_menu_persistence.ahk
; Schema + static wiring (any OS): python ../../_shared/modules/llm/validate_menu_persistence_contract.py
; ==============================================================================






; =============================================
; =============================================
; ======= 1/ Shared test infrastructure =======
; =============================================
; =============================================

_LLM_Persist_ContractPath() {
	return A_ScriptDir . "\..\..\_shared\modules\llm\menu_persistence_contract.json"
}

_LLM_Persist_LoadContract() {
	raw := FileRead(_LLM_Persist_ContractPath(), "UTF-8")
	if (raw == "")
		throw Error("menu_persistence_contract.json missing or empty")
	root := JsonParse(raw)
	if !(root is Map) or !root.Has("entries") or !(root["entries"] is Array)
		throw Error("contract JSON must have an entries array")
	return root["entries"]
}

_LLM_Persist_CloneMap(m) {
	clone := Map()
	for k, v in m
		clone[k] := (Type(v) = "Map") ? _LLM_Persist_CloneMap(v) : v
	return clone
}

_LLM_Persist_CloneFeatures(src) {
	out := Map()
	for k, v in src
		out[k] := (Type(v) = "Map") ? _LLM_Persist_CloneMap(v) : v
	return out
}

_LLM_Persist_MakeDefaultTray() {
	return Map(
		"enabled",                    true,
		"backend",                    "ollama",
		"model",                      "Qwen3.5-0.8B",
		"profile_id",                 "basic",
		"n_predictions",              3,
		"auto_profile_for_model",     true,
		"min_words",                  3,
		"max_words",                  15,
		"language",                   "fr",
		"debounce_ms",                500,
		"ctx_chars",                  500,
		"temperature",                "0.10",
		"instant_on_word_end",        true,
		"after_hotstring",            true,
		"reset_on_nav",               true,
		"disable_url_bars",           true,
		"disable_password_fields",    true,
		"disabled_apps",              [],
		"show_info_bar",              true,
		"streaming",                  true,
		"show_all_at_once",           true,
		"pred_indent",                0,
		"auto_raise_temp",            true,
		"nav_modifiers",              "",
		"val_modifiers",              "alt",
		"trigger_shortcut",           "Ctrl+Space",
		"api_entry_id",               "api_primary",
		"ollama_port",                11434,
		"inline_autotype",            false
	)
}

; Mirror ErgoptiPlus.ahk _CollectFeatureUpdates (kept local so tests need not
; include the full boot script).
_LLM_Persist_CollectFeatureUpdates(Updates, SectionPath, Node) {
	if (Type(Node) != "Map")
		return
	for Key, Value in Node {
		if (SectionPath == "" and Type(Value) != "Map")
			continue
		Sub := (SectionPath == "") ? Key : SectionPath "." Key
		if (Type(Value) == "Map")
			_LLM_Persist_CollectFeatureUpdates(Updates, Sub, Value)
		else
			Updates.Push({ Section: SectionPath, Key: Key, Value: Value })
	}
}

_LLM_Persist_CollectUpdates() {
	global Features, _LLM_Menu
	Updates := []
	_LLM_Menu_SyncToFeatures()
	; Scope to [llm] only - same keys the tray persists; avoids walking the full
	; Features stub (hotstrings, layout, ...) on every contract round-trip.
	if Features.Has("llm")
		_LLM_Persist_CollectFeatureUpdates(Updates, "llm", Features["llm"])
	_LLM_Menu_AppendPersistedUpdates(Updates)
	return Updates
}

_LLM_Persist_FeaturesGet(pathParts) {
	global Features
	node := Features["llm"]
	for part in pathParts
		node := node[part]
	return node
}

_LLM_Persist_NormalizeTomlValue(raw, entry) {
	if entry.Has("toml_array") && entry["toml_array"] {
		if (raw is Array)
			return raw
		return _LLM_Menu_CoerceIniArray(raw)
	}
	if entry.Has("toml_number") && entry["toml_number"]
		return Float(raw) + 0
	if (raw = true or raw = false)
		return raw
	if (raw == "true")
		return true
	if (raw == "false")
		return false
	if IsNumber(raw)
		return raw
	return String(raw)
}

_LLM_Persist_ValuesEqual(expected, actual, entry) {
	if entry.Has("toml_array") && entry["toml_array"] {
		if (Type(expected) = "String")
			expected := _LLM_Menu_ModifiersStringToArray(expected)
		if (Type(actual) = "String")
			actual := _LLM_Menu_ModifiersStringToArray(actual)
		if !(expected is Array)
			expected := _LLM_Menu_CoerceIniArray(expected)
		if !(actual is Array)
			actual := _LLM_Menu_CoerceIniArray(actual)
		if (expected.Length != actual.Length)
			return false
		loop expected.Length {
			if (expected[A_Index] != actual[A_Index])
				return false
		}
		return true
	}
	if entry.Has("toml_number") && entry["toml_number"]
		return (Abs(Float(expected) - Float(actual)) < 0.0001)
	if (Type(expected) = "String" and IsNumber(actual))
		return (Abs(Float(expected) - Float(actual)) < 0.0001)
	return (expected = actual)
}

_LLM_Persist_ReadTomlEntry(cache, section, key) {
	return IniCacheGet(cache, section, key)
}

_LLM_Persist_PersistSource() {
	return A_ScriptDir . "\..\ui\menu\menu_llm\persist.ahk"
}






; =============================================
; =============================================
; ======= 2/ Meta: sync wiring coverage =======
; =============================================
; =============================================

Test_LLM_Persist_AllTrayKeysAreSynced() {
	body := FileRead(_LLM_Persist_PersistSource(), "UTF-8")
	syncStart := RegExMatch(body, "m)^_LLM_Menu_SyncToFeatures\s*\(")
	appendStart := RegExMatch(body, "m)^_LLM_Menu_AppendPersistedUpdates\s*\(")
	if (syncStart = 0 or appendStart = 0)
		throw Error("persist.ahk missing sync helpers")
	syncBlock := SubStr(body, syncStart, appendStart - syncStart)
	appendEnd := InStr(body, "LLM_Menu_BuildSavedOpts")
	appendBlock := appendEnd > 0
		? SubStr(body, appendStart, appendEnd - appendStart)
		: SubStr(body, appendStart)

	for entry in _LLM_Persist_LoadContract() {
		if !entry.Has("ahk") or !(entry["ahk"] is Map)
			continue
		ahk := entry["ahk"]
		if !ahk.Has("tray_key")
			continue
		trayKey := ahk["tray_key"]
		needle1 := '"' . trayKey . '"'
		needle2 := "['" . trayKey . "']"
		inSync := (InStr(syncBlock, needle1) > 0 or InStr(syncBlock, needle2) > 0)
		inAppend := (InStr(appendBlock, needle1) > 0 or InStr(appendBlock, needle2) > 0)
		Assert(inSync or inAppend,
			"tray key '" . trayKey . "' (" . entry["id"] . ") must appear in "
			. "_LLM_Menu_SyncToFeatures or _LLM_Menu_AppendPersistedUpdates")
	}
}
Test("LLM persist: every contract tray_key is synced before save",
	Test_LLM_Persist_AllTrayKeysAreSynced)

Test_LLM_Persist_BuildSavedOptsCoversFeatures() {
	body := FileRead(_LLM_Persist_PersistSource(), "UTF-8")
	for entry in _LLM_Persist_LoadContract() {
		if !entry.Has("ahk") or !(entry["ahk"] is Map)
			continue
		ahk := entry["ahk"]
		if ahk.Has("persist") and ahk["persist"] = "extra"
			continue
		if !ahk.Has("tray_key")
			continue
		needle := 'opts["' . ahk["tray_key"] . '"]'
		Assert(InStr(body, needle) > 0,
			"LLM_Menu_BuildSavedOpts must load " . needle . " (" . entry["id"] . ")")
	}
}
Test("LLM persist: BuildSavedOpts loads every Features-backed tray key",
	Test_LLM_Persist_BuildSavedOptsCoversFeatures)






; =============================================
; =============================================
; ======= 3/ Per-entry round-trip tests =======
; =============================================
; =============================================

_LLM_Persist_RunOneEntry(entry, FeaturesBase) {
	global _LLM_Menu, Features
	ahk := entry["ahk"]
	trayKey := ahk["tray_key"]
	sample := ahk["sample"]

	Features := _LLM_Persist_CloneFeatures(FeaturesBase)
	_LLM_Menu := _LLM_Persist_MakeDefaultTray()
	_LLM_Menu[trayKey] := sample

	if ahk.Has("features") {
		_LLM_Menu_SyncToFeatures()
		path := ahk["features"]
		got := _LLM_Persist_FeaturesGet(path)
		if (trayKey = "temperature")
			AssertEqual(Float(sample), Float(got),
				entry["id"] . " Features sync temperature")
		else if (trayKey = "val_modifiers") {
			Assert(_LLM_Persist_ValuesEqual(_LLM_Menu_ModifiersStringToArray(sample), got, ahk),
				entry["id"] . " Features val_modifiers array")
		} else
			AssertEqual(sample, got, entry["id"] . " Features sync")
	}

	updates := _LLM_Persist_CollectUpdates()
	found := false
	for u in updates {
		if (u.Section = ahk["section"] and u.Key = ahk["key"]) {
			found := true
			Assert(_LLM_Persist_ValuesEqual(sample, u.Value, ahk),
				entry["id"] . " collect update value")
			break
		}
	}
	Assert(found, entry["id"] . " must emit [" . ahk["section"] . "]." . ahk["key"])

	path := A_Temp . "\ergopti_llm_persist_" . entry["id"] . ".toml"
	if FileExist(path)
		FileDelete(path)
	TOML_BatchWrite(path, updates)
	cache := ParseTomlFile(path)
	raw := _LLM_Persist_ReadTomlEntry(cache, ahk["section"], ahk["key"])
	Assert(raw != "_", entry["id"] . " must exist in written TOML")
	Assert(_LLM_Persist_ValuesEqual(sample, _LLM_Persist_NormalizeTomlValue(raw, ahk), ahk),
		entry["id"] . " TOML round-trip")

	opts := LLM_Menu_BuildSavedOpts(cache)
	if (trayKey = "temperature")
		AssertEqual(sample, opts[trayKey], entry["id"] . " BuildSavedOpts temperature")
	else if (trayKey = "val_modifiers")
		Assert(_LLM_Persist_ValuesEqual(sample, opts[trayKey], ahk),
			entry["id"] . " BuildSavedOpts val_modifiers")
	else if (trayKey = "disabled_apps") {
		Assert(opts[trayKey].Length = sample.Length, entry["id"] . " disabled_apps length")
	} else
		AssertEqual(sample, opts[trayKey], entry["id"] . " BuildSavedOpts")
}

Test_LLM_Persist_AllAhkContractEntries() {
	global Features
	OldFeatures := Features
	; Reuse the stub Features tree (same shape as production manifest) so this
	; suite stays fast - ManifestBuildFeaturesMap() is already covered elsewhere.
	FeaturesBase := Features
	for entry in _LLM_Persist_LoadContract() {
		if !entry.Has("ahk") or !(entry["ahk"] is Map)
			continue
		_LLM_Persist_RunOneEntry(entry, FeaturesBase)
	}
	Features := OldFeatures
}
Test("LLM persist AHK: all contract entries round-trip", Test_LLM_Persist_AllAhkContractEntries)

Test_LLM_Persist_PredIndentZeroIsNumeric() {
	global _LLM_Menu, Features
	Features := _LLM_Persist_CloneFeatures(Features)
	_LLM_Menu := _LLM_Persist_MakeDefaultTray()
	_LLM_Menu["pred_indent"] := 0
	updates := _LLM_Persist_CollectUpdates()
	body := ""
	for u in updates {
		if (u.Section = "llm.display" and u.Key = "pred_indent") {
			AssertEqual(0, u.Value, "pred_indent collect must stay numeric 0")
			path := A_Temp . "\ergopti_llm_pred_indent_zero.toml"
			TOML_BatchWrite(path, updates)
			cache := ParseTomlFile(path)
			raw := IniCacheGet(cache, "llm.display", "pred_indent")
			AssertEqual(0, raw, "pred_indent=0 must not serialize as false")
			break
		}
	}
	Assert(updates.Length > 0, "pred_indent must appear in collect updates")
}
Test("LLM persist: pred_indent 0 writes numeric zero not false",
	Test_LLM_Persist_PredIndentZeroIsNumeric)

Test_LLM_Persist_ApiEntryIdRoundTrips() {
	global _LLM_Menu, Features
	SavedFeatures := Features
	SavedMenu := _LLM_Menu
	try {
		Features := _LLM_Persist_CloneFeatures(Features)
		_LLM_Menu := _LLM_Persist_MakeDefaultTray()
		_LLM_Menu["api_entry_id"] := "api_secondary"
		Updates := _LLM_Persist_CollectUpdates()
		Found := false
		for Update in Updates {
			if Update.Section == "llm" && Update.Key == "api_entry_id" {
				Found := true
				AssertEqual("api_secondary", Update.Value)
				break
			}
		}
		AssertTrue(Found,
			"the selected remote endpoint must be serialized into config.toml")
		Path := A_Temp . "\ergopti_llm_api_entry_id.toml"
		try FileDelete(Path)
		AssertTrue(TOML_BatchWrite(Path, Updates))
		Opts := LLM_Menu_BuildSavedOpts(ParseTomlFile(Path))
		AssertEqual("api_secondary", Opts["api_entry_id"],
			"the selected remote endpoint must survive a restart")
	} finally {
		Features := SavedFeatures
		_LLM_Menu := SavedMenu
	}
}
Test("LLM persist: active API entry survives config round-trip "
	. "(llm-api-entry-id-roundtrip)",
	Test_LLM_Persist_ApiEntryIdRoundTrips)

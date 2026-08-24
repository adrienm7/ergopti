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
		"inline_autotype",            false,
		"user_profiles",              []
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
	AssertTrue(_LLM_Menu_SyncToFeatures(),
		"the persistence fixture must not continue after feature reconciliation fails")
	; Scope to [llm] only - same keys the tray persists; avoids walking the full
	; Features stub (hotstrings, layout, ...) on every contract round-trip.
	if Features.Has("llm")
		_LLM_Persist_CollectFeatureUpdates(Updates, "llm", Features["llm"])
	AssertTrue(_LLM_Menu_AppendPersistedUpdates(Updates),
		"the persistence fixture must not continue after menu serialization fails")
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
	global Features
	SavedFeatures := Features
	try {
		Features := _LLM_Persist_CloneFeatures(SavedFeatures)
		Opts := LLM_Menu_BuildSavedOpts()
		for Entry in _LLM_Persist_LoadContract() {
			if !Entry.Has("ahk") or !(Entry["ahk"] is Map)
				continue
			Ahk := Entry["ahk"]
			if !Ahk.Has("features") or !Ahk.Has("tray_key")
				continue
			TrayKey := Ahk["tray_key"]
			AssertTrue(Opts.Has(TrayKey),
				"LLM_Menu_BuildSavedOpts must publish the typed Features value for "
				. TrayKey . " (" . Entry["id"] . ")")
		}
	} finally {
		Features := SavedFeatures
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


_AHK011_PersistenceStoresEffectiveStreaming() {
	global Features
	CandidateFeatures := _LLM_Persist_CloneFeatures(Features)
	CandidateMenu := _LLM_Persist_MakeDefaultTray()
	CandidateMenu["backend"] := "ollama"
	CandidateMenu["streaming"] := true
	AssertTrue(_LLM_Menu_SyncToFeatures(CandidateFeatures, CandidateMenu),
		"the complete menu fixture must be accepted by the real persistence boundary")
	AssertFalse(CandidateFeatures["llm"]["display"]["streaming"],
		"durable Windows configuration must record the effective unsupported value, "
		. "not preserve a checked-but-unreachable streaming request")
}
Test("AHK-011: persistence stores only effective streaming",
	_AHK011_PersistenceStoresEffectiveStreaming)

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

Test_LLM_Persist_LosslessCustomProfiles() {
	Profiles := [Map(
		"id", "custom;=é",
		"label", 'French "profile"',
		"system_single", "line 1`nline 2;=é",
		"system_multi", "multi",
		"system_multi_template", "{text}",
		"batch", true
	)]
	Payload := _LLM_Menu_SerializeUserProfiles(Profiles)
	Assert(SubStr(Payload, 1, 3) == "v1:", "custom profile payload must be versioned")
	Decoded := _LLM_Menu_DeserializeUserProfiles(Payload)
	Assert(Decoded is Array, "custom profile payload must decode")
	AssertEqual(1, Decoded.Length)
	AssertEqual(Profiles[1]["id"], Decoded[1]["id"])
	AssertEqual(Profiles[1]["system_single"], Decoded[1]["system_single"])
	AssertEqual(true, Decoded[1]["batch"])
	AssertEqual(false, _LLM_Menu_DeserializeUserProfiles("v1:not-base64"))
}
Test("LLM persist: custom profiles use a lossless versioned codec",
	Test_LLM_Persist_LosslessCustomProfiles)

_LLM_Persist_AssertProfilesExact(Expected, Actual, Context) {
	Assert(Expected is Array, Context . " expected profiles must be an Array")
	Assert(Actual is Array, Context . " restored profiles must be an Array")
	AssertEqual(Expected.Length, Actual.Length, Context . " profile count")
	Schema := ["id", "label", "system_single", "system_multi",
		"system_multi_template", "raw_prompt", "batch", "stop_sequences"]
	loop Expected.Length {
		ExpectedProfile := Expected[A_Index]
		ActualProfile := Actual[A_Index]
		Assert(ExpectedProfile is Map, Context . " expected profile must be a Map")
		Assert(ActualProfile is Map, Context . " restored profile must be a Map")
		for Key in Schema {
			AssertEqual(ExpectedProfile.Has(Key), ActualProfile.Has(Key),
				Context . " field presence " . Key)
			if !ExpectedProfile.Has(Key)
				continue
			ExpectedValue := ExpectedProfile[Key]
			ActualValue := ActualProfile[Key]
			if (ExpectedValue is Array) {
				Assert(ActualValue is Array, Context . " " . Key . " must remain an Array")
				AssertEqual(ExpectedValue.Length, ActualValue.Length,
					Context . " " . Key . " length")
				loop ExpectedValue.Length
					AssertEqual(ExpectedValue[A_Index], ActualValue[A_Index],
						Context . " " . Key . " item")
			} else
				AssertEqual(ExpectedValue, ActualValue, Context . " " . Key)
		}
	}
}

_LLM_Persist_ProfileRoundTrip(Path) {
	global _LLM_Menu, _LLM_Menu_Loaded
	Updates := _LLM_Persist_CollectUpdates()
	FoundStore := false
	for Update in Updates {
		if (Update.Section == "llm" && Update.Key == "user_profiles") {
			FoundStore := true
			break
		}
	}
	AssertTrue(FoundStore,
		"the real full collector must emit the canonical custom-profile store")
	AssertTrue(TOML_BatchWrite(Path, Updates),
		"the real TOML writer must commit the custom-profile store")
	SavedOpts := LLM_Menu_BuildSavedOpts(ParseTomlFile(Path))
	AssertTrue(SavedOpts.Has("user_profiles"),
		"the real saved-options loader must reconstruct custom profiles")
	_LLM_Menu := _LLM_Persist_MakeDefaultTray()
	_LLM_Menu_Loaded := false
	AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(SavedOpts),
		"the real boot restore must publish the reconstructed custom profiles")
	return _LLM_Menu["user_profiles"]
}

Test_LLM_Persist_CustomProfileCrudSurvivesRestart() {
	global _LLM_Menu, _LLM_Menu_Loaded, Features
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedFeatures := Features
	Path := A_Temp . "\ergopti_ahk018_custom_profiles.toml"
	try {
		try FileDelete(Path)
		Features := _LLM_Persist_CloneFeatures(SavedFeatures)
		_LLM_Menu := _LLM_Persist_MakeDefaultTray()
		First := Map(
			"id", "user_création_一",
			"label", 'Profil "création"',
			"system_single", "Première ligne`nDeuxième ligne = " . Chr(59) . " 一",
			"system_multi", "Multi ligne`n{context}",
			"system_multi_template", "Produis {n}`nrésultats",
			"raw_prompt", 'RAW "exact"`n{context}',
			"batch", true,
			"stop_sequences", [Chr(96) . Chr(96) . Chr(96), "`n`n",
				" padded ", "終", "終"])
		Second := Map(
			"id", "user_second",
			"label", "Second",
			"system_single", "Prompt second",
			"system_multi", "",
			"batch", false)
		AssertTrue(_LLM_Menu_AddProfileCandidate(_LLM_Menu, First),
			"the production create mutator must accept the first profile")
		AssertTrue(_LLM_Menu_AddProfileCandidate(_LLM_Menu, Second),
			"the production create mutator must accept the second profile")
		Expected := LLM_Menu_DeepClone(_LLM_Menu["user_profiles"])
		Restored := _LLM_Persist_ProfileRoundTrip(Path)
		_LLM_Persist_AssertProfilesExact(Expected, Restored,
			"create then restart")

		AssertTrue(_LLM_Menu_EditProfileCandidate(_LLM_Menu, First["id"],
			"Édité", "Prompt édité`nligne 2"),
			"the production edit mutator must find the restored profile")
		Expected := LLM_Menu_DeepClone(_LLM_Menu["user_profiles"])
		Restored := _LLM_Persist_ProfileRoundTrip(Path)
		_LLM_Persist_AssertProfilesExact(Expected, Restored,
			"edit then restart")

		AssertTrue(_LLM_Menu_DeleteProfileCandidate(_LLM_Menu, First["id"]),
			"the production delete mutator must remove the first profile")
		Expected := LLM_Menu_DeepClone(_LLM_Menu["user_profiles"])
		Restored := _LLM_Persist_ProfileRoundTrip(Path)
		_LLM_Persist_AssertProfilesExact(Expected, Restored,
			"delete one then restart")

		AssertTrue(_LLM_Menu_DeleteProfileCandidate(_LLM_Menu, Second["id"]),
			"the production delete mutator must remove the last profile")
		Restored := _LLM_Persist_ProfileRoundTrip(Path)
		AssertEqual(0, Restored.Length,
			"deleting the last custom profile must clear the durable store")
		RawToml := FileRead(Path, "UTF-8")
		Assert(InStr(RawToml, First["id"]) == 0 && InStr(RawToml, Second["id"]) == 0,
			"empty-list persistence must not retain a stale profile payload")

		InvalidUpdates := []
		Invalid := _LLM_Persist_MakeDefaultTray()
		Invalid["user_profiles"] := [First, LLM_Menu_DeepClone(First)]
		AssertFalse(_LLM_Menu_AppendPersistedUpdates(InvalidUpdates, Invalid),
			"duplicate profile ids must fail before durable publication")
		AssertEqual(0, InvalidUpdates.Length,
			"a rejected profile graph must not append a partial update list")
		Incomplete := _LLM_Persist_MakeDefaultTray()
		Incomplete["user_profiles"] := [Map("id", "missing_required_fields")]
		AssertFalse(_LLM_Menu_AppendPersistedUpdates([], Incomplete),
			"missing required profile strings and Boolean must fail closed")
	} finally {
		try FileDelete(Path)
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		Features := SavedFeatures
	}
}
Test("LLM persist: profile CRUD survives the real restart path "
	. "(ahk-018-profile-durability)",
	Test_LLM_Persist_CustomProfileCrudSurvivesRestart)

Test_LLM_Persist_ProfileStoreWiringIsBidirectional() {
	Collector := _DriverFuncBody("_LLM_Menu_AppendPersistedUpdates")
	Loader := _DriverFuncBody("LLM_Menu_BuildSavedOpts")
	Assert(InStr(Collector, "user_profiles") > 0,
		"the full collector must enumerate the canonical custom-profile store")
	Assert(InStr(Loader, "user_profiles") > 0,
		"the saved-options loader must enumerate the canonical custom-profile store")
	Combined := Collector . Loader
	Count := 0
	Pos := 1
	while Pos := InStr(Combined, '"user_profiles"', true, Pos) {
		Count += 1
		Pos += StrLen('"user_profiles"')
	}
	Assert(Count >= 4,
		"collector and loader must keep a non-vacuous bidirectional profile-store floor")
}
Test("LLM persist: custom-profile store wiring is bidirectional "
	. "(ahk-018-profile-store-class)",
	Test_LLM_Persist_ProfileStoreWiringIsBidirectional)

Test_LLM_Persist_LosslessAppOverrides() {
	Overrides := Map("semi;tool", "advanced", "eq=tool", "basic", "éditeur", "raw")
	Payload := _LLM_Menu_SerializeAppProfileOverrides(Overrides)
	Assert(SubStr(Payload, 1, 3) == "v1:", "override payload must be versioned")
	Decoded := _LLM_Menu_DeserializeAppProfileOverrides(Payload)
	Assert(Decoded is Map, "override payload must decode")
	AssertEqual(3, Decoded.Count)
	AssertEqual("advanced", Decoded["semi;tool"])
	AssertEqual("basic", Decoded["eq=tool"])
	AssertEqual("raw", Decoded["éditeur"])
	Legacy := _LLM_Menu_DeserializeAppProfileOverrides("eq=tool=advanced")
	Assert(Legacy is Map, "a recoverable legacy payload must decode")
	AssertEqual(1, Legacy.Count)
	AssertEqual("advanced", Legacy["eq=tool"],
		"legacy migration must split on the last equals sign so a legal app basename survives")
	AssertEqual(false, _LLM_Menu_DeserializeAppProfileOverrides("dup=raw;dup=basic"))
	AssertEqual(false, _LLM_Menu_DeserializeAppProfileOverrides("broken"))
	AssertEqual(false, _LLM_Menu_DeserializeAppProfileOverrides("good=basic;;late=advanced"),
		"an empty legacy fragment is corruption, not an entry to skip")
	AssertEqual(false, _LLM_Menu_DeserializeAppProfileOverrides("semi;tool=advanced"),
		"an ambiguous semicolon basename must fail as one complete legacy image")
}
Test("LLM persist: app overrides round-trip delimiter and Unicode basenames",
	Test_LLM_Persist_LosslessAppOverrides)

Test_LLM_Persist_AppOverridesTraverseRealFullSave() {
	global Features, _LLM_Menu
	Path := A_Temp . "\ergopti_llm_app_overrides_full_save.toml"
	try {
		try FileDelete(Path)
		CandidateFeatures := _HSDeepCloneMap(Features)
		CandidateMenu := _LLM_Persist_MakeDefaultTray()
		CandidateMenu["onboarding_seen"] := false
		CandidateMenu["app_profile_overrides"] := Map(
			"semi;tool", "advanced", "eq=tool", "basic", "éditeur", "raw")
		Updates := _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
		AssertTrue(TOML_BatchWrite(Path, Updates),
			"the real full-save collector image must reach the canonical TOML writer")
		Cache := ParseTomlFile(Path)
		Opts := LLM_Menu_BuildSavedOpts(Cache)
		AssertTrue(_LLM_Menu_LoadAppProfileOverridesFromCache(Opts, Cache),
			"the boot restore boundary must accept the canonical full-save image")
		AssertTrue(Opts.Has("app_profile_overrides"),
			"the production saved-options loader must restore the serialized override graph")
		Decoded := Opts["app_profile_overrides"]
		AssertEqual(3, Decoded.Count)
		AssertEqual("advanced", Decoded["semi;tool"])
		AssertEqual("basic", Decoded["eq=tool"])
		AssertEqual("raw", Decoded["éditeur"])
	} finally {
		try FileDelete(Path)
	}
}
Test("LLM persist: app overrides traverse the real full-save and boot codecs (AHK-019)",
	Test_LLM_Persist_AppOverridesTraverseRealFullSave)

_LLM_Persist_AssertCompositeScalarRejected(Key, Literal, Slug) {
	Path := A_Temp . "\ergopti_llm_scalar_" . Slug . ".toml"
	try {
		Toml := "[llm]`n" . Key . " = " . Literal . "`n"
		try FileDelete(Path)
		FileAppend(Toml, Path, "UTF-8")
		Cache := ParseTomlFile(Path)
		Assert(IniCacheGet(Cache, "llm", Key) is Array,
			Slug . " fixture must reach its scalar boundary as an Array")

		Thrown := false
		Failure := ""
		try Opts := LLM_Menu_BuildSavedOpts(Cache)
		catch as Err {
			Thrown := true
			Failure := Err.Message
		}
		AssertFalse(Thrown,
			Slug . " must be rejected before String()/deserialization; got: " . Failure)
		AssertFalse(Opts.Has(Key),
			Slug . " must not publish a composite value into scalar state")
	} finally {
		try FileDelete(Path)
	}
}

Test_LLM_Persist_CompositeTriggerShortcutRejected() {
	_LLM_Persist_AssertCompositeScalarRejected(
		"trigger_shortcut", '["Ctrl+Space"]', "trigger-shortcut")
}
Test("LLM persist: composite trigger shortcut fails closed "
	. "(llm-persisted-option-type-boundary-trigger-shortcut)",
	Test_LLM_Persist_CompositeTriggerShortcutRejected)

Test_LLM_Persist_CompositeApiEntryIdRejected() {
	_LLM_Persist_AssertCompositeScalarRejected(
		"api_entry_id", '["api_primary"]', "api-entry-id")
}
Test("LLM persist: composite API entry identity fails closed "
	. "(llm-persisted-option-type-boundary-api-entry-id)",
	Test_LLM_Persist_CompositeApiEntryIdRejected)

Test_LLM_Persist_CompositeUserProfilesPayloadRejected() {
	_LLM_Persist_AssertCompositeScalarRejected(
		"user_profiles", '[["encoded-profile"]]', "user-profiles")
}
Test("LLM persist: composite custom-profile payload fails closed "
	. "(llm-persisted-option-type-boundary-user-profiles)",
	Test_LLM_Persist_CompositeUserProfilesPayloadRejected)

_LLM_Persist_AssertNestedArrayRejected(Section, Key, Slug) {
	global Features
	Path := A_Temp . "\ergopti_llm_nested_" . Slug . ".toml"
	Toml := "[" . Section . "]`n" . Key . ' = [["sentinel"]]`n'
	try {
		try FileDelete(Path)
		FileAppend(Toml, Path, "UTF-8")
		Cache := ParseTomlFile(Path)
		Raw := IniCacheGet(Cache, Section, Key)
		Assert(Raw is Array && Raw.Length = 1 && (Raw[1] is Array),
			Slug . " fixture must reach production as Array -> Array")
		ApplyConfigToml(Features, Path)
		if (Key == "val_modifiers") {
			Applied := Features["llm"]["navigation"]["val_modifiers"]
			Assert(Applied is Array && Applied.Length = 1 && (Applied[1] is Array),
				"ApplyConfigToml must prove the Features contamination is reachable")
		}

		Thrown := false
		Failure := ""
		try Opts := LLM_Menu_BuildSavedOpts(Cache)
		catch as Err {
			Thrown := true
			Failure := Err.Message
		}
		AssertFalse(Thrown,
			Slug . " must fail closed before String()/RegExReplace; got: " . Failure)
		AssertFalse(Opts.Has(Key),
			Slug . " must not publish a nested element to menu/engine state")
	} finally {
		try FileDelete(Path)
	}
}

Test_LLM_Persist_NestedValModifiersRejected() {
	global Features
	SavedFeatures := Features
	try {
		Features := _LLM_Persist_CloneFeatures(Features)
		_LLM_Persist_AssertNestedArrayRejected(
			"llm.navigation", "val_modifiers", "val")
	} finally {
		Features := SavedFeatures
	}
}
Test("LLM persist: nested val modifiers fail closed "
	. "(llm-persisted-option-type-boundary-val)",
	Test_LLM_Persist_NestedValModifiersRejected)

Test_LLM_Persist_NestedNavModifiersRejected() {
	global Features
	SavedFeatures := Features
	try {
		Features := _LLM_Persist_CloneFeatures(Features)
		_LLM_Persist_AssertNestedArrayRejected(
			"llm.navigation", "nav_modifiers", "nav")
	} finally {
		Features := SavedFeatures
	}
}
Test("LLM persist: nested navigation modifiers fail closed "
	. "(llm-persisted-option-type-boundary-nav)",
	Test_LLM_Persist_NestedNavModifiersRejected)

Test_LLM_Persist_NestedDisabledAppsRejected() {
	global Features
	SavedFeatures := Features
	try {
		Features := _LLM_Persist_CloneFeatures(Features)
		_LLM_Persist_AssertNestedArrayRejected(
			"llm.trigger", "disabled_apps", "disabled-apps")
	} finally {
		Features := SavedFeatures
	}
}
Test("LLM persist: nested disabled applications fail closed "
	. "(llm-persisted-option-type-boundary-disabled-apps)",
	Test_LLM_Persist_NestedDisabledAppsRejected)

_LLM_Persist_AssertFeatureCompositeRejected(Section, Key, OptionKey,
		FeaturePath, Slug) {
	global Features
	SavedFeatures := Features
	Path := A_Temp . "\ergopti_llm_feature_scalar_" . Slug . ".toml"
	try {
		Features := _LLM_Persist_CloneFeatures(Features)
		try FileDelete(Path)
		FileAppend("[" . Section . "]`n" . Key . ' = [["sentinel"]]`n',
			Path, "UTF-8")
		AssertEqual(1, ApplyConfigToml(Features, Path),
			Slug . " fixture must be accepted by the generic TOML loader")
		Applied := _LLM_Persist_FeaturesGet(FeaturePath)
		Assert(Applied is Array,
			Slug . " fixture must reach the LLM boundary as a composite value")

		Thrown := false
		Failure := ""
		try Opts := LLM_Menu_BuildSavedOpts(ParseTomlFile(Path))
		catch as Err {
			Thrown := true
			Failure := Err.Message
		}
		AssertFalse(Thrown,
			Slug . " must be rejected before conversion/publication; got: " . Failure)
		AssertFalse(Opts.Has(OptionKey),
			Slug . " must keep the validated menu default")
	} finally {
		Features := SavedFeatures
		try FileDelete(Path)
	}
}

Test_LLM_Persist_CompositeFeatureModelRejected() {
	_LLM_Persist_AssertFeatureCompositeRejected(
		"llm.models", "ollama", "model", ["models", "ollama"], "model")
}
Test("LLM persist: composite Features string fails closed "
	. "(llm-persisted-option-type-boundary-feature-string)",
	Test_LLM_Persist_CompositeFeatureModelRejected)

Test_LLM_Persist_CompositeFeatureEnabledRejected() {
	_LLM_Persist_AssertFeatureCompositeRejected(
		"llm", "enabled", "enabled", ["enabled"], "enabled")
}
Test("LLM persist: composite Features boolean fails closed "
	. "(llm-persisted-option-type-boundary-feature-boolean)",
	Test_LLM_Persist_CompositeFeatureEnabledRejected)

Test_LLM_Persist_CompositeFeatureCountRejected() {
	_LLM_Persist_AssertFeatureCompositeRejected(
		"llm.profiles", "num_predictions", "n_predictions",
		["profiles", "num_predictions"], "n-predictions")
}
Test("LLM persist: composite Features integer fails closed "
	. "(llm-persisted-option-type-boundary-feature-integer)",
	Test_LLM_Persist_CompositeFeatureCountRejected)

Test_LLM_Persist_CompositeFeatureTemperatureRejected() {
	_LLM_Persist_AssertFeatureCompositeRejected(
		"llm.generation", "temperature", "temperature",
		["generation", "temperature"], "temperature")
}
Test("LLM persist: composite Features temperature fails before Float "
	. "(llm-persisted-option-type-boundary-feature-temperature)",
	Test_LLM_Persist_CompositeFeatureTemperatureRejected)

Test_LLM_Persist_OnboardingBooleanIsTyped() {
	BadPath := A_Temp . "\ergopti_llm_onboarding_bad.toml"
	GoodPath := A_Temp . "\ergopti_llm_onboarding_good.toml"
	try {
		try FileDelete(BadPath)
		try FileDelete(GoodPath)
		FileAppend("[llm]`nonboarding_seen = [[true]]`n", BadPath, "UTF-8")
		BadOpts := LLM_Menu_BuildSavedOpts(ParseTomlFile(BadPath))
		AssertFalse(BadOpts.Has("onboarding_seen"),
			"a composite onboarding value must retain the default")

		FileAppend("[llm]`nonboarding_seen = true`n", GoodPath, "UTF-8")
		GoodOpts := LLM_Menu_BuildSavedOpts(ParseTomlFile(GoodPath))
		AssertTrue(GoodOpts.Has("onboarding_seen"),
			"the production saved-options loader must own the onboarding field")
		AssertTrue(GoodOpts["onboarding_seen"],
			"a valid persisted boolean must survive the typed boundary")
	} finally {
		try FileDelete(BadPath)
		try FileDelete(GoodPath)
	}
}
Test("LLM persist: onboarding boolean uses the typed saved-options path "
	. "(llm-persisted-option-type-boundary-onboarding)",
	Test_LLM_Persist_OnboardingBooleanIsTyped)

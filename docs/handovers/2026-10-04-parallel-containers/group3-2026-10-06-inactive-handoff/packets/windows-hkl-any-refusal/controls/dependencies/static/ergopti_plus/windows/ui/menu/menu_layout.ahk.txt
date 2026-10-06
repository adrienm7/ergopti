; ui/menu/menu_layout.ahk

; ==============================================================================
; MODULE: Tray Menu / Layout Submenu
; DESCRIPTION:
; Builds the Layout category entries (base layout features and AltGr layer features) straight into the parent menu from the manifest.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




/**
 * Reports the enabled emulation; selection belongs to the shared layout manager.
 * macOS and Linux's same list provider selects native input sources instead.
 * @param {Map} FeaturesSource Feature preferences; the live map when omitted.
 * @param {Integer} Enabled Layout category gate; the live gate when omitted.
 * @param {Map} Index Registry metadata; the current catalogue when omitted.
 * @returns {Array} One disabled status row without a selection callback.
 */
_LAY_CustomLayoutRows(FeaturesSource := unset, Enabled := unset, Index := unset) {
	global Features
	if !IsSet(FeaturesSource)
		FeaturesSource := Features
	if !IsSet(Enabled)
		Enabled := IsCategoryGated("Layout")
	Active := Enabled ? LayoutManager_ActiveId(FeaturesSource) : ""
	Name := ""
	if Active != "" {
		if !IsSet(Index) {
			Index := LayoutCatalogue_Last()["index"]
			if !(Index is Map)
				Index := LayoutCatalogue_BundledIndex()
		}
		Entry := LayoutCatalogue_Entry(Index, Active)
		; A previously selected layout absent from the current catalogue remains
		; identified explicitly; it must never be reported as no emulation.
		Name := (Entry is Map) ? Entry.Get("name", Active) : Active
	}
	Label := Name == "" ? t("menu.layout.emulated_none") : Format(t("menu.layout.emulated_status"), Name)
	return [Map("label", Label, "disabled", true)]
}

; List provider: Ergopti base-layer feature only (ergopti_base).
;
; A `list` since 2026-08-07, where both blocks were `dynamic` handlers handed the
; menu object. Every row here is a manifest feature — label, tick and greying all
; derived from the declaration by MenuRowFromManifest — so there was never
; anything for a handler to decide that data could not carry.
_LAY_LayoutFeatureBaseRows() {
	Rows := []
	for _, LayoutEntry in ManifestFeaturesForSection("layout") {
		if (LayoutEntry["id"] == "ergopti_base") {
			Row := MenuRowFromManifest(LayoutEntry, "Layout")
			if (Row != "") {
				Rows.Push(Row)
			}
		}
	}
	return Rows
}

; List provider: the Ergopti AltGr features (ergopti_alt_gr, ergopti_plus).
; The rows that work on any layout are declared on their own in the manifest's
; « any layout » section: direct_access_digits, and ctrl_magic_save after the
; magic-key replace option it depends on. emulated_layout names a registry
; layout: a choice, not a switch, so no toggle row lists it.
_LAY_LayoutFeatureAltGrRows() {
	static STANDALONE_IDS := Map("ergopti_base", true, "ctrl_magic_save", true,
		"direct_access_digits", true, "emulated_layout", true)
	Rows := []
	for _, LayoutEntry in ManifestFeaturesForSection("layout") {
		if !STANDALONE_IDS.Has(LayoutEntry["id"]) {
			Row := MenuRowFromManifest(LayoutEntry, "Layout")
			if (Row != "") {
				Rows.Push(Row)
			}
		}
	}
	return Rows
}


; ── Hotstrings dynamic handlers ────────────────────────────────────────────────

/** Collects the actual live input/configuration owners before any choice write. */
_LAY_NumberRowRuntime() {
	global Features, KLE_Model, _TrayRootLifecycleEpoch, _LayoutPollRetry
	try {
		Desired := IsSet(Features) && Features is Map ? MasterGateDesiredFeatures(Features) : Map()
		Mode := Desired.Has("layout") && Desired["layout"] is Map ? NumberRowPolicyMode(Desired["layout"].Get("direct_access_digits", "")) : ""
		Caps := GetKeyState("CapsLock", "T")
		Hkl := GetForegroundKeyboardLayout()
		return Map("owner", IsSet(Features) ? Features : 0,
			"source", IsSet(KLE_Model) && IsObject(KLE_Model) && KeylayoutEmulation_LayerIsActive("ergopti_base") ? KLE_Model : Hkl,
			"native_owner", IsSet(_LayoutPollRetry) ? _LayoutPollRetry : 0,
			"generation", MagicEditorState()["configuration_generation"],
			"lifecycle", IsSet(_TrayRootLifecycleEpoch) ? _TrayRootLifecycleEpoch : -1,
			"hkl", Hkl, "platform", "ahk", "mode", Mode,
			"master", IsCategoryGated("Layout") ? true : false,
			"paused", A_IsSuspended ? true : false, "blocked", false,
			"symbols", NumberRowSymbolsCapable(Caps), "caps", Caps)
	} catch {
		return Map("mode", "", "symbols", false, "blocked", true)
	}
}

/** Retains exact source bytes and verifies stored intent agrees with live owners. */
_LAY_NumberRowSnapshot() {
	global ConfigurationFile, Features
	Snapshot := _LAY_NumberRowRuntime()
	try {
		Snapshot["path"] := ConfigurationFile
		Presence := FSStrictExists(ConfigurationFile)
		Content := Presence ? FSReadUtf8Exact(ConfigurationFile) : ""
		if !(Content is String)
			throw TypeError("Number-row source is not readable.")
		Snapshot["content"] := Content
		Snapshot["presence"] := Presence
		Document := TOML_ParseDocument(Content)
		Desired := MasterGateDesiredFeatures(Features)
		for Path, Expected in Map("layout.direct_access_digits", Snapshot["mode"],
			"layout.emulated_layout", Desired["layout"].Get("emulated_layout", ""),
			"layout.ergopti_base", Desired["layout"].Get("ergopti_base", false),
			"category_enabled.layout", Snapshot["master"]) {
			Read := _TOML_DocumentLookup(Document, StrSplit(Path, "."))
			Value := Read["found"] ? Read["value"] : ManifestDefaultFor(Path)
			if Read["found"] && (Path == "layout.ergopti_base" || Path == "category_enabled.layout") && !(Value is TOML_Bool)
				Snapshot["blocked"] := true
			if Value is TOML_Bool
				Value := Value.Value
			if Read["blocked"] || !ManifestValuesEqual(Value, Expected)
				Snapshot["blocked"] := true
		}
		if !_TOML_WriteSourceMatches(ConfigurationFile, Presence, Content)
				|| !NumberRowPolicyIntent(Snapshot, _LAY_NumberRowRuntime(), "native")
			Snapshot["blocked"] := true
	} catch {
		Snapshot["blocked"] := true
	}
	return Snapshot
}

/** Publishes through the existing leased sparse feature owner, with strict ACK. */
_LAY_NumberRowCommit(Expected, Value, WriterFn := 0, RefreshFn := 0, NotifyFn := 0, *) {
	global Features
	Current := _LAY_NumberRowSnapshot()
	if !NumberRowPolicyIntent(Expected, Current, Value)
		return false
	; Choosing an already effective intent must not flush a default into an
	; absent source or claim a persistence acknowledgement for a no-op.
	if StrCompare(Value, Current["mode"], true) == 0
		return false
	try Written := WriteFeatureV2(Features, "layout.direct_access_digits", Value, "",
		_LAY_NumberRowWrite.Bind(Expected, Value, WriterFn), NotifyFn)
	catch {
		return false
	}
	if !(Written is Integer) || Written != true
		return false
	if HasMethod(RefreshFn, "Call")
		RefreshFn.Call()
	else
		RebuildTrayMenu()
	return true
}

/** Keeps the raw admitted image through the canonical publisher's own fences. */
_LAY_NumberRowWrite(Expected, Value, WriterFn, Path, Updates) {
	Current := _LAY_NumberRowSnapshot()
	if !NumberRowPolicyIntent(Expected, Current, Current["mode"])
			|| StrCompare(Expected["path"], Path, true) != 0
			|| Expected["presence"] != Current.Get("presence", -1)
			|| StrCompare(Expected["content"], Current.Get("content", ""), true) != 0
		return false
	if Updates.Length != 1 || Updates[1].Section != "layout" || Updates[1].Key != "direct_access_digits"
			|| !NumberRowPolicyReady(Current, Value)
		return false
	Update := Updates[1]
	if Update.HasOwnProp("Delete") && Update.Delete {
		if StrCompare(Value, ManifestDefaultFor("layout.direct_access_digits"), true) != 0
			return false
	} else if !Update.HasOwnProp("Value") || !(Update.Value is String) || StrCompare(Update.Value, Value, true) != 0
		return false
	if HasMethod(WriterFn, "Call")
		return WriterFn.Call(Path, Updates, Expected["content"], Expected["presence"])
	return _TOML_BatchWriteImpl(Path, Updates, [], "write", Expected["content"], Expected["presence"])
}

/** Supplies only shared choice DATA; each retained callback owns its source. */
_LAY_NumberRowRows(WriterFn := 0, RefreshFn := 0, NotifyFn := 0) {
	Expected := _LAY_NumberRowSnapshot()
	Row := MenuRenderer_ChoiceRow("number_row_policy_rows", "number_row_mode",
		Map("number_row_mode", _LAY_NumberRowChoose.Bind(Expected, WriterFn, RefreshFn, NotifyFn)),
		Map("layout.direct_access_digits", (*) => Expected["mode"]))
	if !(Row is Map) || !Row.Has("items") || !(Row["items"] is Array)
		return []
	Definition := _MR_GetMenuDef("number_row_policy_rows")
	if !(Definition is Array) || Definition.Length != 1 || !(Definition[1] is Map)
			|| !Definition[1].Has("choices") || !(Definition[1]["choices"] is Array)
			|| Definition[1]["choices"].Length != 3
			|| Definition[1]["choices"].Length != Row["items"].Length
		return []
	for Index, Value in ["native", "digits", "symbols"] {
		Choice := Definition[1]["choices"][Index]
		if !(Choice is Map) || !(Row["items"][Index] is Map)
				|| !(Choice.Get("value", 0) is String) || StrCompare(Choice["value"], Value, true) != 0
			return []
	}
	for Index, Item in Row["items"] {
		Value := Definition[1]["choices"][Index]["value"]
		if !NumberRowPolicyReady(Expected, Value) {
			Item["disabled"] := true
			if Value == "symbols" && !Expected["symbols"]
				Item["disabled_reason_key"] := "platform_reason.number_row_source_unavailable"
		}
	}
	return [Row]
}

/** Binds optional native ports without erasing the selected canonical value. */
_LAY_NumberRowChoose(Expected, WriterFn, RefreshFn, NotifyFn, Value) {
	return _LAY_NumberRowCommit(Expected, Value, WriterFn, RefreshFn, NotifyFn)
}

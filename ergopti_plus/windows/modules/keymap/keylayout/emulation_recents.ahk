; modules/keymap/keylayout/emulation_recents.ahk

; ==============================================================================
; MODULE: Recently Emulated Layouts
; DESCRIPTION:
; The layouts chosen last for the emulation (layout.emulated_layout_recents),
; most recent first, and the quick choices the « Layout to emulate » menu draws
; from them above « Others… » (maintainer decision of 2026-11-25). The Windows
; twin of _shared/layouts/engine/emulation/recents.lua: both replay
; _shared/tests/corpus/layouts/emulation_recents_vectors.json. The menu's
; vocabulary holds "" for « None », which is never recorded.
; ==============================================================================

#Include %A_LineFile%\..\..\..\..\_generated\config_keys.ahk

/**
 * How many recent layouts the menu offers: emulation.recent_count of
 * _shared/layouts/data/defaults.json.
 * @returns {Integer} A whole number of at least one.
 */
EmulationRecents_Count() {
	; Read once: the defaults file ships with the app.
	static Cached := 0
	if Cached
		return Cached
	Count := _LayoutRegistryReadJson("layouts\data\defaults.json")["emulation"]["recent_count"]
	if !(Count is Integer) || Count < 1
		throw ValueError("_shared/layouts/data/defaults.json declares no whole emulation.recent_count of at least 1.")
	Cached := Count
	return Count
}

/**
 * The stored list of a Features map: distinct layout ids, or none when the
 * value is in another shape (outdated configuration, reported once).
 * @param {Map} FeaturesSource Feature preferences.
 * @returns {Array}
 */
EmulationRecents_Read(FeaturesSource) {
	if !FeaturesSource.Has("layout") || !FeaturesSource["layout"].Has(ConfigLeaf.EMULATED_LAYOUT_RECENTS)
		return []
	Value := FeaturesSource["layout"][ConfigLeaf.EMULATED_LAYOUT_RECENTS]
	if EmulationRecents_IsValid(Value)
		return Value
	static Reported := false
	if !Reported {
		Reported := true
		try LoggerWarn("Layout", "layout.emulated_layout_recents is not a list of distinct layout ids — read as empty.")
	}
	return []
}

/**
 * Whether a value is a list of distinct layout ids.
 * @param {Any} Value
 * @returns {Boolean}
 */
EmulationRecents_IsValid(Value) {
	if !(Value is Array)
		return false
	Seen := Map()
	for Id in Value {
		if !LayoutRegistry_IsValidId(Id) || Id == "none" || Seen.Has(Id)
			return false
		Seen[Id] := true
	}
	return true
}

/**
 * The list after a choice: the chosen layout first, then the others in order.
 * @param {Array} Recents The stored list.
 * @param {String} Choice "" for « None », else a layout id.
 * @param {Integer} Count The length; EmulationRecents_Count() when 0.
 * @returns {Array} A new list; « None » leaves the order unchanged.
 */
EmulationRecents_After(Recents, Choice, Count := 0) {
	if !Count
		Count := EmulationRecents_Count()
	Result := []
	if Choice != ""
		Result.Push(Choice)
	for Id in Recents {
		if Result.Length >= Count
			break
		if Id != Choice
			Result.Push(Id)
	}
	return Result
}

/**
 * The quick choices under « None »: the layout in force first, then the recent
 * ones the catalogue still offers, at most Count of them.
 * @param {String} Current The choice in force, "" when nothing is emulated.
 * @param {Array} Recents The stored list.
 * @param {Func} OfferedFn (Id) => whether the catalogue offers the layout.
 * @param {Integer} Count The length; EmulationRecents_Count() when 0.
 * @returns {Array} Layout ids.
 */
EmulationRecents_Quick(Current, Recents, OfferedFn, Count := 0) {
	if !Count
		Count := EmulationRecents_Count()
	Ids := []
	Seen := Map()
	if Current != "" {
		Ids.Push(Current)
		Seen[Current] := true
	}
	for Id in Recents {
		if Ids.Length >= Count
			break
		if !Seen.Has(Id) && OfferedFn.Call(Id) {
			Ids.Push(Id)
			Seen[Id] := true
		}
	}
	return Ids
}

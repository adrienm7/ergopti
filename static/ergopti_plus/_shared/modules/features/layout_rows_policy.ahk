; _shared/modules/features/layout_rows_policy.ahk

; ==============================================================================
; MODULE: Layout Rows Policy
; DESCRIPTION:
; The four physical rows a layout emulation types, each behind its own [layout]
; switch (emulate_<row>, declared in the features manifest): which keys each
; row holds, read from the shared physical-key registry, and whether a row is
; emulated. A row switched off is the OS layout's on every level, so the
; number-row ordering then reads the OS layout's row. Drivers keep the hotkeys,
; the pass-through and the menus; the Lua twin replays the same corpus.
; ==============================================================================

#Requires AutoHotkey v2.0




; The rows in registry order: ISO geometry rows 1 (the number row) to 4.
global LAYOUT_ROWS_POLICY_IDS := ["number_row", "top_row", "home_row", "bottom_row"]

/**
 * The character keys of each emulated row, read from the physical-key registry:
 * the alphanumeric keys that type a character (no layout-independent Send name)
 * on ISO rows 1 to 4, left to right. Tab, CapsLock, Enter, Backspace and the
 * Shift keys belong to no row; the space bar row is never emulated by row.
 * @param {Map} Registry Decoded _shared/data/keycodes/physical_keys.json.
 * @returns {Map} Row id -> Array of KeyboardEvent.code, left to right.
 * @throws {TypeError} When the registry lacks its keys.
 */
LayoutRowsPolicyKeys(Registry) {
	global LAYOUT_ROWS_POLICY_IDS
	if !(Registry is Map) || !(Registry.Get("keys", 0) is Map)
		throw TypeError("The layout rows need the physical-key registry.")
	Columns := Map()
	for Row in LAYOUT_ROWS_POLICY_IDS
		Columns[Row] := []
	for Code, Key in Registry["keys"] {
		; A character key has a null Send name (JSON null decodes to a sentinel object).
		Send := Key is Map ? Key.Get("ahk_send", "") : ""
		if !(Key is Map) || Key.Get("kind", "") != "key" || Key.Get("group", "") != "alphanumeric"
				|| (Send is String && Send != "") || !(Key.Get("geometry", 0) is Map)
			continue
		Iso := Key["geometry"].Get("iso", 0)
		if !(Iso is Map) || !(Iso.Get("row", 0) is Integer) || Iso["row"] < 1 || Iso["row"] > LAYOUT_ROWS_POLICY_IDS.Length
			continue
		Columns[LAYOUT_ROWS_POLICY_IDS[Iso["row"]]].Push([Iso["col"], Code])
	}
	Rows := Map()
	for Row, Entries in Columns {
		; An insertion sort keeps this free of any library: a row has 13 keys at most.
		Loop Entries.Length - 1 {
			Index := A_Index + 1
			Entry := Entries[Index]
			while Index > 1 && Entries[Index - 1][1] > Entry[1] {
				Entries[Index] := Entries[Index - 1]
				Index -= 1
			}
			Entries[Index] := Entry
		}
		Codes := []
		for Entry in Entries
			Codes.Push(Entry[2])
		Rows[Row] := Codes
	}
	return Rows
}

/**
 * Whether row Row is emulated under the stored [layout] switches.
 * @param {Map} Layout The [layout] settings, holding the emulate_<row> booleans.
 * @param {String} Row One of LAYOUT_ROWS_POLICY_IDS.
 * @returns {Boolean}
 * @throws {ValueError} On an unknown row or a switch that is not a boolean.
 */
LayoutRowsPolicyEmulates(Layout, Row) {
	global LAYOUT_ROWS_POLICY_IDS
	Known := false
	for Id in LAYOUT_ROWS_POLICY_IDS
		Known := Known || Row == Id
	if !Known
		throw ValueError("Unknown layout row: " . Row)
	Value := Layout is Map ? Layout.Get("emulate_" . Row, "") : ""
	if !(Value is Integer) || (Value != true && Value != false)
		throw ValueError("The layout row switch emulate_" . Row . " is not a boolean.")
	return Value == true
}

/**
 * Which row the number-row ordering reads: the emulated one while an emulation
 * is active and types the number row, else the OS layout's.
 * @param {Boolean} EmulationActive A layout emulation is in force.
 * @param {Map} Layout The [layout] settings.
 * @returns {String} "emulated" or "native".
 */
LayoutRowsPolicyNumberRowSource(EmulationActive, Layout) {
	return EmulationActive && LayoutRowsPolicyEmulates(Layout, "number_row") ? "emulated" : "native"
}

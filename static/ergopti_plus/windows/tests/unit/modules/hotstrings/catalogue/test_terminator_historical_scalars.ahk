; tests/unit/modules/hotstrings/catalogue/test_terminator_historical_scalars.ahk

; ==============================================================================
; MODULE: Historical Terminator Scalar Ownership
; DESCRIPTION:
; The delimiter strings of earlier builds move to config.toml records. A scalar
; outside the BMP is one character, never two UTF-16 units: the move and the
; native menu rows must keep every full scalar whole, even when two scalars
; share a high surrogate.
; ==============================================================================

#Requires AutoHotkey v2.0

_HTHS_With(Mode) {
	global HSE_Terminators
	Saved := _HSDT_SaveState(), SavedTerms := HSE_Terminators, WasSuspended := A_IsSuspended
	Built := 0
	try {
		Suspend(false)
		HSE_Terminators := Terminators()
		if Mode == "migration"
			_HTHS_Migration()
		else {
			_HTHS_SeedRows(Mode)
			Built := _HSDT_NativeControlMenu(_HSDT_AcceptWriter)
			Labels := []
			_HTHS_CollectLabels(Built, Labels)
			Expected := Chr(0x1F600) . " : " . t("menu.hotstrings.custom_label")
			Matching := 0, CustomRows := 0
			for Label in Labels {
				if Label == Expected
					Matching += 1
				if InStr(Label, " : " . t("menu.hotstrings.custom_label"))
					CustomRows += 1
				for Character in _TextCodepoints(Label)
					AssertTrue(HotstringsTerminatorRecordCharacter(Character), "native row labels cannot expose orphan units")
			}
			; A record row is a parent and its own toggle, both labelled with the
			; record: the pair is one row, a split scalar would add more.
			AssertEqual(2, Matching, "one full scalar must own its native custom row and its toggle")
			AssertEqual(2, CustomRows, "a surrogate pair must not create two partial custom commands")
			if Mode == "record-shared-high" {
				Owned := 0
				for Label in Labels
					Owned += Label == "Owned sibling"
				AssertEqual(2, Owned, "the sibling retains its parent and toggle labels")
			}
		}
	} finally {
		try {
			if Built is Menu
				_CTC_ReleaseMenu(Built)
		} finally {
			HSE_Terminators := SavedTerms
			_HSDT_Restore(Saved)
			Suspend(WasSuspended)
		}
	}
}

; Two scalars sharing the high surrogate D83D, and a BMP currency sign. The old
; word string keeps the period of the catalogue, and its consumed string two of
; the three personal scalars.
_HTHS_Migration() {
	global _HSDT_WrittenUpdates
	Face := Chr(0x1F600), Other := Chr(0x1F601)
	_HSDT_Seed("historical-scalar-migration")
	Moved := HotstringsTerminatorMigrateStrings("." . Face . Other . "¤", Other . "¤", _HSDT_AcceptWriter)
	AssertEqual(1, Moved, "the move must be acknowledged by the writer")
	AssertEqual(1, _HSDT_WrittenUpdates.Length, "the whole move is one write")
	Records := 0
	for Update in _HSDT_WrittenUpdates[1]
		if Update.Section == "hotstrings" && Update.Key == "terminators"
			Records := Update.Value
	AssertTrue(Records is Array, "the personal scalars become records")
	AssertEqual(3, Records.Length)
	Expected := [[Face, false], [Other, true], ["¤", true]]
	for Index, Pair in Expected {
		AssertEqual(Pair[1], Records[Index]["char"], "each record holds one complete scalar")
		AssertEqual(Pair[2], !!Records[Index]["consume"].Value, "the consumption of each scalar is kept")
		AssertTrue(HotstringsTerminatorRecordCharacter(Records[Index]["char"]))
	}
}

_HTHS_SeedRows(Mode) {
	Face := Chr(0x1F600)
	Extra := '[[hotstrings.terminators]]`nkey = "face"`nchar = "' . Face . '"`nlabel = "' . Face . " : "
		. t("menu.hotstrings.custom_label") . '"`nconsume = false`n'
	if Mode == "record-shared-high"
		Extra .= '[[hotstrings.terminators]]`nkey = "other_face"`nchar = "' . Chr(0x1F601)
			. '"`nlabel = "Owned sibling"`nconsume = false`n'
	_HSDT_Seed("historical-row-" . Mode, Extra)
}

_HTHS_CollectLabels(Built, Labels) {
	loop TrayMenuItemCount(Built) {
		Position := A_Index - 1
		Labels.Push(_CTC_LabelAt(Built, Position))
		Child := TrayMenuSubmenuHandle(Built.Handle, Position)
		if Child
			_HTHS_CollectLabels(MenuFromHandle(Child), Labels)
	}
}

for _HTHS_Mode in ["migration", "record-astral", "record-shared-high"]
	Test("terminator historical scalars: " . _HTHS_Mode . " preserves exact characters (terminator-historical-scalars)", _HTHS_With.Bind(_HTHS_Mode))

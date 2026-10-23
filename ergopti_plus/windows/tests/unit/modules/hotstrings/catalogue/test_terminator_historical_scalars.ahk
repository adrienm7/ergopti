; tests/unit/modules/hotstrings/catalogue/test_terminator_historical_scalars.ahk

; ==============================================================================
; MODULE: Historical Terminator Scalar Ownership
; DESCRIPTION:
; Drives the bulk delimiter transaction and the actual native menu provider.
; Historical custom scalars must not share membership or rows through one half.
; ==============================================================================

#Requires AutoHotkey v2.0

_HTHS_With(Mode) {
	global HSE_Terminators, _HotstringsTerminatorRecords
	Saved := _HSDT_SaveState(), SavedTerms := HSE_Terminators
	SavedRecords := _HotstringsTerminatorRecords, WasSuspended := A_IsSuspended
	Built := 0
	try {
		Suspend(false)
		HSE_Terminators := Terminators()
		_HotstringsTerminatorRecords := 0
		if Mode == "enable-all" || Mode == "disable-all"
			_HTHS_Bulk(Mode)
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
			AssertEqual(1, Matching, "one full historical scalar must own its native custom row")
			AssertEqual(1, CustomRows, "a surrogate pair must not create two partial custom commands")
			if Mode == "record-shared-high" {
				Owned := 0
				for Label in Labels
					Owned += Label == "Owned sibling"
				AssertEqual(2, Owned, "the canonical sibling retains its parent and toggle labels")
			}
		}
	} finally {
		try {
			if Built is Menu
				_CTC_ReleaseMenu(Built)
		} finally {
			HSE_Terminators := SavedTerms
			_HotstringsTerminatorRecords := SavedRecords
			_HSDT_Restore(Saved)
			Suspend(WasSuspended)
		}
	}
}

_HTHS_Bulk(Mode) {
	global HSE_Terminators, _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	global _HSDT_WriteCalls, _HSDT_ReplaceCalls, _HSDT_NotifyCalls, _HSDT_WrittenContents
	Face := Chr(0x1F600), Other := Chr(0x1F601), Personal := Other . "¤"
	HSE_Terminators.updateMagicKey(Face)
	_HSDT_Seed("historical-scalar-" . Mode, "." . Personal, Personal)
	AssertTrue(_HS_DelimSetAll(Mode == "enable-all", _HSDT_AcceptWriter,
		_HSDT_AcceptReplace, _HSDT_Notify), "the actual bulk transaction must acknowledge")
	if Mode == "disable-all"
		AssertEqual(Personal, _HotstringsWordDelimiters, "disabling built-ins preserves each entire personal scalar")
	else {
		AssertEqual(Personal, SubStr(_HotstringsWordDelimiters, 1, StrLen(Personal)),
			"enabling built-ins retains the personal prefix without dropping a shared high unit")
		AssertTrue(InStr(_HotstringsWordDelimiters, Face) > 0, "the distinct built-in is enabled independently")
	}
	AssertEqual(Personal, _HotstringsConsumedDelimiters, "bulk toggles do not rewrite personal consumption")
	AssertEqual(_HotstringsWordDelimiters, HSE_WORD_TERMINATORS)
	AssertEqual(Personal, HSE_CONSUMED_DELIMITERS)
	AssertEqual(1, _HSDT_WriteCalls), AssertEqual(1, _HSDT_ReplaceCalls), AssertEqual(1, _HSDT_NotifyCalls)
	Document := TOML_ParseDocument(_HSDT_WrittenContents[1])
	AssertEqual(_HotstringsWordDelimiters, Document["__global__"]["word_delimiters"],
		"the actual staged TOML image must contain the same complete characters")
	for Character in _TextCodepoints(_HotstringsWordDelimiters)
		AssertTrue(HotstringsTerminatorRecordCharacter(Character), "bulk publication cannot persist an orphan unit")
}

_HTHS_SeedRows(Mode) {
	Face := Chr(0x1F600)
	_HSDT_Seed("historical-row-" . Mode, Face, "¤")
	if Mode == "record-shared-high" {
		Source := '[hotstrings]`nterminators = [{key="other_face", char="' . Chr(0x1F601)
			. '", label="Owned sibling", consume=false}]`n'
		AssertTrue(HotstringsTerminatorRecordsInit(Source), "the neighboring scalar must pass the real record admission")
	}
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

for _HTHS_Mode in ["enable-all", "disable-all", "raw-astral", "record-shared-high"]
	Test("terminator historical scalars: " . _HTHS_Mode . " preserves exact characters (terminator-historical-scalars)", _HTHS_With.Bind(_HTHS_Mode))

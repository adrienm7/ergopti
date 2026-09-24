; static/ergopti_plus/windows/tests/unit/test_about_menu_channel_rows.ahk

; ==============================================================================
; MODULE: About Menu Channel Rows Tests
; DESCRIPTION:
; The About submenu lists one row per channel of the shared update-channel
; registry, ticked on the subscribed channel, right before the check row, and
; the check-frequency picker after it. The channels used to be a nested
; "Update channel" submenu with two hardcoded rows (main and dev).
;
; The row actions are called for real through an injected setter, which also
; guards the AHK closure trap: a fat arrow written inside the loop would share
; the loop variable and switch every row to the last channel.
; ==============================================================================

_AMCR_RecordChannel(State, Id) {
	State.Calls.Push(Id)
	return true
}

_AMCR_ChannelRowsFollowTheRegistry() {
	global UPDATER_CHANNEL
	SavedChannel := UPDATER_CHANNEL
	try {
		Ids := UpdateChannels_Ids()
		AssertTrue(Ids.Length >= 2, "the registry must declare the channels the menu lists")
		UPDATER_CHANNEL := Ids[Ids.Length]
		State := { Calls: [] }
		Rows := _MI_AboutUpdateRows(false, _AMCR_RecordChannel.Bind(State))

		AssertTrue(InStr(Rows[1]["label"], "ErgoptiPlus ") == 1, "the version row comes first")
		AssertTrue(Rows[2].Has("separator"), "a separator follows the version row")
		for Index, Id in Ids {
			Row := Rows[2 + Index]
			AssertEqual(t(UpdateChannels_Field(Id, "menu_label_key")), Row["label"],
				"channel row " . Index . " must read its registry label")
			AssertEqual(Id == UPDATER_CHANNEL, Row["checked"] ? true : false,
				"only the subscribed channel is ticked (" . Id . ")")
			Row["action"].Call("", Index, 0)
		}
		AssertEqual(Ids.Length, State.Calls.Length, "every channel row must subscribe")
		for Index, Id in Ids
			AssertEqual(Id, State.Calls[Index], "row " . Index . " must subscribe to its own channel")

		Check := Rows[3 + Ids.Length]
		AssertEqual(Updater_GetUpdateMenuLabel(), Check["label"],
			"the check row comes right after the channel rows")
		Frequency := Rows[4 + Ids.Length]
		AssertTrue(Frequency.Has("items"), "the check-frequency picker follows the check row")
		AssertEqual(4 + Ids.Length, Rows.Length, "nothing else belongs to the updater block")
	} finally {
		UPDATER_CHANNEL := SavedChannel
	}
}
Test("About menu: one row per registry channel right before the check row", _AMCR_ChannelRowsFollowTheRegistry)

; The frequency picker lists the shared presets (defaults.json, never last) and
; its parent row reads the translated label of the preset in force. It used to
; print the raw preset code ("Check frequency: 24h") and "?" for a saved value
; outside its own hand-copied list.
_AMCR_FrequencyPickerReadsTheSharedPresets() {
	global UPDATER_CHECK_INTERVAL
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		Presets := UpdateSchedule_Presets()
		AssertTrue(Presets.Length >= 5, "the shared presets must be listed")
		for _, Pair in [[86400, "1d"], [600, "5m"], [0, "never"]] {
			UPDATER_CHECK_INTERVAL := Pair[1]
			Rows := _MI_AboutUpdateRows(false, _AMCR_RecordChannel.Bind({ Calls: [] }))
			Frequency := Rows[Rows.Length]
			AssertTrue(Frequency.Has("items"), "the frequency picker closes the updater block")
			AssertEqual(t("menu.about.frequency_menu") . ": " . t("menu.about.frequency." . Pair[2]),
				Frequency["label"], "the parent row reads the translated preset for " . Pair[1] . " s")
			Items := Frequency["items"]
			AssertEqual(Presets.Length, Items.Length, "one row per shared preset")
			Ticked := 0
			for Index, Preset in Presets {
				AssertEqual(t("menu.about.frequency." . Preset["code"]), Items[Index]["label"],
					"preset row " . Index . " reads its translated label")
				if Items[Index]["checked"] {
					Ticked += 1
					AssertEqual(Pair[2], Preset["code"], "the preset in force is the ticked row")
				}
			}
			AssertEqual(1, Ticked, "exactly one preset row is ticked for " . Pair[1] . " s")
		}
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
	}
}
Test("About menu: the frequency picker lists the shared presets with translated labels",
	_AMCR_FrequencyPickerReadsTheSharedPresets)

_AMCR_LocalCheckoutListsChannelsOnly() {
	Ids := UpdateChannels_Ids()
	Rows := _MI_AboutUpdateRows(true, _AMCR_RecordChannel.Bind({ Calls: [] }))
	AssertEqual(2 + Ids.Length, Rows.Length,
		"a local checkout lists the version and the channels, with no check row")
	AssertTrue(Rows[1].Has("disabled") && Rows[1]["disabled"], "a local checkout's version is a label")
}
Test("About menu: a local checkout shows the channels without a check row", _AMCR_LocalCheckoutListsChannelsOnly)

; static/ergopti_plus/windows/tests/unit/test_about_menu_channel_rows.ahk

; ==============================================================================
; MODULE: About Menu Channel Rows Tests
; DESCRIPTION:
; The About submenu offers the update channels in ONE submenu right before the
; check row, titled with the subscribed channel's registry name (« Canal de mise
; à jour : Dev »), listing every channel of the shared registry in registry
; order with the subscribed one ticked; the check-frequency picker follows the
; check row. The channels were once a nested submenu with two hardcoded rows
; (main and dev), then one flat row each, which read as unrelated commands.
;
; The row actions are called for real through an injected setter, which also
; guards the AHK closure trap: a fat arrow written inside the loop would share
; the loop variable and switch every row to the last channel.
; ==============================================================================

; Where the channel picker sits: after the version row and its separator.
global _AMCR_PICKER_AT := 3

_AMCR_RecordChannel(State, Id) {
	State.Calls.Push(Id)
	return true
}

; Records the request and persists it the way Updater_SetChannel does.
_AMCR_PersistChannel(State, Id) {
	global UPDATER_CHANNEL
	State.Calls.Push(Id)
	UPDATER_CHANNEL := Id
	return true
}

; The title the picker must read for a subscribed channel, spelled from the
; translated template and the registry's own name for the channel.
_AMCR_ExpectedTitle(Id) {
	return StrReplace(t("menu.about.channel_menu"), "{channel}", t(UpdateChannels_Field(Id, "label_key")))
}

_AMCR_ChannelPickerFollowsTheRegistry() {
	global UPDATER_CHANNEL, _AMCR_PICKER_AT
	SavedChannel := UPDATER_CHANNEL
	try {
		Ids := UpdateChannels_Ids()
		AssertTrue(Ids.Length >= 2, "the registry must declare the channels the menu lists")
		AssertTrue(InStr(t("menu.about.channel_menu"), "{channel}") > 0,
			"the picker's title template must carry its placeholder")
		for _, Subscribed in Ids {
			UPDATER_CHANNEL := Subscribed
			Rows := _MI_AboutUpdateRows(false, _AMCR_RecordChannel.Bind({ Calls: [] }))

			Identity := Updater_BuildIdentity()
			AssertEqual(Updater_VersionRowLabel(Identity["kind"], Identity["version"], Identity["commit"]),
				Rows[1]["label"], "the version row comes first")
			AssertTrue(Rows[2].Has("separator"), "a separator follows the version row")
			Picker := Rows[_AMCR_PICKER_AT]
			AssertTrue(Picker.Has("items"), "the channels are one submenu")
			AssertEqual(_AMCR_ExpectedTitle(Subscribed), Picker["label"],
				"the picker's title names the subscribed channel " . Subscribed)
			Items := Picker["items"]
			AssertEqual(Ids.Length, Items.Length, "one row per registry channel")
			Ticked := 0
			for Index, Id in Ids {
				AssertEqual(t(UpdateChannels_Field(Id, "menu_label_key")), Items[Index]["label"],
					"channel row " . Index . " must read its registry label, in registry order")
				if Items[Index]["checked"] {
					Ticked += 1
					AssertEqual(Subscribed, Id, "only the subscribed channel is ticked")
				}
			}
			AssertEqual(1, Ticked, "exactly one channel is ticked for " . Subscribed)

			Check := Rows[_AMCR_PICKER_AT + 1]
			AssertEqual(Updater_GetUpdateMenuLabel(), Check["label"],
				"the check row comes right after the channel picker")
			Frequency := Rows[_AMCR_PICKER_AT + 2]
			AssertTrue(Frequency.Has("items"), "the check-frequency picker follows the check row")
			AssertEqual(_AMCR_PICKER_AT + 2, Rows.Length, "nothing else belongs to the updater block")
		}
	} finally {
		UPDATER_CHANNEL := SavedChannel
	}
}
Test("About menu: one channel submenu titled with the subscribed channel, right before the check row",
	_AMCR_ChannelPickerFollowsTheRegistry)

; Every row subscribes to its own channel. The injected setter persists like
; Updater_SetChannel does, so the next build reads the channel just chosen and
; the title must follow it.
_AMCR_ChannelRowSubscribesAndRetitles() {
	global UPDATER_CHANNEL, _AMCR_PICKER_AT
	SavedChannel := UPDATER_CHANNEL
	try {
		Ids := UpdateChannels_Ids()
		UPDATER_CHANNEL := Ids[1]
		State := { Calls: [] }
		Setter := _AMCR_PersistChannel.Bind(State)
		for Index, Id in Ids {
			Rows := _MI_AboutUpdateRows(false, Setter)
			Rows[_AMCR_PICKER_AT]["items"][Index]["action"].Call("", Index, 0)
			Rebuilt := _MI_AboutUpdateRows(false, Setter)
			AssertEqual(_AMCR_ExpectedTitle(Id), Rebuilt[_AMCR_PICKER_AT]["label"],
				"the rebuilt title names the channel row " . Index . " chose")
		}
		AssertEqual(Ids.Length, State.Calls.Length, "every channel row must subscribe")
		for Index, Id in Ids
			AssertEqual(Id, State.Calls[Index], "row " . Index . " must subscribe to its own channel")
	} finally {
		UPDATER_CHANNEL := SavedChannel
	}
}
Test("About menu: a channel row subscribes to its own channel and the title follows",
	_AMCR_ChannelRowSubscribesAndRetitles)

; The flat rows are gone: no row of the updater block reads a channel label.
_AMCR_NoFlatChannelRow() {
	for _, IsLocal in [false, true] {
		Rows := _MI_AboutUpdateRows(IsLocal, _AMCR_RecordChannel.Bind({ Calls: [] }))
		for _, Row in Rows {
			Label := Row.Get("label", "")
			for _, Id in UpdateChannels_Ids()
				AssertTrue(Label != t(UpdateChannels_Field(Id, "menu_label_key")),
					"the channel " . Id . " must be listed inside the picker only")
		}
	}
}
Test("About menu: no channel is a flat row of the About submenu any more", _AMCR_NoFlatChannelRow)

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

; A local version has no installation to update, so it checks for nothing.
; Its check row and its frequency row used to be left out, and nobody could
; tell whether the automatic update existed: they are drawn greyed, with the
; reason, and run nothing (update-rows-greyed-on-local-2026-10-01).
_AMCR_LocalCheckoutGreysTheUpdateRows() {
	global _AMCR_PICKER_AT, UPDATER_CHECK_INTERVAL
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		UPDATER_CHECK_INTERVAL := 86400
		Rows := _MI_AboutUpdateRows(true, _AMCR_RecordChannel.Bind({ Calls: [] }))
		AssertTrue(Rows[1].Has("disabled") && Rows[1]["disabled"], "a local checkout's version is a label")
		AssertTrue(Rows[_AMCR_PICKER_AT].Has("items"), "the channel picker stays")
		AssertEqual(_AMCR_PICKER_AT + 2, Rows.Length,
			"a local checkout draws the check row and the frequency row after the channel picker")
		Check := Rows[_AMCR_PICKER_AT + 1]
		Frequency := Rows[_AMCR_PICKER_AT + 2]
		AssertEqual(t("menu.about.check_for_updates"), Check["label"])
		AssertEqual(t("menu.about.frequency_menu") . ": " . t("menu.about.frequency.1d"), Frequency["label"],
			"the frequency row still names the preset in force")
		for _, Row in [Check, Frequency] {
			AssertTrue(Row.Has("disabled") && Row["disabled"], Row["label"] . " is greyed on a local version")
			AssertEqual("menu.about.source_run_reason", Row.Get("disabled_reason_key", ""),
				Row["label"] . " says why it is greyed")
			AssertFalse(Row.Has("action"), Row["label"] . " runs nothing")
			AssertFalse(Row.Has("items"), Row["label"] . " opens nothing")
		}
		Installed := _MI_AboutUpdateRows(false, _AMCR_RecordChannel.Bind({ Calls: [] }))
		AssertEqual(Rows.Length, Installed.Length, "a local version and an installed one draw the same rows")
		for _, Row in [Installed[_AMCR_PICKER_AT + 1], Installed[_AMCR_PICKER_AT + 2]]
			AssertFalse(Row.Has("disabled_reason_key"), "an installed build greys no update row for this reason")
	} finally {
		UPDATER_CHECK_INTERVAL := SavedInterval
	}
}
Test("About menu: a local checkout draws the update rows greyed with their reason (update-rows-greyed-on-local-2026-10-01)",
	_AMCR_LocalCheckoutGreysTheUpdateRows)


; Captured labels and state are independent of the generated choice projection.
_AMCR_ChannelCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\update_channel_rows.json", "UTF-8"))
}

_AMCR_PublishedChannelOrder() {
	global UPDATER_CHANNEL
	Root := _MR_GetManifestRoot()
	Previous := Root["about_update_channel_menu"]
	SavedChannel := UPDATER_CHANNEL
	Owned := []
	Corpus := _AMCR_ChannelCorpus()
	Choices := []
	for Value in Corpus["reordered_values"] {
		for Choice in Corpus["choices"] {
			if Choice["value"] == Value
				Choices.Push(Choice)
		}
	}
	Root["about_update_channel_menu"] := [Map(
		"type", "choice", "id", "update_channel", "path", "updater.channel",
		"i18n", "menu.about.channel_menu", "show_current_choice", true,
		"current_choice_placeholder", "{channel}", "choices", Choices)]
	try {
		UPDATER_CHANNEL := "main"
		State := { Calls: [] }
		Picker := _AMCR_NativeChannelPicker(Owned, _AMCR_RecordChannel.Bind(State))
		AssertEqual(2, Picker["items"].Length, "the independent two-channel corpus stays complete")
		for Index, Choice in Choices {
			Leaf := Picker["items"][Index]
			AssertEqual(t(Choice["i18n"]), Leaf["label"], "the native provider consumes published order")
			AssertEqual(Choice["value"] == "main", Leaf["checked"], "reordered state follows identity")
			Leaf["action"].Call("", Index, 0)
		}
		for Index, Value in Corpus["reordered_values"]
			AssertEqual(Value, State.Calls[Index], "the native callback retains its own channel")
	} finally {
		Root["about_update_channel_menu"] := Previous
		UPDATER_CHANNEL := SavedChannel
		for Built in Owned
			_CTC_ReleaseMenu(Built)
	}
}
Test("About menu: native channel provider consumes the published alternate order", _AMCR_PublishedChannelOrder)

; Captures the actual Win32 provider submenu and dispatcher, not mirrored rows.
_AMCR_NativeChannelPicker(Owned, Setter) {
	global _MenuDispatchCallbacks
	Built := Menu()
	Owned.Push(Built)
	MenuRenderer_AppendRows(Built, "about_menu", "about_updates", _MI_AboutUpdateRows(false, Setter))
	Handle := DllCall("GetSubMenu", "ptr", Built.Handle, "int", 2, "ptr")
	Assert(Handle != 0, "the actual About provider opens the declared channel submenu")
	Sub := MenuFromHandle(Handle)
	Items := []
	loop TrayMenuItemCount(Sub) {
		Position := A_Index - 1
		Id := DllCall("GetMenuItemID", "ptr", Handle, "int", Position, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id), "the channel leaf uses the actual dispatcher")
		Items.Push(Map("label", _CTC_LabelAt(Sub, Position),
			"checked", _CTC_IsChecked(Sub, Position), "action", _MenuDispatchCallbacks[Id]))
	}
	return Map("label", _CTC_LabelAt(Built, 2), "items", Items)
}

; Refusals leave the actual native preference untouched; callbacks retain the
; existing setter's receipt or exception rather than manufacture a success.
_AMCR_RefusedChannel(State, Kind, Id) {
	State.Calls.Push(Id)
	if Kind == "throw"
		throw Error("refused channel write")
	return false
}

_AMCR_RefusedChannelOwner() {
	global UPDATER_CHANNEL
	SavedChannel := UPDATER_CHANNEL
	Owned := []
	try {
		for Kind in ["false", "throw"] {
			UPDATER_CHANNEL := "main"
			State := { Calls: [] }
			Picker := _AMCR_NativeChannelPicker(Owned, _AMCR_RefusedChannel.Bind(State, Kind))
			Thrown := false
			Result := true
			try Result := Picker["items"][2]["action"].Call("", 2, 0)
			catch Error as Err {
				Thrown := true
				AssertEqual("refused channel write", Err.Message, "the native refusal propagates unchanged")
			}
			AssertEqual(Kind == "throw", Thrown, "only the owner's exception throws")
			if !Thrown
				AssertEqual(false, Result, "the owner's false receipt survives the renderer")
			AssertEqual(1, State.Calls.Length, "one click invokes the owner once")
			AssertEqual("dev", State.Calls[1], "the second leaf selects dev")
			AssertEqual("main", UPDATER_CHANNEL, "refusal never publishes a guessed channel")
		}
	} finally {
		UPDATER_CHANNEL := SavedChannel
		for Built in Owned
			_CTC_ReleaseMenu(Built)
	}
}
Test("About menu: native channel callbacks retain preference refusal receipts", _AMCR_RefusedChannelOwner)


_AMCR_CapturedChannelStates() {
	global UPDATER_CHANNEL
	SavedChannel := UPDATER_CHANNEL
	Owned := []
	Corpus := _AMCR_ChannelCorpus()
	try {
		for State in Corpus["states"] {
			UPDATER_CHANNEL := State["selected"]
			Picker := _AMCR_NativeChannelPicker(Owned, _AMCR_RecordChannel.Bind({ Calls: [] }))
			AssertEqual(2, Picker["items"].Length, "the captured two choices remain complete")
			for Index, Choice in Corpus["choices"] {
				Leaf := Picker["items"][Index]
				AssertEqual(t(Choice["i18n"]), Leaf["label"], "the independent legacy full-label key is retained")
				AssertEqual(State["checked"][Index], Leaf["checked"], "the captured exclusive tick is retained")
			}
		}
	} finally {
		UPDATER_CHANNEL := SavedChannel
		for Built in Owned
			_CTC_ReleaseMenu(Built)
	}
}
Test("About menu: the independent two-channel states remain unchanged", _AMCR_CapturedChannelStates)

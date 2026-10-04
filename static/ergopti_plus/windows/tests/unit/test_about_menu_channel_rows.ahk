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


/** Reads the independently captured ten cadence values and label keys. */
_AMCR_FrequencyCorpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\update_check_frequency.json", "UTF-8"))
}

_AMCR_FrequencyIdentity() {
	return Map("kind", "release", "version", "0.0.0-dev.140", "commit", "c3005e0b9")
}

/** Observes scalar delivery before the injected durable acknowledgement. */
_AMCR_RecordFrequency(State, Seconds) {
	global UPDATER_CHECK_INTERVAL
	State["calls"].Push(Seconds)
	if !State["acknowledged"]
		return false
	UPDATER_CHECK_INTERVAL := Seconds
	return true
}

_AMCR_FrequencyRows(State, IsLocal := false) {
	return _MI_AboutUpdateRows(IsLocal, _AMCR_RecordChannel.Bind({ Calls: [] }),
		_AMCR_FrequencyIdentity, _AMCR_RecordFrequency.Bind(State))
}

_AMCR_FrequencyIndependentProjection() {
	global UPDATER_CHECK_INTERVAL
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		Corpus := _AMCR_FrequencyCorpus()
		AssertEqual(10, Corpus["choices"].Length)
		for Expected in Corpus["snapped_states"] {
			UPDATER_CHECK_INTERVAL := Expected["stored"]
			State := Map("calls", [], "acknowledged", true)
			Rows := _AMCR_FrequencyRows(State)
			Frequency := Rows[Rows.Length]
			AssertEqual(t(Corpus["i18n"]) . ": " . t("menu.about.frequency." . Expected["code"]), Frequency["label"])
			AssertEqual(10, Frequency["items"].Length)
			AssertEqual(Expected["stored"], UPDATER_CHECK_INTERVAL, "rendering must not rewrite historical stored seconds")
			for Index, Choice in Corpus["choices"] {
				Row := Frequency["items"][Index]
				AssertEqual(t(Choice["i18n"]), Row["label"])
				AssertEqual(Choice["value"] == Expected["value"], Row["checked"])
				AssertTrue(Row["action"].Call())
				AssertEqual(Choice["value"], State["calls"][Index], "the shared renderer binds this row's numeric interval")
				AssertEqual(Choice["value"], UPDATER_CHECK_INTERVAL)
			}
		}
	} finally UPDATER_CHECK_INTERVAL := SavedInterval
}
Test("About menu: shared frequency goldens keep numeric values labels and snapped current captions",
	_AMCR_FrequencyIndependentProjection)

_AMCR_FrequencyHeldRefusal() {
	global UPDATER_CHECK_INTERVAL
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		UPDATER_CHECK_INTERVAL := 3600
		State := Map("calls", [], "acknowledged", false)
		Rows := _AMCR_FrequencyRows(State)
		Callback := Rows[Rows.Length]["items"][1]["action"]
		AssertFalse(Callback.Call())
		AssertEqual(3600, UPDATER_CHECK_INTERVAL, "a refused native owner cannot publish the selected cadence")
		AssertEqual(1, State["calls"].Length)
		State["acknowledged"] := true
		AssertTrue(Callback.Call())
		Selected := _AMCR_FrequencyCorpus()["choices"][1]["value"]
		AssertEqual(Selected, UPDATER_CHECK_INTERVAL)
		UPDATER_CHECK_INTERVAL := 86400
		AssertTrue(Callback.Call(), "a held absolute selection keeps its published scalar")
		AssertEqual(Selected, UPDATER_CHECK_INTERVAL)
		AssertEqual(3, State["calls"].Length)
	} finally UPDATER_CHECK_INTERVAL := SavedInterval
}
Test("About menu: frequency callbacks retain the native refusal and absolute held selection receipt",
	_AMCR_FrequencyHeldRefusal)

_AMCR_FrequencyPublishedOrder() {
	global UPDATER_CHECK_INTERVAL
	Root := _MR_GetManifestRoot()
	Previous := Root["about_update_frequency_menu"]
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		Corpus := _AMCR_FrequencyCorpus()
		Choices := []
		Loop Corpus["choices"].Length {
			Choice := Corpus["choices"][Corpus["choices"].Length - A_Index + 1]
			Choices.Push(Map("value", Choice["value"], "i18n", Choice["i18n"]))
		}
		Choices[1]["i18n"] := Corpus["alternate_i18n"]
		Root["about_update_frequency_menu"] := [Map("type", "choice", "id", Corpus["id"],
			"path", Corpus["path"], "i18n", Corpus["i18n"], "show_current_choice", true,
			"current_choice_suffix", Corpus["suffix"], "choices", Choices)]
		UPDATER_CHECK_INTERVAL := 3600
		State := Map("calls", [], "acknowledged", true)
		Rows := _AMCR_FrequencyRows(State)
		Frequency := Rows[Rows.Length]
		AssertEqual(10, Frequency["items"].Length)
		for Index, Choice in Choices {
			Row := Frequency["items"][Index]
			AssertEqual(t(Choice["i18n"]), Row["label"])
			AssertTrue(Row["action"].Call())
			AssertEqual(Choice["value"], State["calls"][Index], "no private preset loop may replace the published choices")
		}
	} finally {
		Root["about_update_frequency_menu"] := Previous
		UPDATER_CHECK_INTERVAL := SavedInterval
	}
}
Test("About menu: frequency provider consumes the published order and alternate translated label",
	_AMCR_FrequencyPublishedOrder)


; The source-only row follows its declaration without gaining an update action.
_AMCR_SourceCheckSharedCommand() {
	global _AMCR_PICKER_AT
	Root := _MR_GetManifestRoot()
	Assert(Root.Has("about_source_menu"), "the shared source-only check must be declared")
	Original := Root["about_source_menu"]
	try {
		for Labels in [Map("i18n", "menu.about.check_for_updates", "reason", "menu.about.source_run_reason"),
			Map("i18n", "common.restore_recommended", "reason", "common.clear_to_system")] {
			Declaration := Original[1].Clone()
			Declaration["i18n"] := Labels["i18n"]
			Declaration["disabled_reason_key"] := Labels["reason"]
			Root["about_source_menu"] := [Declaration]
			State := { Calls: [] }
			Rows := _MI_AboutUpdateRows(true, _AMCR_RecordChannel.Bind(State))
			Row := Rows[_AMCR_PICKER_AT + 1]
			AssertEqual(t(Labels["i18n"]), Row["label"], "the declared caption owns the source check")
			AssertEqual(Labels["reason"], Row.Get("disabled_reason_key", ""),
				"the source-only reason comes from the same shared declaration")
			AssertEqual(true, Row.Get("disabled", false))
			AssertFalse(Row.Has("action"), "a source checkout exposes no native update command")
			AssertFalse(Row.Has("items"), "a source checkout opens no update window")
			AssertFalse(Row.Has("checked"), "the source check cannot toggle settings")
			AssertEqual(0, State.Calls.Length, "building a source row cannot mutate its channel")
		}
	} finally Root["about_source_menu"] := Original
}
Test("About source check: canonical disabled label reason and zero native effects", _AMCR_SourceCheckSharedCommand)

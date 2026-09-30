; static/ergopti_plus/windows/tests/unit/test_updater_channel_registry.ahk

; ==============================================================================
; MODULE: Update Channel Registry Tests
; DESCRIPTION:
; Replays the shared _shared/modules/updater/channel_vectors.json through the
; AHK port (modules/updater/channels.ahk) over the generated registry data. The
; JavaScript matcher and the Lua port replay the same file, so the three
; interpreters cannot disagree on which channel owns a release tag, which
; persisted value maps to which channel, or which candidate a check offers.
; The vectors spell "no channel" as an empty string, the value the AHK port
; returns for it.
; ==============================================================================

_UpdChanTest_Vectors() {
	Path := A_ScriptDir . "\..\..\_shared\modules\updater\channel_vectors.json"
	AssertTrue(FileExist(Path) != "", "channel vectors must exist at: " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_UpdChanTest_RegistryOrder() {
	Ids := UpdateChannels_Ids()
	AssertEqual(2, Ids.Length, "the registry declares main and dev")
	AssertEqual("main", Ids[1], "the most stable channel comes first")
	AssertEqual("dev", Ids[2])
	AssertEqual("dev", UpdateChannels_UnreleasedBuildChannel())
	AssertEqual("updater.channel.main", UpdateChannels_Field("main", "label_key"))
	AssertEqual("updater.channel.dev_menu", UpdateChannels_Field("dev", "menu_label_key"))
	AssertThrows(() => UpdateChannels_Field("beta", "label_key"),
		"an unknown channel must be refused, not defaulted")
}
Test("Update channels: registry order and fields come from the generated data", _UpdChanTest_RegistryOrder)

_UpdChanTest_TagVectors() {
	Vectors := _UpdChanTest_Vectors()["tag"]
	AssertTrue(Vectors.Length >= 20, "tag vectors: >=20 expected, got " . Vectors.Length)
	for _, V in Vectors {
		AssertEqual(V["channel"], UpdateChannels_ForTag(V["tag"]), "tag vector " . V["id"])
		for _, Id in UpdateChannels_Ids()
			AssertEqual(Id == V["channel"], UpdateChannels_Matches(Id, V["tag"]),
				"matches(" . Id . ") for tag vector " . V["id"])
	}
}
Test("Update channels: tags map to their channel (shared vectors)", _UpdChanTest_TagVectors)

_UpdChanTest_ResolveVectors() {
	Vectors := _UpdChanTest_Vectors()["resolve"]
	AssertTrue(Vectors.Length >= 5, "resolve vectors: >=5 expected")
	for _, V in Vectors
		AssertEqual(V["expect"], UpdateChannels_Resolve(V["value"]), "resolve vector " . V["id"])
}
Test("Update channels: persisted values and aliases resolve exactly (shared vectors)", _UpdChanTest_ResolveVectors)

_UpdChanTest_VisibleVectors() {
	Vectors := _UpdChanTest_Vectors()["visible"]
	AssertTrue(Vectors.Length >= 5, "visible vectors: >=5 expected")
	for _, V in Vectors
		AssertEqual(V["expect"] ? true : false, UpdateChannels_VisibleIn(V["view"], V["tag"]) ? true : false,
			"visible vector " . V["id"])
}
Test("Update channels: a view lists its releases and the more stable ones (shared vectors)", _UpdChanTest_VisibleVectors)

_UpdChanTest_OfferVectors() {
	Vectors := _UpdChanTest_Vectors()["offer"]
	AssertTrue(Vectors.Length >= 8, "offer vectors: >=8 expected")
	for _, V in Vectors
		AssertEqual(V["expect"] ? true : false,
			UpdateChannels_ShouldOffer(V["latest"], V["current"], V["selected"], V["installed"]) ? true : false,
			"offer vector " . V["id"])
}
Test("Update channels: candidates are offered like on the other drivers (shared vectors)", _UpdChanTest_OfferVectors)

_UpdChanTest_PickVectors() {
	Vectors := _UpdChanTest_Vectors()["pick"]
	AssertTrue(Vectors.Length >= 5, "pick vectors: >=5 expected")
	for _, V in Vectors {
		Index := UpdateChannels_PickLatest(V["tags"], V["channel"])
		AssertEqual(V["expect"], Index ? V["tags"][Index] : "", "pick vector " . V["id"])
	}
}
Test("Update channels: a channel's latest release is picked by semver (shared vectors)", _UpdChanTest_PickVectors)

_UpdChanTest_NewerElsewhereVectors() {
	Vectors := _UpdChanTest_Vectors()["newer_elsewhere"]
	AssertTrue(Vectors.Length >= 10, "newer_elsewhere vectors: >=10 expected, got " . Vectors.Length)
	for _, V in Vectors {
		Found := UpdateChannels_NewerElsewhere(V["releases"], V["selected"], V["installed"])
		Expected := V["expect"]
		AssertEqual(Expected.Length, Found.Length, "newer_elsewhere vector " . V["id"] . ": entry count")
		for Index, Entry in Expected {
			if (Index > Found.Length)
				break
			AssertEqual(Entry["channel"], Found[Index]["channel"], "newer_elsewhere vector " . V["id"] . ": channel #" . Index)
			AssertEqual(Entry["tag"], Found[Index]["tag"], "newer_elsewhere vector " . V["id"] . ": tag #" . Index)
		}
	}
}
Test("Update channels: other channels newer than the installed build are listed (shared vectors)", _UpdChanTest_NewerElsewhereVectors)

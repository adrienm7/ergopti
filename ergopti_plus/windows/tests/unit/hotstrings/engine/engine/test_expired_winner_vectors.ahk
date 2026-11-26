; tests/unit/hotstrings/engine/engine/test_expired_winner_vectors.ahk

; ==============================================================================
; MODULE: Expired Winner Corpus (hcd-1-expired-winner)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/expired_winner_vectors.json through
; the real matcher and dispatcher. The matcher picks its winner first and asks
; only that winner's expansion delay (HSE_TimeGateExpired): an expired winner
; fires nothing, and no shorter rule whose delay still allows it fires in its
; place (maintainer decision HCD-1, 2026-11-21). The shared engine (Linux) and
; macOS replay the same vectors.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Corpus replay ===========================
; ====================================================
; ====================================================

_EWV_Vectors() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\hotstrings\expired_winner_vectors.json"
	return JsonParse(FileRead(Path, "UTF-8"))["vectors"]
}

_EWV_Replay(Vector) {
	global LastSentCharacterKeyTime, LastSentCharacterKeyComplex, HSE_LastEndChar, HSE_TypoNbspStripped
	global _TimingsCache
	if (Type(_TimingsCache) != "Map")
		TimingsLoadShared()
	for Mapping in Vector["mappings"] {
		IsAuto := Mapping.Has("auto_expand") and Mapping["auto_expand"]
		CreateHotstring(IsAuto ? "*?C" : "?C", Mapping["trigger"], Mapping["replacement"],
			Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON, "TimeActivationSeconds", Mapping["delay_s"]))
	}
	Base := A_TickCount
	LastSentCharacterKeyTime := Map()
	LastSentCharacterKeyComplex := Map()
	Typed := Vector["typed"]
	Match := ""
	for Index, Key in Typed {
		Match := HSE_FeedChar(Key["char"], true)
		if (Index < Typed.Length) {
			AssertFalse(IsObject(Match), Vector["id"] . ": only the expander may complete")
			LastSentCharacterKeyTime[Key["char"]] := Base + Key["down_ms"]
			LastSentCharacterKeyComplex[Key["char"]] := false
		}
	}
	AssertTrue(IsObject(Match), Vector["id"] . ": the typed text completes a winner")
	AssertEqual(Vector["expected"]["winner"], Match.Trigger, Vector["id"] . ": the matcher's winner")
	GateTick := Base + Typed[Typed.Length]["down_ms"]
	Expired := HSE_TimeGateExpired(Match, HSE_Buffer, HSE_LastEndChar, HSE_TypoNbspStripped, GateTick)
	Fires := Vector["expected"]["fires"]
	AssertEqual(Fires is String ? false : true, Expired ? true : false,
		Vector["id"] . ": the winner's own delay decides, nothing lower is asked")
}

_EWV_Run(Vector) {
	_HOF_Run(_EWV_Replay.Bind(Vector))
}

for _EWV_Vector in _EWV_Vectors()
	Test("expired winner corpus: " . _EWV_Vector["id"] . " (hcd-1-expired-winner)", _EWV_Run.Bind(_EWV_Vector))

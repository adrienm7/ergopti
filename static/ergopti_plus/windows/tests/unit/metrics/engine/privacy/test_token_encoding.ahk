; tests/unit/metrics/engine/privacy/test_token_encoding.ahk

; ==============================================================================
; MODULE: Keystats Token Encoding Tests
; DESCRIPTION:
; Replays token_encoding_vectors.json on the Windows walker, which owns the rule
; in AHK. The audit's two histories that shared one hexagram key are vectors of
; correction_sequence_vectors.json, walked by the three drivers' corpus tests.
; ==============================================================================

_KTE_EventTokens() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\keystats\token_encoding_vectors.json"
	Vectors := JsonParse(FileRead(Path, "UTF-8"))
	AssertEqual(Vectors["version"], KEYSTATS_TOKEN_VERSION, "the walker runs the corpus version")
	for Vector in Vectors["event_tokens"]
		AssertEqual(Vector["token"], KLW_EventToken(Vector["char"]), "the key form of " . Vector["char"])
}
Test("Keystats tokens: every corpus event has its shared key form (token-encoding)", _KTE_EventTokens)

_KTE_OldSpellingJoinsItsMarker() {
	SavedBatch := KLW.batch
	SavedCtx := KLW.ctx
	try {
		KLW_ResetBatch()
		KLW.ctx := Map()
		Events := [["[PGUP]", 80, Map()], ["[PAGEUP]", 80, Map()], ["[DEL]", 80, Map()]]
		KLW_WalkTypingEntry(Map("app", "TokenApp", "timestamp", "2024-06-01 10:00:00.000", "events", Events))
		Tokens := Map()
		for Key, Row in KLW.batch["ngram"]["ngram_chars"] {
			Parts := StrSplit(Key, Chr(1))
			Tokens[Parts[Parts.Length]] := Row["c"]
		}
		AssertEqual(2, Tokens.Count, "an old raw event lands on the shared marker")
		AssertEqual(2, Tokens["[PAGEUP]"])
		AssertEqual(1, Tokens["[DELETE]"])
	} finally {
		KLW.batch := SavedBatch
		KLW.ctx := SavedCtx
	}
}
Test("Keystats tokens: an older raw spelling lands on the shared marker (token-encoding)", _KTE_OldSpellingJoinsItsMarker)

; The last image of the old encoding is the rebuild's backup: renamed, once.
_KTE_PreEncodingImageIsKept() {
	Root := A_Temp . "\ergopti_token_backup_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	DirCreate(Root)
	Path := Root . "\klr_cache.sqlite", Backup := Path . KLR_PRE_ENCODING_BACKUP_SUFFIX
	try {
		FileAppend("old image", Path, "UTF-8-RAW")
		Observed := KLR_LedgerSnapshot(Path)
		AssertTrue(_KLR_CacheKeepPreEncodingImage(Path, "", Observed), "the old image moves aside")
		AssertFalse(FileExist(Path), "the rebuild starts from no image")
		AssertEqual("old image", FileRead(Backup, "UTF-8-RAW"))
		FileAppend("a later image", Path, "UTF-8-RAW")
		AssertFalse(_KLR_CacheKeepPreEncodingImage(Path, "", KLR_LedgerSnapshot(Path)), "a first backup is never replaced")
		AssertEqual("old image", FileRead(Backup, "UTF-8-RAW"))
		AssertFalse(_KLR_CacheKeepPreEncodingImage(Path, "", Observed), "a peer's newer image is not moved")
		AssertEqual("a later image", FileRead(Path, "UTF-8-RAW"))
	} finally {
		DirDelete(Root, true)
	}
}
Test("Keystats tokens: the rebuild keeps the old image as its one backup (token-encoding)", _KTE_PreEncodingImageIsKept)

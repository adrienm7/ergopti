; tests/meta/test_corpus_diagnostics.ahk

; ==============================================================================
; MODULE: Diagnostics Corpus Consumer (Windows / AHK)
; DESCRIPTION:
; Replays the shared diagnostics corpora against the AHK copies of the shared
; Lua logic, so both ports are held to the same golden vectors:
; 1. _shared/tests/corpus/healthcheck/errors_tail_vectors.json through
;    _HealthCheck_ParseErrorsTail (the window's recent issues), decoding the
;    raw bytes with the production tail decoder so a read cut inside a UTF-8
;    sequence is replayed as the file reader sees it.
; 2. _shared/tests/corpus/diagnostics/issue_link_vectors.json through
;    IssueLink_PercentEncode and IssueLink_BuildUrl (the prefilled GitHub issue
;    URL).
; Each corpus fails loudly when unreadable or empty: a replay over zero
; vectors would report success while checking nothing.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================
; =================================
; ======= 1/ Corpus Loading =======
; =================================
; =================================

; Reads and parses one shared corpus.
; @param Rel {String} Path under _shared\.
; @returns {Map}
_TCD_Corpus(Rel) {
	global _SharedDir
	Path := _SharedDir . "\" . Rel
	Assert(FileExist(Path), "corpus must exist: " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

; Builds the raw bytes a tail read returns: optional prefix bytes, then the
; chunk as UTF-8.
; @param PrefixHex {String}
; @param Chunk {String}
; @returns {String} The decoded text.
_TCD_DecodeRaw(PrefixHex, Chunk) {
	PrefixLen := StrLen(PrefixHex) // 2
	ChunkLen := StrPut(Chunk, "UTF-8") - 1
	Bytes := Buffer(Max(1, PrefixLen + ChunkLen))
	Loop PrefixLen
		NumPut("UChar", Integer("0x" . SubStr(PrefixHex, A_Index * 2 - 1, 2)), Bytes, A_Index - 1)
	if (ChunkLen > 0) {
		Scratch := Buffer(ChunkLen + 1)
		StrPut(Chunk, Scratch, "UTF-8")
		DllCall("RtlMoveMemory", "Ptr", Bytes.Ptr + PrefixLen, "Ptr", Scratch.Ptr, "UPtr", ChunkLen)
	}
	return _HealthCheck_DecodeTail(Bytes, PrefixLen + ChunkLen)
}





; ===================================
; ===================================
; ======= 2/ Errors-file Tail =======
; ===================================
; ===================================

_TCD_ErrorsTail() {
	Data := _TCD_Corpus("tests\corpus\healthcheck\errors_tail_vectors.json")
	Vectors := Data["vectors"]
	Assert(Vectors.Length >= 10, "the errors-tail corpus must hold its vectors")
	for Vector in Vectors {
		Input := Vector["input"]
		Text := _TCD_DecodeRaw(Input.Get("prefix_hex", ""), Input["chunk"])
		Got := _HealthCheck_ParseErrorsTail(Text, Input["at_file_start"], Input["max_entries"])
		Expected := Vector["expected"]
		AssertEqual(Expected.Length, Got.Length, Vector["id"] . ": entry count")
		for Index, Entry in Expected
			AssertEqual(Entry, Got[Index], Vector["id"] . ": entry " . Index)
	}
}

Test("corpus:diagnostics: errors-file tail vectors (errors-tail-corpus)", _TCD_ErrorsTail)





; ====================================
; ====================================
; ======= 3/ GitHub Issue Link =======
; ====================================
; ====================================

_TCD_IssueLink() {
	Data := _TCD_Corpus("tests\corpus\diagnostics\issue_link_vectors.json")
	Assert(Data["encode_vectors"].Length >= 5, "the issue-link corpus must hold its encoding vectors")
	Assert(Data["url_vectors"].Length >= 5, "the issue-link corpus must hold its URL vectors")
	for Vector in Data["encode_vectors"]
		AssertEqual(Vector["expected"], IssueLink_PercentEncode(Vector["input"]), Vector["id"])
	for Vector in Data["url_vectors"] {
		Templates := Data["templates"].Clone()
		Templates["max_url_bytes"] := Vector["max_url_bytes"]
		Build := IssueLink_BuildUrl.Bind(Templates, Data["repository"], Vector["template"], Vector["values"])
		if Vector.Has("expect_error") {
			AssertThrows(Build, Vector["id"] . ": an error was expected")
			continue
		}
		AssertEqual(Vector["expected"], Build.Call(), Vector["id"])
	}
}

Test("corpus:diagnostics: GitHub issue link vectors (issue-link-corpus)", _TCD_IssueLink)

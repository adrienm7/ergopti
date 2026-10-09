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
; 3. _shared/tests/corpus/diagnostics/redaction_vectors.json through
;    Redact_Apply with the rules of _shared/modules/diagnostics/redaction.json
;    (what leaves the machine).
; 4. _shared/tests/corpus/diagnostics/issue_report_vectors.json through
;    IssueReport_Dump and IssueReport_Markdown (the bug report text).
; 5. _shared/tests/corpus/healthcheck/action_vectors.json through
;    HealthCheck_ValidateAction (what the diagnostics page may ask its host to
;    do).
; 6. _shared/tests/corpus/diagnostics/error_policy_vectors.json through
;    ErrorPolicy_Validate, ErrorPolicy_Signature and ErrorPolicy_Decide (when
;    a logged ERROR opens the error window).
; 7. _shared/tests/corpus/diagnostics/error_report_vectors.json through
;    ErrorReport_Compose (the report the error window shows and sends).
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





; ============================
; ============================
; ======= 4/ Redaction =======
; ============================
; ============================

_TCD_Redaction() {
	Data := _TCD_Corpus("tests\corpus\diagnostics\redaction_vectors.json")
	Rules := _TCD_Corpus("modules\diagnostics\redaction.json")
	Assert(Data["vectors"].Length >= 10, "the redaction corpus must hold its vectors")
	for Vector in Data["vectors"]
		AssertEqual(Vector["expected"], Redact_Apply(Vector["input"], Rules, Vector["context"]), Vector["id"])
}

Test("corpus:diagnostics: redaction vectors (redaction-corpus)", _TCD_Redaction)





; ==================================
; ==================================
; ======= 5/ Bug Report Text =======
; ==================================
; ==================================

_TCD_IssueReport() {
	Data := _TCD_Corpus("tests\corpus\diagnostics\issue_report_vectors.json")
	for List in ["dump_vectors", "markdown_vectors"]
		Assert(Data[List].Length >= 2, "the bug-report corpus must hold its " . List)
	for Vector in Data["dump_vectors"]
		AssertEqual(Vector["expected"], IssueReport_Dump(Vector["input"]), Vector["id"])
	for Vector in Data["markdown_vectors"]
		AssertEqual(Vector["expected"], IssueReport_Markdown(Vector["info"], Vector["body"]), Vector["id"])
}

Test("corpus:diagnostics: bug report text vectors (issue-report-corpus)", _TCD_IssueReport)





; ===============================
; ===============================
; ======= 6/ Page Actions =======
; ===============================
; ===============================

; Asserts an accepted action carries exactly the expected values.
; @param Expected {Map}
; @param Actual {Any}
; @param Id {String} The vector's id, for the messages.
_TCD_AssertAction(Expected, Actual, Id) {
	Assert(Actual is Map, Id . ': the action must be a Map')
	for Key, Value in Expected {
		Assert(Actual.Has(Key), Id . ': the action lacks ' . Key)
		if (Value is Map) {
			Assert(Actual[Key] is Map, Id . ': ' . Key . ' must be a Map')
			for SubKey, SubValue in Value
				AssertEqual(SubValue, Actual[Key].Get(SubKey, ''), Id . ': ' . Key . '.' . SubKey)
			AssertEqual(Value.Count, Actual[Key].Count, Id . ': ' . Key . ' carries extra keys')
		} else {
			AssertEqual(Value, Actual[Key], Id . ': ' . Key)
		}
	}
	AssertEqual(Expected.Count, Actual.Count, Id . ': the action carries extra keys')
}

_TCD_PageActions() {
	Data := _TCD_Corpus("tests\corpus\healthcheck\action_vectors.json")
	Assert(Data['vectors'].Length >= 30, 'the page-actions corpus must hold its vectors')
	for Vector in Data['vectors'] {
		Context := Map('schema', Data['schema'], 'templates', Data['templates'], 'driver', Vector['driver'])
		Result := HealthCheck_ValidateAction(Vector['message'], Context)
		if Vector.Has('error') {
			Assert(!Result.Has('action'), Vector['id'] . ' must be refused')
			AssertEqual(Vector['error'], Result.Get('reason', ''), Vector['id'])
		} else {
			Assert(!Result.Has('reason'), Vector['id'] . ' must be accepted: ' . Result.Get('reason', ''))
			_TCD_AssertAction(Vector['expected'], Result['action'], Vector['id'])
		}
	}
}

Test('corpus:diagnostics: page action vectors (page-actions-corpus)', _TCD_PageActions)





; ======================================
; ======================================
; ======= 7/ Error Window Policy =======
; ======================================
; ======================================

_TCD_ErrorPolicy() {
	Data := _TCD_Corpus("tests\corpus\diagnostics\error_policy_vectors.json")
	Assert(Data["signature_vectors"].Length >= 5, "the error-policy corpus must hold its signature vectors")
	Assert(Data["scenarios"].Length >= 5, "the error-policy corpus must hold its scenarios")
	Assert(Data["invalid_policies"].Length >= 5, "the error-policy corpus must hold its invalid policies")

	; The shipped thresholds pass the same validation the drivers apply at load
	ErrorPolicy_Validate(_TCD_Corpus("modules\diagnostics\error_policy.json"))

	for Vector in Data["signature_vectors"]
		AssertEqual(Vector["expected"],
			ErrorPolicy_Signature(Map("signature_separator", Vector["separator"]), Vector["module"], Vector["template"]),
			Vector["id"])

	Scenarios := 0
	for Scenario in Data["scenarios"] {
		Policy := ErrorPolicy_Validate(Scenario["policy"])
		State := ErrorPolicy_NewState()
		for Index, Event in Scenario["events"]
			AssertEqual(Event["expected"], ErrorPolicy_Decide(State, Policy, Event)["verdict"],
				Scenario["id"] . " event " . Index)
		Scenarios += 1
	}
	AssertEqual(Data["scenarios"].Length, Scenarios, "every scenario must be replayed")

	for Vector in Data["invalid_policies"] {
		Refused := false
		try ErrorPolicy_Validate(Vector["policy"])
		catch ValueError
			Refused := true
		Assert(Refused, Vector["id"] . " must be refused")
	}
}

Test("corpus:diagnostics: error window policy vectors (error-policy-corpus)", _TCD_ErrorPolicy)





; ===============================
; ===============================
; ======= 8/ Error Report =======
; ===============================
; ===============================

_TCD_ErrorReport() {
	Data := _TCD_Corpus("tests\corpus\diagnostics\error_report_vectors.json")
	Assert(Data["vectors"].Length >= 3, "the error-report corpus must hold its vectors")
	Assert(Data["invalid_errors"].Length >= 3, "the error-report corpus must hold its invalid errors")
	for Vector in Data["vectors"] {
		Got := ErrorReport_Compose(Vector["error"], Vector["identity"])
		Expected := Vector["expected"]
		AssertEqual(Expected.Count, Got.Count, Vector["id"] . ": the report carries extra keys")
		AssertEqual(Expected["text"], Got["text"], Vector["id"] . ": text")
		for Id, Value in Expected["fields"]
			AssertEqual(Value, Got["fields"].Get(Id, ""), Vector["id"] . ": " . Id)
		AssertEqual(Expected["fields"].Count, Got["fields"].Count, Vector["id"] . ": the fields carry extra keys")
	}
	for Vector in Data["invalid_errors"]
		AssertThrows(ErrorReport_Compose.Bind(Vector["error"], Vector["identity"]), Vector["id"] . " must be refused")
}

Test("corpus:diagnostics: error window report vectors (error-report-corpus)", _TCD_ErrorReport)

; tests/unit/modules/updater/test_updater_release_list_budget.ahk

; ==============================================================================
; MODULE: Updater Release List Decode Budget Tests
; DESCRIPTION:
; The GitHub release list the updater receives is about 6 MB (100 releases of
; 39 assets each, every asset with its uploader, plus the author and the notes
; of every release). The update check reads two members of each release (its
; tag and publication time), yet it decoded the whole list into maps on the
; AutoHotkey thread, twice for a manual check and again on every 304: about
; 4 s during which the keyboard hook was frozen.
;
; ROOT CAUSE ENCODED:
; The list is validated whole but only the named members are built
; (JsonArrayObjectMembers), the two readers of one response share one index,
; and a conditional-GET entry keeps its index, so a 304 decodes nothing. The
; budget is counted, not timed: JsonDecodeTally counts the containers and the
; string code units the JSON owner builds, which the old full decode exceeds by
; two orders of magnitude on the GitHub-shaped list below. The equivalence
; cases prove the validating skip accepts and refuses exactly what JsonParse
; does, so no list is offered that the full decode would have refused.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===== 1/ A GitHub-shaped release list =====
; ===========================================

; One asset uploader or release author, as GitHub serializes a user.
_URLB_User(Id) {
	return '{"login":"github-actions[bot]","id":' . Id . ',"node_id":"MDM6Qm90NDE4OTgyODI=",'
		. '"avatar_url":"https://avatars.githubusercontent.com/in/15368?v=4","gravatar_id":"",'
		. '"url":"https://api.github.com/users/github-actions%5Bbot%5D","type":"Bot",'
		. '"user_view_type":"public","site_admin":false}'
}

; One release with Assets assets, an author, reactions and notes that carry
; escapes and a character above U+FFFF, the shapes that cost the most to skip.
_URLB_Release(Tag, Published, Assets) {
	Items := ""
	loop Assets {
		Items .= (A_Index > 1 ? "," : "")
			. '{"url":"https://api.github.com/repos/o/r/releases/assets/' . A_Index . '","id":' . (300000000 + A_Index)
			. ',"node_id":"RA_kwDOIiPc","name":"ErgoptiPlus-' . A_Index . '.zip","label":"","uploader":'
			. _URLB_User(41898282) . ',"content_type":"application/zip","state":"uploaded","size":' . (1000 * A_Index)
			. ',"digest":"sha256:0f3c","download_count":' . A_Index
			. ',"created_at":"2026-10-21T04:38:53Z","updated_at":"2026-10-21T04:38:54Z",'
			. '"browser_download_url":"https://github.com/o/r/releases/download/' . Tag . '/a' . A_Index . '.zip"}'
	}
	Notes := ""
	loop 40
		Notes .= '- Fixed item ' . A_Index . ' with \"quotes\" and a tab\t.\r\n'
	return '{"url":"https://api.github.com/repos/o/r/releases/1","html_url":"https://github.com/o/r/releases/tag/'
		. Tag . '","id":419165197,"author":' . _URLB_User(41898282) . ',"node_id":"RE_kwDOIiPc","tag_name":"'
		. Tag . '","target_commitish":"main","name":"' . Tag . '","draft":false,"immutable":false,'
		. '"prerelease":' . (InStr(Tag, "-") ? "true" : "false") . ',"created_at":"' . Published
		. '","published_at":"' . Published . '","assets":[' . Items . '],'
		. '"tarball_url":"https://api.github.com/repos/o/r/tarball/' . Tag . '","body":"## ' . Tag . ' '
		. Chr(0x1F389) . '\r\n' . Notes . '","reactions":{"url":"https://api.github.com/x","total_count":1,'
		. '"+1":1,"-1":0,"laugh":0,"hooray":0,"confused":0,"heart":0,"rocket":0,"eyes":0},"mentions_count":2}'
}

; Releases releases, indented with newlines the way GitHub answers.
_URLB_List(Releases, Assets) {
	List := "[`n"
	loop Releases {
		Tag := Mod(A_Index, 4) == 2 ? "v1.0." . (Releases - A_Index) : "v0.0.0-dev." . (200 - A_Index)
		List .= (A_Index > 1 ? ",`n" : "") . "  " . _URLB_Release(Tag,
			Format("2026-10-{:02}T04:38:53Z", 28 - Mod(A_Index, 27)), Assets)
	}
	return List . "`n]"
}

; The containers and string code units the JSON owner builds while Fn runs.
_URLB_Tally(Fn) {
	Before := JsonDecodeTally()
	Fn.Call()
	After := JsonDecodeTally()
	return Map("containers", After["containers"] - Before["containers"],
		"string_units", After["string_units"] - Before["string_units"])
}





; ======================================
; ===== 2/ The update check budget =====
; ======================================

; A manual check of a 40-release list decodes one members map per release and
; only the tag and date strings (with the keys of each release), once; the 304
; that follows decodes nothing. The full decode built about 120 containers per
; release, and did so twice.
_URLB_CheckDecodesOnlyWhatItReads() {
	global _UpdaterFetchCache, UPDATER_REQUEST_ORIGIN_MANUAL
	SavedCache := _UpdaterFetchCache
	try {
		_UpdaterFetchCache := Map()
		Releases := 40
		List := _URLB_List(Releases, 39)
		AssertTrue(StrLen(List) > 1000000, "the list must carry assets as heavy as the real ones")
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false, "main")
		Selected := ""
		Fresh := _URLB_Tally(() => Selected := _Updater_InterpretResponse(
			200, List, '"budget-etag"', "main", "test://release-list-budget", Request))
		AssertEqual("v1.0." . (Releases - 2), Updater_ParseTagName(Selected),
			"the channel's latest release must still be selected")
		AssertEqual(Releases, Fresh["containers"],
			"a fresh list must build one members map per release and nothing nested")
		AssertTrue(Fresh["string_units"] < Releases * 400,
			"only the tag, the date and the release keys may be decoded, not "
			. Fresh["string_units"] . " code units")
		Fields := _URLB_Tally(() => (Updater_ParseTagName(Selected), Updater_ParseBody(Selected),
			_Updater_ParsePublishedAt(Selected)))
		AssertEqual(3, Fields["containers"],
			"each field of the selected release must decode that member alone, not its assets")
		AssertTrue(_Updater_RequestOtherChannels(Request) is Array,
			"the other channels must still be read from the same index")
		Again := _URLB_Tally(() => Selected := _Updater_InterpretResponse(
			304, "", "", "main", "test://release-list-budget", Request))
		AssertEqual("v1.0." . (Releases - 2), Updater_ParseTagName(Selected),
			"a 304 must select the same release from the cached list")
		AssertEqual(0, Again["containers"], "a 304 must reuse the cached entry's index")
		AssertEqual(0, Again["string_units"], "a 304 must decode no string")
	} finally {
		_UpdaterFetchCache := SavedCache
	}
}
Test("updater: a release list check decodes only the members it reads (release-list-budget)",
	_URLB_CheckDecodesOnlyWhatItReads)

; The Versions window lists every release but decodes a release's notes only
; when they are read, and they read exactly what the full decode gave.
_URLB_ListedNotesDecodeOnRead() {
	List := _URLB_List(6, 39)
	Records := 0
	Listing := _URLB_Tally(() => Records := Updater_ParseReleasesList(List))
	AssertEqual(6, Records.Length, "every release must be listed")
	AssertEqual(6, Listing["containers"], "listing must not build the notes, assets or authors")
	Whole := JsonParse(List)
	for Index, Record in Records {
		AssertEqual(Whole[Index]["tag_name"], Record.Tag)
		AssertEqual(Whole[Index]["published_at"], Record.PublishedAt)
		AssertTrue(Record.HasProp("Body"), "a listed release must offer its notes")
		AssertEqual(Whole[Index]["body"], Record.Body, "the notes must decode exactly")
		AssertEqual(Whole[Index]["body"], Record.Body, "a second read must return the kept notes")
	}
}
Test("updater: listed releases decode their notes only when read (release-list-budget)",
	_URLB_ListedNotesDecodeOnRead)





; =================================================
; ===== 3/ Validating skip equals full decode =====
; =================================================

; Every document is accepted by JsonArrayObjectMembers exactly when JsonParse
; accepts it as an array of objects, and the selected members decode alike.
_URLB_SkipAcceptsWhatParseAccepts() {
	global JSON_MAX_NESTING_DEPTH
	Deep := ""
	loop JSON_MAX_NESTING_DEPTH - 3
		Deep .= "["
	DeepClose := StrReplace(Deep, "[", "]")
	Values := [
		'1', '-0', '0.5', '1e5', '-12.5E-3', '123456789012345678', '9223372036854775807',
		'9223372036854775808', '01', '1.', '.5', '+1', '1e', '--1', '1e999', 'true', 'false', 'null',
		'tru', 'nul', 'falsey', '""', '"a\"b\\c\/d\b\f\n\r\t"', '"é\u0000😀"',
		'"\uD800"', '"\uDC00"', '"\uD800A"', '"\uZZZZ"', '"\x"', '"' . Chr(1) . '"', '"a' . Chr(0) . 'b"',
		'"' . Chr(0xD800) . '"', '"x' . Chr(0xD800) . '"', '"' . Chr(0xDC00) . 'y"', '"' . Chr(0x1F389) . '"',
		'"tick' . Chr(0x60) . '"', '"del' . Chr(0x7F) . '"', '"unterminated', '{}', '[]', '{ }', '[ ]',
		'{"a":1}', '{"a":1,}', '[1,]', '[,1]', '{"a" 1}', '{"a":}', '{1:2}', '{"a":1 "b":2}',
		'{"a":{"b":{"c":[1,{"d":null}]}}}', '[{"x":[{"y":{"z":"w"}}]}]', '{"k\u0000":1}', '{"\u0000":1}',
		'{"k":{"\u0000":1}}', '[[[[{"deep":[1,2,{"e":"f"}]}]]]]', Deep . "1" . DeepClose,
		Deep . "[[1]]" . DeepClose, Deep . "[[[1]]]" . DeepClose, '{"a":[1,2,3,{"b":"c"},[4]]}',
		'{"a":"b"' , '[1', '{"a":[', '"\u12', '{"a":1}}', '[1]]', ' { "a" : [ 1 , 2 ] } ']
	Failures := []
	for Value in Values {
		for Document in ['[{"tag_name":"v1","x":' . Value . '}]', '[{"x":' . Value . ',"tag_name":"v1"}]',
			'[{"tag_name":' . Value . '}]', '[' . Value . ']', '[{"tag_name":"v1"},' . Value . ']'] {
			Expected := ""
			try {
				Whole := JsonParse(Document)
				Expected := "accept"
				for Element in Whole
					if !(Element is Map)
						Expected := "refuse"
			} catch {
				Expected := "refuse"
			}
			Got := ""
			try {
				Spans := JsonArrayObjectMembers(Document, ["tag_name"])
				Got := "accept"
			} catch {
				Got := "refuse"
			}
			if (Got != Expected) {
				Failures.Push(Expected . " but " . Got . ": " . Document)
				continue
			}
			if (Got == "accept") {
				for Index, Span in Spans {
					WholeTag := Whole[Index].Get("tag_name", "<absent>")
					Tag := Span["members"].Get("tag_name", "<absent>")
					if (Type(WholeTag) != Type(Tag) || (!IsObject(Tag) && Tag !== WholeTag))
						Failures.Push("member differs: " . Document)
					if (SubStr(Document, Span["start"], Span["length"]) == "")
						Failures.Push("empty span: " . Document)
				}
			}
		}
	}
	AssertEqual(0, Failures.Length, "the validating skip must equal JsonParse; first: "
		. (Failures.Length ? Failures[1] : ""))
}
Test("JSON: selected members accept and refuse exactly what JsonParse does (release-list-budget)",
	_URLB_SkipAcceptsWhatParseAccepts)

; The skip fast path reads a lone surrogate as the code unit it is: with one
; anywhere in the text, a quote after a lone high surrogate still ends its
; string, and the members after it are read, not swallowed.
_URLB_LoneSurrogateNeverSwallowsAQuote() {
	Lone := Chr(0xD800)
	Document := '[{"x":"a' . Lone . '","tag_name":"v2","y":{"z":"' . Lone . '"}}]'
	Spans := JsonArrayObjectMembers(Document, ["tag_name"])
	AssertEqual("v2", Spans[1]["members"]["tag_name"], "the tag after a lone surrogate must be read")
	AssertEqual(StrLen(Document) - 2, Spans[1]["length"], "the span must end at its own closing brace")
	Pair := '[{"x":"' . Chr(0x1F389) . '","tag_name":"v3"}]'
	AssertEqual("v3", JsonArrayObjectMembers(Pair, ["tag_name"])[1]["members"]["tag_name"])
}
Test("JSON: a lone surrogate never hides the members after it (release-list-budget)",
	_URLB_LoneSurrogateNeverSwallowsAQuote)

; The single-object form decodes the named members of one release only.
_URLB_ObjectMembers() {
	Release := _URLB_Release("v1.2.3", "2026-10-21T04:38:53Z", 39)
	Picked := 0
	Count := _URLB_Tally(() => Picked := JsonObjectMembers(Release, ["tag_name", "draft"]))
	AssertEqual("v1.2.3", Picked["tag_name"])
	AssertEqual(false, Picked["draft"])
	AssertEqual(2, Picked.Count, "only the named members are returned")
	AssertEqual(1, Count["containers"], "one members map, nothing nested")
	AssertThrows(() => JsonObjectMembers(Release . "x", ["tag_name"]), "trailing data must be refused")
	AssertThrows(() => JsonObjectMembers("[1]", ["tag_name"]), "a non-object root must be refused")
}
Test("JSON: one object decodes only its named members (release-list-budget)", _URLB_ObjectMembers)

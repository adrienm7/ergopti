; infra/issue_link.ahk

; ==============================================================================
; MODULE: GitHub Issue Link Builder
; DESCRIPTION:
; AHK port of _shared/ui/issue_link.js: builds the prefilled "new issue" URL
; of the repository's GitHub issue forms, bounded to the byte budget of
; _shared/modules/diagnostics/issue_templates.json.
;
; FEATURES & RATIONALE:
; 1. Pure: the caller passes the templates document and the repository read
;    from _shared/modules/updater/defaults.json, so neither is typed here.
; 2. The budget is measured on the percent-encoded string, where an accented
;    letter costs 6 bytes and an emoji 12.
; 3. An oversized prefill is cut, never refused: the last parameter first, at
;    a whole code point, ending with the truncation marker; a parameter that
;    cannot keep one code point is dropped; the title goes last and the
;    template never.
; 4. The JS original and the Lua port replay the same vectors:
;    _shared/tests/corpus/diagnostics/issue_link_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Percent-encoding =======
; ===================================
; ===================================

; Splits a string into code points: a surrogate pair is one code point, and a
; lone surrogate becomes U+FFFD because it has no UTF-8 form.
; @param Text {String}
; @returns {Array} Array of Maps { char, code }.
_IssueLink_CodePoints(Text) {
	static REPLACEMENT := 0xFFFD
	Out := []
	Len := StrLen(Text)
	Index := 1
	while (Index <= Len) {
		Code := Ord(SubStr(Text, Index, 1))
		if (Code >= 0xD800 && Code <= 0xDBFF && Index < Len) {
			Low := Ord(SubStr(Text, Index + 1, 1))
			if (Low >= 0xDC00 && Low <= 0xDFFF) {
				Out.Push(Map("char", SubStr(Text, Index, 2),
					"code", 0x10000 + ((Code - 0xD800) << 10) + (Low - 0xDC00)))
				Index += 2
				continue
			}
		}
		if (Code >= 0xD800 && Code <= 0xDFFF)
			Out.Push(Map("char", Chr(REPLACEMENT), "code", REPLACEMENT))
		else
			Out.Push(Map("char", SubStr(Text, Index, 1), "code", Code))
		Index += 1
	}
	return Out
}

; Percent-encodes one code point; only RFC 3986 unreserved characters stay.
; @param Code {Integer} Unicode code point.
; @returns {String}
_IssueLink_EncodeCodePoint(Code) {
	if ((Code >= 0x41 && Code <= 0x5A) || (Code >= 0x61 && Code <= 0x7A)
		|| (Code >= 0x30 && Code <= 0x39) || Code = 0x2D || Code = 0x2E
		|| Code = 0x5F || Code = 0x7E)
		return Chr(Code)
	if (Code < 0x80)
		Bytes := [Code]
	else if (Code < 0x800)
		Bytes := [0xC0 | (Code >> 6), 0x80 | (Code & 0x3F)]
	else if (Code < 0x10000)
		Bytes := [0xE0 | (Code >> 12), 0x80 | ((Code >> 6) & 0x3F), 0x80 | (Code & 0x3F)]
	else
		Bytes := [0xF0 | (Code >> 18), 0x80 | ((Code >> 12) & 0x3F),
			0x80 | ((Code >> 6) & 0x3F), 0x80 | (Code & 0x3F)]
	Out := ""
	for Byte in Bytes
		Out .= Format("%{:02X}", Byte)
	return Out
}

; Percent-encodes a query value as UTF-8, only unreserved characters literal.
; @param Text {String}
; @returns {String}
IssueLink_PercentEncode(Text) {
	Out := ""
	for Point in _IssueLink_CodePoints(String(Text))
		Out .= _IssueLink_EncodeCodePoint(Point["code"])
	return Out
}





; ================================
; ================================
; ======= 2/ The Issue URL =======
; ================================
; ================================

; Joins the parameters behind the base URL.
; @param Base {String}
; @param Params {Array} Array of [key, value] arrays.
; @returns {String}
_IssueLink_JoinUrl(Base, Params) {
	Query := ""
	for Index, Pair in Params
		Query .= (Index > 1 ? "&" : "") . Pair[1] . "=" . IssueLink_PercentEncode(Pair[2])
	return Base . "?" . Query
}

; Cuts one value so its encoded form fits Budget bytes with the marker.
; @param Value {String}
; @param Budget {Integer} Encoded bytes the value may take, marker included.
; @param Marker {String}
; @returns {String} The cut value, or "" when not one code point fits.
_IssueLink_CutValue(Value, Budget, Marker) {
	Room := Budget - StrLen(IssueLink_PercentEncode(Marker))
	Points := _IssueLink_CodePoints(Value)
	Kept := ""
	Used := 0
	; Strictly shorter than the value: a cut that keeps everything is no cut
	Loop Points.Length - 1 {
		Cost := StrLen(_IssueLink_EncodeCodePoint(Points[A_Index]["code"]))
		if (Used + Cost > Room)
			break
		Kept .= Points[A_Index]["char"]
		Used += Cost
	}
	return (Kept == "") ? "" : Kept . Marker
}

; Builds the prefilled issue URL.
; @param Templates {Map} The parsed issue_templates.json document.
; @param Repository {Map} { owner, repo } from the updater defaults.json.
; @param TemplateId {String} Key of Templates["templates"] ("bug", "feature").
; @param Values {Map} Title and field values by id.
; @returns {String} The URL, at most Templates["max_url_bytes"] long.
; @throws {Error} On an unknown template, a malformed repository, or a URL that
;   cannot fit at all.
IssueLink_BuildUrl(Templates, Repository, TemplateId, Values) {
	if !(Templates is Map) || !Templates.Has("templates") || !Templates["templates"].Has(TemplateId)
		throw ValueError("issue_link: unknown template '" . TemplateId . "'.")
	if !(Repository is Map) || Repository.Get("owner", "") == "" || Repository.Get("repo", "") == ""
		throw ValueError("issue_link: the repository needs an owner and a repo.")
	Template := Templates["templates"][TemplateId]
	Max := Templates["max_url_bytes"]
	Marker := Templates["truncation_marker"]
	Base := Templates["issue_new_url"]
	if !InStr(Base, "{owner}", true) || !InStr(Base, "{repo}", true)
		throw ValueError("issue_link: issue_new_url must contain {owner} and {repo}.")
	Base := StrReplace(Base, "{owner}", Repository["owner"], true, , 1)
	Base := StrReplace(Base, "{repo}", Repository["repo"], true, , 1)

	Params := [["template", Template["file"]]]
	Title := Values.Get("title", "")
	if (Title != "")
		Params.Push(["title", Template["title_prefix"] . Title])
	for Id in Template["fields"] {
		Value := Values.Get(Id, "")
		if (Value != "")
			Params.Push([Id, String(Value)])
	}

	Index := Params.Length
	while (Index >= 2) {
		Over := StrLen(_IssueLink_JoinUrl(Base, Params)) - Max
		if (Over <= 0)
			break
		Cut := _IssueLink_CutValue(Params[Index][2],
			StrLen(IssueLink_PercentEncode(Params[Index][2])) - Over, Marker)
		if (Cut == "") {
			Params.RemoveAt(Index)
		} else {
			Params[Index] := [Params[Index][1], Cut]
			break
		}
		Index -= 1
	}

	Url := _IssueLink_JoinUrl(Base, Params)
	if (StrLen(Url) > Max)
		throw Error("issue_link: " . StrLen(Url) . " bytes left after every cut, budget " . Max . ".")
	return Url
}

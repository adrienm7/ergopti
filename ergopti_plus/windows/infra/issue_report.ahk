; infra/issue_report.ahk

; ==============================================================================
; MODULE: Bug Report Text
; DESCRIPTION:
; AHK port of _shared/lua/diagnostics/issue_report.lua: the full diagnostics
; as Markdown, copied to the clipboard and prefilled into the GitHub issue
; form. Both ports replay
; _shared/tests/corpus/diagnostics/issue_report_vectors.json.
;
; FEATURES & RATIONALE:
; 1. IssueReport_Dump writes every field of a diagnostic snapshot, keys
;    sorted, so the report is complete and deterministic.
; 2. The whole report is prefilled: GitHub answers 414 a little above 8 KB,
;    so the issue link cuts it to its budget, and the clipboard keeps it
;    whole.
; 3. Nothing here redacts: the caller redacts the finished text with
;    Redact_Apply, the single place that decides what leaves the machine.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Snapshot Dump =======
; ================================
; ================================

; Renders a scalar: integral numbers without a fraction, others with two
; decimals, as the Lua port does.
; @param Value {Any}
; @returns {String}
_IssueReport_Scalar(Value) {
	static EMPTY_STRING := "(empty)"
	if (Value is Integer)
		return String(Value)
	if (Value is Float)
		return (Value = Floor(Value)) ? Format("{:d}", Value) : Format("{:.2f}", Value)
	Text := String(Value)
	return (Text == "") ? EMPTY_STRING : Text
}

; The map's keys, sorted by code unit (the order Lua's string comparison gives
; to ASCII keys).
; @param Value {Map}
; @returns {Array}
_IssueReport_SortedKeys(Value) {
	Keys := []
	for Key in Value
		Keys.Push(String(Key))
	Loop Keys.Length - 1 {
		Outer := A_Index + 1
		Current := Keys[Outer]
		Index := Outer - 1
		while (Index >= 1 && StrCompare(Keys[Index], Current, true) > 0) {
			Keys[Index + 1] := Keys[Index]
			Index -= 1
		}
		Keys[Index + 1] := Current
	}
	return Keys
}

; Appends one labelled value, recursing into maps and arrays.
; @param Lines {Array} Output lines.
; @param Indent {String}
; @param Label {String} "key:" or "-".
; @param Value {Any}
_IssueReport_Emit(Lines, Indent, Label, Value) {
	static EMPTY_TABLE := "(none)"
	if (Value is Map || Value is Array) {
		Count := (Value is Map) ? Value.Count : Value.Length
		if (Count == 0) {
			Lines.Push(Indent . Label . " " . EMPTY_TABLE)
			return
		}
		Lines.Push(Indent . Label)
		if (Value is Array) {
			for Item in Value
				_IssueReport_Emit(Lines, Indent . "  ", "-", Item)
		} else {
			for Key in _IssueReport_SortedKeys(Value)
				_IssueReport_Emit(Lines, Indent . "  ", Key . ":", Value[Key])
		}
		return
	}
	Text := StrReplace(_IssueReport_Scalar(Value), "`r`n", "`n")
	for Index, Line in StrSplit(Text, "`n") {
		if (Index == 1)
			Lines.Push(Indent . Label . " " . Line)
		else
			Lines.Push(Indent . "  " . Line)
	}
}

; Writes every field of a snapshot, keys sorted, one per line.
; @param Snapshot {Map}
; @returns {String}
IssueReport_Dump(Snapshot) {
	if !(Snapshot is Map)
		throw TypeError("issue_report: the snapshot must be a Map.")
	Lines := []
	for Key in _IssueReport_SortedKeys(Snapshot)
		_IssueReport_Emit(Lines, "", Key . ":", Snapshot[Key])
	return _IssueReport_Join(Lines, "`n")
}





; ==================================
; ==================================
; ======= 2/ Markdown Report =======
; ==================================
; ==================================

; Joins an array of strings.
_IssueReport_Join(Parts, Separator) {
	Out := ""
	for Index, Part in Parts
		Out .= (Index > 1 ? Separator : "") . Part
	return Out
}

; Escapes a Markdown table cell.
_IssueReport_Cell(Value) {
	Text := RegExReplace(String(Value), "[\r\n]+", " ")
	return StrReplace(Text, "|", "\|")
}

; A code fence longer than every backtick run in the text.
_IssueReport_Fence(Text) {
	Longest := 0
	Pos := 1
	while (Found := RegExMatch(Text, '``+', &Match, Pos)) {
		Longest := Max(Longest, Match.Len)
		Pos := Found + Match.Len
	}
	Fence := ""
	Loop Max(3, Longest + 1)
		Fence .= '``'
	return Fence
}

; The full report, as a Markdown document.
; @param Info {Map} { version, commit, os, driver, generated_utc, warn_count, err_count }
; @param Body {String} The dumped snapshot.
; @returns {String}
IssueReport_Markdown(Info, Body) {
	Fence := _IssueReport_Fence(Body)
	return _IssueReport_Join([
		"# ErgoptiPlus diagnostics",
		"",
		"| Field | Value |",
		"| --- | --- |",
		"| Version | " . _IssueReport_Cell(Info["version"]) . " |",
		"| Commit | " . _IssueReport_Cell(Info.Get("commit", "")) . " |",
		"| OS | " . _IssueReport_Cell(Info["os"]) . " |",
		"| Driver | " . _IssueReport_Cell(Info["driver"]) . " |",
		"| Generated (UTC) | " . _IssueReport_Cell(Info["generated_utc"]) . " |",
		"| Warnings / errors this session | " . _IssueReport_Scalar(Info["warn_count"])
			. " / " . _IssueReport_Scalar(Info["err_count"]) . " |",
		"",
		Fence . "text",
		Body,
		Fence,
		""
	], "`n")
}

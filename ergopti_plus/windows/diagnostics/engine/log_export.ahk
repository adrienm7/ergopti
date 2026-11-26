; diagnostics/engine/log_export.ahk

; ==============================================================================
; MODULE: Log Export Selection and Scrub (Windows)
; DESCRIPTION:
; The pure half of « Export the logs (zip) »: which files of the logs folders
; enter the archive, the archive's name, and the copy of each entry without the
; user's typed text. The AutoHotkey port of
; _shared/core/logger/engine/log_export.lua, replaying the same shared vectors
; (_shared/tests/corpus/logger/log_export_vectors.json). The I/O lives in
; diagnostics/ui/log_export.ahk.
;
; FEATURES & RATIONALE:
; 1. One daily log is the only log (maintainer decision, 2026-11-25): the
;    archive holds the daily logs and errors mirrors of the last N days, the
;    bootstrap log written before the logger starts and the crash reports, and
;    nothing else in the folder, a user file or a retired topical file.
; 2. The scrub rules are generated (_generated/log_export_data.ahk) from
;    _shared/core/logger/data/log_export.toml, the runtime port of
;    tools/dev/field-log-scrub.py: plain markers, so the three drivers withhold
;    exactly the same text, and a bundled trigger is withheld too.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Selection ==========
; ===============================
; ===============================

; The calendar dates of the export window, newest first.
; @param Today {String} "yyyy-MM-dd".
; @param Days {Integer} Whole days, today included.
; @returns {Array} "yyyy-MM-dd" strings.
LogExport_WindowDates(Today, Days) {
	if !(Today is String) || !RegExMatch(Today, "^(\d{4})-(\d{2})-(\d{2})$", &Parts)
		throw ValueError("LogExport_WindowDates: today must be yyyy-MM-dd.", -1, Today is String ? Today : Type(Today))
	if !(Days is Integer) || Days < 1
		throw ValueError("LogExport_WindowDates: days must be a positive whole number.", -1, String(Days))
	; Noon anchor, as the Lua port: a DST change never moves the date.
	Anchor := Parts[1] . Parts[2] . Parts[3] . "120000"
	if FormatTime(Anchor, "yyyy-MM-dd") != Today
		throw ValueError("LogExport_WindowDates: today is not a calendar date.", -1, Today)
	Dates := []
	loop Days
		Dates.Push(FormatTime(DateAdd(Anchor, -(A_Index - 1), "Days"), "yyyy-MM-dd"))
	return Dates
}

; Indexes a list of names.
_LogExport_SetOf(Names) {
	Set := Map()
	Set.CaseSense := true
	for Name in Names
		Set[Name] := true
	return Set
}

; Selects the files of the archive.
; @param Listing {Map} "today" (yyyy-MM-dd), optional "days" (defaults to the
;   generated archive days), "logs" (names of the regular files directly in the
;   logs folder), "default" (the same for the default logs folder, where the
;   bootstrap log is written) and "crash_reports" (names in <logs>\crash_reports).
; @returns {Array} Maps { folder: "logs"|"default"|"crash_reports", name, archive },
;   sorted by archive name.
LogExport_Select(Listing) {
	if !(Listing is Map)
		throw TypeError("LogExport_Select: the listing must be a Map.", -1, Type(Listing))
	if Listing.Get("platform", "ahk") != "ahk"
		throw ValueError("LogExport_Select: the Windows port selects for ahk only.", -1, String(Listing["platform"]))
	Data := LogExportData()
	Logs := _LogExport_SetOf(Listing.Get("logs", []))
	Default := _LogExport_SetOf(Listing.Get("default", []))
	Selected := []
	for Date in LogExport_WindowDates(Listing["today"], Listing.Get("days", Data["days"])) {
		for Prefix in [AppDirsLogUnifiedPrefix(), AppDirsLogErrorsPrefix()] {
			Name := Prefix . Date . AppDirsLogExtension()
			if Logs.Has(Name)
				Selected.Push(Map("folder", "logs", "name", Name, "archive", Name))
		}
	}
	; The only file Windows writes where the logger cannot: before it starts.
	Bootstrap := AppDirsLogBootstrapName()
	if Default.Has(Bootstrap)
		Selected.Push(Map("folder", "default", "name", Bootstrap, "archive", Bootstrap))
	Extension := Data["crash_report_extension"]
	for Name in Listing.Get("crash_reports", []) {
		if StrLen(Name) > StrLen(Extension) && SubStr(Name, -StrLen(Extension)) == Extension
			&& SubStr(Name, 1, 1) != "." && !InStr(Name, "/") && !InStr(Name, "\")
			Selected.Push(Map("folder", "crash_reports", "name", Name,
				"archive", AppDirsCrashReportsDir() . "/" . Name))
	}
	; Insertion sort on the ordinal archive name, the Lua port's byte order.
	loop Selected.Length - 1 {
		Index := A_Index + 1
		Entry := Selected[Index]
		Position := Index - 1
		while Position >= 1 && StrCompare(Selected[Position]["archive"], Entry["archive"], true) > 0 {
			Selected[Position + 1] := Selected[Position]
			Position -= 1
		}
		Selected[Position + 1] := Entry
	}
	return Selected
}

; The archive's file name.
; @param Stamp {String} YYYYMMDDHH24MISS, the export instant.
; @returns {String}
LogExport_ArchiveName(Stamp) {
	if !(Stamp is String) || !RegExMatch(Stamp, "^\d{14}$")
		throw ValueError("LogExport_ArchiveName: the stamp must be YYYYMMDDHH24MISS.", -1, String(Stamp))
	Data := LogExportData()
	return Data["name_prefix"] . FormatTime(Stamp, "yyyy-MM-dd_HH-mm-ss") . Data["extension"]
}




; ===============================
; ===============================
; ======= 2/ Scrub ==============
; ===============================
; ===============================

; Whether a line starts a record (a timestamp or a "=====" banner).
_LogExport_StartsRecord(Line) {
	return RegExMatch(Line, "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}") || SubStr(Line, 1, 5) == "====="
}

; One line without the user's typed text.
; @param Line {String}
; @param &Withheld {Boolean} Set to true when the line was rewritten.
; @returns {String}
LogExport_ScrubLine(Line, &Withheld := false) {
	Data := LogExportData()
	for Rule in Data["rules"] {
		Found := InStr(Line, Rule["marker"], true)
		if !Found
			continue
		Keep := Found + StrLen(Rule["marker"]) - 1
		if (Rule["cut"] != "") {
			CutAt := InStr(Line, Rule["cut"], true, Keep + 1)
			if CutAt
				Keep := CutAt + StrLen(Rule["cut"]) - 1
		}
		Withheld := true
		return SubStr(Line, 1, Keep) . Data["withheld"]
	}
	Withheld := false
	return Line
}

; A whole file without the user's typed text: LF line endings, no BOM, and
; the continuation lines of a withheld record dropped.
; @param Text {String} File contents.
; @returns {String}
LogExport_ScrubText(Text) {
	if !(Text is String)
		throw TypeError("LogExport_ScrubText: text must be a string.", -1, Type(Text))
	if SubStr(Text, 1, 1) == Chr(0xFEFF)
		Text := SubStr(Text, 2)
	Text := StrReplace(Text, "`r`n", "`n")
	Out := []
	Dropping := false
	for Line in StrSplit(Text, "`n") {
		if Dropping && !_LogExport_StartsRecord(Line)
			continue
		Out.Push(LogExport_ScrubLine(Line, &Dropping))
	}
	; The split yields one empty line after a final newline; drop only that one.
	if SubStr(Text, -1) == "`n" && Out.Length > 0 && Out[Out.Length] == ""
		Out.Pop()
	Result := ""
	for Line in Out
		Result .= Line . "`n"
	return Result
}

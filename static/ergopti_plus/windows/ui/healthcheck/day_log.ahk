; ui/healthcheck/day_log.ahk

; ==============================================================================
; MODULE: Healthcheck / Day Log Attachment
; DESCRIPTION:
; AHK port of _shared/lua/diagnostics/day_log.lua plus this driver's thin part:
; reads today's complete log, redacts it line by line and keeps the result for
; the report actions. The attachment is opt-in: the page asks for it, shows the
; preview this module returns, and the Save and Report actions write the file
; next to the report only when the user ticked the box. Nothing is uploaded by
; the product; the user attaches the saved file by hand on GitHub.
;
; FEATURES & RATIONALE:
; 1. A day, not a tail: the whole file is redacted, line by line, with the
;    rules of redaction.json (the same ones the logger applies when it writes,
;    plus the configuration directory names).
; 2. A refusal is a result, never a silent truncation: over the cap the page
;    gets the reason and both sizes, and nothing is attached.
; 3. The text lives here, never in the snapshot the page receives: the snapshot
;    carries only the closed record (included, bytes, lines).
; 4. Both ports replay _shared/tests/corpus/diagnostics/day_log_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ The Collector =======
; ================================
; ================================

; Validates the parsed day_log.json.
; @param Limits {Map}
; @returns {Map} The same map.
DayLog_CheckLimits(Limits) {
	if !(Limits is Map)
		throw TypeError("day_log: the limits must be the parsed day_log.json.")
	for Key in ["max_bytes", "preview_head_lines", "preview_tail_lines", "preview_line_max_chars"] {
		if !Limits.Has(Key) || !(Limits[Key] is Integer) || Limits[Key] < 1
			throw ValueError("day_log: " . Key . " must be a positive integer.")
	}
	return Limits
}

; Cuts a line to MaxChars code points, marking the cut.
; @param Line {String}
; @param MaxChars {Integer}
; @returns {String}
_DayLog_Cut(Line, MaxChars) {
	Count := 0
	Kept := 0
	Loop Parse Line {
		Code := Ord(A_LoopField)
		if !(Code >= 0xDC00 && Code <= 0xDFFF)
			Count += 1
		if (Count > MaxChars)
			return SubStr(Line, 1, Kept) . Chr(0x2026)
		Kept += 1
	}
	return Line
}

; Redacts and measures today's log.
; @param Raw {String} The file's text; "" only when FileSize is over the cap.
; @param FileSize {Integer} The file's size in bytes.
; @param Rules {Map} Parsed redaction.json.
; @param Context {Map} Redaction context { home, user, config_dir, case_insensitive }.
; @param Limits {Map} Parsed day_log.json.
; @returns {Map} { ok: false, reason: "empty"|"too_large", bytes, cap_bytes } or
;   { ok: true, text, bytes, lines, first_time, last_time, head, tail, cap_bytes }
DayLog_Collect(Raw, FileSize, Rules, Context, Limits) {
	DayLog_CheckLimits(Limits)
	Cap := Limits["max_bytes"]
	if !(FileSize is Integer) || FileSize < 0
		throw ValueError("day_log: the file size is unknown.")
	if (FileSize > Cap)
		return Map("ok", false, "reason", "too_large", "bytes", FileSize, "cap_bytes", Cap)
	if !(Raw is String)
		throw TypeError("day_log: the log text is missing.")
	if (SubStr(Raw, 1, 1) == Chr(0xFEFF))
		Raw := SubStr(Raw, 2)
	Raw := StrReplace(Raw, "`r`n", "`n")
	if (Raw == "")
		return Map("ok", false, "reason", "empty", "bytes", 0, "cap_bytes", Cap)
	if (SubStr(Raw, -1) != "`n")
		Raw .= "`n"
	Lines := []
	FirstTime := "", LastTime := ""
	Text := ""
	for Line in StrSplit(SubStr(Raw, 1, -1), "`n") {
		Clean := Redact_Apply(Line, Rules, Context)
		Lines.Push(Clean)
		Text .= Clean . "`n"
		if RegExMatch(Clean, "^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", &Stamp) {
			if (FirstTime == "")
				FirstTime := Stamp[1]
			LastTime := Stamp[1]
		}
	}
	Bytes := StrPut(Text, "UTF-8") - 1
	if (Bytes > Cap)
		return Map("ok", false, "reason", "too_large", "bytes", Bytes, "cap_bytes", Cap)
	HeadCount := Limits["preview_head_lines"], TailCount := Limits["preview_tail_lines"]
	if (Lines.Length <= HeadCount + TailCount) {
		HeadCount := Lines.Length
		TailCount := 0
	}
	Head := [], Tail := []
	PreviewMax := Limits["preview_line_max_chars"]
	Loop HeadCount
		Head.Push(_DayLog_Cut(Lines[A_Index], PreviewMax))
	Loop TailCount
		Tail.Push(_DayLog_Cut(Lines[Lines.Length - TailCount + A_Index], PreviewMax))
	return Map("ok", true, "text", Text, "bytes", Bytes, "lines", Lines.Length, "first_time", FirstTime,
		"last_time", LastTime, "head", Head, "tail", Tail, "cap_bytes", Cap)
}





; =============================
; =============================
; ======= 2/ The Driver =======
; =============================
; =============================

; The retained collection: the redacted text of the snapshot it was prepared
; for. One slot; a new snapshot or an unticked box drops it.
; @returns {Map} { snapshot, result }
_DayLog_State() {
	static State := Map("snapshot", 0, "result", 0)
	return State
}

; Reads today's log file as the logger names it. A file over the cap is
; measured, never read.
; @param Cap {Integer} The most bytes worth reading.
; @returns {Map} { found: Boolean, size, text }
_DayLog_ReadToday(Cap) {
	; Lines still queued in memory reach the file before it is read
	try _LoggerFlush(true)
	Path := LoggerTodayLogPath()
	if (Path == "" || !FileExist(Path))
		return Map("found", false, "size", 0, "text", "")
	Size := FileGetSize(Path)
	return Map("found", true, "size", Size, "text", (Size > Cap) ? "" : FileRead(Path, "UTF-8"))
}

; The page's answer for a collection result.
; @param Result {Map} From DayLog_Collect, or { ok: false, reason: "missing" }.
; @returns {Map}
_DayLog_Reply(Result) {
	Reply := Map("type", "action", "action", "day_log", "ok", true)
	if !Result["ok"] {
		Reply["state"] := Result["reason"]
		Reply["bytes"] := Result.Get("bytes", 0)
		Reply["cap_bytes"] := Result.Get("cap_bytes", 0)
		return Reply
	}
	Reply["state"] := "ready"
	for Key in ["bytes", "lines", "cap_bytes", "first_time", "last_time", "head", "tail"]
		Reply[Key] := Result[Key]
	return Reply
}

; Drops the retained collection and the record in the snapshot.
; @param Snapshot {Map}
HealthCheck_DayLogDiscard(Snapshot) {
	State := _DayLog_State()
	State["snapshot"] := 0
	State["result"] := 0
	if (Snapshot is Map && Snapshot.Has("day_log_attachment"))
		Snapshot.Delete("day_log_attachment")
}

; Collects today's log for the snapshot on screen and retains it.
; @param Snapshot {Map} The window's snapshot; receives the closed record.
; @param Config {Map} From HealthCheck_Config().
; @param Context {Map} The redaction context.
; @param Reader {Func|Integer} Replaces the file read (tests only): takes the
;   cap and returns the Map _DayLog_ReadToday returns; 0 for production.
; @returns {Map} The page's answer.
HealthCheck_DayLogPrepare(Snapshot, Config, Context, Reader := 0) {
	LoggerStart("HealthCheckDayLog", "Collecting today's log for the report…")
	HealthCheck_DayLogDiscard(Snapshot)
	Limits := Config["day_log"]
	File := (Reader is Func) ? Reader.Call(Limits["max_bytes"]) : _DayLog_ReadToday(Limits["max_bytes"])
	if !File["found"] {
		LoggerWarn("HealthCheckDayLog", "Today's log does not exist yet; nothing to attach.")
		return _DayLog_Reply(Map("ok", false, "reason", "missing"))
	}
	Result := DayLog_Collect(File["text"], File["size"], Config["redaction"], Context, Limits)
	if !Result["ok"] {
		LoggerWarn("HealthCheckDayLog", "Today's log is not attachable: {1} ({2} of {3} bytes).",
			Result["reason"], Result["bytes"], Result["cap_bytes"])
		return _DayLog_Reply(Result)
	}
	State := _DayLog_State()
	State["snapshot"] := Snapshot
	State["result"] := Result
	Snapshot["day_log_attachment"] := Map("included", true, "bytes", Result["bytes"], "lines", Result["lines"])
	LoggerSuccess("HealthCheckDayLog", "Today's log is ready: {1} lines, {2} bytes.", Result["lines"], Result["bytes"])
	return _DayLog_Reply(Result)
}

; The retained collection of a snapshot.
; @param Snapshot {Map}
; @returns {Map|Integer} The collection, or 0 when none was prepared for it.
HealthCheck_DayLogRetained(Snapshot) {
	State := _DayLog_State()
	if (State["result"] is Map && State["snapshot"] == Snapshot && Snapshot.Has("day_log_attachment"))
		return State["result"]
	return 0
}

; The attachment's file name, from the report's identity.
; @param Config {Map}
; @param Safe {Map} The shareable snapshot.
; @returns {String}
HealthCheck_DayLogName(Config, Safe) {
	Limits := Config["day_log"]
	return Limits["name_prefix"] . Safe["driver"] . "-"
		. RegExReplace(Safe.Get("generated_at", "unknown"), "[^A-Za-z0-9_.-]", "_") . Limits["name_suffix"]
}

; diagnostics/ui/healthcheck/report.ahk

; ==============================================================================
; MODULE: Healthcheck / Exports And GitHub Forms
; DESCRIPTION:
; What the diagnostics page's buttons do on this machine once
; HealthCheck_ValidateAction accepted them: copy the report, save it as a
; Markdown file under the logs folder and select it in Explorer, report it on
; GitHub (copy, save and reveal its attachment, then open the bug template) and open
; a folder. Also the Debug menu's "Report a bug", which runs that same report
; action on a fresh snapshot without the window, and "Suggest a feature".
;
; FEATURES & RATIONALE:
; 1. Shared output is rebuilt from the host snapshot through a closed typed
;    policy. Free text, paths and unknown fields are excluded regardless of
;    the page or details checkbox. Only approved technical content leaves.
; 2. The clipboard and attachment hold the complete approved report.
;    GitHub receives stable host version, OS and driver metadata. Editable
;    fields stay out of the URL; the browser opens after attachment reveal.
; 3. Paths come from the snapshot the host collected, by field id; a folder
;    that does not exist yet is created before it is opened; a file that does
;    not exist yet (today's errors file before the day's first warning) is
;    said to the page, not logged as a failure.
; 4. Side effects are one Map so a test can observe each of them; the browser
;    opens last, after the clipboard holds what it asks for, and nothing
;    follows it that could take the focus back.
; ==============================================================================

#Requires AutoHotkey v2.0

; The opt-in redacted copy of today's log the report actions may save
#Include day_log.ahk

/**
 * Projects one configuration row {setting, type, value}. A value outside the
 * grammar of its type drops the whole row: an enum is a bare identifier, a text
 * or a list only a count, so a path or a sentence matches none of them.
 */
_HCShare_SettingRow(Value) {
	if !(Value is Map)
		return 0
	Setting := Value.Get("setting", 0), Kind := Value.Get("type", 0), Text := Value.Get("value", 0)
	if !(Setting is String) || !(Kind is String) || !(Text is String) || StrLen(Setting) > 96
		|| !RegExMatch(Setting, "^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$")
		return 0
	switch Kind {
		case "boolean": Fits := Text == "true" || Text == "false"
		case "number": Fits := StrLen(Text) <= 24 && RegExMatch(Text, "i)^-?\d[\d.]*e?[+-]?\d*$") && IsNumber(Text)
			&& Abs(Number(Text)) < 1.7e308
		case "enum": Fits := RegExMatch(Text, "^[A-Za-z0-9_+-]{1,40}$")
		case "text", "list": Fits := RegExMatch(Text, "^\d{1,6}$")
		default: Fits := false
	}
	return Fits ? Map("setting", Setting, "type", Kind, "value", Text) : 0
}

/** Projects only typed fields declared in the canonical sharing policy. */
_HCShare_Project(Value, Rule, &Present) {
	Present := true
	Kind := Rule["kind"]
	if !InStr("|object|array|enum|boolean|number|integer|version|hash|utc|commit|runtime|platform_name|setting_row|", "|" . Kind . "|")
		throw Error("An unknown diagnostic sharing rule was refused.")
	if Kind == "object" {
		Result := Map()
		if !(Value is Map)
			return Result
		for Key, Child in Rule["fields"] {
			if !Value.Has(Key) && !Child.Has("default")
				continue
			Projected := _HCShare_Project(Value.Get(Key, 0), Child, &HasValue)
			if HasValue
				Result[Key] := Projected
		}
		return Result
	}
	if Kind == "array" {
		Result := []
		if Value is Array
			for Item in Value {
				if Rule.Has("max_items") && Result.Length >= Rule["max_items"]
					break
				Kept := _HCShare_Project(Item, Rule["item"], &HasValue)
				if HasValue
					Result.Push(Kept)
			}
		return Result
	}
	if Kind == "setting_row" {
		Row := _HCShare_SettingRow(Value)
		Present := Row is Map
		return Row
	}
	if Kind == "enum" {
		if Value is String
			for Accepted in Rule["values"]
				if Value == Accepted
					return Value
		if Rule.Has("default")
			return Rule["default"]
	} else {
		if Kind == "boolean" && Value is Integer && (Value == 0 || Value == 1)
			return Value
		if (Kind == "number" || Kind == "integer") && Value is Number
			&& Abs(Value) <= 9007199254740991 && (!Rule.Has("minimum") || Value >= Rule["minimum"])
			&& (!Rule.Has("maximum") || Value <= Rule["maximum"]) && (Kind != "integer" || Value == Floor(Value))
			return Value
		if Value is String {
			if Kind == "commit" && RegExMatch(Value, "^([a-fA-F0-9]{7,64})(?: \((?:build|git)\))?$", &Binding)
				return Binding[1]
			if Kind == "runtime" {
				for Prefix in Rule["prefixes"]
					for Suffix in Rule["suffixes"] {
						if !(SubStr(Value, 1, StrLen(Prefix)) == Prefix) || (Suffix != "" && !(SubStr(Value, -StrLen(Suffix)) == Suffix))
							continue
						Version := SubStr(Value, StrLen(Prefix) + 1, StrLen(Value) - StrLen(Prefix) - StrLen(Suffix))
						Projected := _HCShare_Project(Version, Map("kind", "version"), &HasValue)
						if HasValue
							return Projected
					}
			}
			; An operating system or desktop name from the host: one of the rule's known
			; families, then a closed set of name characters. A path, an address, a
			; sentence or a name that is not listed never matches.
			if Kind == "platform_name" && StrLen(Value) <= 64 {
				for Family in Rule["families"] {
					Rest := SubStr(Value, StrLen(Family) + 1)
					if StrLower(SubStr(Value, 1, StrLen(Family))) == StrLower(Family)
						&& RegExMatch(Rest, "D)^[A-Za-z0-9 .+/:(),!-]*$") && !RegExMatch(Rest, "^[A-Za-z]")
						return Value
				}
			}
			if Kind == "version" && RegExMatch(Value, "^\d+(?:\.\d+){1,3}(?:-dev\.\d+|-beta\d+)?$")
				return Value
			if Kind == "hash" && RegExMatch(Value, "^[a-fA-F0-9]{7,64}$")
				return Value
			if Kind == "utc" && RegExMatch(Value, "^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?Z$")
				return Value
		}
	}
	Present := false
	return 0
}

/** Classifies known technical messages without exporting their text or claiming cause. */
HealthCheck_RecentErrorFacts(Entries, Source, Schema) {
	Observed := Entries is Array, Events := [], Count := 0, Specs := Schema["recent_error_facts"]
	if Observed {
		for Index, Entry in Entries {
			Count += 1
			First := Entry is String ? StrSplit(Entry, ["`r", "`n"])[1] : ""
			Start := InStr(First, Specs["owner_prefix"], true)
			Marker := Start ? InStr(First, Specs["failure_marker"], true, Start + StrLen(Specs["owner_prefix"])) : 0
			Reason := Marker ? SubStr(First, Marker + StrLen(Specs["failure_marker"])) : ""
			for Rule in Specs["rules"] {
				Event := 0, Candidate := Reason
				if Rule.Has("message_prefix") {
					Position := InStr(First, Rule["message_prefix"], true)
					Candidate := Position ? SubStr(First, Position) : ""
					if Rule.Has("number_marker") {
						NumberAt := InStr(Candidate, Rule["number_marker"], true, StrLen(Rule["message_prefix"]) + 1)
						Candidate := NumberAt ? SubStr(Candidate, NumberAt) : ""
					}
				}
				if Rule.Has("literal") && Candidate == Rule["literal"]
					Event := Map("entry_index", Index, "code", Rule["code"])
				else if Rule.Has("prefix") && SubStr(Candidate, 1, StrLen(Rule["prefix"])) == Rule["prefix"] {
					Value := SubStr(Candidate, StrLen(Rule["prefix"]) + 1)
					if Rule["suffix"] != "" {
						Finish := InStr(Value, Rule["suffix"], true)
						Value := Finish ? SubStr(Value, 1, Finish - 1) : ""
					}
					if StrLen(Value) <= 11 && Value != "-0" && RegExMatch(Value, "^-?(?:0|[1-9]\d*)$") {
						ValueNumber := _HCShare_Project(Number(Value), Map("kind", "integer", "minimum", Rule["minimum"], "maximum", Rule["maximum"]), &Present)
						if Present
							Event := Map("entry_index", Index, "code", Rule["code"], Rule["field"], ValueNumber)
					}
				}
				if Event is Map {
					Events.Push(Event)
					break
				}
			}
		}
	}
	return Map("observed", Observed, "source", Source == "errors_file" || Source == "ring" ? Source : "unavailable",
		"qualification", "log_observation_only", "examined_entries", Count, "excluded_entries", Count - Events.Length, "events", Events)
}

/**
 * Returns a detached technical projection; unknown fields cannot be shared.
 * The day log record (included, bytes, lines) is part of it only when the
 * action that saves the attachment asks for it.
 */
HealthCheck_ShareSnapshot(Snapshot, Schema, WithDayLog := false) {
	Policy := Schema.Get("share_policy", 0)
	if !(Policy is Map) || Policy.Get("version", 0) != 1 || !(Snapshot is Map)
		throw Error("The diagnostic sharing policy is unavailable.")
	Driver := Snapshot.Get("driver", "")
	if !(Driver == "windows" || Driver == "macos" || Driver == "linux")
		throw Error("The diagnostic sharing identity is unavailable.")
	Safe := _HCShare_Project(Snapshot, Policy["projection"], &Present)
	if !WithDayLog && Safe.Has("day_log_attachment")
		Safe.Delete("day_log_attachment")
	if WithDayLog && !Safe.Has("day_log_attachment")
		throw Error("The day log was asked for but the snapshot holds no record of it.")
	Sections := Snapshot.Get("sections", 0)
	Issues := Sections is Map ? Sections.Get("issues", 0) : 0
	if Issues is Map
		Safe["sections"]["issues"]["recent_error_facts"] := HealthCheck_RecentErrorFacts(Issues.Get("recent", 0), Issues.Get("recent_source", "unavailable"), Schema)
	return Safe
}

/** Rebuilds only schema-owned installed-page records, without native authority. */
HealthCheck_PageChecks(Results, Schema) {
	if !(Results is Map)
		return false
	Accepted := Map(), Expected := Map()
	for Spec in Schema["diagnostic_checks"]["items"] {
		Id := Spec["id"], Expected[Id] := true, Row := Results.Get(Id, 0)
		if !(Row is Map) || !(Row.Get("scope", "") == Spec["scope"])
			return false
		for Key in Row
			if !(Key == "state" || Key == "scope" || Key == "reason" || Key == "ms")
				return false
		Rule := Schema["share_policy"]["projection"]["fields"]["page_check_observations"]["fields"]["results"]["fields"][Id]
		Clean := _HCShare_Project(Row, Rule, &Present)
		if !Clean.Has("state") || !Clean.Has("scope")
			return false
		for Key in ["state", "scope", "reason", "ms"]
			if Clean.Has(Key) != Row.Has(Key) || (Row.Has(Key) && !(Clean[Key] == Row[Key]))
				return false
		State := Row.Get("state", "")
		if Spec.Has("reason") {
			if !(State == "not_run") || !(Row.Get("reason", "") == Spec["reason"]) || Row.Has("ms")
				return false
		} else if State == "ok" || State == "error" {
			if !Row.Has("ms") || (Row.Has("reason") && !(Row["reason"] == "invalid_diagnostic_model"))
				return false
		} else if Row.Has("ms") || (State == "cancelled" ? Row.Has("reason") : !(Row.Get("reason", "") == "opt_in_required"))
			return false
		Accepted[Id] := Clean
	}
	for Id in Results
		if !Expected.Has(Id)
			return false
	return Map("source", "installed_page_reported", "qualification", "unqualified", "results", Accepted)
}

/** Retains page observations only on the exact host report generation. */
HealthCheck_CapturePageChecks(Snapshot, Action) {
	if !Action.Has("page_check_observations")
		return true
	if !(Action["generated_at"] == Snapshot["generated_at"]) || Action["snapshot_revision"] != Snapshot.Get("export_revision", 0)
		return false
	Snapshot["page_check_observations"] := Action["page_check_observations"]
	return true
}


/**
 * The operating-system name a driver is shown as: the issue form's Driver
 * dropdown option and the report's Driver line; an unknown driver stays as is.
 */
_HCShare_OsName(Driver) {
	static OS_NAMES := Map("macos", "macOS", "windows", "Windows", "linux", "Linux")
	return OS_NAMES.Get(Driver, Driver)
}

/** The keys of a Map, sorted case-sensitively as the Lua and JS ports sort them. */
_HCShare_SortedKeys(Value) {
	Keys := ""
	for Key in Value
		Keys .= Key . "`n"
	Sorted := []
	for Key in StrSplit(RTrim(Sort(Keys, "C"), "`n"), "`n")
		if Key != ""
			Sorted.Push(Key)
	return Sorted
}

/** A number as the three ports print it: an integer bare, else at most two decimals. */
_HCShare_Number(Value) {
	if Value is Integer
		return String(Value)
	if Value == Floor(Value)
		return String(Integer(Value))
	return RegExReplace(RegExReplace(Format("{:.2f}", Value), "0+$"), "\.$")
}

/** A section field's scalar by its schema type: units for sizes and durations, yes or no for a boolean. */
_HCShare_FieldText(Schema, Value, Kind) {
	if Kind == "bool"
		return _HCShare_English(Schema, Value ? "healthcheck.value.yes" : "healthcheck.value.no")
	if !(Value is Number)
		return String(Value)
	switch Kind {
		case "bytes": return Format("{:d} MB", Floor(Value / 1048576 + 0.5))
		case "percent": return _HCShare_Number(Value) . " %"
		case "seconds": return _HCShare_Number(Value) . " s"
		case "ms": return _HCShare_Number(Value) . " ms"
	}
	return _HCShare_Number(Value)
}

/** The `key=value` facts of a record in the given key order: "" or " (k=v, k=v)". */
_HCShare_Facts(Record, Keys) {
	Parts := ""
	for Key in Keys {
		if !Record.Has(Key)
			continue
		Value := Record[Key]
		Parts .= (Parts == "" ? "" : ", ") . Key . "=" . (Value is Number ? _HCShare_Number(Value) : String(Value))
	}
	return Parts == "" ? "" : " (" . Parts . ")"
}

/** Appends one group: its heading, its lines (fenced for identifiers), a blank line. */
_HCShare_Group(Out, Title, Lines, Fenced := false) {
	static Fence := Chr(96) . Chr(96) . Chr(96)
	if !Lines.Length
		return
	Out.Push("## " . Title)
	if Fenced
		Out.Push(Fence)
	for Line in Lines
		Out.Push(Line)
	if Fenced
		Out.Push(Fence)
	Out.Push("")
}

/** The labelled scalar fields of one section, in the schema's field order. */
_HCShare_FieldLines(Schema, Spec, Data) {
	Lines := []
	if !(Data is Map)
		return Lines
	for Field in Spec.Get("fields", []) {
		Id := Field["id"]
		if !Data.Has(Id) || Data[Id] is Map || Data[Id] is Array
			continue
		Lines.Push(_HCShare_English(Schema, "healthcheck.field." . Id) . ": "
			. _HCShare_FieldText(Schema, Data[Id], Field.Get("type", "")))
	}
	return Lines
}

/**
 * Formats only detached approved leaves as readable English lines, grouped in
 * the order of share_policy.report_order, most useful first: when the issue
 * link cuts the report, the least useful part goes. Port of share.lua's
 * readable(); both replay report_vectors.json byte for byte.
 */
_HCShare_Readable(Safe, Schema) {
	; The probe facts shown after the state; the hashes and deep-test
	; provenance stay in the JSON block of the complete report
	static PROBE_FACTS := ["detail", "cleanup", "native_status", "ms"]
	static PAGE_CHECK_FACTS := ["reason", "ms"]
	Sections := Safe.Get("sections", Map())
	Specs := Map()
	for Section in Schema["sections"]
		Specs[Section["id"]] := Section
	L := (Key) => _HCShare_English(Schema, Key)
	YesNo := (Value) => L(Value ? "healthcheck.value.yes" : "healthcheck.value.no")
	Out := []
	for Id in Schema["share_policy"]["report_order"] {
		Lines := []
		switch Id {
			case "issues":
				Lines := _HCShare_FieldLines(Schema, Specs["issues"], Sections.Get("issues", 0))
				Recent := Sections.Get("issues", Map()).Get("recent_error_facts", 0)
				if (Recent is Map) && Recent.Has("examined_entries") {
					; An unread source is no count: "0" would say the log held no error
					Lines.Push(L("healthcheck.export.recent_errors_read") . ": " . (Recent.Get("observed", false)
						? _HCShare_Number(Recent["examined_entries"]) . " (" . L("healthcheck.recent_source." . Recent["source"]) . ")"
						: L("healthcheck.value.unknown")))
					for Event in Recent.Get("events", []) {
						Keys := []
						for Key in _HCShare_SortedKeys(Event)
							if Key != "code" && Key != "entry_index"
								Keys.Push(Key)
						Lines.Push(L("healthcheck.export.recognised_error") . ": " . Event["code"] . _HCShare_Facts(Event, Keys))
					}
				}
				; The maintainer's ask of 2026-11-24: a report without DEBUG lines says how to get them
				Developer := Sections.Get("developer", 0)
				; config-key-literal-ok: the report field, named like the menu row
				if (Developer is Map) && Developer.Has("detailed_log") && !Developer["detailed_log"]
					Lines.Push(L("healthcheck.export.detailed_log_off"))
				_HCShare_Group(Out, L("healthcheck.section.issues"), Lines)
			case "checks":
				Probes := Safe.Get("probes", Map())
				for ProbeId in _HCShare_SortedKeys(Probes) {
					Probe := Probes[ProbeId]
					Shown := []
					for Key in PROBE_FACTS
						if !(Key == "cleanup" && Probe.Get("cleanup", "") == "settled")
							Shown.Push(Key)
					Lines.Push(ProbeId . ": " . Probe.Get("state", "") . _HCShare_Facts(Probe, Shown))
				}
				Pages := Safe.Get("page_check_observations", Map()).Get("results", Map())
				for PageId in _HCShare_SortedKeys(Pages)
					Lines.Push("page." . PageId . ": " . Pages[PageId].Get("state", "") . _HCShare_Facts(Pages[PageId], PAGE_CHECK_FACTS))
				Retired := Safe.Get("retired_probes", [])
				if (Retired is Array) && Retired.Length
					Lines.Push("retired_runs: " . Retired.Length)
				_HCShare_Group(Out, L("healthcheck.export.checks"), Lines, true)
			case "permissions":
				for Item in Sections.Get("permissions", Map()).Get("items", [])
					Lines.Push(L("healthcheck.permission." . Item["id"]) . ": " . Item["state"])
				_HCShare_Group(Out, L("healthcheck.section.permissions"), Lines)
			case "configuration_files":
				for Item in Sections.Get("configuration_files", Map()).Get("items", [])
					Lines.Push(L("healthcheck.config_file." . Item["id"]) . ": " . L("healthcheck.config_state." . Item["state"]))
				_HCShare_Group(Out, L("healthcheck.section.configuration_files"), Lines)
			case "report":
				Lines.Push(L("healthcheck.export.driver") . ": " . _HCShare_OsName(Safe["driver"]))
				if Safe.Has("generated_at")
					Lines.Push(L("healthcheck.export.generated") . ": " . Safe["generated_at"])
				if Safe.Has("schema_version")
					Lines.Push(L("healthcheck.export.schema") . ": " . _HCShare_Number(Safe["schema_version"]))
				if Safe.Has("detailed")
					Lines.Push(L("healthcheck.export.details") . ": " . YesNo(Safe["detailed"]))
				if Safe.Has("extensive")
					Lines.Push(L("healthcheck.export.extensive") . ": " . YesNo(Safe["extensive"]))
				DayLog := Safe.Get("day_log_attachment", 0)
				if (DayLog is Map) && DayLog.Has("included")
					Lines.Push(L("healthcheck.export.day_log") . ": " . YesNo(DayLog["included"]) . _HCShare_Facts(DayLog, ["bytes", "lines"]))
				_HCShare_Group(Out, L("healthcheck.export.report"), Lines)
			case "configuration":
				; Until the configuration probe answers, an empty list would claim
				; no setting was changed
				Probe := Safe.Get("probes", Map()).Get("configuration", 0)
				if (Probe is Map) && Probe.Get("state", "") != "ok" {
					_HCShare_Group(Out, L("healthcheck.export.changed_settings"), [L("healthcheck.value.unknown")])
					continue
				}
				for Item in Sections.Get("configuration", Map()).Get("items", []) {
					Value := Item["value"]
					if Item["type"] == "text"
						Value .= " " . L("healthcheck.export.characters")
					else if Item["type"] == "list"
						Value .= " " . L("healthcheck.export.items")
					Lines.Push(Item["setting"] . " = " . Value)
				}
				if !Lines.Length {
					_HCShare_Group(Out, L("healthcheck.export.changed_settings"), [L("healthcheck.value.none")])
					continue
				}
				_HCShare_Group(Out, L("healthcheck.export.changed_settings"), Lines, true)
			default:
				if !Specs.Has(Id)
					throw Error("report_order names an unknown section: " . Id)
				_HCShare_Group(Out, L("healthcheck.section." . Id), _HCShare_FieldLines(Schema, Specs[Id], Sections.Get(Id, 0)))
		}
	}
	Text := ""
	for Index, Line in Out
		Text .= (Index == 1 ? "" : "`n") . Line
	return Text
}

/** Resolves an export label without changing or falling back to UI locale. */
_HCShare_English(Schema, Key) {
	Strings := Schema.Get("export_strings", 0)
	if !(Strings is Map) || !Strings.Has(Key) || !(Strings[Key] is String) || Strings[Key] == ""
		throw Error("English export label unavailable: " . Key)
	return Strings[Key]
}

/**
 * The version the issue form shows. A source run has no release version (the
 * host reports "local"), so it is named by its commit: a true statement, where
 * "unknown" would be false.
 */
_HCShare_FormVersion(Safe, Snapshot) {
	Versions := Safe.Get("sections", Map()).Get("versions", Map())
	if Versions.Has("ergopti_version")
		return Versions["ergopti_version"]
	Raw := (Snapshot is Map && Snapshot.Get("sections", 0) is Map) ? Snapshot["sections"].Get("versions", Map()) : Map()
	RawCommit := Raw.Get("commit", "")
	FromGit := (RawCommit is String) && RegExMatch(RawCommit, " \(git\)$")
	if Raw.Get("ergopti_version", "") == "local" || FromGit
		return "dev source" . (Versions.Has("commit") ? " " . Versions["commit"] : "")
	return "unknown"
}

/**
 * The operating system the issue form shows: the name and version the host
 * reported, then the desktop, the session and the architecture when known.
 */
_HCShare_FormOs(Safe) {
	static SESSION_NAMES := Map("wayland", "Wayland", "x11", "X11")
	Sections := Safe.Get("sections", Map())
	System := Sections.Get("system", Map())
	Details := []
	if System.Has("desktop")
		Details.Push(System["desktop"])
	if System.Has("display_server") && SESSION_NAMES.Has(System["display_server"])
		Details.Push(SESSION_NAMES[System["display_server"]])
	Arch := Sections.Get("hardware", Map()).Get("arch", "unknown")
	if Arch != "unknown"
		Details.Push(Arch)
	Name := System.Has("os") ? System["os"] : _HCShare_OsName(Safe["driver"]) . " (version unknown)"
	Joined := ""
	for Detail in Details
		Joined .= (Joined == "" ? "" : ", ") . Detail
	return Name . (Joined == "" ? "" : " (" . Joined . ")")
}

/** Builds file and issue-form content only from the host-retained snapshot. */
HealthCheck_ShareDocument(Snapshot, Schema, WithDayLog := false) {
	Safe := HealthCheck_ShareSnapshot(Snapshot, Schema, WithDayLog)
	Versions := Safe.Get("sections", Map()).Get("versions", Map())
	Fence := Chr(96) . Chr(96) . Chr(96)
	Head := "# ErgoptiPlus diagnostics`n`n" . _HCShare_English(Schema, Schema["share_policy"]["notice_key"])
		. "`n`n" . _HCShare_Readable(Safe, Schema)
	Text := Head . "`n" . Fence . "json`n" . _HC_ValueToJson(Safe) . "`n" . Fence . "`n"
	Name := Schema["report"]["name_prefix"] . Safe["driver"] . "-"
		. RegExReplace(Safe.Get("generated_at", "unknown"), "[^A-Za-z0-9_.-]", "_") . Schema["report"]["name_suffix"]
	Summary := "A diagnostic attachment was saved locally. Attach that file here after reviewing it; no attachment is uploaded automatically.`n"
		. "Driver: " . Safe["driver"] . "`nVersion: " . Versions.Get("ergopti_version", "unknown")
		. "`nCommit: " . Versions.Get("commit", "unknown") . "`nDriver suites: NOT_RUN"
	return Map("snapshot", Safe, "text", Text, "name", Name, "summary", Summary,
		"fields", Map("driver", _HCShare_OsName(Safe["driver"]), "version", _HCShare_FormVersion(Safe, Snapshot),
			"os", _HCShare_FormOs(Safe), "diagnostics", Head),
		"notes", Map("diagnostics", _HCShare_English(Schema, Schema["share_policy"]["truncated_note_key"])))
}


; The path fields that name a folder: created when missing, then opened
global HC_FOLDER_IDS := Map("config_dir", true, "logs_dir", true, "crash_dir", true, "diagnostics_dir", true,
	"app_dir", true)





; ===============================
; ===============================
; ======= 1/ Side Effects =======
; ===============================
; ===============================

; Saves the report in Dir, creating the folder when it is missing.
; @param WriterFn {Func|Integer} Optional durable native writer for fault coverage.
; @returns {String} The saved file's path.
; @throws {Error} When the folder or the file cannot be written.
_HCReport_Save(Dir, Name, Text, WriterFn := 0) {
	DirCreate(Dir)
	if !(WriterFn is Integer && WriterFn == 0) && !HasMethod(WriterFn, "Call")
		throw TypeError("The diagnostics attachment writer must be callable or zero.")
	ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWriteCreateNewDurable
	SplitPath(Name, , , &Ext, &Stem)
	Suffix := Ext == "" ? "" : "." . Ext
	Loop 1000 {
		Index := A_Index - 1
		Path := Dir . "\" . Stem . (Index == 0 ? "" : "-" . Index) . Suffix
		Written := ResolvedWriter.Call(Path, Text)
		if (Written is Integer) && Written == 1
			return Path
		if Written != "exists"
			throw Error("The complete diagnostics attachment could not be written.")
	}
	throw Error("No unused diagnostics attachment name remains.")
}

; Starts a command line through the shell's file associations.
; @param CommandLine {String}
; @returns {Boolean} False when it could not be started (logged).
_HCReport_Start(CommandLine) {
	try {
		Run(CommandLine)
	} catch as Err {
		LoggerWarn("HealthCheckReport", "{1} could not be started: {2}", CommandLine, Err.Message)
		return false
	}
	return true
}

; Selects the saved report in Explorer.
; @returns {Boolean} False when Explorer could not be started.
_HCReport_Reveal(Path) {
	return _HCReport_Start(ShellRunner_SystemProgramCommand("explorer.exe", '/select,"' . Path . '"'))
}

; Opens a folder in Explorer, or a file with its default program.
; @returns {Boolean}
_HCReport_Open(Path) {
	return _HCReport_Start(InStr(FileExist(Path), "D") ? ShellRunner_SystemProgramCommand("explorer.exe", '"' . Path . '"') : '"' . Path . '"')
}

; Shows a system notification through the notifier adapter.
_HCReport_Notify(Title, Body, Kind) {
	NotifierSend(Body, Map("title", Title, "level", Kind))
	return true
}

; What identifies this machine in paths: the profile folder, the account name
; and the configuration directory, whose folder and file names are chosen by
; the user.
; @returns {Map} { home, user, config_dir } (config_dir is "" before boot knows it)
_HCReport_Identity() {
	global _ConfigDir
	return Map("home", EnvGet("USERPROFILE"), "user", A_UserName,
		"config_dir", IsSet(_ConfigDir) ? RTrim(_ConfigDir, "\") : "")
}

; The production side effects; a test replaces any of them.
; @param Overrides {Map|Integer} Replacement effects, or 0.
; @returns {Map}
_HCReport_Effects(Overrides := 0) {
	Effects := Map(
		"copy",     CB_Write,
		"save",     _HCReport_Save,
		"reveal",   _HCReport_Reveal,
		"make_dir", (Dir) => (DirCreate(Dir), true),
		"exists",   (Path) => FileExist(Path) != "",
		"open",     _HCReport_Open,
		"open_url", ExternalUrl_OpenHttp,
		"notify",   _HCReport_Notify,
		"identity", _HCReport_Identity)
	if (Overrides is Map) {
		for Name, Fn in Overrides
			Effects[Name] := Fn
	}
	return Effects
}

; What identifies this machine in paths and text, for redaction. Windows paths
; compare case-insensitively.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Map} { home, user, config_dir, case_insensitive }
HealthCheck_RedactionContext(Overrides := 0) {
	Identity := _HCReport_Effects(Overrides)["identity"].Call()
	; Without the profile folder nothing would remove it, and every path under
	; it would be published
	if (Identity["home"] == "")
		throw Error("The profile folder is unknown, so nothing could be redacted.")
	return Map("home", Identity["home"], "user", Identity["user"],
		"config_dir", Identity.Get("config_dir", ""), "case_insensitive", true)
}





; ===============================
; ===============================
; ======= 2/ Page Actions =======
; ===============================
; ===============================

; Saves the report under the diagnostics folder and selects it in Explorer.
; @returns {String} The saved file's path.
_HCReport_SaveAndReveal(Effects, Paths, Name, Text, LogFile := 0) {
	if !Paths.Has("diagnostics_dir")
		throw Error("The diagnostics folder is unknown.")
	; The opt-in day log first, so the report is the file Explorer selects last
	if (LogFile is Map)
		Effects["save"].Call(Paths["diagnostics_dir"], LogFile["name"], LogFile["text"])
	Path := Effects["save"].Call(Paths["diagnostics_dir"], Name, Text)
	if !Effects["reveal"].Call(Path)
		LoggerWarn("HealthCheckReport", "The saved report could not be selected in Explorer.")
	return Path
}

; Reports on GitHub: copies and saves the complete approved report, then
; reveals its local attachment before opening the bug form with the host
; version, OS and driver fields and the compact report (tables, no JSON block),
; cut to the URL budget with a note that the complete report is on the
; clipboard and in the saved file. The browser opens last and no attachment is
; uploaded automatically.
; @param Action {Map} Host-approved report text and technical identity fields.
; @throws {Error} When clipboard, attachment completion or browser opening refuses.
_HCReport_Report(Effects, Config, Action, Rules, Context, Paths) {
	Text := Action["text"]
	; Copy the complete approved report independently of its compact URL form
	if !Effects["copy"].Call(Text)
		throw Error("The clipboard refused the report.")
	; The complete approved document stays in a local attachment; the URL carries its compact form.
	Path := _HCReport_SaveAndReveal(Effects, Paths, Action["name"], Text, Action.Get("day_log_file", 0))
	Fields := Map()
	ReportField := Config["templates"]["templates"]["bug"]["report_field"]
	if !(ReportField is String) || ReportField == ""
		throw Error("The bug template names no report field.")
	; The host-derived identity and the compact report; the budget cuts the report.
	for Id in ["version", "os", "driver", ReportField]
		Fields[Id] := Action["fields"][Id]
	Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "bug", Fields, Action.Get("notes", 0))
	if !Effects["open_url"].Call(Url)
		throw Error("The browser could not be opened.")
	return Path
}

; Performs one action of the diagnostics page, already validated.
; @param Action {Map} From HealthCheck_ValidateAction (copy, save, report, open_path).
; @param Paths {Map} The snapshot's paths section.
; @param Config {Map} From HealthCheck_Config().
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Map} { ok: Boolean, path?: String, missing?: true }
HealthCheck_PerformAction(Action, Paths, Config, Overrides := 0, Snapshot := 0) {
	Name := Action["action"]
	LoggerStart("HealthCheckReport", "Diagnostics action '{1}'…", Name)
	Effects := _HCReport_Effects(Overrides)
	Outcome := Map("ok", true)
	; A file not created yet, such as today's errors file before the day's
	; first warning: nothing to open, and no failure of ours
	Missing := ""
	try {
		Context := HealthCheck_RedactionContext(Overrides)
		Rules := Config["redaction"]
		if Name == "copy" || Name == "save" || Name == "report" {
			; The opt-in day log is written by save and report only, and only
			; from the collection prepared for this very snapshot
			WithLog := Action.Get("day_log", false) ? true : false
			if WithLog && Name == "copy"
				throw Error("The day log is saved with the report, never copied.")
			Document := HealthCheck_ShareDocument(Snapshot, Config["schema"], WithLog)
			if !Action.Has("text") || !(Action["text"] == Document["text"])
				throw Error("The diagnostic sharing preview is stale or invalid.")
			Action := Action.Clone()
			if WithLog {
				Retained := HealthCheck_DayLogRetained(Snapshot)
				if !(Retained is Map)
					throw Error("The day log was not prepared for this report.")
				Action["day_log_file"] := Map("name", HealthCheck_DayLogName(Config, Document["snapshot"]),
					"text", Retained["text"])
			}
			Action["text"] := Document["text"]
			Action["fields"] := Document["fields"]
			Action["notes"] := Document["notes"]
			Action["name"] := Document["name"]
			Action["summary"] := Document["summary"]
		}
		switch Name {
			case "copy":
				if !Effects["copy"].Call(Action["text"])
					throw Error("The clipboard refused the report.")
			case "save":
				Outcome["path"] := _HCReport_SaveAndReveal(Effects, Paths, Action["name"],
					Action["text"], Action.Get("day_log_file", 0))
			case "report":
				Outcome["path"] := _HCReport_Report(Effects, Config, Action, Rules, Context, Paths)
			case "open_path":
				Id := Action["id"]
				if !Paths.Has(Id)
					throw Error("The path " . Id . " is unknown.")
				Path := Paths[Id]
				if HC_FOLDER_IDS.Has(Id)
					Effects["make_dir"].Call(Path)
				if !Effects["exists"].Call(Path) {
					if HC_FOLDER_IDS.Has(Id)
						throw Error(Path . " does not exist.")
					Missing := Path
				} else if !Effects["open"].Call(Path) {
					throw Error(Path . " could not be opened.")
				}
			default:
				throw Error("No handler for the action " . Name . ".")
		}
	} catch as Err {
		LoggerError("HealthCheckReport", "Diagnostics action '{1}' failed: {2}", Name, Err.Message)
		return Map("ok", false)
	}
	if (Missing != "") {
		LoggerInfo("HealthCheckReport", "Diagnostics action '{1}': {2} does not exist yet.", Name, Missing)
		return Map("ok", false, "missing", true)
	}
	LoggerSuccess("HealthCheckReport", "Diagnostics action '{1}' done.", Name)
	return Outcome
}





; =============================
; =============================
; ======= 3/ Debug Menu =======
; =============================
; =============================

; Reports a bug exactly as the diagnostics page's report button does, without
; the window: the approved report of a fresh snapshot is copied, saved and
; selected in Explorer, then the bug form opens with the host version, OS and
; driver prefilled. One path, HealthCheck_PerformAction, owns the policy.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Boolean} Whether the bug form was opened.
HealthCheck_ReportBug(Overrides := 0) {
	LoggerStart("HealthCheckReport", "Reporting a bug from the Debug menu…")
	Effects := _HCReport_Effects(Overrides)
	Opened := false
	try {
		Config := HealthCheck_Config()
		Snapshot := HealthCheck_Run()
		; A report from the Debug menu has no page to keep responsive
		HealthCheck_CompleteConfiguration(Snapshot, Config["schema"])
		Document := HealthCheck_ShareDocument(Snapshot, Config["schema"])
		Outcome := HealthCheck_PerformAction(Map("action", "report", "text", Document["text"],
			"fields", Document["fields"]), Snapshot["sections"]["paths"], Config, Overrides, Snapshot)
		Opened := Outcome["ok"] ? true : false
		if !Opened
			LoggerError("HealthCheckReport", "Bug report failed: the report action was refused.")
	} catch as Err {
		LoggerError("HealthCheckReport", "Bug report failed: {1}", Err.Message)
	}
	if !Opened {
		Effects["notify"].Call(t("menu.debug.report_bug"), t("notify.github_report_failed"), "error")
		return false
	}
	LoggerSuccess("HealthCheckReport", "Bug report form opened.")
	return true
}

; The field report's evidence line, the only text of it a bug form carries:
; keys, step ids, verdict enums and counts, never a path or a sentence. The
; grammar of the shared Lua runner's EVIDENCE_LINE
; (_shared/diagnostics/engine/healthcheck/report.lua), which macOS and Linux check.
global HC_FIELD_REPORT_LINE := "^check=field_report verdict=\w+ request=[\w.:-]+[\w=\s-]*$"

; Opens the bug form for a finished field report
; (diagnostics/ui/field_check/field_report.ahk), as macOS and Linux do through
; report_field_run: this PC's version, OS and driver from a fresh snapshot and
; the run's evidence line in the report field, the redacted complete report on
; the clipboard first for the Full report field.
; @param Line {String} The run's evidence line (FieldReport_LogLine).
; @param Text {String} The complete report.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Boolean} Whether the bug form was opened.
; @throws {ValueError} When the line is outside the evidence grammar.
HealthCheck_ReportFieldRun(Line, Text, Overrides := 0) {
	global HC_FIELD_REPORT_LINE
	if !(Line is String) || !RegExMatch(Line, HC_FIELD_REPORT_LINE)
		throw ValueError("A field report issue needs its evidence line.")
	LoggerStart("HealthCheckReport", "Opening the bug form for the field report…")
	Effects := _HCReport_Effects(Overrides)
	try {
		Config := HealthCheck_Config()
		Document := HealthCheck_ShareDocument(HealthCheck_Run(), Config["schema"])
		ReportField := Config["templates"]["templates"]["bug"]["report_field"]
		if !(ReportField is String) || ReportField == ""
			throw Error("The bug template names no report field.")
		Fields := Map("version", Document["fields"]["version"], "os", Document["fields"]["os"],
			"driver", Document["fields"]["driver"], ReportField, Line)
		Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "bug", Fields)
		; The clipboard first: the form the browser opens asks for it
		if !Effects["copy"].Call(Redact_Apply(Text, Config["redaction"], HealthCheck_RedactionContext(Overrides)))
			throw Error("The clipboard refused the field report.")
		if !Effects["open_url"].Call(Url)
			throw Error("The browser could not be opened.")
	} catch as Err {
		LoggerError("HealthCheckReport", "Field report issue failed: {1}", Err.Message)
		return false
	}
	LoggerSuccess("HealthCheckReport", "Field report issue form opened.")
	return true
}

; Opens the GitHub feature form with the version and the system prefilled.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Boolean}
HealthCheck_SuggestFeature(Overrides := 0) {
	LoggerStart("HealthCheckReport", "Opening the feature request form…")
	Effects := _HCReport_Effects(Overrides)
	try {
		Config := HealthCheck_Config()
		Rules := Config["redaction"]
		Context := HealthCheck_RedactionContext(Overrides)
		Document := HealthCheck_ShareDocument(HealthCheck_Run(), Config["schema"])
		Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "feature", Document["fields"])
		if !Effects["open_url"].Call(Url)
			throw Error("The browser could not be opened.")
	} catch as Err {
		LoggerError("HealthCheckReport", "Feature request failed: {1}", Err.Message)
		Effects["notify"].Call(t("menu.debug.suggest_feature"), t("notify.github_report_failed"), "error")
		return false
	}
	LoggerSuccess("HealthCheckReport", "Feature request form opened.")
	return true
}

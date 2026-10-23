; ui/healthcheck/report.ahk

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
	if !InStr("|object|array|enum|boolean|number|integer|version|hash|utc|commit|runtime|setting_row|", "|" . Kind . "|")
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

/** Returns a detached technical projection; unknown fields cannot be shared. */
HealthCheck_ShareSnapshot(Snapshot, Schema) {
	Policy := Schema.Get("share_policy", 0)
	if !(Policy is Map) || Policy.Get("version", 0) != 1 || !(Snapshot is Map)
		throw Error("The diagnostic sharing policy is unavailable.")
	Driver := Snapshot.Get("driver", "")
	if !(Driver == "windows" || Driver == "macos" || Driver == "linux")
		throw Error("The diagnostic sharing identity is unavailable.")
	Safe := _HCShare_Project(Snapshot, Policy["projection"], &Present)
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


/** Renders only the detached projection; no local message or path reaches a row. */
_HCShare_Rows(Value, Rule, Prefix, Rows) {
	if Rule["kind"] == "object" {
		Keys := ""
		for Key in Value
			Keys .= Key . "`n"
		for Key in StrSplit(RTrim(Sort(Keys, "C"), "`n"), "`n") {
			if Key != ""
				_HCShare_Rows(Value[Key], Rule["fields"][Key], Prefix == "" ? Key : Prefix . "." . Key, Rows)
		}
	} else if Rule["kind"] == "array" {
		for Index, Item in Value
			_HCShare_Rows(Item, Rule["item"], Prefix . "." . Index, Rows)
	} else if Rule["kind"] == "setting_row" {
		Rows.Push("| " . _HCShare_Cell(Value["setting"]) . " | " . _HCShare_Cell(Value["type"] . ": " . Value["value"]) . " |")
	} else {
		Text := Rule["kind"] == "boolean" ? (Value ? "true" : "false") : Value
		Rows.Push("| " . _HCShare_Cell(Prefix) . " | " . _HCShare_Cell(Text) . " |")
	}
}

_HCShare_Cell(Value) {
	return StrReplace(RegExReplace(Value . "", "[\r\n]+", " "), "|", "\|")
}

_HCShare_Table(Rows, Title := "") {
	if !Rows.Length
		return ""
	Text := (Title == "" ? "" : "## " . Title . "`n`n") . "| | |`n| --- | --- |`n"
	for Row in Rows
		Text .= Row . "`n"
	return Text
}

/** Canonical section labels describe only values admitted by the sharing policy. */
_HCShare_Readable(Safe, Schema) {
	Policy := Schema["share_policy"]["projection"]["fields"]
	Rows := [], Keys := ""
	for Key in Safe
		if Key != "sections" && Key != "probes" && Key != "retired_probes"
			Keys .= Key . "`n"
	for Key in StrSplit(RTrim(Sort(Keys, "C"), "`n"), "`n")
		if Key != ""
			_HCShare_Rows(Safe[Key], Policy[Key], Key, Rows)
	Text := _HCShare_Table(Rows)
	for Section in Schema["sections"] {
		Id := Section["id"]
		if !Safe.Get("sections", Map()).Has(Id)
			continue
		Data := Safe["sections"][Id], Rows := [], Keys := ""
		for Key in Data
			Keys .= Key . "`n"
		for Key in StrSplit(RTrim(Sort(Keys, "C"), "`n"), "`n") {
			if Key == ""
				continue
			Label := Key
			for Field in Section.Get("fields", [])
				if Field["id"] == Key {
					Label := _HCShare_English(Schema, "healthcheck.field." . Key)
					break
				}
			_HCShare_Rows(Data[Key], Policy["sections"]["fields"][Id]["fields"][Key], Label, Rows)
		}
		TableText := _HCShare_Table(Rows, _HCShare_English(Schema, "healthcheck.section." . Id))
		if TableText != ""
			Text .= "`n" . TableText
	}
	Rows := []
	for Key in ["probes", "retired_probes"]
		if Safe.Has(Key)
			_HCShare_Rows(Safe[Key], Policy[Key], Key, Rows)
	TableText := _HCShare_Table(Rows, _HCShare_English(Schema, "healthcheck.deep_tests.probe_inventory"))
	return Text . (TableText == "" ? "" : "`n" . TableText)
}

/** Resolves an export label without changing or falling back to UI locale. */
_HCShare_English(Schema, Key) {
	Strings := Schema.Get("export_strings", 0)
	if !(Strings is Map) || !Strings.Has(Key) || !(Strings[Key] is String) || Strings[Key] == ""
		throw Error("English export label unavailable: " . Key)
	return Strings[Key]
}

/** Builds file and issue-form content only from the host-retained snapshot. */
HealthCheck_ShareDocument(Snapshot, Schema) {
	Safe := HealthCheck_ShareSnapshot(Snapshot, Schema)
	Versions := Safe.Get("sections", Map()).Get("versions", Map())
	Fence := Chr(96) . Chr(96) . Chr(96)
	Text := "# ErgoptiPlus diagnostics`n`n" . _HCShare_English(Schema, Schema["share_policy"]["notice_key"])
		. "`n`ndriver-suites: not_run`npage-model-checks: " . (Safe.Has("page_check_observations") ? "installed_page_reported (unqualified)" : "not_collected") . "`n`n" . _HCShare_Readable(Safe, Schema)
		. "`n" . Fence . "json`n" . _HC_ValueToJson(Safe) . "`n" . Fence . "`n"
	Name := Schema["report"]["name_prefix"] . Safe["driver"] . "-"
		. RegExReplace(Safe.Get("generated_at", "unknown"), "[^A-Za-z0-9_.-]", "_") . Schema["report"]["name_suffix"]
	Summary := "A diagnostic attachment was saved locally. Attach that file here after reviewing it; no attachment is uploaded automatically.`n"
		. "Driver: " . Safe["driver"] . "`nVersion: " . Versions.Get("ergopti_version", "unknown")
		. "`nCommit: " . Versions.Get("commit", "unknown") . "`nDriver suites: NOT_RUN"
	return Map("snapshot", Safe, "text", Text, "name", Name, "summary", Summary,
		"fields", Map("driver", Safe["driver"], "version", Versions.Get("ergopti_version", "unknown"), "os", Safe["driver"]))
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
	Path := Dir . "\" . Name
	if !(WriterFn is Integer && WriterFn == 0) && !HasMethod(WriterFn, "Call")
		throw TypeError("The diagnostics attachment writer must be callable or zero.")
	ResolvedWriter := HasMethod(WriterFn, "Call") ? WriterFn : FSWriteDurable
	Written := ResolvedWriter.Call(Path, Text)
	if !(Written is Integer) || Written != 1
		throw Error("The complete diagnostics attachment could not be written.")
	return Path
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
	return _HCReport_Start('explorer.exe /select,"' . Path . '"')
}

; Opens a folder in Explorer, or a file with its default program.
; @returns {Boolean}
_HCReport_Open(Path) {
	return _HCReport_Start(InStr(FileExist(Path), "D") ? 'explorer.exe "' . Path . '"' : '"' . Path . '"')
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
_HCReport_SaveAndReveal(Effects, Paths, Name, Text) {
	if !Paths.Has("diagnostics_dir")
		throw Error("The diagnostics folder is unknown.")
	Path := Effects["save"].Call(Paths["diagnostics_dir"], Name, Text)
	if !Effects["reveal"].Call(Path)
		LoggerWarn("HealthCheckReport", "The saved report could not be selected in Explorer.")
	return Path
}

; Reports on GitHub: copies and saves the complete approved report, then
; reveals its local attachment before opening the bug form with stable host
; version, OS and driver fields. Editable fields stay outside the URL; the
; browser opens last and no attachment is uploaded automatically.
; @param Action {Map} Host-approved report text and technical identity fields.
; @throws {Error} When clipboard, attachment completion or browser opening refuses.
_HCReport_Report(Effects, Config, Action, Rules, Context, Paths) {
	Text := Action["text"]
	; Copy the complete approved report independently of its short metadata URL
	if !Effects["copy"].Call(Text)
		throw Error("The clipboard refused the report.")
	; The complete approved document stays in a local attachment, never the URL.
	Path := _HCReport_SaveAndReveal(Effects, Paths, Action["name"], Text)
	Fields := Map()
	; Only the host-derived technical identity is stable enough to prefill.
	for Id in ["version", "os", "driver"]
		Fields[Id] := Action["fields"][Id]
	ReportField := Config["templates"]["templates"]["bug"]["report_field"]
	if !(ReportField is String) || ReportField == ""
		throw Error("The bug template names no report field.")
	Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "bug", Fields)
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
			Document := HealthCheck_ShareDocument(Snapshot, Config["schema"])
			if !Action.Has("text") || !(Action["text"] == Document["text"])
				throw Error("The diagnostic sharing preview is stale or invalid.")
			Action := Action.Clone()
			Action["text"] := Document["text"]
			Action["fields"] := Document["fields"]
			Action["name"] := Document["name"]
			Action["summary"] := Document["summary"]
		}
		switch Name {
			case "copy":
				if !Effects["copy"].Call(Action["text"])
					throw Error("The clipboard refused the report.")
			case "save":
				Outcome["path"] := _HCReport_SaveAndReveal(Effects, Paths, Action["name"],
					Action["text"])
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

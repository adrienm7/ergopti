; ui/healthcheck/report.ahk

; ==============================================================================
; MODULE: Healthcheck / Exports And GitHub Forms
; DESCRIPTION:
; What the diagnostics page's buttons do on this machine once
; HealthCheck_ValidateAction accepted them: copy the report, save it as a
; Markdown file under the logs folder and select it in Explorer, report it on
; GitHub (copy it, then open the bug form with the report prefilled) and open
; a folder. Also the Debug menu's "Report a bug", which opens the diagnostics
; window at its preview, and "Suggest a feature".
;
; FEATURES & RATIONALE:
; 1. Shared output is rebuilt from the host snapshot through a closed typed
;    policy. Free text, paths and unknown fields are excluded regardless of
;    the page or details checkbox. Only approved technical content leaves.
; 2. GitHub answers 414 a little above 8 KB, so the issue link cuts a long
;    report to its budget; the clipboard holds it whole. A report saves no
;    file and selects nothing: Explorer would take the focus from the form.
; 3. Paths come from the snapshot the host collected, by field id; a folder
;    that does not exist yet is created before it is opened; a file that does
;    not exist yet (today's errors file before the day's first warning) is
;    said to the page, not logged as a failure.
; 4. Side effects are one Map so a test can observe each of them; the browser
;    opens last, after the clipboard holds what it asks for, and nothing
;    follows it that could take the focus back.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Projects only typed fields declared in the canonical sharing policy. */
_HCShare_Project(Value, Rule, &Present) {
	Present := true
	Kind := Rule["kind"]
	if !InStr("|object|array|enum|boolean|number|integer|version|hash|utc|commit|runtime|", "|" . Kind . "|")
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
			for Item in Value
				Result.Push(_HCShare_Project(Item, Rule["item"], &HasValue))
		return Result
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

/** Returns a detached technical projection; unknown fields cannot be shared. */
HealthCheck_ShareSnapshot(Snapshot, Schema) {
	Policy := Schema.Get("share_policy", 0)
	if !(Policy is Map) || Policy.Get("version", 0) != 1 || !(Snapshot is Map)
		throw Error("The diagnostic sharing policy is unavailable.")
	Driver := Snapshot.Get("driver", "")
	if !(Driver == "windows" || Driver == "macos" || Driver == "linux")
		throw Error("The diagnostic sharing identity is unavailable.")
	return _HCShare_Project(Snapshot, Policy["projection"], &Present)
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
	Text := (Title == "" ? "" : "## " . t(Title) . "`n`n") . "| | |`n| --- | --- |`n"
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
					Label := t("healthcheck.field." . Key)
					break
				}
			_HCShare_Rows(Data[Key], Policy["sections"]["fields"][Id]["fields"][Key], Label, Rows)
		}
		TableText := _HCShare_Table(Rows, "healthcheck.section." . Id)
		if TableText != ""
			Text .= "`n" . TableText
	}
	Rows := []
	for Key in ["probes", "retired_probes"]
		if Safe.Has(Key)
			_HCShare_Rows(Safe[Key], Policy[Key], Key, Rows)
	TableText := _HCShare_Table(Rows, "healthcheck.deep_tests.probe_inventory")
	return Text . (TableText == "" ? "" : "`n" . TableText)
}

/** Builds file and issue-form content only from the host-retained snapshot. */
HealthCheck_ShareDocument(Snapshot, Schema) {
	Safe := HealthCheck_ShareSnapshot(Snapshot, Schema)
	Versions := Safe.Get("sections", Map()).Get("versions", Map())
	Fence := Chr(96) . Chr(96) . Chr(96)
	Text := "# ErgoptiPlus diagnostics`n`n" . t(Schema["share_policy"]["notice_key"])
		. "`n`ndriver-suites: not_run`npage-model-checks: not_collected`n`n" . _HCShare_Readable(Safe, Schema)
		. "`n" . Fence . "json`n" . _HC_ValueToJson(Safe) . "`n" . Fence . "`n"
	Name := Schema["report"]["name_prefix"] . Safe["driver"] . "-"
		. RegExReplace(Safe.Get("generated_at", "unknown"), "[^A-Za-z0-9_.-]", "_") . Schema["report"]["name_suffix"]
	return Map("snapshot", Safe, "text", Text, "name", Name,
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
; @returns {String} The saved file's path.
; @throws {Error} When the folder or the file cannot be written.
_HCReport_Save(Dir, Name, Text) {
	DirCreate(Dir)
	Path := Dir . "\" . Name
	File := FileOpen(Path, "w", "UTF-8-RAW")
	try File.Write(Text)
	finally File.Close()
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
		"identity", () => Map("home", EnvGet("USERPROFILE"), "user", A_UserName))
	if (Overrides is Map) {
		for Name, Fn in Overrides
			Effects[Name] := Fn
	}
	return Effects
}

; What identifies this machine in paths and text, for redaction. Windows paths
; compare case-insensitively.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Map} { home, user, case_insensitive }
HealthCheck_RedactionContext(Overrides := 0) {
	Identity := _HCReport_Effects(Overrides)["identity"].Call()
	; Without the profile folder nothing would remove it, and every path under
	; it would be published
	if (Identity["home"] == "")
		throw Error("The profile folder is unknown, so nothing could be redacted.")
	return Map("home", Identity["home"], "user", Identity["user"], "case_insensitive", true)
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

; Reports on GitHub: copies the full report, then opens the bug form with that
; same report prefilled. Nothing is saved and nothing is selected: the browser
; opening is the last side effect, so the form keeps the focus.
; @param Action {Map} { text, fields } The page's text and identity fields.
; @throws {Error} When the clipboard or the browser refuses.
_HCReport_Report(Effects, Config, Action, Rules, Context) {
	Text := Action["text"]
	; First, and whole: the link may cut the report to fit GitHub's budget
	if !Effects["copy"].Call(Text)
		throw Error("The clipboard refused the report.")
	Fields := Map()
	for Id, Value in Action["fields"]
		Fields[Id] := Value
	Fields[Config["templates"]["templates"]["bug"]["report_field"]] := Text
	Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "bug", Fields)
	if !Effects["open_url"].Call(Url)
		throw Error("The browser could not be opened.")
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
		}
		switch Name {
			case "copy":
				if !Effects["copy"].Call(Action["text"])
					throw Error("The clipboard refused the report.")
			case "save":
				Outcome["path"] := _HCReport_SaveAndReveal(Effects, Paths, Action["name"],
					Action["text"])
			case "report":
				_HCReport_Report(Effects, Config, Action, Rules, Context)
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

; Opens the diagnostics window at its preview: the user reviews exactly what
; is shared before the report button copies it and opens GitHub.
HealthCheck_ReportBug() {
	HealthCheck_ShowWindow("report")
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

; ui/healthcheck/report.ahk

; ==============================================================================
; MODULE: Healthcheck / GitHub Issue Reports
; DESCRIPTION:
; The Debug menu's "Report a bug" and "Suggest a feature" rows. A bug report
; copies the full diagnostics, redacted, to the clipboard, saves them as a
; Markdown file next to today's errors file and selects it in Explorer, then
; opens the repository's bug form with the version, the system and a short
; summary prefilled. GitHub cannot receive a file through a URL and answers
; 414 a little above 8 KB, which is why the full report travels through the
; clipboard and the saved file.
;
; FEATURES & RATIONALE:
; 1. Every text that leaves the machine goes through Redact_Apply: the home
;    folder, the account name and token-like secrets are removed from the
;    clipboard, the file and the URL alike.
; 2. The repository comes from _shared/modules/updater/defaults.json and the
;    forms from _shared/modules/diagnostics/issue_templates.json.
; 3. Side effects are one Map so a test can observe each of them; the browser
;    opens last, after the clipboard holds what it asks for.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================
; ================================
; ======= 1/ Configuration =======
; ================================
; ================================

; Reads and parses one shared JSON document.
; @param Rel {String} Path under _shared\.
; @returns {Map}
_HCReport_ReadSharedJson(Rel) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\" . Rel, "UTF-8"))
}

; The issue forms, the repository and the redaction rules.
; @returns {Map} { templates, repository, redaction }
_HCReport_Config() {
	Defaults := _HCReport_ReadSharedJson("modules\updater\defaults.json")
	return Map(
		"templates",  _HCReport_ReadSharedJson("modules\diagnostics\issue_templates.json"),
		"repository", Defaults["github"],
		"redaction",  _HCReport_ReadSharedJson("modules\diagnostics\redaction.json"))
}

; What identifies this machine in paths and text, for redaction. Windows paths
; compare case-insensitively.
; @param Effects {Map}
; @returns {Map}
_HCReport_RedactionContext(Effects) {
	Identity := Effects["identity"].Call()
	; Without the profile folder nothing would remove it, and every path under
	; it would be published
	if (Identity["home"] == "")
		throw Error("The profile folder is unknown, so the report cannot be redacted.")
	return Map("home", Identity["home"], "user", Identity["user"], "case_insensitive", true)
}





; ===============================
; ===============================
; ======= 2/ Side Effects =======
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

; Selects the saved report in Explorer.
; @returns {Boolean} False when Explorer could not be started.
_HCReport_Reveal(Path) {
	try {
		Run('explorer.exe /select,"' . Path . '"')
	} catch as Err {
		LoggerWarn("HealthCheckReport", "Explorer could not be started: {1}", Err.Message)
		return false
	}
	return true
}

; Shows a system notification through the notifier adapter.
_HCReport_Notify(Title, Body, Kind) {
	NotifierSend(Body, Map("title", Title, "level", Kind))
	return true
}

; The production side effects; a test replaces any of them.
; @param Overrides {Map|Integer} Replacement effects, or 0.
; @returns {Map} { copy, save, reveal, open_url, notify, now_utc }
_HCReport_Effects(Overrides := 0) {
	Effects := Map(
		"copy",     CB_Write,
		"save",     _HCReport_Save,
		"reveal",   _HCReport_Reveal,
		"open_url", ExternalUrl_OpenHttp,
		"notify",   _HCReport_Notify,
		"now_utc",  () => A_NowUTC,
		"identity", () => Map("home", EnvGet("USERPROFILE"), "user", A_UserName))
	if (Overrides is Map) {
		for Name, Fn in Overrides
			Effects[Name] := Fn
	}
	return Effects
}





; ==========================
; ==========================
; ======= 3/ Reports =======
; ==========================
; ==========================

; The report's identity fields, from a healthcheck snapshot.
; @param Snapshot {Map}
; @param NowUtc {String} YYYYMMDDHH24MISS timestamp in UTC.
; @returns {Map}
_HCReport_Info(Snapshot, NowUtc) {
	Sys := Snapshot["sys"]
	return Map(
		"driver",        "windows",
		"version",       String(Snapshot["version"]),
		"commit",        _HealthCheck_CommitText(Sys),
		"os",            Trim(Sys.Get("os_name", "Windows") . " " . Sys.Get("os_build", "")),
		"generated_utc", FormatTime(NowUtc, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
		"file_stamp",    FormatTime(NowUtc, "yyyyMMdd'T'HHmmss'Z'"),
		"warn_count",    Snapshot["warn_count"],
		"err_count",     Snapshot["err_count"],
		"last_error",    String(Snapshot["last_error"]))
}

; The folder reports are saved in: beside today's errors file.
; @returns {String}
_HCReport_Dir() {
	ErrorsFile := _HealthCheck_ErrorsLogPath()
	if (ErrorsFile == "")
		throw Error("The logger has no errors file yet.")
	SplitPath(ErrorsFile, , &Dir)
	return Dir . "\diagnostics"
}

; Prepares a bug report and opens the GitHub bug form.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Boolean} True when the form was opened with its report.
HealthCheck_ReportBug(Overrides := 0) {
	LoggerStart("HealthCheckReport", "Preparing a bug report…")
	Effects := _HCReport_Effects(Overrides)
	try {
		Config := _HCReport_Config()
		Rules := Config["redaction"]
		Context := _HCReport_RedactionContext(Effects)
		Snapshot := HealthCheck_Run()
		Info := _HCReport_Info(Snapshot, Effects["now_utc"].Call())
		Name := IssueReport_FileName(Info)
		Markdown := Redact_Apply(IssueReport_Markdown(Info, IssueReport_Dump(Snapshot)), Rules, Context)

		if !Effects["copy"].Call(Markdown)
			throw Error("The clipboard refused the report.")
		Path := Effects["save"].Call(_HCReport_Dir(), Name, Markdown)
		if !Effects["reveal"].Call(Path)
			LoggerWarn("HealthCheckReport", "The saved report could not be selected in Explorer.")

		Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "bug", Map(
			"version",     Redact_Apply(Info["version"], Rules, Context),
			"os",          Redact_Apply(Info["os"], Rules, Context),
			"driver",      Info["driver"],
			"diagnostics", Redact_Apply(IssueReport_Summary(Info, Name), Rules, Context)))
		if !Effects["open_url"].Call(Url)
			throw Error("The browser could not be opened.")
	} catch as Err {
		LoggerError("HealthCheckReport", "Bug report failed: {1}", Err.Message)
		Effects["notify"].Call(t("menu.debug.report_bug"), t("notify.github_report_failed"), "error")
		return false
	}
	Effects["notify"].Call(t("notify.report_bug_title"), t("notify.report_bug_body"), "info")
	LoggerSuccess("HealthCheckReport", "Bug report prepared ({1}) and the GitHub form opened.", Path)
	return true
}

; Opens the GitHub feature form with the version and the system prefilled.
; @param Overrides {Map|Integer} Replacement side effects (tests only).
; @returns {Boolean}
HealthCheck_SuggestFeature(Overrides := 0) {
	LoggerStart("HealthCheckReport", "Opening the feature request form…")
	Effects := _HCReport_Effects(Overrides)
	try {
		Config := _HCReport_Config()
		Rules := Config["redaction"]
		Context := _HCReport_RedactionContext(Effects)
		Info := _HCReport_Info(HealthCheck_Run(), Effects["now_utc"].Call())
		Url := IssueLink_BuildUrl(Config["templates"], Config["repository"], "feature", Map(
			"version", Redact_Apply(Info["version"], Rules, Context),
			"os",      Redact_Apply(Info["os"], Rules, Context),
			"driver",  Info["driver"]))
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

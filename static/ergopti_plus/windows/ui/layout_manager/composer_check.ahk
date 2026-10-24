; ui/layout_manager/composer_check.ahk

; ==============================================================================
; MODULE: Composer Check (Windows)
; DESCRIPTION:
; The Debug menu's one-click « Test the composed layout »: builds a small
; composition (the shipped _shared/modules/layouts/composer_check files),
; installs it through the composer's real save path, verifies the installed
; copy against its record, asks the emulation's reader whether it would accept
; it, removes it again, and writes one evidence record. The result window shows
; one line per step and a « Copy report » button.
;
; FEATURES & RATIONALE:
; 1. Never overwrites the user's work: when a composition is already stored,
;    installed or selected, the check only verifies that one (no save, no
;    removal) and says so in its mode step. Otherwise the layout it installs is
;    removed at the end, whatever happened in between.
; 2. Nothing is selected and the driver is not reloaded: the save runs with
;    use = 0, so the emulation keeps what it was typing.
; 3. Privacy by construction: a step value follows a closed grammar (letters,
;    digits and . _ : + -, 48 characters at most); anything else, such as a
;    path or an error message, is replaced by "redacted". The record holds
;    states, codes and counts only.
; 4. Every collaborator is injectable, so the unit suite replays a fresh run,
;    an existing composition and each failure without a window or the real
;    configuration folder. The window is a thin shell over ComposerCheck_Text.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; Logger tag of every line the check writes; the maintainer filters on it.
global COMPOSER_CHECK_TAG := "ComposerCheck"

; Identity of the check in its evidence record (the macOS and Linux records
; carry the same one).
global COMPOSER_CHECK_ID := "composer"

; Step states. A run passes when no step failed; info and skip never fail it.
global COMPOSER_CHECK_PASS := "pass"
global COMPOSER_CHECK_FAIL := "fail"
global COMPOSER_CHECK_INFO := "info"
global COMPOSER_CHECK_SKIP := "skip"

; Longest value a step may carry, and what replaces one outside the grammar.
global COMPOSER_CHECK_MAX_VALUE_LENGTH := 48
global COMPOSER_CHECK_REDACTED := "redacted"

; The shipped composition, relative to _SharedDir.
global COMPOSER_CHECK_FIXTURE_DIR := "modules\layouts\composer_check\"

; At most one check runs at a time.
global _ComposerCheckBusy := false





; ==============================
; ==============================
; ======= 2/ The report ========
; ==============================
; ==============================

/**
 * A value that is safe to log, or the redaction marker.
 * @param {Any} Value - Candidate value.
 * @returns {string} "" when there is no value.
 */
ComposerCheck_SanitizeValue(Value) {
	global COMPOSER_CHECK_MAX_VALUE_LENGTH, COMPOSER_CHECK_REDACTED
	if Value is Object
		return COMPOSER_CHECK_REDACTED
	Text := String(Value)
	if Text == ""
		return ""
	if StrLen(Text) > COMPOSER_CHECK_MAX_VALUE_LENGTH || !RegExMatch(Text, "^[A-Za-z0-9_.:+\-]+$")
		return COMPOSER_CHECK_REDACTED
	return Text
}

/**
 * An empty report.
 * @returns {Map} "steps" (array of Maps) and "seen".
 */
ComposerCheck_NewReport() {
	return Map("steps", [], "seen", Map())
}

/**
 * Records one step; a repeated step identity is a bug and throws.
 * @param {Map} Report - From ComposerCheck_NewReport.
 * @param {string} Id - Step identity (the locale key field_check.step.<id>).
 * @param {string} State - pass, fail, info or skip.
 * @param {Any} Value - Optional short value.
 */
ComposerCheck_Step(Report, Id, State, Value := "") {
	global COMPOSER_CHECK_PASS, COMPOSER_CHECK_FAIL, COMPOSER_CHECK_INFO, COMPOSER_CHECK_SKIP
	if Type(Id) != "String" || Id == ""
		throw ValueError("A composer check step needs an identity.")
	if State != COMPOSER_CHECK_PASS && State != COMPOSER_CHECK_FAIL
			&& State != COMPOSER_CHECK_INFO && State != COMPOSER_CHECK_SKIP
		throw ValueError("Unknown composer check step state.", -1, State)
	if Report["seen"].Has(Id)
		throw Error("Composer check step recorded twice: " . Id)
	Report["seen"][Id] := true
	Report["steps"].Push(Map("id", Id, "state", State, "value", ComposerCheck_SanitizeValue(Value)))
}

/**
 * Whether no step failed.
 * @param {Map} Report
 * @returns {boolean}
 */
ComposerCheck_Passed(Report) {
	global COMPOSER_CHECK_FAIL
	for Step in Report["steps"]
		if Step["state"] == COMPOSER_CHECK_FAIL
			return false
	return true
}

/**
 * The one evidence line: check=composer verdict=pass steps=N id=state[:value] …
 * Same grammar as the macOS and Linux records.
 * @param {Map} Report
 * @param {string} CheckId - Identity of the check; the composer's by default (the
 *   network check shares this record's grammar).
 * @returns {string}
 */
ComposerCheck_LogLine(Report, CheckId := "") {
	global COMPOSER_CHECK_ID
	if CheckId == ""
		CheckId := COMPOSER_CHECK_ID
	Parts := ""
	for Step in Report["steps"] {
		Part := Step["id"] . "=" . Step["state"] . (Step["value"] != "" ? ":" . Step["value"] : "")
		Parts .= " " . Part
	}
	return "check=" . CheckId . " verdict=" . (ComposerCheck_Passed(Report) ? "pass" : "fail")
		. " steps=" . Report["steps"].Length . Parts
}

/**
 * The window and clipboard text, one line per step.
 * @param {Map} Report
 * @param {Func} TranslateFn - Locale key -> text.
 * @returns {string}
 */
ComposerCheck_Text(Report, TranslateFn) {
	global COMPOSER_CHECK_PASS, COMPOSER_CHECK_FAIL, COMPOSER_CHECK_INFO
	Marks := Map(COMPOSER_CHECK_PASS, "[OK]", COMPOSER_CHECK_FAIL, "[X]", COMPOSER_CHECK_INFO, "[i]")
	Text := TranslateFn.Call(ComposerCheck_Passed(Report) ? "field_check.verdict_pass" : "field_check.verdict_fail") . "`n"
	for Step in Report["steps"] {
		Line := Marks.Get(Step["state"], "[-]") . " " . TranslateFn.Call("field_check.step." . Step["id"])
		if Step["value"] != ""
			Line .= " : " . Step["value"]
		Text .= "`n" . Line
	}
	return Text
}





; ==========================
; ==========================
; ======= 3/ The run =======
; ==========================
; ==========================

/**
 * The shipped composition: its declaration and compiled layout.
 * @returns {Map} "declaration" and "keylayout" (texts).
 * @throws {Error} When a file is missing or not text.
 */
ComposerCheck_ReadFixture() {
	global _SharedDir, COMPOSER_CHECK_FIXTURE_DIR
	Dir := _SharedDir . "\" . COMPOSER_CHECK_FIXTURE_DIR
	return Map("declaration", FSReadStrict(Dir . "composition.json"),
		"keylayout", FSReadStrict(Dir . "composed.keylayout"))
}

/**
 * Whether the emulation's reader accepts an installed copy.
 * @param {Map} Copy - From LayoutRegistry_ReadLocal.
 * @returns {Integer} Number of keys the emulation would take.
 * @throws {Error} Where the emulation would refuse the layout.
 */
ComposerCheck_HostReady(Copy) {
	return KeylayoutEmulation_Check(Copy["Entry"]["id"], Copy["Text"], Copy["Entry"]["keycode_convention"],
		LayoutRegistry_Keycodes())
}

_ComposerCheck_Deps(Deps) {
	global _ConfigDir
	Defaults := Map(
		"config_dir", _ConfigDir,
		"local_dir", LayoutRegistry_LocalDir(_ConfigDir),
		"selected", KeylayoutEmulation_SelectedId,
		"fixture", ComposerCheck_ReadFixture,
		"handle", LayoutComposer_Handle,
		"installed", LayoutCatalogue_ReadInstalled,
		"read_local", LayoutRegistry_ReadLocal,
		"ready", ComposerCheck_HostReady,
		"exists", FileExist
	)
	if (Deps is Map)
		for Key, Value in Deps
			Defaults[Key] := Value
	return Defaults
}

/**
 * Runs the check and delivers its report exactly once.
 * @param {Func} OnDone - OnDone(Report) with the finished report.
 * @param {Map} Deps - Collaborators: "config_dir", "local_dir", "selected",
 *   "fixture", "handle", "installed", "read_local", "ready", "exists"; the
 *   production ones by default.
 * @returns {boolean} False when a check is already running.
 */
ComposerCheck_Run(OnDone, Deps := 0) {
	global _ComposerCheckBusy, COMPOSER_CHECK_TAG
	if _ComposerCheckBusy {
		LoggerWarn(COMPOSER_CHECK_TAG, "A composer check was refused: another one is still running.")
		return false
	}
	_ComposerCheckBusy := true
	LoggerStart(COMPOSER_CHECK_TAG, "Composer check started…")
	Run := {Report: ComposerCheck_NewReport(), Deps: _ComposerCheck_Deps(Deps), OnDone: OnDone,
		Fresh: false, Settled: false, Fixture: 0}
	try {
		_ComposerCheck_Begin(Run)
	} catch as Err {
		LoggerError(COMPOSER_CHECK_TAG, "The composer check raised: {1}", Err.Message)
		_ComposerCheck_Record(Run, "internal_error", "fail", "raised")
		_ComposerCheck_Finish(Run)
	}
	return true
}

; Records a step unless the report already holds it (a late callback of a run
; that already failed must not throw).
_ComposerCheck_Record(Run, Id, State, Value := "") {
	if !Run.Report["seen"].Has(Id)
		ComposerCheck_Step(Run.Report, Id, State, Value)
}

; The first steps: the shipped files and whether a composition already exists.
_ComposerCheck_Begin(Run) {
	global COMPOSER_CHECK_TAG
	Deps := Run.Deps
	try Run.Fixture := Deps["fixture"].Call()
	catch as Err {
		LoggerError(COMPOSER_CHECK_TAG, "The shipped check composition cannot be read: {1}", Err.Message)
		_ComposerCheck_Record(Run, "composer_fixture", "fail", "unreadable")
		_ComposerCheck_Finish(Run)
		return
	}
	_ComposerCheck_Record(Run, "composer_fixture", "pass")
	Id := LayoutRegistry_Composer()["id"]
	try {
		Installed := Deps["installed"].Call(Deps["local_dir"])
		Existing := Installed.Has(Id) || Deps["selected"].Call() == Id
			|| Deps["exists"].Call(LayoutComposer_DeclarationPath(Deps["config_dir"])) != ""
	} catch as Err {
		LoggerError(COMPOSER_CHECK_TAG, "The installed layouts cannot be read: {1}", Err.Message)
		_ComposerCheck_Record(Run, "composer_mode", "fail", "record_unreadable")
		_ComposerCheck_Finish(Run)
		return
	}
	if Existing {
		_ComposerCheck_Record(Run, "composer_mode", "info", "existing")
		_ComposerCheck_Record(Run, "composer_install", "skip", "kept")
		_ComposerCheck_Verify(Run)
		return
	}
	_ComposerCheck_Record(Run, "composer_mode", "info", "fresh")
	Run.Fresh := true
	Payload := Map("declaration", Run.Fixture["declaration"], "keylayout", Run.Fixture["keylayout"], "use", 0)
	if !Deps["handle"].Call("composer_save", Payload, _ComposerCheck_HandleDeps(Run, "composer_save", _ComposerCheck_OnSaved)) {
		_ComposerCheck_Record(Run, "composer_install", "fail", "refused")
		_ComposerCheck_Cleanup(Run)
	}
}

; The composer's collaborators: its page pushes become this run's callbacks.
_ComposerCheck_HandleDeps(Run, Action, Callback) {
	Deps := Run.Deps
	Push(Name, Payload) {
		if Name == "composerResult" && Payload["action"] == Action
			Callback.Call(Run, Payload)
	}
	return Map("config_dir", Deps["config_dir"], "local_dir", Deps["local_dir"], "push", Push,
		"selected", Deps["selected"])
}

_ComposerCheck_OnSaved(Run, Result) {
	global COMPOSER_CHECK_TAG
	if Run.Settled
		return
	if !Result["ok"] {
		LoggerError(COMPOSER_CHECK_TAG, "The check composition was not installed ({1}).", Result["code"])
		_ComposerCheck_Record(Run, "composer_install", "fail", Result["code"])
		_ComposerCheck_Cleanup(Run)
		return
	}
	_ComposerCheck_Record(Run, "composer_install", "pass")
	_ComposerCheck_Verify(Run)
}

; The installed copy against its record, then the emulation's reader.
_ComposerCheck_Verify(Run) {
	global COMPOSER_CHECK_TAG
	Deps := Run.Deps
	Id := LayoutRegistry_Composer()["id"]
	try {
		Copy := Deps["read_local"].Call(Id, Deps["local_dir"])
	} catch as Err {
		LoggerError(COMPOSER_CHECK_TAG, "The installed composition fails its record: {1}", Err.Message)
		_ComposerCheck_Record(Run, "composer_copy", "fail", "unreadable")
		_ComposerCheck_Record(Run, "composer_ready", "skip", "no_copy")
		_ComposerCheck_Cleanup(Run)
		return
	}
	_ComposerCheck_Record(Run, "composer_copy", "pass")
	try {
		Keys := Deps["ready"].Call(Copy)
	} catch as Err {
		LoggerError(COMPOSER_CHECK_TAG, "The emulation would refuse the installed composition: {1}", Err.Message)
		_ComposerCheck_Record(Run, "composer_ready", "fail", "refused")
		_ComposerCheck_Cleanup(Run)
		return
	}
	_ComposerCheck_Record(Run, "composer_ready", "pass", "keys:" . Keys)
	_ComposerCheck_Cleanup(Run)
}

; Removes what a fresh run installed, then reports.
_ComposerCheck_Cleanup(Run) {
	global COMPOSER_CHECK_TAG
	if !Run.Fresh {
		_ComposerCheck_Record(Run, "composer_cleanup", "skip", "kept")
		_ComposerCheck_Finish(Run)
		return
	}
	Deps := Run.Deps
	if !Deps["handle"].Call("composer_remove", Map(), _ComposerCheck_HandleDeps(Run, "composer_remove", _ComposerCheck_OnRemoved)) {
		_ComposerCheck_Record(Run, "composer_cleanup", "fail", "refused")
		_ComposerCheck_Finish(Run)
	}
}

_ComposerCheck_OnRemoved(Run, Result) {
	global COMPOSER_CHECK_TAG
	if Run.Settled
		return
	Deps := Run.Deps
	Id := LayoutRegistry_Composer()["id"]
	if !Result["ok"] {
		LoggerError(COMPOSER_CHECK_TAG, "The check composition was not removed ({1}).", Result["code"])
		_ComposerCheck_Record(Run, "composer_cleanup", "fail", Result["code"] != "" ? Result["code"] : "failed")
	} else {
		try {
			Left := Deps["installed"].Call(Deps["local_dir"]).Has(Id)
				|| Deps["exists"].Call(LayoutComposer_DeclarationPath(Deps["config_dir"])) != ""
		} catch {
			Left := true
		}
		_ComposerCheck_Record(Run, "composer_cleanup", Left ? "fail" : "pass", Left ? "left_behind" : "")
	}
	_ComposerCheck_Finish(Run)
}

; Settles once: the evidence record, the closing log line and the callback.
_ComposerCheck_Finish(Run) {
	global _ComposerCheckBusy, COMPOSER_CHECK_TAG
	if Run.Settled
		return
	Run.Settled := true
	_ComposerCheckBusy := false
	Passed := ComposerCheck_Passed(Run.Report)
	LoggerEvidence(COMPOSER_CHECK_TAG, "Composer check result: {1}", ComposerCheck_LogLine(Run.Report))
	LoggerSuccess(COMPOSER_CHECK_TAG, "Composer check finished: {1}.", Passed ? "pass" : "fail")
	Run.OnDone.Call(Run.Report)
}





; =============================
; =============================
; ======= 4/ The window =======
; =============================
; =============================

/**
 * Debug menu: « Test the composed layout ». Runs the check and shows its report.
 */
ComposerCheck_Command(*) {
	Started := ComposerCheck_Run(ComposerCheck_ShowReport)
	if !Started
		Ui_MsgBox(t("field_check.busy"), t("menu.debug.composer_check"), "Icon!")
}

/**
 * Shows a finished report, one line per step, with a « Copy report » button.
 * @param {Map} Report
 * @param {Func} ShowFn - Opens the window; tests replace it.
 * @param {string} TitleKey - Locale key of the window title; the composer's by
 *   default (the network check shows its report through the same window).
 */
ComposerCheck_ShowReport(Report, ShowFn := 0, TitleKey := "menu.debug.composer_check") {
	Text := ComposerCheck_Text(Report, t)
	if !HasMethod(ShowFn, "Call")
		ShowFn := (Title, Body) => _ComposerCheck_ShowWindow(Title, Body, TitleKey)
	ShowFn.Call(t(TitleKey), Text)
}

_ComposerCheck_ShowWindow(Title, Text, TitleKey := "menu.debug.composer_check") {
	Window := Gui("+AlwaysOnTop", WindowTitle(Title))
	Window.AddEdit("w560 r10 ReadOnly -Wrap", Text)
	Copy := Window.AddButton("w140 Default", t("field_check.copy"))
	Close := Window.AddButton("x+10 w140", t("field_check.close"))
	Copy.OnEvent("Click", (*) => ComposerCheck_CopyReport(Text, 0, 0, TitleKey))
	Close.OnEvent("Click", (*) => Window.Destroy())
	Window.OnEvent("Close", (*) => Window.Destroy())
	Window.Show()
}

/**
 * Copies a report to the clipboard and says so.
 * The write goes through the clipboard owner: a raw A_Clipboard assignment is
 * recorded by the metrics clipboard watcher as a copy the user made. As on
 * macOS and Linux, the notice is shown only when the copy succeeded.
 * @param {string} Text - The report text.
 * @param {Func} WriteFn - Receives the text and returns true once written; CB_Write by default.
 * @param {Func} NoticeFn - Receives the notice text; a tray tip by default.
 * @param {string} TitleKey - Locale key of the tray tip's title.
 * @returns {Boolean} True when the report reached the clipboard.
 */
ComposerCheck_CopyReport(Text, WriteFn := 0, NoticeFn := 0, TitleKey := "menu.debug.composer_check") {
	global COMPOSER_CHECK_TAG
	if !HasMethod(WriteFn, "Call")
		WriteFn := CB_Write
	if !HasMethod(NoticeFn, "Call")
		NoticeFn := (Notice) => TrayTip(Notice, WindowTitle(t(TitleKey)))
	; The clipboard takes Windows line breaks, as the window's own text has.
	if WriteFn.Call(StrReplace(Text, "`n", "`r`n")) != true {
		LoggerWarn(COMPOSER_CHECK_TAG, "Report not copied: the clipboard refused the write.")
		return false
	}
	LoggerInfo(COMPOSER_CHECK_TAG, "Report copied to the clipboard.")
	NoticeFn.Call(t("field_check.copied"))
	return true
}

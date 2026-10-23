; tests/unit/modules/keymap/test_layout_composer_check.ahk

; ==============================================================================
; MODULE: Composer Check Tests (Windows)
; DESCRIPTION:
; The Debug menu's « Test the composed layout » (ui/layout_manager/composer_check.ahk)
; runs against the real composer host and the real layout registry over a
; scratch configuration folder: a fresh run installs, verifies and removes the
; shipped check composition, a run over the user's own composition only reads
; it, and each way the host can fail is a failed step, never a silent pass.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LCC_TempDir() {
	Dir := A_Temp . "\ergopti_composer_check_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir)
	return Dir
}

; Production collaborators over a scratch folder, with overrides.
_LCC_Deps(Dir, Overrides := 0, Selected := "") {
	Deps := Map("config_dir", Dir, "local_dir", LayoutRegistry_LocalDir(Dir), "selected", () => Selected)
	if (Overrides is Map)
		for Key, Value in Overrides
			Deps[Key] := Value
	return Deps
}

; Runs the check and returns its report; the host settles synchronously.
_LCC_Run(Deps) {
	Box := {Report: 0}
	AssertTrue(ComposerCheck_Run((Report) => Box.Report := Report, Deps), "the check starts")
	Started := A_TickCount
	while !(Box.Report is Map) && A_TickCount - Started < 3000
		Sleep(10)
	Assert(Box.Report is Map, "the check delivers its report")
	return Box.Report
}

; "id=state:value" of every step, in order.
_LCC_Steps(Report) {
	Out := ""
	for Step in Report["steps"]
		Out .= (Out != "" ? " " : "") . Step["id"] . "=" . Step["state"] . (Step["value"] != "" ? ":" . Step["value"] : "")
	return Out
}

; Installs the shipped check composition the way a user's save would.
_LCC_InstallComposition(Dir) {
	Fixture := ComposerCheck_ReadFixture()
	Pushed := []
	LayoutComposer_Handle("composer_save", Map("declaration", Fixture["declaration"], "keylayout", Fixture["keylayout"],
		"use", 0), Map("config_dir", Dir, "local_dir", LayoutRegistry_LocalDir(Dir),
		"push", (Name, Payload) => Pushed.Push(Payload), "selected", () => ""))
	return Fixture
}

; A collaborator that raises.
_LCC_Refuse(*) {
	throw Error("refused by the test")
}

_LCC_Join(Items) {
	Out := ""
	for Item in Items
		Out .= (Out != "" ? "|" : "") . Item
	return Out
}

_LCC_Installed(Dir) => LayoutCatalogue_ReadInstalled(LayoutRegistry_LocalDir(Dir)).Has("composed")





; ====================================
; ====================================
; ======= 2/ Report and values =======
; ====================================
; ====================================

_LCC_ValueGrammar() {
	AssertEqual("keys:49", ComposerCheck_SanitizeValue("keys:49"), "counts and states pass")
	AssertEqual("", ComposerCheck_SanitizeValue(""), "no value is no value")
	for Leaky in ["C:\Users\jane\AppData\x", "https://example.com/a", "jane doe", "a/b", Map()]
		AssertEqual("redacted", ComposerCheck_SanitizeValue(Leaky), "a value outside the closed grammar is redacted")
	AssertEqual("redacted", ComposerCheck_SanitizeValue(StrReplace(Format("{:49}", ""), " ", "a")), "49 characters is too long")
	AssertEqual(StrReplace(Format("{:48}", ""), " ", "a"), ComposerCheck_SanitizeValue(StrReplace(Format("{:48}", ""), " ", "a")),
		"48 characters is the longest value")
}
Test("composer check: a step value follows the closed grammar and leaks no path, URL or name (composer-check)",
	_LCC_ValueGrammar)

_LCC_ReportContract() {
	Report := ComposerCheck_NewReport()
	ComposerCheck_Step(Report, "a", "pass")
	ComposerCheck_Step(Report, "b", "info", "fresh")
	ComposerCheck_Step(Report, "c", "skip", "kept")
	AssertTrue(ComposerCheck_Passed(Report), "info and skip never fail a run")
	AssertEqual("check=composer verdict=pass steps=3 a=pass b=info:fresh c=skip:kept", ComposerCheck_LogLine(Report))
	ComposerCheck_Step(Report, "d", "fail", "C:\Users\jane")
	AssertFalse(ComposerCheck_Passed(Report), "one failed step fails the run")
	AssertEqual("check=composer verdict=fail steps=4 a=pass b=info:fresh c=skip:kept d=fail:redacted",
		ComposerCheck_LogLine(Report))
	Threw := false
	try ComposerCheck_Step(Report, "a", "pass")
	catch
		Threw := true
	AssertTrue(Threw, "a step recorded twice is a bug")
	Threw := false
	try ComposerCheck_Step(Report, "e", "maybe")
	catch
		Threw := true
	AssertTrue(Threw, "an unknown state is a bug")
	Text := ComposerCheck_Text(Report, (Key) => "<" . Key . ">")
	AssertEqual("<field_check.verdict_fail>`n`n[OK] <field_check.step.a>`n[i] <field_check.step.b> : fresh`n"
		. "[-] <field_check.step.c> : kept`n[X] <field_check.step.d> : redacted", Text, "one line per step")
}
Test("composer check: the record and the window text list every step once (composer-check)", _LCC_ReportContract)





; ====================================
; ====================================
; ======= 3/ The shipped files =======
; ====================================
; ====================================

_LCC_FixtureIsAcceptedByTheHost() {
	Fixture := ComposerCheck_ReadFixture()
	Checked := LayoutComposer_Check(Fixture["declaration"], Fixture["keylayout"])
	AssertEqual("Composer Check", Checked["declaration"]["name"])
	AssertEqual("composed", Checked["entry"]["id"])
	Keys := KeylayoutEmulation_Check("composed", Fixture["keylayout"], "iso", LayoutRegistry_Keycodes())
	Assert(Keys >= 40, "the emulation takes the keys of the layout, got " . Keys)
}
Test("composer check: the shipped composition passes the host's own checks (composer-check)",
	_LCC_FixtureIsAcceptedByTheHost)

_LCC_CheckAgreesWithLoad() {
	Fixture := ComposerCheck_ReadFixture()
	Table := LayoutRegistry_Keycodes()
	Saved := KLE_Id
	try {
		AssertEqual(KeylayoutEmulation_Load("composed", Fixture["keylayout"], "iso", Table),
			KeylayoutEmulation_Check("composed", Fixture["keylayout"], "iso", Table),
			"Check counts the keys Load takes")
		Before := KLE_Id
		KeylayoutEmulation_Check("composed", Fixture["keylayout"], "iso", Table)
		AssertEqual(Before, KLE_Id, "Check leaves the loaded layout alone")
		for Broken in ["<keyboard>", StrReplace(Fixture["keylayout"], 'action="azerty__dead_diaeresis"', 'action="missing"', , , 1)] {
			CheckRefused := false, LoadRefused := false
			try KeylayoutEmulation_Check("composed", Broken, "iso", Table)
			catch
				CheckRefused := true
			try KeylayoutEmulation_Load("composed", Broken, "iso", Table)
			catch
				LoadRefused := true
			AssertTrue(CheckRefused && LoadRefused, "Check refuses what Load refuses")
		}
		AssertEqual(Before, KLE_Id, "a refused load keeps the loaded layout")
	} finally KeylayoutEmulation_Unload()
}
Test("composer check: the emulation check agrees with Load and changes nothing (composer-check)", _LCC_CheckAgreesWithLoad)





; ==============================
; ==============================
; ======= 4/ A fresh run =======
; ==============================
; ==============================

_LCC_FreshRun() {
	Dir := _LCC_TempDir()
	try {
		Report := _LCC_Run(_LCC_Deps(Dir))
		AssertEqual("composer_fixture=pass composer_mode=info:fresh composer_install=pass composer_copy=pass "
			. "composer_ready=pass:keys:" . KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), "iso").Count
			. " composer_cleanup=pass", _LCC_Steps(Report), "every step of a fresh run")
		AssertTrue(ComposerCheck_Passed(Report))
		AssertFalse(_LCC_Installed(Dir), "the check composition is removed again")
		AssertFalse(FileExist(LayoutComposer_DeclarationPath(Dir)), "and its declaration with it")
		AssertFalse(FileExist(LayoutRegistry_LocalDir(Dir) . "composed.keylayout"), "and its layout file")
	} finally DirDelete(Dir, true)
}
Test("composer check: a fresh run installs, verifies and removes the check composition (composer-check)",
	_LCC_FreshRun)

_LCC_ReportSucceedsAgain() {
	Dir := _LCC_TempDir()
	try {
		_LCC_Run(_LCC_Deps(Dir))
		Second := _LCC_Run(_LCC_Deps(Dir))
		AssertTrue(ComposerCheck_Passed(Second), "the check can run again: nothing was left busy or behind")
	} finally DirDelete(Dir, true)
}
Test("composer check: it runs twice in a row (composer-check)", _LCC_ReportSucceedsAgain)

_LCC_BusyRefusal() {
	Dir := _LCC_TempDir()
	try {
		Seen := []
		; A host that never answers keeps the first run pending.
		Pending := _LCC_Deps(Dir, Map("handle", (Action, Payload, HandleDeps) => (Seen.Push(Action), true)))
		AssertTrue(ComposerCheck_Run((Report) => Seen.Push("done"), Pending), "the first run starts")
		AssertFalse(ComposerCheck_Run((Report) => Seen.Push("second"), _LCC_Deps(Dir)),
			"a second run is refused while one is pending")
		AssertEqual("composer_save", _LCC_Join(Seen), "only the first run reached the host")
	} finally {
		global _ComposerCheckBusy := false
		DirDelete(Dir, true)
	}
}
Test("composer check: one run at a time (composer-check)", _LCC_BusyRefusal)





; ====================================
; ====================================
; ======= 5/ The user's layout =======
; ====================================
; ====================================

_LCC_ExistingCompositionIsOnlyRead() {
	Dir := _LCC_TempDir()
	try {
		Fixture := _LCC_InstallComposition(Dir)
		Before := FileRead(LayoutRegistry_LocalDir(Dir) . "composed.keylayout", "UTF-8-RAW")
		Calls := []
		Report := _LCC_Run(_LCC_Deps(Dir, Map("handle", (Action, Payload, HandleDeps) => (Calls.Push(Action), true))))
		AssertEqual("composer_fixture=pass composer_mode=info:existing composer_install=skip:kept composer_copy=pass "
			. "composer_ready=pass:keys:" . KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), "iso").Count
			. " composer_cleanup=skip:kept", _LCC_Steps(Report), "an existing composition is verified, not replaced")
		AssertEqual(0, Calls.Length, "the host is never asked to save or remove the user's composition")
		AssertTrue(_LCC_Installed(Dir), "the composition is still installed")
		AssertEqual(Before, FileRead(LayoutRegistry_LocalDir(Dir) . "composed.keylayout", "UTF-8-RAW"), "and unchanged")
		AssertEqual(Fixture["declaration"], LayoutComposer_ReadDeclaration(Dir), "with its declaration")
	} finally DirDelete(Dir, true)
}
Test("composer check: it never saves over or removes a composition that already exists (composer-check)",
	_LCC_ExistingCompositionIsOnlyRead)

_LCC_SelectedCompositionCountsAsExisting() {
	Dir := _LCC_TempDir()
	try {
		Calls := []
		Report := _LCC_Run(_LCC_Deps(Dir, Map("handle", (Action, Payload, HandleDeps) => (Calls.Push(Action), true)), "composed"))
		AssertEqual(0, Calls.Length, "the layout in use is never rewritten by the check")
		Assert(InStr(_LCC_Steps(Report), "composer_mode=info:existing"), "mode: existing")
		AssertFalse(ComposerCheck_Passed(Report), "a selected layout with no installed copy is a failed check")
		Assert(InStr(_LCC_Steps(Report), "composer_copy=fail:unreadable"), "the missing copy is the failed step")
	} finally DirDelete(Dir, true)
}
Test("composer check: the layout in use is verified but never rewritten (composer-check)",
	_LCC_SelectedCompositionCountsAsExisting)

_LCC_CorruptCopyFails() {
	Dir := _LCC_TempDir()
	try {
		_LCC_InstallComposition(Dir)
		Path := LayoutRegistry_LocalDir(Dir) . "composed.keylayout"
		FileAppend(" ", Path, "UTF-8-RAW")
		Report := _LCC_Run(_LCC_Deps(Dir))
		Assert(InStr(_LCC_Steps(Report), "composer_copy=fail:unreadable composer_ready=skip:no_copy"),
			"a copy that no longer matches its record fails, and the reader is not asked: " . _LCC_Steps(Report))
		AssertFalse(ComposerCheck_Passed(Report))
	} finally DirDelete(Dir, true)
}
Test("composer check: an installed copy that fails its record fails the check (composer-check)",
	_LCC_CorruptCopyFails)





; ================================
; ================================
; ======= 6/ Host failures =======
; ================================
; ================================

_LCC_EmulationRefusalFails() {
	Dir := _LCC_TempDir()
	try {
		Report := _LCC_Run(_LCC_Deps(Dir, Map("ready", _LCC_Refuse)))
		Assert(InStr(_LCC_Steps(Report), "composer_copy=pass composer_ready=fail:refused composer_cleanup=pass"),
			"a layout the emulation refuses fails, and is still removed: " . _LCC_Steps(Report))
		AssertFalse(_LCC_Installed(Dir), "nothing is left installed after a failed run")
	} finally DirDelete(Dir, true)
}
Test("composer check: a layout the emulation refuses fails the check and is still removed (composer-check)",
	_LCC_EmulationRefusalFails)

_LCC_RefusedInstallFails() {
	Dir := _LCC_TempDir()
	try {
		Fixture := ComposerCheck_ReadFixture()
		Broken := Map("fixture", () => Map("declaration", Fixture["declaration"],
			"keylayout", StrReplace(Fixture["keylayout"], "Composer Check", "Other")))
		Report := _LCC_Run(_LCC_Deps(Dir, Broken))
		Assert(InStr(_LCC_Steps(Report), "composer_install=fail:invalid"),
			"a composition the host refuses fails the install step: " . _LCC_Steps(Report))
		Assert(InStr(_LCC_Steps(Report), "composer_cleanup=pass"), "and the cleanup still ran")
		AssertFalse(ComposerCheck_Passed(Report))
		AssertFalse(_LCC_Installed(Dir))
	} finally DirDelete(Dir, true)
}
Test("composer check: a composition the host refuses fails the install step (composer-check)",
	_LCC_RefusedInstallFails)

_LCC_LeftBehindFails() {
	Dir := _LCC_TempDir()
	try {
		; A host that reports the removal without doing it.
		Lying := (Action, Payload, HandleDeps) => Action == "composer_remove"
			? (HandleDeps["push"].Call("composerResult", Map("action", Action, "ok", 1, "code", "")), true)
			: LayoutComposer_Handle(Action, Payload, HandleDeps)
		Report := _LCC_Run(_LCC_Deps(Dir, Map("handle", Lying)))
		Assert(InStr(_LCC_Steps(Report), "composer_cleanup=fail:left_behind"),
			"a removal that leaves the layout installed fails the check: " . _LCC_Steps(Report))
		AssertFalse(ComposerCheck_Passed(Report))
	} finally {
		try LayoutComposer_Handle("composer_remove", Map(), Map("config_dir", Dir, "local_dir", LayoutRegistry_LocalDir(Dir),
			"push", (Name, Payload) => 0, "selected", () => ""))
		DirDelete(Dir, true)
	}
}
Test("composer check: a removal that leaves the layout behind fails the check (composer-check)", _LCC_LeftBehindFails)

_LCC_MissingFixtureTouchesNothing() {
	Dir := _LCC_TempDir()
	try {
		Calls := []
		Report := _LCC_Run(_LCC_Deps(Dir, Map("fixture", _LCC_Refuse,
			"handle", (Action, Payload, HandleDeps) => (Calls.Push(Action), true))))
		AssertEqual("composer_fixture=fail:unreadable", _LCC_Steps(Report))
		AssertEqual(0, Calls.Length, "no unreadable fixture reaches the installer")
	} finally DirDelete(Dir, true)
}
Test("composer check: missing shipped files fail before anything is installed (composer-check)",
	_LCC_MissingFixtureTouchesNothing)

_LCC_HostRaisingIsAFailedStep() {
	Dir := _LCC_TempDir()
	try {
		Report := _LCC_Run(_LCC_Deps(Dir, Map("handle", _LCC_Refuse)))
		Assert(InStr(_LCC_Steps(Report), "internal_error=fail:raised"), "a raising host is a failed step, not a lost run")
		AssertFalse(ComposerCheck_Passed(Report))
		AssertTrue(ComposerCheck_Run((R) => 0, _LCC_Deps(Dir, Map("fixture", _LCC_Refuse))),
			"and the check is not left busy")
	} finally DirDelete(Dir, true)
}
Test("composer check: a host that raises is recorded and the check stays usable (composer-check)",
	_LCC_HostRaisingIsAFailedStep)





; =============================
; =============================
; ======= 7/ The window =======
; =============================
; =============================

_LCC_WindowText() {
	Report := ComposerCheck_NewReport()
	ComposerCheck_Step(Report, "composer_fixture", "pass")
	Shown := []
	ComposerCheck_ShowReport(Report, (Title, Text) => Shown.Push(Title, Text))
	AssertEqual(2, Shown.Length, "the window opens once")
	AssertEqual(ComposerCheck_Text(Report, t), Shown[2], "the window text is the clipboard text")
}
Test("composer check: the window shows the report text (composer-check)", _LCC_WindowText)

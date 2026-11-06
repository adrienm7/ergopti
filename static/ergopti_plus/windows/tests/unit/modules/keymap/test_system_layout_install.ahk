; tests/unit/modules/keymap/test_system_layout_install.ahk

; ==============================================================================
; MODULE: Ergopti System Layout Install (Windows)
; DESCRIPTION:
; Layout > « Install the Ergopti system layout »: the row follows where the
; layout stands, the install asks first and runs the shipped installer through
; UAC, a refusal is told and changes nothing, and the poll chains the elevated
; step, the user's language list and the live switch, reporting a failure.
; ==============================================================================

#Requires AutoHotkey v2.0




; Status ports: an AMD64 Windows whose files and registry are the given ones.
_SLI_Ports(Shipped, Klid, Installed, Same := true) {
	Exists(Path) {
		if InStr(Path, "\keyboard_layout\amd64\")
			return Shipped
		return Installed
	}
	return Map("architecture", () => "AMD64", "exists", Exists, "klid", (Dll) => Klid, "same", (A, B) => Same)
}

; Runs Body with no install in progress and restores the job and its timer.
_SLI_WithIdleJob(Body) {
	global _SystemLayoutJob
	Saved := _SystemLayoutJob
	_SystemLayoutJob := Map("stage", "", "pid", 0, "result", "", "klid", "", "spec", 0)
	try Body.Call()
	finally {
		SetTimer(SystemLayout_Poll, 0)
		_SystemLayoutJob := Saved
	}
}

/** The status reads the shipped build, the registry and System32. */
_SLI_Status() {
	Spec := SystemLayout_Spec()
	AssertEqual("unbuilt", SystemLayout_Status(Spec, _SLI_Ports(false, "", false))["status"], "no build in this copy")
	Ports := _SLI_Ports(true, "", false)
	Ports["architecture"] := () => "IA64"
	AssertEqual("unbuilt", SystemLayout_Status(Spec, Ports)["status"], "no build for this Windows")
	AssertEqual("not_installed", SystemLayout_Status(Spec, _SLI_Ports(true, "", false))["status"])
	AssertEqual("not_installed", SystemLayout_Status(Spec, _SLI_Ports(true, "A000040C", false))["status"],
		"a registry entry without its DLL is not an install")
	Status := SystemLayout_Status(Spec, _SLI_Ports(true, "A000040C", true, false))
	AssertEqual("outdated", Status["status"], "another build is installed")
	AssertEqual("A000040C", Status["klid"])
	AssertEqual("installed", SystemLayout_Status(Spec, _SLI_Ports(true, "A000040C", true))["status"])
}

/** One row per state; only an install or an update is a command. */
_SLI_MenuRows() {
	global _SystemLayoutJob
	Started := 0
	Install() {
		Started += 1
	}
	Unreadable() {
		throw Error("registry refused")
	}
	_SLI_WithIdleJob(() => (
		Rows := SystemLayout_MenuRows(() => Map("status", "not_installed", "klid", ""), Install),
		AssertEqual(1, Rows.Length),
		AssertEqual(t("menu.layout.system_layout_install"), Rows[1]["label"]),
		Rows[1]["action"].Call(),
		Rows := SystemLayout_MenuRows(() => Map("status", "outdated", "klid", "A000040C"), Install),
		AssertEqual(t("menu.layout.system_layout_update"), Rows[1]["label"]),
		Rows[1]["action"].Call(),
		Rows := SystemLayout_MenuRows(() => Map("status", "installed", "klid", "A000040C"), Install),
		AssertEqual(t("menu.layout.system_layout_installed"), Rows[1]["label"]),
		AssertFalse(Rows[1].Has("action"), "installed is an inert row"),
		Rows := SystemLayout_MenuRows(() => Map("status", "unbuilt", "klid", ""), Install),
		AssertEqual(t("menu.layout.system_layout_unbuilt"), Rows[1]["label"]),
		AssertFalse(Rows[1].Has("action")),
		Rows := SystemLayout_MenuRows(Unreadable, Install),
		AssertEqual(t("menu.layout.system_layout_unreadable"), Rows[1]["label"], "an unreadable state says so"),
		_SystemLayoutJob["stage"] := "elevated",
		Rows := SystemLayout_MenuRows(() => Map("status", "not_installed", "klid", ""), Install),
		AssertEqual(t("menu.layout.system_layout_installing"), Rows[1]["label"], "a running install shows progress"),
		AssertFalse(Rows[1].Has("action"))))
	AssertEqual(2, Started, "the install and the update rows start the installer")
	AssertContains(t("menu.layout.system_layout_install"), "…")
}

/** Declined, refused at UAC, then started: only the last one runs. */
_SLI_Install() {
	global _SystemLayoutJob
	Commands := []
	Told := []
	Tell(Message) {
		Told.Push(Message)
	}
	Refuse(Command, &Pid) {
		Commands.Push(Command)
		throw Error("The operation was canceled by the user.")
	}
	Accept(Command, &Pid) {
		Commands.Push(Command)
		Pid := 4242
	}
	_SLI_WithIdleJob(() => (
		AssertFalse(SystemLayout_Install(() => false, Accept, Tell), "a declined dialog starts nothing"),
		AssertEqual(0, Commands.Length),
		AssertFalse(SystemLayout_Install(() => true, Refuse, Tell), "a refused elevation is not an install"),
		AssertEqual(t("dialog.system_layout.elevation_refused"), Told[1]),
		AssertEqual("", _SystemLayoutJob["stage"]),
		AssertTrue(SystemLayout_Install(() => true, Accept, Tell)),
		SetTimer(SystemLayout_Poll, 0),
		AssertEqual("elevated", _SystemLayoutJob["stage"]),
		AssertEqual(4242, _SystemLayoutJob["pid"]),
		AssertFalse(SystemLayout_Install(() => true, Accept, Tell), "one install at a time")))
	AssertEqual(2, Commands.Length)
	AssertEqual(1, InStr(Commands[2], "*RunAs powershell.exe "), "the installer runs through UAC")
	AssertContains(Commands[2], "\keyboard_layout\install_keyboard_layout.ps1")
	AssertContains(Commands[2], "-Action install")
	AssertContains(Commands[2], "windows_system_layout.json")
	AssertContains(t("dialog.system_layout.confirm"), "Windows")
}

; Writes a step outcome where the running job expects it.
_SLI_WriteOutcome(Json) {
	global _SystemLayoutJob
	FSDelete(_SystemLayoutJob["result"])
	AssertTrue(FSWrite(_SystemLayoutJob["result"], Json), "the outcome fixture is written")
}

/** The elevated step, then the user step, then the live switch. */
_SLI_PollChain() {
	global _SystemLayoutJob
	Commands := []
	Finished := []
	Told := []
	Run(Command, &Pid) {
		Commands.Push(Command)
		Pid := 4343
	}
	Accept(Command, &Pid) {
		Pid := 4242
	}
	_SLI_WithIdleJob(() => (
		SystemLayout_Install(() => true, Accept, (Message) => Told.Push(Message)),
		SetTimer(SystemLayout_Poll, 0),
		_SLI_WriteOutcome('{"status":"installed","klid":"A000040C","message":""}'),
		AssertEqual("user", SystemLayout_Poll(Run, (Klid) => Finished.Push(Klid))),
		SetTimer(SystemLayout_Poll, 0),
		AssertEqual(1, Commands.Length),
		AssertEqual("A000040C", _SystemLayoutJob["klid"]),
		_SLI_WriteOutcome('{"status":"added","message":""}'),
		AssertEqual("", SystemLayout_Poll(Run, (Klid) => Finished.Push(Klid)))))
	AssertFalse(InStr(Commands[1], "*RunAs"), "the language list step runs as the user")
	AssertContains(Commands[1], "add_user_keyboard_layout.ps1")
	AssertContains(Commands[1], "-Klid A000040C")
	AssertContains(Commands[1], "-LanguageId " . SystemLayout_Spec()["language_id"])
	AssertEqual(1, Finished.Length)
	AssertEqual("A000040C", Finished[1], "the installed layout is selected")
	AssertEqual(0, Told.Length)
}

/** A failed install is told with its reason and selects nothing. */
_SLI_PollFailure() {
	global _SystemLayoutJob
	Finished := []
	Told := []
	Accept(Command, &Pid) {
		Pid := 4242
	}
	_SLI_WithIdleJob(() => (
		SystemLayout_Install(() => true, Accept, (Message) => Told.Push(Message)),
		SetTimer(SystemLayout_Poll, 0),
		_SLI_WriteOutcome('{"status":"failed","klid":"","message":"no DLL"}'),
		AssertEqual("", SystemLayout_Poll(Accept, (Klid) => Finished.Push(Klid))),
		AssertEqual("", _SystemLayoutJob["stage"])))
	AssertEqual(0, Finished.Length)
	AssertEqual(Format(t("dialog.system_layout.failed"), "no DLL"), Told[1])
}

Test("system layout install: the status follows the build, the registry and System32", _SLI_Status)
Test("system layout install: one menu row per state", _SLI_MenuRows)
Test("system layout install: asks first, a UAC refusal changes nothing", _SLI_Install)
Test("system layout install: elevated step, user languages, then the switch", _SLI_PollChain)
Test("system layout install: a failed install is told and selects nothing", _SLI_PollFailure)

; tests/meta/infra/lifecycle/test_boot_paths_fail_soft.ahk

; ==============================================================================
; MODULE: Regression — nothing in the boot path may abort it, and no HotIf
;         criterion may leak (boot-paths-fail-soft)
; DESCRIPTION:
; Three ways the auto-execute section could be left half-finished, each leaving
; a resident driver with some hotkeys armed and others never registered — the
; worst possible state, because the keyboard is partly remapped and nothing
; says so.
;
;   L-10  ReadPathsToml called FileRead with no guard. It runs during the
;         auto-execute section, before the logger exists and while parse-time
;         hotkeys are already armed, so a locked paths.toml — a sync client, an
;         AV scan — threw straight out of boot.
;
;   L-08  The always-armed Ctrl+Alt+Shift+I rescue hotkey called LoggerInfo
;         bare. It has no #HotIf by design, so it is live during Bundle_Init's
;         message-pumping RunWait, before the logger's severity flags exist:
;         pressing the hotkey that exists to rescue a broken LLM killed the boot
;         it was meant to rescue.
;
;   L-11  RegisterCapsLockLayer reset its HotIf criterion with a bare call while
;         its sibling RegisterShiftLayer used a finally. HotIf is PROCESS-WIDE
;         and stays in force until cleared, so a throwing Hotkey() leaked the
;         CapsLock condition onto every hotkey registered afterwards — those
;         would then only fire while CapsLock happened to be active.
;
; ROOT CAUSE ENCODED: boot-time code has no error net worth the name. The global
; handler treats any pre-ready fault as fatal, so "let it throw" is not a
; recovery strategy here — it is the failure. Each of these must degrade to a
; documented fallback instead.
;
; SCOPE: behavioural for the reader (a real exclusive lock); source-level for
; the hotkey and the registration, which bind live hotkeys at parse time.
; ==============================================================================

#Requires AutoHotkey v2.0

global _BPF_EXCLUSIVE_LOCK_FLAGS := "r-rwd"




; ==================================================================
; ==================================================================
; ======= 1/ A locked paths.toml does not abort the boot ===========
; ==================================================================
; ==================================================================

_BPF_LockedPathsTomlFallsBack() {
	Path := A_Temp . "\ergopti_test_paths_" . A_TickCount . ".toml"
	try FileDelete(Path)
	FileAppend('ConfigDirPath = "C:/somewhere/"' . "`n", Path, "UTF-8")

	Lock := FileOpen(Path, _BPF_EXCLUSIVE_LOCK_FLAGS)
	Assert(Lock != "" and IsObject(Lock), "the test could not take an exclusive lock — it would otherwise assert nothing")
	Threw := ""
	Result := ""
	try {
		Result := ReadPathsToml(Path)
	} catch as Err {
		Threw := Err.Message
	}
	Lock.Close()

	Assert(Threw == "",
		"ReadPathsToml must not throw on a locked file. It runs in the auto-execute section with parse-time hotkeys already armed, so an exception here aborts the boot mid-way and leaves a resident driver with a subset of its keys remapped. Got: " . Threw)
	Assert(Result is Map,
		"it must still return a Map so the caller's .Has checks keep working")

	; The fallback must be the DEFAULT directory, i.e. no override — the same
	; state as a paths.toml that sets nothing.
	Assert(Result.Count == 0,
		"an unreadable paths.toml must yield no overrides, falling back to the default configuration directory")

	; And a readable file must still be read, or the guard is a regression.
	Ok := ReadPathsToml(Path)
	try FileDelete(Path)
	Assert(Ok.Has("ConfigDirPath"),
		"a readable paths.toml must still provide its override")
}

_BPF_PathsTomlStripsOnlyUnquotedInlineComments() {
	Path := A_Temp . "\ergopti_test_paths_comments_" . A_TickCount . ".toml"
	try FileDelete(Path)
	try {
		FileAppend('ConfigDirPath = "D:/cfg" # operator note' . "`n"
			. 'HashPath = "D:/configs/#team" # another note' . "`n", Path, "UTF-8")
		Result := ReadPathsToml(Path)
		Assert(Result.Has("ConfigDirPath"),
			"an inline comment after a paths.toml value must not discard the assignment")
		AssertEqual("D:\cfg", Result["ConfigDirPath"])
		Assert(Result.Has("HashPath"), "the second fixture row must be parsed")
		AssertEqual("D:\configs\#team", Result["HashPath"],
			"a hash inside the quoted path is data and must never start a comment")
	} finally try FileDelete(Path)
}





; ==================================================================
; ==================================================================
; ======= 2/ The always-armed rescue hotkey cannot kill boot =======
; ==================================================================
; ==================================================================

; This hotkey is deliberately armed with no #HotIf, which is exactly what makes
; it dangerous: it is live from parse time, long before the logger exists.
_BPF_RescueHotkeyIsGuarded() {
	Src := _StripFullLineComments(_DriverDirConcat("ui/menu/menu_llm"))
	Assert(Src != "", "the LLM menu sources must be readable")

	Start := InStr(Src, "^!+i::")
	Assert(Start > 0, "the Ctrl+Alt+Shift+I rescue hotkey must still exist")
	Body := SubStr(Src, Start, 600)

	Assert(RegExMatch(Body, "try\s+LoggerInfo"),
		"the rescue hotkey's first log call must be try-wrapped. It is armed at parse time with no #HotIf, so it is live during Bundle_Init's message-pumping RunWait — a bare LoggerInfo there reads the logger's severity flags before they exist, throws inside a hotkey thread while the boot phase is still 'starting', and the error net treats that as fatal")
	Assert(InStr(Body, "try TrayTip") > 0 and InStr(Body, "try LLM_Menu_BootstrapOllama") > 0,
		"every other call in the rescue handler must stay guarded too — the whole point of the hotkey is to work when the driver is already in a bad state")
}





; ==================================================================
; ==================================================================
; ======= 3/ No layer registration leaks its HotIf criterion =======
; ==================================================================
; ==================================================================

; HotIf is process-wide. Both sibling registrations must clear it in a finally,
; or a throw part-way through silently re-contexts every hotkey registered
; afterwards — including in modules loaded much later.
_BPF_LayerRegistrationsClearHotIfInFinally() {
	for FuncName in ["RegisterShiftLayer", "RegisterCapsLockLayer"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")
		Assert(InStr(Body, "HotIf(") > 0, FuncName . " must still set a HotIf criterion")
		Assert(InStr(Body, "finally") > 0,
			FuncName . " must clear its HotIf criterion in a finally. HotIf is process-wide and stays in force until cleared, so a Hotkey() that throws part-way through leaks the criterion onto every registration that follows — those hotkeys then only fire when that condition happens to hold")

		; The reset must be INSIDE the finally, not merely present somewhere.
		FinallyPos := InStr(Body, "finally")
		Tail := SubStr(Body, FinallyPos)
		Assert(RegExMatch(Tail, "HotIf\(\s*\)"),
			FuncName . "'s finally must contain the bare HotIf() reset — a finally that does not clear the criterion protects nothing")
	}
}

; The guard must cover the WHOLE registration, not just its last block. The
; first Hotkey() call is as able to throw as the last.
_BPF_CapsLockGuardCoversEveryRegistration() {
	Body := _DriverFuncBody("RegisterCapsLockLayer")
	Assert(Body != "", "RegisterCapsLockLayer() must exist")

	TryPos := InStr(Body, "try {")
	Assert(TryPos > 0, "RegisterCapsLockLayer must open a try block")

	; Every Hotkey() registration must sit after that try opens.
	Pos := 1
	Registrations := 0
	while (F := RegExMatch(Body, "\bHotkey\(", &M, Pos)) {
		Pos := F + M.Len
		Registrations += 1
		Assert(F > TryPos,
			"every Hotkey() call in RegisterCapsLockLayer must be inside the guarded block — one left outside can throw with the CapsLock criterion armed and leak it exactly as before")
	}
	Assert(Registrations >= 2,
		"the scan must reach the real registrations (found only " . Registrations . ") — a scan that matches nothing cannot fail")
}


Test("meta boot-paths-fail-soft: a locked paths.toml falls back instead of throwing",
	_BPF_LockedPathsTomlFallsBack)
Test("AHK-007: paths.toml strips only unquoted inline comments",
	_BPF_PathsTomlStripsOnlyUnquotedInlineComments)
Test("meta boot-paths-fail-soft: the always-armed rescue hotkey is guarded",
	_BPF_RescueHotkeyIsGuarded)
Test("meta boot-paths-fail-soft: layer registrations clear HotIf in a finally",
	_BPF_LayerRegistrationsClearHotIfInFinally)
Test("meta boot-paths-fail-soft: the CapsLock guard covers every registration",
	_BPF_CapsLockGuardCoversEveryRegistration)


; Read the actual private profile selected by each equivalent TOML spelling.
; The canonical semantic decoder independently proves the source's identity.
_BPF_PathsTomlSemanticDirectory(Shape, Key) {
	Directory := A_Temp . "\ergopti_paths_semantic_" . A_ScriptHwnd . "_" . A_TickCount
	Desired := Directory . "\café O'Brien profile\" . AppDirsFolderName() . "\"
	Path := Directory . "\paths.toml"
	DirCreate(Desired)
	try {
		FileAppend("selected profile", Desired . "receipt.txt", "UTF-8-RAW")
		Forward := StrReplace(Desired, "\", "/")
		switch Shape {
			case "canonical": Source := Key . ' = "' . Forward . '"`n'
			case "unicode-escape": Source := Key . ' = "' . StrReplace(Forward, "é", "\u00e9") . '"`n'
			case "escaped-backslashes": Source := Key . " = " . TOML_RenderString(Desired) . "`n"
			case "literal-string":
				Template := FileRead(A_ScriptDir . "\fixtures\paths_literal_string.toml.template", "UTF-8")
				Source := StrReplace(StrReplace(Template, "__key__", Key), "__path__", Forward)
			case "quoted-key": Source := '"' . Key . '" = "' . Forward . '"`n'
			default: throw ValueError("Unknown bootstrap TOML shape")
		}
		Document := TOML_ParseDocument(Source)
		AssertEqual(Shape == "escaped-backslashes" ? Desired : Forward, Document[Key],
			"the real semantic decoder must admit the fixture")
		FileAppend(Source, Path, "UTF-8-RAW")
		Overrides := ReadPathsToml(Path)
		AssertTrue(Overrides.Has(Key), "a valid locator spelling must retain the configuration key")
		AssertEqual(Desired, Overrides[Key], "the locator must decode TOML string contents exactly once")
		Selected := Key == "ConfigDirPath"
			? ConfigTransitionSelectBootConfigDir(Overrides, Directory . "\fallback\")
			: LoggerResolveLogsDir(Overrides[Key], Directory . "\fallback\")
		AssertEqual(Desired, Selected, "boot must select the exact authored profile")
		AssertEqual("selected profile", FileRead(Selected . "receipt.txt", "UTF-8"),
			"the selected profile must reach the actual private file")
		AssertEqual(Source, FileRead(Path, "UTF-8"), "reading must preserve every locator byte")
	} finally DirDelete(Directory, true)
}
for _bpfPathShape in ["canonical", "unicode-escape", "literal-string", "quoted-key", "escaped-backslashes"] {
	for _bpfPathKey in ["ConfigDirPath", AppDirsLogsOverrideKey()]
		Test("bootstrap paths: equivalent " . _bpfPathShape . " TOML selects " . _bpfPathKey . " (bootstrap-toml-directory)",
			_BPF_PathsTomlSemanticDirectory.Bind(_bpfPathShape, _bpfPathKey))
}


_BPF_PathsTomlEarlyOwner(Mode) {
	Directory := A_Temp . "\ergopti_paths_early_" . A_ScriptHwnd . "_" . A_TickCount
	DirCreate(Directory)
	Locator := Directory . "\paths.toml", Receipt := Directory . "\receipt.txt"
	Source := 'ConfigDirPath = "C:/café/"`n'
	if Mode == "malformed"
		Source .= "[unterminated`n"
	try {
		FileAppend(Source, Locator, "UTF-8-RAW")
		Fixture := A_ScriptDir . "\fixtures\paths_toml_early_owner.ahk"
		AssertTrue(FileExist(Fixture) != "", "the actual early-owner child must exist")
		Command := '"' . A_AhkPath . '" /ErrorStdOut "' . Fixture . '" "' . Locator . '" "' . Receipt . '"'
		ExitCode := RunWait(Command, A_ScriptDir, "Hide")
		Evidence := FileRead(Receipt, "UTF-8")
		if Mode == "valid" {
			AssertEqual(0, ExitCode, "reading needs no late manifest or configuration globals")
			AssertContains(Evidence, "parsed_key=C:\café\")
			AssertContains(Evidence, "semantic_parses=1")
			AssertContains(Evidence, "counter_parses=1")
			AssertContains(Evidence, "after_read")
			AssertFalse(InStr(Evidence, "fatal-startup=") > 0, "a valid locator must not enter fatal handling")
		} else {
			AssertEqual(1, ExitCode, "malformed startup authority must terminate the actual child")
			AssertContains(Evidence, "fatal-startup=starting")
			AssertContains(Evidence, "Unterminated TOML document record")
			AssertContains(Evidence, "ReadPathsToml")
			AssertContains(Evidence, "toml_document.ahk")
			AssertFalse(InStr(Evidence, "after_read") > 0, "fatal handling must prevent a partial startup continuation")
		}
		AssertContains(Evidence, "exit=Exit/" . ExitCode, "the genuine process exit must be independently observed")
		AssertEqual(Source, FileRead(Locator, "UTF-8"), "even a refused locator remains unchanged")
	} finally DirDelete(Directory, true)
}
for _bpfEarlyMode in ["valid", "malformed"]
	Test("bootstrap paths: " . _bpfEarlyMode . " source honors the early error owner (bootstrap-toml-early-owner)",
		_BPF_PathsTomlEarlyOwner.Bind(_bpfEarlyMode))

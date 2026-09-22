; tests/unit/test_diagnostic_logging.ahk

; ==============================================================================
; MODULE: Boot diagnostics, runtime events and log privacy (Windows)
; DESCRIPTION:
; 1. The diagnostic snapshot is a cross-driver contract: the field list matches
;    _shared/modules/logger/diagnostic_snapshot.json, every shared vector renders
;    byte for byte, and the emitted line is one INFO line with every field.
; 2. Boot stages pair START with SUCCESS (or a WARNING abort), and the entry
;    point closes every stage it opens and logs the snapshot after "ready".
; 3. Failures that were swallowed with no trace now log: a refused launch, a
;    config file's ignored keys, a process exit.
; 4. Privacy: a hotstring driven through the engine at DEBUG leaves neither its
;    trigger nor its replacement in the log, and launch arguments never appear.
; ==============================================================================

#Requires AutoHotkey v2.0

; Resets the ring buffer and dedup state and forces DEBUG, so a test reads only
; its own lines and nothing is filtered away.
_TDL_ResetLog() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
}

; Every ring line joined, so an absence is checked across all of them at once.
_TDL_RingText() {
	Text := ""
	for _, Line in LoggerRingBufferSnapshot()
		Text .= Line . "`n"
	return Text
}

; The shared snapshot contract.
_TDL_Contract() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\modules\logger\diagnostic_snapshot.json", "UTF-8"))
}

; Reads the driver entry point as text.
_TDL_EntrySource() {
	global _DriverDir
	return FileRead(_DriverDir . "\ErgoptiPlus.ahk", "UTF-8")
}





; ============================================
; ============================================
; ======= 1/ Diagnostic snapshot contract ====
; ============================================
; ============================================

_TDL_FieldsMatchContract() {
	Contract := _TDL_Contract()
	Fields := DiagSnapshot_Fields()
	AssertEqual(Contract["fields"].Length, Fields.Length, "field count")
	for Index, Name in Contract["fields"]
		AssertEqual(Name, Fields[Index], "field " . Index)
	AssertEqual(Contract["module"], DiagSnapshot_Module(), "log tag")
}
Test("diagnostics: the AHK field list is the shared contract, in order", _TDL_FieldsMatchContract)

_TDL_VectorsRender() {
	Vectors := _TDL_Contract()["vectors"]
	Assert(Vectors.Length >= 3, "the shared vectors must load — zero would make this vacuous")
	for _, Vector in Vectors
		AssertEqual(Vector["expected"], DiagSnapshot_Format(Vector["values"]), "vector " . Vector["id"])
}
Test("diagnostics: every shared snapshot vector renders byte for byte", _TDL_VectorsRender)

_TDL_EmitCarriesEveryField() {
	_TDL_ResetLog()
	DiagSnapshot_Emit(812)
	Found := []
	for _, Line in LoggerRingBufferSnapshot() {
		if InStr(Line, "[Diagnostics]")
			Found.Push(Line)
	}
	AssertEqual(1, Found.Length, "exactly one snapshot line")
	Assert(InStr(Found[1], "[INFO]"), "at INFO: " . Found[1])
	for _, Name in _TDL_Contract()["fields"]
		Assert(InStr(Found[1], Name . "="), "field '" . Name . "' missing: " . Found[1])
	Assert(InStr(Found[1], "driver=windows"), Found[1])
	Assert(InStr(Found[1], "boot_ms=812"), Found[1])
	Assert(InStr(Found[1], "runtime=" . Chr(34) . "AutoHotkey " . A_AhkVersion . Chr(34)), Found[1])
	Profile := EnvGet("USERPROFILE")
	SplitPath(Profile, &Account)
	if (Account != "")
		Assert(!InStr(Found[1], "\" . Account . "\"), "the account directory must not be logged: " . Found[1])
}
Test("diagnostics: the emitted snapshot is one INFO line carrying every field", _TDL_EmitCarriesEveryField)

_TDL_RedactsHome() {
	AssertEqual("~\config", DiagSnapshot_RedactHome("C:\Users\alice\config", "C:\Users\alice"))
	AssertEqual("C:\Users\alicex\cfg", DiagSnapshot_RedactHome("C:\Users\alicex\cfg", "C:\Users\alice"),
		"a sibling account sharing a prefix is not the home directory")
}
Test("diagnostics: the configuration path is rendered relative to the profile", _TDL_RedactsHome)

_TDL_GitCommitFromWorktreePointer() {
	Root := A_Temp . "\ergopti_tdl_git_" . A_TickCount
	Sha := "3b924cd46aaaabbbbccccddddeeeeffff0000111"
	try {
		DirCreate(Root . "\repo\.git\worktrees\wt")
		DirCreate(Root . "\repo\.git\refs\heads")
		DirCreate(Root . "\wt\static")
		FileAppend("gitdir: " . Root . "\repo\.git\worktrees\wt`n", Root . "\wt\.git", "UTF-8-RAW")
		FileAppend("ref: refs/heads/feature`n", Root . "\repo\.git\worktrees\wt\HEAD", "UTF-8-RAW")
		FileAppend("../..`n", Root . "\repo\.git\worktrees\wt\commondir", "UTF-8-RAW")
		FileAppend(Sha . "`n", Root . "\repo\.git\refs\heads\feature", "UTF-8-RAW")
		AssertEqual("3b924cd46", DiagSnapshot_GitCommit(Root . "\wt\static"),
			"a linked worktree resolves its branch through the common directory")
		AssertEqual("", DiagSnapshot_GitCommit(A_Temp . "\ergopti_tdl_no_repo_" . A_TickCount),
			"outside a repository there is no commit")
	} finally {
		try DirDelete(Root, true)
	}
}
Test("diagnostics: a source checkout reports its commit from .git", _TDL_GitCommitFromWorktreePointer)





; ======================================
; ======================================
; ======= 2/ Boot stages ===============
; ======================================
; ======================================

_TDL_StagesPair() {
	_TDL_ResetLog()
	BootProfile_StageBegin("tdl stage")
	BootProfile_StageEnd("tdl stage", "3 thing(s)")
	BootProfile_StageBegin("tdl aborted")
	BootProfile_StageAbort("tdl aborted", "refused")
	Text := _TDL_RingText()
	Assert(InStr(Text, "[START] [BootProfile] Boot stage 'tdl stage'…"), Text)
	Assert(RegExMatch(Text, "\[SUCCESS\] \[BootProfile\] Boot stage 'tdl stage' done in \d+ ms: 3 thing\(s\)\."), Text)
	Assert(InStr(Text, "[WARNING] [BootProfile] Boot stage 'tdl aborted' did not complete"), Text)
	AssertEqual("", BootProfile_OpenStageNames(), "both stages are closed")
}
Test("boot stages: START pairs with a timed SUCCESS, an abort is a WARNING", _TDL_StagesPair)

_TDL_EntryClosesEveryStage() {
	Src := _TDL_EntrySource()
	Count := 0
	Pos := 1
	while (Pos := RegExMatch(Src, 'BootProfile_StageBegin\("([^"]+)"\)', &M, Pos)) {
		Count += 1
		Assert(InStr(Src, 'BootProfile_StageEnd("' . M[1] . '"'),
			"stage '" . M[1] . "' is opened but never closed: a boot that dies there would be unnamed")
		Pos += StrLen(M[0])
	}
	Assert(Count >= 8, "the boot must be split into stages, found " . Count)
}
Test("boot stages: the entry point closes every stage it opens", _TDL_EntryClosesEveryStage)

_TDL_SnapshotFollowsReady() {
	Src := _TDL_EntrySource()
	Ready := InStr(Src, 'LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")')
	Complete := InStr(Src, '"Boot complete in {1} ms (since process start)."')
	Emit := InStr(Src, "try DiagSnapshot_Emit(_BootTotalMs)")
	Early := InStr(Src, "DiagSnapshot_EarlyLine()")
	Assert(Ready && Complete && Emit && Early, "ready, boot total, snapshot and early environment lines must exist")
	Assert(Early < Ready, "the environment is described before any stage can fail")
	Assert(Ready < Complete && Complete < Emit, "the snapshot follows ready and carries the boot total")
}
Test("boot stages: the snapshot is logged after ready, the environment before", _TDL_SnapshotFollowsReady)





; ======================================
; ======================================
; ======= 3/ Previously silent =========
; ======================================
; ======================================

_TDL_FailedLaunchIsLogged() {
	_TDL_ResetLog()
	Missing := A_Temp . "\ergopti_tdl_missing_" . A_TickCount . "\nothing.exe"
	AL_LaunchWithArgs(Missing, "--query zqxsecretarg")
	Text := _TDL_RingText()
	Assert(InStr(Text, "[ERROR] [AppLauncher] Launch of 'nothing.exe' with arguments failed"),
		"a refused launch used to leave no trace at all: " . Text)
	Assert(!InStr(Text, "zqxsecretarg"), "launch arguments can carry user text and are never logged")
	AssertEqual("https:", AL_ProgramName("https://example.com/search?q=zqx"), "a URI is named by its scheme")
}
Test("runtime: a refused launch is logged by program name, never with its arguments", _TDL_FailedLaunchIsLogged)

_TDL_ConfigSummaryCountsUnknownKeys() {
	Path := A_Temp . "\ergopti_tdl_config_" . A_TickCount . ".toml"
	try {
		FileAppend("[shortcuts]`nzqx_not_a_feature = true`n[layout]`nzqx_unknown_leaf = true`n", Path, "UTF-8-RAW")
		_TDL_ResetLog()
		ApplyConfigToml(ManifestBuildFeaturesMap(), Path)
		Text := _TDL_RingText()
		Assert(InStr(Text, "Config summary for '" . Path . "': 0 applied, 0 rejected, 2 unknown key(s) ignored"),
			"the summary must count the ignored keys: " . Text)
	} finally {
		try FileDelete(Path)
	}
}
Test("runtime: a config load summarises how many keys it ignored", _TDL_ConfigSummaryCountsUnknownKeys)

_TDL_ProcessExitIsThrottled() {
	_TDL_ResetLog()
	Program := "tdl" . A_TickCount . ".exe"
	Assert(_SR_RecordExit(Program, 3, 5), "the first exit of a program is logged")
	AssertFalse(_SR_RecordExit(Program, 0, 5), "a quick repeat inside the window is folded")
	Assert(_SR_RecordExit(Program, 0, 1500), "a slow run is always logged")
	Text := _TDL_RingText()
	Assert(InStr(Text, "Process '" . Program . "' exited (status=3, 5 ms"), Text)
	Assert(InStr(Text, "1 similar run(s) since the last line"), Text)
	AssertEqual("curl.exe", _SR_ProgramName('"C:\Program Files\curl\curl.exe" -d "zqx secret"'))
}
Test("runtime: process exits are logged by program, status and duration, throttled", _TDL_ProcessExitIsThrottled)

_TDL_CallerNameReadsTheStack() {
	AssertEqual("_TDL_CallerNameProbe", _TDL_CallerNameProbeOuter())
}
_TDL_CallerNameProbeOuter() {
	return _TDL_CallerNameProbe()
}
_TDL_CallerNameProbe() {
	; -1 is this function itself: the helper that reload/suspend call with -2.
	return DiagCallerName(-1)
}
Test("runtime: a lifecycle request can name its requester from the call stack", _TDL_CallerNameReadsTheStack)

_TDL_RuntimeSitesLog() {
	Toggle := _DriverFuncBody("ToggleFeatureV2")
	Assert(Toggle != "", "ToggleFeatureV2 must exist")
	Assert(InStr(Toggle, "toggled to {2}; reloading to apply"), "a menu toggle logs its id and new state")
	Reload := _DriverFuncBody("ReloadPreservingSuspend")
	Assert(Reload != "", "ReloadPreservingSuspend must exist")
	Assert(InStr(Reload, "Reload requested by {1}"), "a reload names its requester")
	Suspend := _DriverFuncBody("ToggleSuspend")
	Assert(Suspend != "", "ToggleSuspend must exist")
	Assert(InStr(Suspend, "Suspend toggle requested by {1}"), "a suspend toggle names its requester")
	Result := _DriverFuncBody("_Updater_HandleBackgroundResult")
	Assert(Result != "", "_Updater_HandleBackgroundResult must exist")
	Assert(InStr(Result, "Background check result: up to date"), "an update check logs its result at INFO")
	Assert(InStr(Result, "carried no tag"), "a tagless response is no longer reported as up to date")
}
Test("runtime: toggles, reloads, suspends and update checks are logged", _TDL_RuntimeSitesLog)





; ======================================
; ======================================
; ======= 4/ Privacy ===================
; ======================================
; ======================================

_TDL_FiredHotstringLeavesNoText() {
	static TRIGGER := "qzxtrig"
	static REPLACEMENT := "zqx private replacement"
	HSE_TestReset()
	_TDL_ResetLog()
	try {
		CreateHotstring("*?", TRIGGER, REPLACEMENT)
		HSE_FeedReset(true)
		Match := ""
		for Char in StrSplit(TRIGGER)
			Match := HSE_FeedChar(Char)
		Assert(IsObject(Match), "the hotstring must match, or the absence below proves nothing")
		Assert(HSE_DispatchMatch(Match, ""), "and the fire path must run end to end")
		; A snapshot and a boot stage are logged in the same window, so the check
		; also covers the new diagnostic lines.
		DiagSnapshot_Emit(1)
		BootProfile_StageBegin("tdl privacy")
		BootProfile_StageEnd("tdl privacy")
		Text := _TDL_RingText()
		Assert(Text != "", "something must have been logged, or this test inspects nothing")
		Assert(!InStr(Text, TRIGGER), "the trigger leaked into the log: " . Text)
		Assert(!InStr(Text, "zqx private"), "the replacement leaked into the log: " . Text)
	} finally {
		HSE_TestReset()
	}
}
Test("privacy: a fired hotstring and the diagnostic lines leave no typed text in the log", _TDL_FiredHotstringLeavesNoText)

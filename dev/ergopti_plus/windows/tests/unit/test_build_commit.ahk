; tests/unit/test_build_commit.ahk

; ==============================================================================
; MODULE: Build commit in the diagnostics (Windows)
; DESCRIPTION:
; The compiled release is stamped with BUNDLE_COMMIT, and the boot snapshot
; already read it, but the healthcheck and the crash report still asked
; `git rev-parse` in A_ScriptDir: a compiled build has no checkout there, so
; "Last git commit" was empty on every release. All three now share
; DiagSnapshot_ResolveCommit: the stamp, else the checkout's HEAD, else an
; explicit "unknown" that is logged with its reason.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TBC_SHA := "f58d15798aaaabbbbccccddddeeeeffff0000111"
global _TBC_OTHER_SHA := "3b924cd46aaaabbbbccccddddeeeeffff0000111"

; Resets the ring buffer at DEBUG so a test reads only its own lines.
_TBC_ResetLog() {
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

; Every ring line joined.
_TBC_RingText() {
	Text := ""
	for _, Line in LoggerRingBufferSnapshot()
		Text .= Line . "`n"
	return Text
}

; A throwaway repository whose HEAD is _TBC_OTHER_SHA, so an answer taken from
; git instead of the stamp is detectable.
_TBC_MakeRepo() {
	global _TBC_OTHER_SHA
	Root := A_Temp . "\ergopti_tbc_" . A_TickCount . "_" . Random(1000, 9999)
	DirCreate(Root . "\.git")
	DirCreate(Root . "\static")
	FileAppend(_TBC_OTHER_SHA . "`n", Root . "\.git\HEAD", "UTF-8-RAW")
	return Root
}





; =====================================
; =====================================
; ======= 1/ Resolver =================
; =====================================
; =====================================

_TBC_StampParsing() {
	global _TBC_SHA
	AssertEqual("", DiagSnapshot_BuildCommit("__BUNDLE_COMMIT__")["commit"], "an unstamped build has no commit")
	AssertEqual("", DiagSnapshot_BuildCommit("__BUNDLE_COMMIT__")["error"], "and that is not an error")
	AssertEqual("f58d15798", DiagSnapshot_BuildCommit(_TBC_SHA)["commit"])
	AssertEqual("f58d15798", DiagSnapshot_BuildCommit(StrUpper(_TBC_SHA))["commit"], "case is normalised")
	Bad := DiagSnapshot_BuildCommit("v3.0.0")
	AssertEqual("", Bad["commit"])
	Assert(InStr(Bad["error"], "v3.0.0"), "the malformed stamp is named: " . Bad["error"])
}
Test("build commit: the BUNDLE_COMMIT stamp is parsed and validated", _TBC_StampParsing)

_TBC_StampWinsOverCheckout() {
	global _TBC_SHA
	Root := _TBC_MakeRepo()
	try {
		Result := DiagSnapshot_ResolveCommit(Root . "\static", _TBC_SHA)
		AssertEqual("f58d15798", Result["commit"])
		AssertEqual("build", Result["source"])
		Result := DiagSnapshot_ResolveCommit(Root . "\static", "__BUNDLE_COMMIT__")
		AssertEqual("3b924cd46", Result["commit"], "a source run answers from its checkout")
		AssertEqual("git", Result["source"])
	} finally {
		try DirDelete(Root, true)
	}
}
Test("build commit: the stamp wins over a checkout, which answers a source run", _TBC_StampWinsOverCheckout)

_TBC_UnknownIsLogged() {
	Root := _TBC_MakeRepo()
	try {
		_TBC_ResetLog()
		Result := DiagSnapshot_ResolveCommit(A_Temp . "\ergopti_tbc_no_repo_" . A_TickCount, "__BUNDLE_COMMIT__")
		AssertEqual("unknown", Result["commit"])
		AssertEqual("unknown", Result["source"])
		Text := _TBC_RingText()
		Assert(InStr(Text, "[WARNING] [BuildCommit] Build commit unknown: no build stamp"), Text)
		Assert(!InStr(Text, "[Diagnostics]"), "the snapshot's grep tag stays reserved for the snapshot line")

		_TBC_ResetLog()
		Result := DiagSnapshot_ResolveCommit(Root . "\static", "not-a-sha")
		AssertEqual("unknown", Result["commit"], "a malformed stamp is not hidden behind the checkout's commit")
		Assert(InStr(_TBC_RingText(), "not-a-sha"), _TBC_RingText())
	} finally {
		try DirDelete(Root, true)
	}
}
Test("build commit: an unknown commit is explicit and logged with its reason", _TBC_UnknownIsLogged)





; =====================================
; =====================================
; ======= 2/ Consumers ================
; =====================================
; =====================================

_TBC_HealthcheckUsesStamp() {
	global _TBC_SHA, _ConfigDir, BUNDLE_COMMIT
	Old := BUNDLE_COMMIT
	BUNDLE_COMMIT := _TBC_SHA
	try {
		Info := _HealthCheck_SysInfo()
		AssertEqual("f58d15798", Info["git_hash"], "a compiled build's healthcheck names its stamped commit")
		AssertEqual("build", Info["commit_source"])
		AssertEqual(A_ScriptDir, Info["script_dir"], "the script folder has its own field")
		AssertEqual(IsSet(_ConfigDir) ? _ConfigDir : "", Info["config_dir"],
			"the config dir is the driver's configuration folder")
	} finally {
		BUNDLE_COMMIT := Old
	}
}
Test("build commit: the healthcheck reports the compiled build's stamp", _TBC_HealthcheckUsesStamp)

_TBC_CrashReportUsesStamp() {
	global _TBC_SHA, BUNDLE_COMMIT
	Old := BUNDLE_COMMIT
	try {
		BUNDLE_COMMIT := _TBC_SHA
		AssertEqual("f58d15798", _CrashReport_SysInfo()["git_hash"],
			"the crash report's system probe names the stamped commit")
		AssertEqual("f58d15798", _CrashReport_CheapSnapshot(Error("stamped"))["git_hash"],
			"the worker snapshot carries the stamp so the worker never asks git")
		BUNDLE_COMMIT := "__BUNDLE_COMMIT__"
		AssertEqual("", _CrashReport_CheapSnapshot(Error("source"))["git_hash"],
			"a source run leaves the commit for the worker to read from the checkout")
	} finally {
		BUNDLE_COMMIT := Old
	}
}
Test("build commit: the crash report paths carry the compiled build's stamp", _TBC_CrashReportUsesStamp)

_TBC_SnapshotUsesStamp() {
	global _TBC_SHA, BUNDLE_COMMIT
	Old := BUNDLE_COMMIT
	BUNDLE_COMMIT := _TBC_SHA
	try {
		AssertEqual("f58d15798", DiagSnapshot_Collect(1)["commit"])
	} finally {
		BUNDLE_COMMIT := Old
	}
}
Test("build commit: the boot snapshot reports the compiled build's stamp", _TBC_SnapshotUsesStamp)

; The copy-to-clipboard texts (plain and Markdown) must carry the same two rows
; the HTML view shows. They lacked both, so a pasted report named no commit and
; no install folder: exactly the two facts a bug triage asks for first.
_TBC_CopyTextsCarryCommitAndAppDir() {
	global _TBC_SHA, BUNDLE_COMMIT
	Old := BUNDLE_COMMIT
	BUNDLE_COMMIT := _TBC_SHA
	try {
		Snapshot := HealthCheck_Run()
		Plain := HealthCheck_FormatPlain(Snapshot)
		Markdown := HealthCheck_FormatMarkdown(Snapshot)
		Assert(InStr(Plain, "Last git commit : f58d15798 (build)`r`n") > 0, Plain)
		Assert(InStr(Plain, "App dir         : " . A_ScriptDir . "`r`n") > 0, Plain)
		Assert(InStr(Markdown, "| Last git commit | f58d15798 (build) |") > 0, Markdown)
		Assert(InStr(Markdown, '| App dir | ``' . A_ScriptDir . '`` |') > 0, Markdown)
	} finally {
		BUNDLE_COMMIT := Old
	}
}
Test("build commit: the copied diagnostics carry Last git commit and App dir", _TBC_CopyTextsCarryCommitAndAppDir)

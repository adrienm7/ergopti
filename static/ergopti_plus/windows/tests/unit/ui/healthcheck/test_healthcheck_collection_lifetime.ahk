; tests/unit/ui/healthcheck/test_healthcheck_collection_lifetime.ahk

; ==============================================================================
; MODULE: Diagnostics Collection Lifetime Tests
; DESCRIPTION:
; Genuine native tree completion precedes a passive acyclic destruction marker.
; The publication donor supplies unchanged owners, assets and passive SDK ABI.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCLT_Source(Root) {
	global _DriverDir
	Source := _HCPT_Source(Root)
	Old := "#Include " . _DriverDir . "\tests\fixtures\healthcheck_collection_publish_owner_body.ahk`n"
	New := "#Include " . _DriverDir . "\tests\fixtures\healthcheck_collection_lifetime_body.ahk`n"
	Source := StrReplace(Source, Old, New, true, &Changed)
	AssertEqual(1, Changed, "Only the genuine donor's terminal fixture include may change.")
	return Source
}

_HCLT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_HCLT_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "Unretired component custody prevents another collection case.")
	Root := A_Temp . "\ergopti_collection_lifetime_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_HCPT_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _HCLT_Source(Root)))
		_TestPrint("# collection-lifetime emitted_sha256=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root], _HCLT_Done.Bind(State))
		AssertTrue(Handle.start(), "The private collection component must actually start.")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed64(Started) < 30000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AtDeadline := {Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText}
		if State.Calls == 0
			Primary := Error("The collection component did not settle within 30000 ms.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Ack := IsObject(Handle) ? Handle.terminate() : 1
			Retired := Ack is Integer && Ack == 1
			if Retired
				DirDelete(Root, true)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				Debt := {Handle: Handle, Root: Root}
			Critical(PreviousCritical)
		}
	}
	try {
		_TestPrint("# collection-lifetime terminal calls=" . State.Calls . " code=" . State.Code
			. " tree_ack=" . Retired . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
		if State.Calls == 1 {
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# collection-lifetime combined_native_capture " . Line)
		}
	} catch Any as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child tree must acknowledge retirement.")
	AssertEqual(1, AtDeadline.Calls, "Exactly one native completion must arrive before the deadline: " . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "The child completion diagnostic must be empty: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The collection component violated ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS healthcheck-collection-lifetime " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Diagnostics collection lifetime: current terminal owner remains retained (healthcheck-collection-lifetime)",
	_HCLT_Case.Bind("current-retained"))
Test("Diagnostics collection lifetime: public successor releases retired owner (healthcheck-collection-lifetime)",
	_HCLT_Case.Bind("successor-releases"))

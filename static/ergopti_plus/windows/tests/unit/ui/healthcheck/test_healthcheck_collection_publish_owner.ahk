; tests/unit/ui/healthcheck/test_healthcheck_collection_publish_owner.ahk

; ==============================================================================
; MODULE: Diagnostics Collection Publication Owner Tests
; DESCRIPTION:
; Real tree-owned collection workers and logger/timer boundaries run in a cold
; private child. The existing error-window generator supplies genuine owners;
; only the SDK environment is passive. Submission is not page execution.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCPT_ClassOwner() {
	global _DriverDir
	Found := "", Definitions := 0
	loop files _DriverDir . "\*.ahk", "FR" {
		if !_DriverIsProductionSource(A_LoopFileFullPath)
			continue
		Text := FSReadStrict(A_LoopFileFullPath), Code := _DriverMaskNonCode(&Text)
		Position := 1, Through := 1, Depth := 0
		while Position := RegExMatch(Code, "m)^[ \t]*class[ \t]+HookDispatcher\b", &Definition, Position) {
			Prefix := SubStr(Code, Through, Position - Through)
			StrReplace(Prefix, "{", , true, &Opens)
			StrReplace(Prefix, "}", , true, &Closes)
			Depth += Opens - Closes
			if Depth == 0 {
				Definitions += 1
				AssertEqual("", Found, "The dispatcher class must have one authentic whole owner.")
				Found := A_LoopFileFullPath
			}
			Through := Position, Position += Definition.Len
		}
	}
	AssertEqual(1, Definitions, "The dispatcher census must observe exactly one top-level class definition.")
	AssertTrue(Found != "", "The actual dispatcher class owner must be present.")
	return Found
}

_HCPT_Source(Root) {
	global _DriverDir
	Source := _EDOT_Source(Root), Owners := Map(), Added := ""
	for Symbol in ["_Updater_ShowManagedDownloadFailure", "_LLM_NavEventOwnerPortFn", "OllamaNativeIdentityDrain",
		"ShellRunner_SpawnTreeOwned", "BootClockWallMs", "BootProfile_MenuWaitMs", "HotPath_RecordLatency", "WMHandleExists",
		"HealthCheck_CollectWindows", "HealthCheck_CancelProbes", "HealthCheck_ValidateAction", "HealthCheck_PerformAction",
		"HealthCheck_CompleteConfiguration"] {
		Owner := _DriverProductionFileForSymbol(Symbol, _DriverDir)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Added .= "#Include " . Owner . "`n"
		}
	}
	Added .= "#Include " . _HCPT_ClassOwner() . "`n"
	Added .= "#Include " . _DriverDir . "\tests\fixtures\healthcheck_collection_publish_owner_body.ahk`n"
	Old := "#Include " . _DriverDir . "\tests\fixtures\error_dialog_startup_owner_body.ahk`n"
	New := StrReplace(Source, Old, Added, true, &Changed)
	AssertEqual(1, Changed, "Only the unique donor terminal fixture include may be replaced.")
	return New
}

_HCPT_Assets(Root) {
	global _DriverDir, _SharedDir, _VendorDir
	_EDOT_Assets(Root)
	FSCreateDirectoryExclusiveStrict(Root . "\localappdata")
	for Pair in [
		[_SharedDir . "\modules\diagnostics\collection.json", Root . "\shared\modules\diagnostics\collection.json"],
		[_VendorDir . "\ergopti_diagnostics.ps1", Root . "\vendor\ergopti_diagnostics.ps1"]] {
		FileCopy(Pair[1], Pair[2], false)
		AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(Pair[1])), CryptoSha256Bytes(FSReadBytesStrict(Pair[2])),
			"The actual collection worker and contract must retain their bytes.")
	}
	; Runtime staging may supply native evidence. Its absence is never invented as PASS.
	for Name in ["ergopti_nav_owner.dll", "ergopti_nav_owner.manifest.json"] {
		Original := _VendorDir . "\" . Name
		if FileExist(Original) {
			Copy := Root . "\vendor\" . Name
			FileCopy(Original, Copy, false)
			AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(Original)), CryptoSha256Bytes(FSReadBytesStrict(Copy)))
		}
	}
	AssertTrue(FSWriteCreateDurable(Root . "\config\absent.toml", '[script]`nlog_level = "DEBUG"`n'))
}

_HCPT_Done(State, Code, Output, ErrorText) {
	State.Calls += 1, State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
}

_HCPT_Case(Mode) {
	static Serial := 0, Debt := 0
	AssertFalse(IsObject(Debt), "Unretired component custody prevents another collection case.")
	Root := A_Temp . "\ergopti_collection_owner_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}, Handle := 0, Primary := 0
	Retired := false, AtDeadline := 0, ExportFailure := 0, PreviousCritical := Critical("Off")
	try {
		_HCPT_Assets(Root)
		Script := Root . "\subject.ahk"
		AssertTrue(FSWriteCreateDurable(Script, _HCPT_Source(Root)))
		_TestPrint("# collection-owner emitted_sha256=" . CryptoSha256Bytes(FSReadBytesStrict(Script)))
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Script, Mode, Root], _HCPT_Done.Bind(State))
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
		_TestPrint("# collection-owner terminal calls=" . State.Calls . " code=" . State.Code
			. " tree_ack=" . Retired . " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1))
		if State.Calls == 1 {
			for Line in StrSplit(State.Output, "`n", "`r")
				if Line != ""
					_TestPrint("# collection-owner combined_native_capture " . Line)
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
	AssertContains(AtDeadline.Output, "PASS healthcheck-collection-publish-owner " . Mode)
	if IsObject(ExportFailure)
		throw ExportFailure
}

Test("Diagnostics collection: current terminal publication retains its exact owner (healthcheck-collection-publish-owner)",
	_HCPT_Case.Bind("current"))
Test("Diagnostics collection: successor survives an old terminal publication (healthcheck-collection-publish-owner)",
	_HCPT_Case.Bind("successor-during-terminal-log"))

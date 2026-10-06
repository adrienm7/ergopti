; tests/unit/test_user_hotstrings_pid_publication.ahk

; ==============================================================================
; MODULE: Fixture Descendant PID Publication Regressions
; DESCRIPTION:
; Real exclusive file handles and tree-owned children test readiness publication.
; Two probes enforce publication before PID-based liveness observations.
; ==============================================================================

global _UCHR_WriterHandles := Map()
OnExit(_UCHR_RefuseWriterDebt)

/** A refused physical close retains its exact resource and exit veto. */
_UCHR_RefuseWriterDebt(*) {
	global _UCHR_WriterHandles
	return _UCHR_WriterHandles.Count ? 1 : 0
}

/** Refuses false-read conversion through the actual exclusive writer window. */
_UCHR_ExclusiveReaderRefusal() {
	global _UCHR_WriterHandles
	Directory := A_Temp . "\ergopti_pid_exclusive_" . DllCall("GetCurrentProcessId") . "_" . Random(1, 0x7FFFFFFF)
	Assert(FSCreateDirectoryExclusiveStrict(Directory))
	Path := Directory . "\child.pid", Handle := -1
	try {
		Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0xC0000000,
			"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
		Assert(Handle != -1, "The fixture must acquire a real exclusive writer")
		_UCHR_WriterHandles[Handle] := Path
		PidText := String(DllCall("GetCurrentProcessId", "UInt"))
		Bytes := StrPut(PidText, "UTF-8") - 1, Encoded := Buffer(Bytes + 1, 0)
		StrPut(PidText, Encoded, Bytes + 1, "UTF-8")
		Written := 0
		Assert(DllCall("kernel32\WriteFile", "Ptr", Handle, "Ptr", Encoded.Ptr,
			"UInt", Bytes, "UInt*", &Written, "Ptr", 0, "Int"))
		AssertEqual(Bytes, Written, "The real open writer must contain every PID byte")
		Assert(DllCall("kernel32\FlushFileBuffers", "Ptr", Handle, "Int"))
		Assert(FSStrictExists(Path), "An open exclusive producer already exposes its final filename")
		Observed := FSReadUtf8Exact(Path)
		Assert(Observed is Integer && Observed == 0, "The genuine sharing refusal must return integer false")
		AssertThrows(_UCHReadFixturePid.Bind(Path), "A sharing refusal must not become scalar PID zero")
	} finally {
		if Handle != -1 {
			Closed := DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int") != 0
			if Closed {
				_UCHR_WriterHandles.Delete(Handle)
				try {
					AssertEqual(Integer(PidText), _UCHReadFixturePid(Path), "The same PID becomes readable after exact close")
					Assert(ProcessExist(_UCHReadFixturePid(Path)), "The independent post-close presence oracle must be non-vacuous")
				} finally {
					Assert(FSDelete(Path))
					DirDelete(Directory)
				}
			}
			Assert(Closed, "The exact fixture writer must physically close before its namespace can retire")
		} else {
			DirDelete(Directory)
		}
	}
}
Test("fixture child PID: an actual exclusive writer refuses scalar admission", _UCHR_ExclusiveReaderRefusal)

/** Exercises the actual generated child through a cooperative pre-rename cut. */
_UCHR_ChildBeforeRename() {
	global _ConfigDir
	PreviousConfigDir := _ConfigDir, PackageRoots := 0
	Directory := A_Temp . "\ergopti_pid_barrier_" . DllCall("GetCurrentProcessId") . "_" . Random(1, 0x7FFFFFFF)
	Assert(FSCreateDirectoryExclusiveStrict(Directory))
	_ConfigDir := Directory . "\"
	Path := UserHotstringsSourcePath(), ChildPath := Directory . "\child.ahk"
	PidPath := Directory . "\child.pid", Staged := Directory . "\staged", Release := Directory . "\release"
	Worker := 0
	try {
		PackageRoots := _UCHPackageRoots()
		Child := _UCHFixtureChildSource(PidPath)
		Rename := 'FileMove("' . PidPath . '.pending", "' . PidPath . '", false)`n'
		Barrier := 'FileAppend("STAGED", "' . Staged . '.pending", "UTF-8-RAW")`n'
			. 'FileMove("' . Staged . '.pending", "' . Staged . '", false)`n'
			. 'Started := DllCall("GetTickCount64", "UInt64")`n'
			. 'while !FileExist("' . Release . '") && DllCall("GetTickCount64", "UInt64") - Started < 10000`n'
			. '`tSleep(10)`nif !FileExist("' . Release . '")`n`tExitApp(1)`n'
		Replacements := 0
		Child := StrReplace(Child, Rename, Barrier . Rename, true, &Replacements)
		AssertEqual(1, Replacements, "The real child must contain exactly one actual publication seam")
		Assert(FSWriteCreateDurable(ChildPath, Child))
		Source := 'ErgoptiDynamicHotstrings(api) {`n`treturn [Map("id", "wait", "suffix", "@wait", "preview", "Wait", "callback", UserWait)]`n}`n'
			. 'UserWait(context) {`n`tRun(Chr(34) . A_AhkPath . Chr(34) . " /script " . Chr(34) . "' . ChildPath . '" . Chr(34))`n`tSleep(10000)`n`treturn "late"`n}`n'
		Assert(FSWriteCreateDurable(Path, Source))
		Completed := []
		Done(Code, Out, Err) => Completed.Push(Code)
		Worker := UserHotstringWorker(_UserHotstringsReadSource(), "execute", "wait", Done, 0, "@wait", "Wait")
		Started := A_TickCount
		Assert(Worker.start())
		while !FSStrictExists(Staged) && TickElapsed(Started) < 10000
			Sleep(10)
		Assert(FSStrictExists(Staged), "The real child must acknowledge the pre-rename barrier")
		AssertEqual("STAGED", FSReadUtf8Exact(Staged), "Only the complete barrier acknowledgement authorizes release")
		AssertFalse(FSStrictExists(PidPath), "The final PID must remain absent before the actual rename")
		StagedPid := _UCHReadFixturePid(PidPath . ".pending")
		Assert(ProcessExist(StagedPid), "The staged PID must describe a genuinely live fixture descendant")
		Assert(FSWriteCreateDurable(Release . ".pending", "GO"))
		AssertEqual(1, FSAtomicMoveCreate(Release . ".pending", Release))
		while !FSStrictExists(PidPath) && TickElapsed(Started) < 10000
			Sleep(10)
		Assert(FSStrictExists(PidPath), "The same actual child must publish after the cooperative release")
		Pid := _UCHReadFixturePid(PidPath)
		AssertEqual(StagedPid, Pid, "Publication preserves the exact child PID acquired before rename")
		Assert(ProcessExist(Pid), "The published descendant is still live before native cancellation")
		Assert(Worker.cancel(), "The original exact native Job must acknowledge quiescence")
		AssertEqual(0, ProcessExist(Pid), "Native cancellation must retire that same descendant")
		AssertEqual(0, Completed.Length, "Cancelled workers never publish completion")
		AssertEqual(Source, FSReadUtf8Exact(Path), "The original source remains unchanged")
	} finally {
		if IsObject(Worker)
			Assert(Worker.cancel(), "The exact Job retains ownership through every fixture refusal")
		_ConfigDir := PreviousConfigDir
		if IsObject(PackageRoots)
			_UCHRestorePackageRoots(PackageRoots)
		for FixturePath in [Path, ChildPath, PidPath, PidPath . ".pending", Staged, Staged . ".pending", Release, Release . ".pending"]
			FSDelete(FixturePath)
		DirDelete(Directory)
	}
}
Test("fixture child PID: the actual tree-owned descendant publishes only after rename", _UCHR_ChildBeforeRename)

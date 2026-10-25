; tests/unit/adapters/test_app_launcher_native_targets.ahk

; ==============================================================================
; MODULE: Native AppLauncher Target Identity
; DESCRIPTION:
; A competing executable at the first space-delimited path prefix must never
; replace the requested program. Real children report their executable and
; literal arguments; cleanup uses the exact queried native process handle.
; ==============================================================================

#Requires AutoHotkey v2.0

_ALNT_Fixture() {
	Stem := "ergopti_al_" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	Root := A_Temp . "\" . Stem
	Directory := Root . "\" . Stem . " with space"
	try {
		DirCreate(Directory)
		Target := Directory . "\" . Stem . "_target.exe"
		Prefix := Root . "\" . Stem . ".exe"
		FileCopy(A_AhkPath, Target)
		; cmd.exe is harmless and stays alive until this fixture retires its handle.
		FileCopy(A_WinDir . "\System32\cmd.exe", Prefix)
		Script := Directory . "\" . Stem . "_target.ahk"
		Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n"
			. 'Text := A_AhkPath . "``n" . A_Args.Length . "``n"' . "`n"
			. "for Arg in A_Args {`n"
			. ' Text .= StrLen(Arg) . ":"' . "`n"
			. " Loop Parse Arg`n"
			. '  Text .= Format("{:04X}", Ord(A_LoopField))' . "`n"
			. ' Text .= "``n"' . "`n}`n"
			. 'FileAppend(Text, A_ScriptDir . "\pending.txt", "UTF-8")' . "`n"
			. 'FileMove(A_ScriptDir . "\pending.txt", A_ScriptDir . "\receipt.txt")' . "`n"
			. "Sleep(30000)`nExitApp(0)`n"
		FileAppend(Source, Script, "UTF-8")
		return { Root: Root, Target: Target, Prefix: Prefix, Script: Script,
			Receipt: Directory . "\receipt.txt", Handle: 0 }
	} catch as Err {
		if DirExist(Root)
			DirDelete(Root, true)
		throw Err
	}
}

_ALNT_Image(Handle) {
	Size := 32768
	Path := Buffer(Size * 2)
	if !DllCall("Kernel32\QueryFullProcessImageNameW", "Ptr", Handle, "UInt", 0, "Ptr", Path, "UInt*", &Size)
		throw OSError()
	return StrGet(Path)
}

; Unique names locate the fixture; the native image receipt admits ownership.
_ALNT_FindChild(Fixture) {
	for Candidate in [Fixture.Prefix, Fixture.Target] {
		SplitPath(Candidate, &Name)
		Pid := ProcessExist(Name)
		if !Pid
			continue
		Handle := DllCall("Kernel32\OpenProcess", "UInt", 0x101001, "Int", 0, "UInt", Pid, "Ptr")
		if !Handle
			continue
		try {
			if StrLower(_ALNT_Image(Handle)) == StrLower(Candidate)
				return Handle
		} catch as Err {
			DllCall("Kernel32\CloseHandle", "Ptr", Handle)
			throw Err
		}
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
	return 0
}

_ALNT_Retire(Fixture) {
	Handle := Fixture.Handle ? Fixture.Handle : _ALNT_FindChild(Fixture)
	if Handle {
		try {
			if DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle, "UInt", 0, "UInt") != 0 {
				if !DllCall("Kernel32\TerminateProcess", "Ptr", Handle, "UInt", 0)
					throw OSError()
				AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle, "UInt", 5000, "UInt"),
					"the exact fixture child must retire before its files are removed")
			}
		} finally DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
	DirDelete(Fixture.Root, true)
}

_ALNT_Encoded(Arg) {
	Text := StrLen(Arg) . ":"
	Loop Parse Arg
		Text .= Format("{:04X}", Ord(A_LoopField))
	return Text
}

_ALNT_Launch(Method, OuterIterations := 1) {
	Fixture := _ALNT_Fixture()
	Words := ["", "alpha beta", 'quoted"word', "é漢", "tail\", 'slash\"quote']
	try {
		Loop OuterIterations {
			if A_Index != OuterIterations
				continue
			switch Method {
				case "launch": AL_Launch(Fixture.Target)
				case "open": AL_OpenStrict(Fixture.Target)
				case "args":
					Arguments := "/ErrorStdOut " . AL_QuoteArgument(Fixture.Script)
					for Word in Words
						Arguments .= " " . AL_QuoteArgument(Word)
					AL_LaunchWithArgs(Fixture.Target, Arguments)
				case "argv":
					Vector := [Fixture.Target, "/ErrorStdOut", Fixture.Script]
					Vector.Push(Words*)
					AL_LaunchArgvStrict(Vector)
				default: throw ValueError("Unknown native launcher fixture method.")
			}
		}
		Begin := A_TickCount
		while !Fixture.Handle && TickElapsed(Begin) < 5000 {
			Fixture.Handle := _ALNT_FindChild(Fixture)
			if !Fixture.Handle
				Sleep(10)
		}
		AssertTrue(!!Fixture.Handle, "the fixture must observe the actual launched native child")
		AssertEqual(StrLower(Fixture.Target), StrLower(_ALNT_Image(Fixture.Handle)),
			"a prefix executable must never replace the exact requested application")
		Begin := A_TickCount
		while !FileExist(Fixture.Receipt) && TickElapsed(Begin) < 5000
			Sleep(10)
		AssertTrue(!!FileExist(Fixture.Receipt), "the selected program must execute its real script")
		Lines := StrSplit(Trim(FileRead(Fixture.Receipt, "UTF-8"), "`r`n"), "`n", "`r")
		AssertEqual(StrLower(Fixture.Target), StrLower(Lines[1]), "the native child confirms its image independently")
		Expected := Method == "args" || Method == "argv" ? Words : []
		AssertEqual(Expected.Length, Integer(Lines[2]), "the literal native argv length is preserved")
		AssertEqual(Expected.Length + 2, Lines.Length, "the entire child receipt is consumed")
		for Index, Word in Expected
			AssertEqual(_ALNT_Encoded(Word), Lines[Index + 2], "each child argument retains its exact UTF-16 contents")
	} finally _ALNT_Retire(Fixture)
}

for _ALNT_Method in ["launch", "open", "args"]
	Test("AppLauncher: exact native " . _ALNT_Method . " target (launcher-native-target)", _ALNT_Launch.Bind(_ALNT_Method))
for _ALNT_OuterIterations in [1, 2]
	Test("AppLauncher: exact native argv in outer loop " . _ALNT_OuterIterations . " (launcher-native-target)",
		_ALNT_Launch.Bind("argv", _ALNT_OuterIterations))

/** A nonexistent literal target cannot fall through to a competing prefix. */
_ALNT_MissingTarget() {
	Fixture := _ALNT_Fixture()
	try {
		FileDelete(Fixture.Target)
		Observed := ""
		try AL_OpenStrict(Fixture.Target)
		catch as Err
			Observed := Err.Message
		AssertTrue(InStr(Observed, "Opening '") == 1, "a real native refusal reaches the strict caller")
		AssertTrue(!!InStr(Observed, AL_ProgramName(Fixture.Target)), "the refusal identifies only the requested program")
		AssertFalse(!!InStr(Observed, Fixture.Root), "native failure diagnostics never expose the target directory")
		Fixture.Handle := _ALNT_FindChild(Fixture)
		AssertFalse(!!Fixture.Handle, "a missing target must not start the prefix executable")
	} finally _ALNT_Retire(Fixture)
}
Test("AppLauncher: missing literal target is refused (launcher-native-target)", _ALNT_MissingTarget)

/** Missing private files report a sanitized native refusal to strict callers. */
_ALNT_MissingPrivateTarget() {
	Stem := "ergopti_al_missing_" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	Root := A_Temp . "\" . Stem
	Target := Root . "\" . Stem . " application.exe"
	DirCreate(Root)
	try {
		AssertFalse(!!FileExist(Target), "the private refusal fixture must not contain an executable")
		Observed := ""
		try AL_OpenStrict(Target)
		catch as Err
			Observed := Err.Message
		AssertTrue(InStr(Observed, "Opening '") == 1, "a real native refusal reaches the strict caller")
		AssertTrue(!!InStr(Observed, AL_ProgramName(Target)), "the refusal identifies only the requested program")
		AssertFalse(!!InStr(Observed, Root), "native failure diagnostics never expose the target directory")
	} finally DirDelete(Root, true)
}
Test("AppLauncher: ordinary missing private target is refused (launcher-private-missing)", _ALNT_MissingPrivateTarget)

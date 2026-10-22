; tests/unit/modules/updater/test_updater_curl_capture_namespace.ahk

; ==============================================================================
; MODULE: Updater Curl Capture Native Namespace
; DESCRIPTION:
; Transplanted identities, junctions and held namespaces cannot lend the
; original capture namespace, move preconditions keep their attack
; requirements and handle renames distinguish empty controls from held
; descendants.
; ==============================================================================

#Requires AutoHotkey v2.0





_CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary, Foreign := 0, Moved := "", Directory := false, Event := 0) {
	CleanupFailure := 0
	Capture.FixtureCleanupContext := Map("foreign", Foreign, "moved", Moved, "event", Event, "parent", Parent)
	try {
		OriginalSource := _CurlCaptureRollbackDirectoryMove(Capture)
		if Directory && OriginalSource == Capture.Directory["path"] {
			Moved := ""
			Capture.FixtureCleanupContext["moved"] := ""
		}
		if Foreign is Map && !Capture.RetireEntry(Foreign)
			throw Error("Independent native foreign fixture retirement was refused.")
		if Moved != "" {
			Entry := Directory ? Capture.Directory : Capture.Files["artifact.bin"]
			Probe := Capture.Open(Moved, 0, 3, Directory)
			if !Probe
				throw Error("Moved original fixture identity was unavailable.")
			try {
				if !Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe))
					throw Error("Moved original fixture identity was refused.")
			} finally Capture.CloseProbe(Probe)
			if Capture.ProbeCloseDebt.Length || FileExist(Entry["path"])
				throw Error("Original fixture path cannot replace an unowned entry.")
			Restored := Directory ? _CurlCaptureMoveRetainedDirectory(Capture, Moved, Entry["path"], Parent)
				: DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Entry["path"], "Int")
			if !Restored
				throw Error("Exact moved fixture restoration was refused.")
			Capture.FixtureCleanupContext["moved"] := ""
		}
		if !_Updater_RetireCurlCapture(Capture)
			throw Error("Native capture fixture retained physical or identity debt.")
		if Event && !DllCall("kernel32\CloseHandle", "Ptr", Event, "Int")
			throw Error("Native progress event retirement was refused.")
		DirDelete(Parent, false)
		Capture.FixtureCleanupContext := 0
	} catch Any as Failure {
		CleanupFailure := Failure
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

; The literal counterexample transplants original file identities into a foreign
; directory, or aliases them through a foreign junction. Neither may lend the
; original namespace to body observation or deletion.
_CurlCaptureNativeHybridNamespace(UseJunction := false) {
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Foreign := 0
	ReparseOwner := 0
	Moved := ""
	Worker := 0
	Failed := false
	Primary := 0
	try {
		Capture.Acquire(Parent)
		Path := StrReplace(Capture.Files["artifact.bin"]["path"], "'", "''")
		Script := "$ErrorActionPreference='Stop';[IO.File]::WriteAllBytes('" . Path
			. "',[byte[]](1,2,3,4));Start-Sleep -Milliseconds 30000"
		Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-EncodedCommand", _UpdaterTestEncodedCommand(Script)],
			, , ObjBindMethod(Capture, "OnNativeAdopt"))
		Capture.Attach(Worker)
		AssertTrue(Worker.start(), "the actual owned native writer starts")
		Start := A_TickCount
		while !TickExpired64(Start, 10000) && Capture.ObserveBody(Worker, 16) != 4 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(4, Capture.ObserveBody(Worker, 16), "the original namespace admits the actual four-byte body")
		Moved := Parent . "\moved-original-namespace"
		AssertTrue(_CurlCaptureMoveRetainedDirectory(Capture, Capture.Path, Moved, Parent))
		AssertFalse(Capture.Running, "fixture setup leaves the genuine production retirement state unchanged")
		AssertEqual(0, Capture.FixtureDirectoryMove, "the complete native setup has no pending fixture transition")
		AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Capture.Path, "Ptr", 0, "Int"))
		Foreign := Map("path", Capture.Path, "handle", 0, "directory", true)
		ForeignHandle := Capture.Open(Capture.Path, 0, 3, true)
		Foreign["handle"] := ForeignHandle
		AssertTrue(ForeignHandle != 0, "the independently created foreign namespace owns a retained native handle")
		if UseJunction {
			ReparseOwner := Capture.Open(Capture.Path, 0x40000000, 3, true)
			AssertTrue(ReparseOwner != 0, "the actual reparse operation owns its exact writable directory handle")
			_CurlCaptureSetNativeJunction(ReparseOwner, Moved)
		} else {
			for Name, Entry in Capture.Files
				AssertTrue(DllCall("kernel32\MoveFileW", "Str", Moved . "\" . Name, "Str", Entry["path"], "Int"),
					"the real original file identity is transplanted into the foreign namespace")
		}
		; Every child still resolves to its original volume/file ID. This proves
		; the counterexample cannot be rejected by file-only identity checks.
		ChildIndex := 0
		for Name, Entry in Capture.Files {
			ChildIndex += 1
			Probe := Capture.Open(Entry["path"], 0, 3, false)
			ProbeError := Probe ? 0 : A_LastError
			if UseJunction && !Probe
				_CurlCaptureReportJunctionProbe(ReparseOwner, Moved, ChildIndex, ProbeError)
			AssertTrue(Probe != 0)
			try AssertTrue(Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe)),
				"the child file identity is genuine despite its foreign namespace")
			finally AssertTrue(Capture.CloseProbe(Probe))
		}
		Observed := Capture.ObserveBody(Worker, 16)
		Closed := _Updater_RetireCurlCapture(Capture)
		AssertEqual(0, Observed, "foreign namespace admission precedes the otherwise valid live-body observation")
		AssertFalse(Closed, "the foreign namespace refuses retirement before any original file is deleted")
		AssertTrue(Capture.NativeState["TreeQuiesced"], "the exact worker still retires physically before namespace refusal")
		for Name, Entry in Capture.Files {
			AssertTrue(Entry["handle"] != 0 && !Entry.Get("retired", false), "every original file handle survives refusal")
			AssertTrue(FileExist(Entry["path"]), "every original file survives the foreign-namespace refusal")
		}
		Body := FileRead(Capture.Files["artifact.bin"]["path"], "RAW")
		AssertEqual(4, Body.Size)
		AssertEqual(0x04030201, NumGet(Body, 0, "UInt"), "the original literal bytes survive namespace refusal")
		AssertTrue(DirExist(Moved) && DirExist(Capture.Path), "neither directory is deleted under the other's authority")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureFinishHybridNamespace(Capture, Parent, Failed, Primary, Foreign, Moved, UseJunction, ReparseOwner)
}
Test("updater curl capture: transplanted original file identities cannot borrow a foreign directory",
	_CurlCaptureNativeHybridNamespace)
Test("updater curl capture: a real foreign junction cannot lend the original namespace",
	_CurlCaptureNativeHybridNamespace.Bind(true))

_CurlCaptureNativeHeldNamespaceLease() {
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Lease := 0
	Failed := false
	Primary := 0
	try {
		Capture.Acquire(Parent)
		Lease := Capture.AcquireDirectoryLease()
		AssertTrue(Lease != 0, "the native admission retains the exact directory with FILE_SHARE_DELETE excluded")
		Moved := Parent . "\rename-refused-while-leased"
		AssertFalse(DllCall("kernel32\MoveFileW", "Str", Capture.Path, "Str", Moved, "Int"),
			"an actual directory rename is fenced throughout the held admission")
		AssertTrue(DirExist(Capture.Path) && !DirExist(Moved), "the lease preserves the named original namespace")
		; Receive a genuine partial retirement before retrying the remaining
		; entries. A missing already-retired file cannot invalidate the namespace.
		AssertTrue(Capture.RetireEntry(Capture.Files["headers.bin"]))
		AssertFalse(FileExist(Capture.Files["headers.bin"]["path"]))
		AssertFalse(Capture.ValidatePaths(), "initial all-file binding cannot masquerade as a partial retry")
		AssertTrue(Capture.CloseProbe(Lease))
		Lease := 0
		AssertTrue(_Updater_RetireCurlCapture(Capture), "a directory-only lease admits remaining deletion on partial retry")
		AssertFalse(DirExist(Capture.Path))
		for Name, Entry in Capture.Files
			AssertEqual(0, Entry["handle"], "every exact original handle closes once after the partial retry")
		AssertEqual(0, Capture.Directory["handle"])
		AssertEqual(0, Capture.ProbeCloseDebt.Length)
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally {
		if Lease && !Capture.CloseProbe(Lease) && !Failed {
			Failed := true
			Primary := Error("Native fixture directory lease closure was refused.")
		}
		_CurlCaptureFinishNativeFixture(Capture, Parent, Failed, Primary)
	}
}
Test("updater curl capture: held native namespace prevents rename and preserves partial retirement retry",
	_CurlCaptureNativeHeldNamespaceLease)

; A declared UTF-16 field must match all bytes, including any embedded NUL.
; This pure projection conveys no namespace, file or process authority.
_CurlCaptureJunctionTargetMatches(Data, Returned, Target) {
	if !(Data is Buffer) || !(Returned is Integer) || !(Target is String) || Target == ""
		|| Data.Size > 16384 || Returned < 16 || Returned > Data.Size
		|| NumGet(Data, 0, "UInt") != 0xA0000003
		return false
	Length := NumGet(Data, 4, "UShort")
	SubstituteOffset := NumGet(Data, 8, "UShort")
	SubstituteLength := NumGet(Data, 10, "UShort")
	PrintOffset := NumGet(Data, 12, "UShort")
	PrintLength := NumGet(Data, 14, "UShort")
	if Length < 8 || Length + 8 > Returned
		|| Mod(SubstituteOffset, 2) != 0 || Mod(SubstituteLength, 2) != 0
		|| Mod(PrintOffset, 2) != 0 || Mod(PrintLength, 2) != 0
		|| SubstituteOffset + SubstituteLength > Length - 8
		|| PrintOffset + PrintLength > Length - 8
		|| SubstituteLength != StrLen("\??\" . Target) * 2 || PrintLength != StrLen(Target) * 2
		return false
	return StrGet(Data.Ptr + 16 + SubstituteOffset, -(SubstituteLength // 2), "UTF-16") == ("\??\" . Target)
		&& StrGet(Data.Ptr + 16 + PrintOffset, -(PrintLength // 2), "UTF-16") == Target
}

; Failure-only native facts never lend reparse or path observation as capture
; authority. Read the exact retained reparse owner, keep the original child-open
; errno, emit only fixed scalars, and leave the original strict assertion intact.
_CurlCaptureReportJunctionProbe(Handle, Target, Child, OpenError) {
	if !Handle || !(Child is Integer) || Child < 1 || Child > 4
		|| !(OpenError is Integer) || OpenError < 0 || OpenError > 0xFFFFFFFF
		return false
	try {
		Data := Buffer(16384, 0)
		Returned := 0
		Read := DllCall("kernel32\DeviceIoControl", "Ptr", Handle, "UInt", 0x900A8,
			"Ptr", 0, "UInt", 0, "Ptr", Data, "UInt", Data.Size,
			"UInt*", &Returned, "Ptr", 0, "Int")
		ReadError := Read ? 0 : A_LastError
		Matches := Read && _CurlCaptureJunctionTargetMatches(Data, Returned, Target)
		_TestAppendProgress("# curl_junction_probe child=" . Child . " open_errno=" . OpenError
			. " target_exists=" . (DirExist(Target) ? 1 : 0) . " reparse_read=" . (Read ? 1 : 0)
			. " reparse_match=" . (Matches ? 1 : 0) . " reparse_errno=" . ReadError)
		return true
	} catch {
		; Diagnostics may be unavailable; never replace the primary assertion.
		return false
	}
}

; Public SDK mount-point reparse ABI. The caller retains the exact directory
; it created; no global privilege, symlink setting or foreign path is modified.
_CurlCaptureSetNativeJunction(Handle, Target) {
	Substitute := "\??\" . Target
	; StrPut measures bytes, including the two-byte UTF-16 terminator.
	SubstituteBytes := StrPut(Substitute, "UTF-16") - 2
	PrintBytes := StrPut(Target, "UTF-16") - 2
	Paths := SubstituteBytes + 2 + PrintBytes + 2
	Data := Buffer(16 + Paths, 0)
	NumPut("UInt", 0xA0000003, "UShort", 8 + Paths, Data, 0)
	NumPut("UShort", 0, "UShort", SubstituteBytes, "UShort", SubstituteBytes + 2, "UShort", PrintBytes, Data, 8)
	StrPut(Substitute, Data.Ptr + 16, SubstituteBytes // 2 + 1, "UTF-16")
	StrPut(Target, Data.Ptr + 16 + SubstituteBytes + 2, PrintBytes // 2 + 1, "UTF-16")
	Returned := 0
	if !DllCall("kernel32\DeviceIoControl", "Ptr", Handle, "UInt", 0x900A4, "Ptr", Data,
		"UInt", Data.Size, "Ptr", 0, "UInt", 0, "UInt*", &Returned, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Owned native junction creation was refused.")
}

_CurlCaptureRemoveNativeJunction(Handle) {
	Data := Buffer(8, 0)
	NumPut("UInt", 0xA0000003, Data, 0)
	Returned := 0
	if !DllCall("kernel32\DeviceIoControl", "Ptr", Handle, "UInt", 0x900AC, "Ptr", Data,
		"UInt", Data.Size, "Ptr", 0, "UInt", 0, "UInt*", &Returned, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Owned native junction restoration was refused.")
}

_CurlCaptureFinishHybridNamespace(Capture, Parent, Failed, Primary, Foreign, Moved, Junction, ReparseOwner) {
	global _UpdaterCurlCaptureDebt
	_UpdaterCurlCaptureDebt[ObjPtr(Capture)] := Capture
	CleanupFailure := 0
	Capture.FixtureCleanupContext := Map("foreign", Foreign, "moved", Moved, "junction", Junction,
		"reparse_owner", ReparseOwner, "parent", Parent)
	try {
		if IsObject(Capture.Worker) && !Capture.Worker.terminate()
			throw Error("Hybrid namespace fixture retained its actual native worker.")
		OriginalSource := _CurlCaptureRollbackDirectoryMove(Capture)
		if OriginalSource == Capture.Directory["path"] {
			Moved := ""
			Capture.FixtureCleanupContext["moved"] := ""
		}
		if Foreign is Map {
			if Junction && ReparseOwner {
				_CurlCaptureRemoveNativeJunction(ReparseOwner)
				if !Capture.CloseProbe(ReparseOwner)
					throw Error("Hybrid namespace reparse owner closure was refused.")
				ReparseOwner := 0
			} else if !Junction {
				for Name, Entry in Capture.Files {
					if Entry.Get("retired", false) && !Entry["handle"]
						continue
					AlreadyMoved := Moved . "\" . Name
					if FileExist(AlreadyMoved) {
						Probe := Capture.Open(AlreadyMoved, 0, 3, false, 3)
						if !Probe
							throw Error("Partially transplanted original identity was unavailable.")
						try {
							if !Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe))
								throw Error("Partially transplanted original identity was refused.")
						} finally Capture.CloseProbe(Probe)
						if Capture.ProbeCloseDebt.Length
							throw Error("Partially transplanted probe closure was refused.")
						continue
					}
					Probe := Capture.Open(Entry["path"], 0, 3, false, 3)
					if !Probe
						throw Error("Transplanted original fixture identity was unavailable.")
					try {
						if !Capture.Same(Capture.Snapshot(Entry["handle"]), Capture.Snapshot(Probe))
							throw Error("Transplanted original fixture identity was refused.")
					} finally Capture.CloseProbe(Probe)
					if Capture.ProbeCloseDebt.Length || FileExist(Moved . "\" . Name)
						throw Error("Transplanted original fixture restoration was refused.")
					if !DllCall("kernel32\MoveFileW", "Str", Entry["path"], "Str", Moved . "\" . Name, "Int")
						throw Error("Exact transplanted fixture restoration was refused.")
				}
			}
		}
		_CurlCaptureFinishNativeFixture(Capture, Parent, false, 0, Foreign, Moved, true)
	} catch Any as Failure {
		CleanupFailure := Failure
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}


; Additive native receiving only: a denied setup does not qualify any of the
; original replacement/transplant/junction assertions. Every phase reports only
; fixed scalar facts, and the original eight controls remain unchanged.
global _CurlCaptureMoveProbeFixtureDebt := Map()

_CurlCaptureMoveProbeEmptyDirectory(HeldRoot := false) {
	global _CurlCaptureMoveProbeFixtureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Owner := _UpdaterCurlCaptureLedger()
	Source := Parent . "\empty-original"
	Target := Parent . "\empty-moved"
	Entry := 0
	Failed := false
	Primary := 0
	CleanupFailure := 0
	Context := Map("parent", Parent, "source", Source, "target", Target, "owner", Owner, "entry", 0)
	_CurlCaptureMoveProbeFixtureDebt[ObjPtr(Owner)] := Context
	try {
		AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Source, "Ptr", 0, "Int"))
		Entry := Map("path", Source, "handle", Owner.Open(Source, 0, 3, true), "directory", true)
		Context["entry"] := Entry
		AssertTrue(Entry["handle"] != 0)
		Original := Owner.Snapshot(Entry["handle"])
		Context["original"] := Original
		AssertTrue(Original.Get("ok", false) && Original["directory"] && !Original["delete_pending"])
		if !HeldRoot {
			AssertTrue(Owner.CloseProbe(Entry["handle"]), "the positive control has no retained handle during rename")
			Entry["handle"] := 0
		}
		BeforeSource := DirExist(Source) != ""
		BeforeTarget := DirExist(Target) != ""
		AssertTrue(BeforeSource && !BeforeTarget, "the independent same-parent positive control is exclusive")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Moved := DllCall("kernel32\MoveFileW", "Str", Source, "Str", Target, "Int")
		MoveError := A_LastError
		AfterSource := DirExist(Source) != ""
		AfterTarget := DirExist(Target) != ""
		Phase := HeldRoot ? "root_only" : "empty"
		HeldSame := HeldRoot && Owner.Same(Original, Owner.Snapshot(Entry["handle"]))
		_TestAppendProgress("# curl_move_probe phase=" . Phase . " moved=" . (Moved ? 1 : 0)
			. " errno=" . MoveError . " errno_valid=" . (Moved ? 0 : 1)
			. " source_before=" . (BeforeSource ? 1 : 0) . " target_before=" . (BeforeTarget ? 1 : 0)
			. " source_after=" . (AfterSource ? 1 : 0) . " target_after=" . (AfterTarget ? 1 : 0)
			. " held_root=" . (HeldRoot ? 1 : 0) . " identity_checked=" . (HeldRoot ? 1 : 0)
			. " directory_same=" . (HeldSame ? 1 : 0))
		if Moved
			Entry["path"] := Target
		AssertTrue(MoveError is Integer && MoveError >= 0 && MoveError <= 0xFFFFFFFF)
		if HeldRoot
			AssertTrue(HeldSame, "the root-only probe preserves its exact held directory identity")
		if !HeldRoot
			AssertTrue(Moved, "the actual unheld empty-directory positive control must rename")
		if Moved
			AssertTrue(!AfterSource && AfterTarget, "a successful independent setup reaches its exact target")
		else {
			AssertTrue(MoveError != 0, "the diagnostic root-only refusal has an actual native error")
			AssertTrue(AfterSource && !AfterTarget, "a refused root-only setup preserves its exact namespace")
		}
		if !Entry["handle"]
			Entry["handle"] := Owner.Open(Entry["path"], 0, 3, true)
		AssertTrue(Entry["handle"] != 0 && Owner.Same(Original, Owner.Snapshot(Entry["handle"])),
			"the independent renamed positive control retains its original native identity")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally {
		try {
			if !(Entry is Map) || !IsSet(Original) || Owner.ProbeCloseDebt.Length
				throw Error("Native move positive-control authority was unavailable.")
			if !Entry["handle"]
				Entry["handle"] := Owner.Open(Entry["path"], 0, 3, true)
			if !Entry["handle"] || !Owner.Same(Original, Owner.Snapshot(Entry["handle"])) || !Owner.RetireEntry(Entry)
				throw Error("Native move positive-control retirement was refused.")
			AssertEqual(0, Owner.ProbeCloseDebt.Length)
			DirDelete(Parent, false)
			_CurlCaptureMoveProbeFixtureDebt.Delete(ObjPtr(Owner))
		} catch Any as Failure {
			CleanupFailure := Failure
		}
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

_CurlCaptureMoveProbeAllocatedNamespace(Phase, LiveBody := false, HeldLease := false) {
	global _CurlCaptureMoveProbeFixtureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Lease := 0
	MovedPath := ""
	Failed := false
	Primary := 0
	Context := Map("capture", Capture, "parent", Parent, "lease", 0, "moved", "")
	_CurlCaptureMoveProbeFixtureDebt[ObjPtr(Capture)] := Context
	try {
		AssertTrue(Phase == "allocated" || Phase == "live_body" || Phase == "held_lease")
		Capture.Acquire(Parent)
		AssertEqual(4, Capture.Files.Count, "the probe uses the actual four-file production ledger")
		AssertTrue(Capture.ValidatePaths(), "all exact production references precede the native setup attempt")
		AssertEqual(0, Capture.ProbeCloseDebt.Length)
		if LiveBody {
			Path := StrReplace(Capture.Files["artifact.bin"]["path"], "'", "''")
			Script := "$ErrorActionPreference='Stop';[IO.File]::WriteAllBytes('" . Path
				. "',[byte[]](1,2,3,4));Start-Sleep -Milliseconds 30000"
			Worker := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
				["-NoProfile", "-NonInteractive", "-EncodedCommand", _UpdaterTestEncodedCommand(Script)],
				, , ObjBindMethod(Capture, "OnNativeAdopt"))
			Capture.Attach(Worker)
			AssertTrue(Worker.start(), "the diagnostic body has a real independently owned native Job")
			Start := A_TickCount
			while !TickExpired64(Start, 10000) && Capture.ObserveBody(Worker, 16) != 4 {
				_SR_TreePoll()
				Sleep(10)
			}
			AssertEqual(4, Capture.ObserveBody(Worker, 16), "the exact real four-byte native body precedes the diagnostic move")
			AssertEqual(0, Capture.ProbeCloseDebt.Length, "all observation probes closed before the diagnostic move")
		}
		if HeldLease {
			Lease := Capture.AcquireDirectoryLease()
			Context["lease"] := Lease
			AssertTrue(Lease != 0, "the comparison phase holds the actual delete-excluding production lease")
		}
		DirectoryBefore := Capture.Snapshot(Capture.Directory["handle"])
		AssertTrue(DirectoryBefore.Get("ok", false) && DirectoryBefore["directory"] && !DirectoryBefore["delete_pending"])
		FilesBefore := Map()
		for Name, Entry in Capture.Files {
			FilesBefore[Name] := Capture.Snapshot(Entry["handle"])
			AssertTrue(FilesBefore[Name].Get("ok", false) && !FilesBefore[Name]["directory"]
				&& !FilesBefore[Name]["delete_pending"] && FilesBefore[Name]["links"] == 1)
		}
		Target := Parent . "\move-probe-target"
		BeforeSource := DirExist(Capture.Path) != ""
		BeforeTarget := DirExist(Target) != ""
		AssertTrue(BeforeSource && !BeforeTarget, "the target is absent in the exact same private parent")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Moved := DllCall("kernel32\MoveFileW", "Str", Capture.Path, "Str", Target, "Int")
		MoveError := A_LastError
		if Moved {
			MovedPath := Target
			Context["moved"] := MovedPath
		}
		AfterSource := DirExist(Capture.Path) != ""
		AfterTarget := DirExist(Target) != ""
		DirectorySame := Capture.Same(DirectoryBefore, Capture.Snapshot(Capture.Directory["handle"]))
		FilesSame := true
		for Name, Entry in Capture.Files {
			Actual := Capture.Snapshot(Entry["handle"])
			FilesSame := Capture.Same(FilesBefore[Name], Actual) && FilesSame
		}
		_TestAppendProgress("# curl_move_probe phase=" . Phase . " moved=" . (Moved ? 1 : 0)
			. " errno=" . MoveError . " errno_valid=" . (Moved ? 0 : 1)
			. " source_before=" . (BeforeSource ? 1 : 0) . " target_before=" . (BeforeTarget ? 1 : 0)
			. " source_after=" . (AfterSource ? 1 : 0) . " target_after=" . (AfterTarget ? 1 : 0)
			. " directory_same=" . (DirectorySame ? 1 : 0) . " files_same=" . (FilesSame ? 1 : 0)
			. " held_lease=" . (Lease ? 1 : 0))
		AssertTrue(MoveError is Integer && MoveError >= 0 && MoveError <= 0xFFFFFFFF)
		AssertTrue(DirectorySame && FilesSame, "the observation never replaces or closes original authority")
		if HeldLease {
			AssertFalse(Moved, "the actual held admission must deny the native move")
			AssertTrue(MoveError == 5 || MoveError == 32, "held-lease denial has an actual access or sharing error")
		}
		if Moved {
			AssertTrue(!AfterSource && AfterTarget, "a successful native setup physically reaches its target")
			if LiveBody
				AssertEqual(0, Capture.ObserveBody(Capture.Worker, 16), "missing original namespace refuses body admission")
			Probe := Capture.Open(Target, 0, 3, true)
			AssertTrue(Probe != 0)
			try AssertTrue(Capture.Same(DirectoryBefore, Capture.Snapshot(Probe)))
			finally AssertTrue(Capture.CloseProbe(Probe))
			Restored := DllCall("kernel32\MoveFileW", "Str", Target, "Str", Capture.Path, "Int")
			RestoreError := A_LastError
			_TestAppendProgress("# curl_move_probe phase=restore source_phase=" . Phase
				. " moved=" . (Restored ? 1 : 0) . " errno=" . RestoreError . " errno_valid=" . (Restored ? 0 : 1))
			AssertTrue(Restored, "only the exact unchanged moved namespace is restored")
			MovedPath := ""
			Context["moved"] := MovedPath
		} else {
			AssertTrue(MoveError != 0, "a refused setup must report the actual native error")
			AssertTrue(AfterSource && !AfterTarget, "a denied move preserves the original named namespace")
		}
		AssertTrue(Capture.ValidatePaths(), "diagnostic receiving leaves all exact file and directory paths admitted")
		if LiveBody
			AssertEqual(4, Capture.ObserveBody(Capture.Worker, 16), "the real owned body remains observable in its restored namespace")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureMoveProbeFinishOwnedContext(Context, Failed, Primary)
}

; A restoration refusal can precede production debt registration. This exact
; external owner exists before Acquire and survives every cleanup exception.
; A retry uses this same context and already-acquired native references only.
_CurlCaptureMoveProbeFinishOwnedContext(Context, Failed := false, Primary := 0) {
	global _CurlCaptureMoveProbeFixtureDebt
	Capture := Context["capture"]
	Key := ObjPtr(Capture)
	if !_CurlCaptureMoveProbeFixtureDebt.Has(Key) || _CurlCaptureMoveProbeFixtureDebt[Key] != Context
		throw Error("Native move diagnostic fixture owner was replaced.")
	if Capture.ProbeCloseDebt.Length {
		if Failed
			throw Primary
		throw Error("Native move diagnostic retained unknown close debt.")
	}
	Lease := Context["lease"]
	if Lease {
		if Capture.CloseProbe(Lease)
			Context["lease"] := 0
		else if !Failed {
			Failed := true
			Primary := Error("Native move diagnostic lease closure was refused.")
		}
	}
	CleanupFailure := 0
	try {
		; Receive cleanup's physical completion separately from the original
		; assertion failure, which remains primary after this actual receipt.
		_CurlCaptureMoveProbeRestoreOwnedNamespace(Context)
		_CurlCaptureFinishNativeFixture(Capture, Context["parent"], false, 0, 0, Context["moved"], true)
		if !_CurlCaptureMoveProbeFixtureDebt.Has(Key) || _CurlCaptureMoveProbeFixtureDebt[Key] != Context
			throw Error("Native move diagnostic fixture owner changed during cleanup.")
		_CurlCaptureMoveProbeFixtureDebt.Delete(Key)
	} catch Any as Failure {
		CleanupFailure := Failure
	}
	if Failed
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

_CurlCaptureMoveProbeRestoreOwnedNamespace(Context) {
	Moved := Context["moved"]
	if Moved == ""
		return
	Capture := Context["capture"]
	Probe := Capture.Open(Moved, 0, 3, true)
	if !Probe
		throw Error("Native move diagnostic original restoration identity was unavailable.")
	try {
		Original := Capture.Snapshot(Capture.Directory["handle"])
		Actual := Capture.Snapshot(Probe)
		if !Capture.Same(Original, Actual) || !Actual["directory"] || Actual["delete_pending"]
			throw Error("Native move diagnostic original restoration identity was refused.")
	} finally Capture.CloseProbe(Probe)
	if Capture.ProbeCloseDebt.Length || FileExist(Capture.Directory["path"])
		throw Error("Native move diagnostic restoration cannot replace an unowned namespace.")
	Restored := DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Capture.Directory["path"], "Int")
	RestoreError := A_LastError
	if Restored
		Context["moved"] := ""
	_TestAppendProgress("# curl_move_probe phase=cleanup_restore moved=" . (Restored ? 1 : 0)
		. " errno=" . RestoreError . " errno_valid=" . (Restored ? 0 : 1))
	if !Restored
		throw OSError(RestoreError, "Native move diagnostic exact original restoration was refused.")
}

_CurlCaptureNativeMovePreconditionProbe() {
	_CurlCaptureMoveProbeEmptyDirectory()
	_CurlCaptureMoveProbeEmptyDirectory(true)
	_CurlCaptureMoveProbeAllocatedNamespace("allocated")
	_CurlCaptureMoveProbeAllocatedNamespace("live_body", true)
	_CurlCaptureMoveProbeAllocatedNamespace("held_lease", false, true)
}
Test("updater curl capture: additive native move precondition facts preserve original attack requirements",
	_CurlCaptureNativeMovePreconditionProbe)


; Public SDK receiving only. POSIX flag2 does not promise that an absent-target
; source directory with retained descendants can move. The original attacks
; keep their strict assertions until a genuine setup is independently received.
_CurlCaptureHandleRenameBuffer(Path, Parent, InformationClass, Flags) {
	AssertTrue(A_PtrSize == 4 || A_PtrSize == 8)
	AssertTrue(InformationClass == 3 || InformationClass == 22)
	AssertTrue(Flags == 0 || (InformationClass == 22 && Flags == 2), "replacement is never authorized")
	; RootDirectory=NULL requires an absolute destination, independent of CWD.
	AssertTrue(StrLen(Path) <= 4096 && RegExMatch(Parent, "^[A-Za-z]:\\")
		&& !InStr(Parent, "/") && !RegExMatch(Parent, "(?:^|\\)\.{1,2}(?:\\|$)")
		&& !RegExMatch(Parent, "[\x00-\x1F]"), "the captured original parent is a bounded absolute Windows path")
	AssertTrue(SubStr(Path, 1, StrLen(Parent) + 1) == Parent . "\"
		&& RegExMatch(SubStr(Path, StrLen(Parent) + 2), "^[A-Za-z0-9.-]{1,80}$")
		&& SubStr(Path, StrLen(Parent) + 2) != "." && SubStr(Path, StrLen(Parent) + 2) != "..",
		"the absolute destination remains one bounded leaf in the exact original private parent")
	NameBytes := StrPut(Path, "UTF-16") - 2
	; Public FILE_RENAME_INFO: union DWORD/BOOLEAN, aligned HANDLE root=NULL,
	; DWORD name byte length, then WCHAR name. Preserve full SDK structure size.
	Data := Buffer((A_PtrSize == 8 ? 24 : 16) + NameBytes, 0)
	NumPut("UInt", Flags, Data, 0)
	NumPut("UInt", NameBytes, Data, 2 * A_PtrSize)
	StrPut(Path, Data.Ptr + 2 * A_PtrSize + 4, NameBytes // 2 + 1, "UTF-16")
	return Data
}

_CurlCaptureHandleRenameFacts(Capture, DirectoryBefore, FilesBefore) {
	DirectorySame := Capture.Same(DirectoryBefore, Capture.Snapshot(Capture.Directory["handle"]))
	FilesSame := true
	for Name, Entry in Capture.Files {
		Actual := Capture.Snapshot(Entry["handle"])
		FilesSame := Capture.Same(FilesBefore[Name], Actual) && FilesSame
	}
	return Map("directory_same", DirectorySame, "files_same", FilesSame)
}

_CurlCaptureHandleRenameFinish(Context, Failed, Primary) {
	global _CurlCaptureMoveProbeFixtureDebt
	Capture := Context["capture"]
	Key := ObjPtr(Capture)
	if !_CurlCaptureMoveProbeFixtureDebt.Has(Key) || _CurlCaptureMoveProbeFixtureDebt[Key] != Context
		throw Error("Native handle-rename receiving fixture owner was replaced.")
	if Context["moved"] != "" {
		if Failed
			throw Primary
		throw Error("Native handle-rename receiving retained unpaid exact restoration.")
	}
	if Context["rename_handle"] {
		if Capture.ProbeCloseDebt.Length {
			if Failed
				throw Primary
			throw Error("Native handle-rename receiving retained unknown close debt.")
		}
		if Capture.CloseProbe(Context["rename_handle"])
			Context["rename_handle"] := 0
		else if !Failed {
			Failed := true
			Primary := Error("Native handle-rename receiving closure was refused.")
		}
	}
	_CurlCaptureMoveProbeFinishOwnedContext(Context, Failed, Primary)
}

_CurlCaptureHandleRenameCase(InformationClass, Flags, FourFiles) {
	global _CurlCaptureMoveProbeFixtureDebt
	Parent := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Capture := _UpdaterCurlCaptureLedger()
	Context := Map("capture", Capture, "parent", Parent, "lease", 0, "moved", "", "rename_handle", 0)
	_CurlCaptureMoveProbeFixtureDebt[ObjPtr(Capture)] := Context
	Failed := false
	Primary := 0
	Kind := FourFiles ? "four" : "empty"
	try {
		if FourFiles {
			Capture.Acquire(Parent)
			AssertEqual(4, Capture.Files.Count)
			AssertTrue(Capture.ValidatePaths(), "the exact original four-file ledger precedes handle-based receiving")
		} else {
			; Independent empty positive control; it never stands in for four files.
			Path := Parent . "\empty-handle-original"
			AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Path, "Ptr", 0, "Int"))
			Capture.Path := Path
			Capture.Directory := Map("path", Path, "handle", Capture.Open(Path, 0, 3, true), "directory", true)
			AssertTrue(Capture.Directory["handle"] != 0)
			AssertEqual(0, Capture.Files.Count)
		}
		DirectoryBefore := Capture.Snapshot(Capture.Directory["handle"])
		AssertTrue(DirectoryBefore.Get("ok", false) && DirectoryBefore["directory"] && !DirectoryBefore["delete_pending"])
		FilesBefore := Map()
		for Name, Entry in Capture.Files {
			FilesBefore[Name] := Capture.Snapshot(Entry["handle"])
			AssertTrue(FilesBefore[Name].Get("ok", false) && !FilesBefore[Name]["directory"]
				&& !FilesBefore[Name]["delete_pending"] && FilesBefore[Name]["links"] == 1)
		}
		TargetName := "handle-receiving-target"
		Target := Parent . "\" . TargetName
		AssertTrue(DirExist(Capture.Path) && !FileExist(Target), "no replacement or foreign destination is permitted")
		Data := _CurlCaptureHandleRenameBuffer(Target, Parent, InformationClass, Flags)
		DllCall("kernel32\SetLastError", "UInt", 0)
		Context["rename_handle"] := Capture.Open(Capture.Path, 0x10000, 3, true)
		OpenError := A_LastError
		Facts := _CurlCaptureHandleRenameFacts(Capture, DirectoryBefore, FilesBefore)
		_TestAppendProgress("# curl_handle_rename kind=" . Kind . " stage=open api=" . InformationClass
			. " flags=" . Flags . " acquired=" . (Context["rename_handle"] ? 1 : 0)
			. " errno=" . OpenError . " errno_valid=" . (Context["rename_handle"] ? 0 : 1)
			. " directory_same=" . (Facts["directory_same"] ? 1 : 0) . " files_same=" . (Facts["files_same"] ? 1 : 0))
		AssertTrue(Facts["directory_same"] && Facts["files_same"])
		if !Context["rename_handle"] {
			AssertTrue(FourFiles && OpenError != 0, "the empty-directory positive control must acquire DELETE access")
			return
		}
		AssertTrue(Capture.Same(DirectoryBefore, Capture.Snapshot(Context["rename_handle"])),
			"the DELETE handle is the exact original directory, never a new admission authority")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Renamed := DllCall("kernel32\SetFileInformationByHandle", "Ptr", Context["rename_handle"],
			"Int", InformationClass, "Ptr", Data, "UInt", Data.Size, "Int")
		RenameError := A_LastError
		if Renamed
			Context["moved"] := Target
		Facts := _CurlCaptureHandleRenameFacts(Capture, DirectoryBefore, FilesBefore)
		SourceAfter := DirExist(Capture.Path) != ""
		TargetAfter := DirExist(Target) != ""
		_TestAppendProgress("# curl_handle_rename kind=" . Kind . " stage=rename api=" . InformationClass
			. " flags=" . Flags . " moved=" . (Renamed ? 1 : 0) . " errno=" . RenameError
			. " errno_valid=" . (Renamed ? 0 : 1) . " source_after=" . (SourceAfter ? 1 : 0)
			. " target_after=" . (TargetAfter ? 1 : 0) . " directory_same=" . (Facts["directory_same"] ? 1 : 0)
			. " files_same=" . (Facts["files_same"] ? 1 : 0))
		AssertTrue(Facts["directory_same"] && Facts["files_same"], "all original metadata handles remain held and identical")
		if !FourFiles
			AssertTrue(Renamed, "the actual same-parent empty-directory handle-rename positive control must succeed")
		if !Renamed {
			AssertTrue(RenameError != 0 && SourceAfter && !TargetAfter, "a reported denial preserves the original namespace")
			return
		}
		AssertTrue(!SourceAfter && TargetAfter, "a successful API must physically reach the target namespace")
		RestoreData := _CurlCaptureHandleRenameBuffer(Capture.Path, Parent, InformationClass, Flags)
		AssertTrue(Capture.Same(DirectoryBefore, Capture.Snapshot(Context["rename_handle"]))
			&& !FileExist(Capture.Path), "restoration retains exact identity and cannot replace a foreign path")
		DllCall("kernel32\SetLastError", "UInt", 0)
		Restored := DllCall("kernel32\SetFileInformationByHandle", "Ptr", Context["rename_handle"],
			"Int", InformationClass, "Ptr", RestoreData, "UInt", RestoreData.Size, "Int")
		RestoreError := A_LastError
		if Restored
			Context["moved"] := ""
		_TestAppendProgress("# curl_handle_rename kind=" . Kind . " stage=restore api=" . InformationClass
			. " flags=" . Flags . " moved=" . (Restored ? 1 : 0) . " errno=" . RestoreError . " errno_valid=" . (Restored ? 0 : 1))
		AssertTrue(Restored && DirExist(Capture.Path) && !DirExist(Target), "the same exact native API must restore before retirement")
	} catch Any as Failure {
		Failed := true
		Primary := Failure
	} finally _CurlCaptureHandleRenameFinish(Context, Failed, Primary)
}

_CurlCaptureNativeHandleRenameReceiving() {
	for NativeAPI in [[3, 0], [22, 0], [22, 2]] {
		_CurlCaptureHandleRenameCase(NativeAPI[1], NativeAPI[2], false)
		_CurlCaptureHandleRenameCase(NativeAPI[1], NativeAPI[2], true)
	}
}
Test("updater curl capture: public handle-rename receiving distinguishes empty controls from held descendants",
	_CurlCaptureNativeHandleRenameReceiving)

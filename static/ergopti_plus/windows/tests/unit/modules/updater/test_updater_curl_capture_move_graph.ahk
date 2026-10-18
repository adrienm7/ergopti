; tests/unit/modules/updater/test_updater_curl_capture_move_graph.ahk

; ==============================================================================
; MODULE: Updater Curl Capture Directory Move Graph
; DESCRIPTION:
; The fixture owner stages retained children before the empty root move,
; and graph rollback, close refusal, foreign holdings and reentry keep
; every transition debt; declared junction fields refuse NUL prefixes.
; ==============================================================================

#Requires AutoHotkey v2.0





; These graph ports receive the actual fixture owner above. They model the
; independent documented open-descendant denial, not native Windows success.
class _CurlCaptureDirectoryMoveGraphCapture extends _UpdaterCurlCaptureLedger {
	__New() {
		super.__New()
		this.Path := "C:\owned\original"
		this.Directory := Map("path", this.Path, "handle", 10, "directory", true)
		this.GraphHandles := Map(10, 10)
		this.GraphDirectories := Map(10, true)
		this.GraphPaths := Map(this.Path, 10)
		Id := 20
		for Name in ["artifact.bin", "headers.bin", "capability.json", "transport.conf"] {
			this.GraphHandles[Id] := Id
			this.GraphDirectories[Id] := false
			this.GraphPaths[this.Path . "\" . Name] := Id
			this.Files[Name] := Map("path", this.Path . "\" . Name, "handle", Id, "directory", false)
			Id += 1
		}
	}
	Snapshot(Handle) {
		if !this.GraphHandles.Has(Handle)
			return Map("ok", false)
		Id := this.GraphHandles[Handle]
		return Map("ok", true, "directory", this.GraphDirectories[Id], "volume", 1,
			"index_high", 0, "index_low", Id, "delete_pending", false, "links", 1)
	}
}
class _CurlCaptureDirectoryMoveGraph extends _CurlCaptureDirectoryMoveFixture {
	__New(Capture, FailurePoint := 0) {
		this.RenameCalls := 0
		this.FailurePoint := FailurePoint
		this.NextHandle := 100
		this.Denials := 0
		this.CloseRefused := false
		super.__New(Capture, Capture.Path, "C:\owned\moved", "C:\owned")
	}
	NewHoldingPath() => "C:\owned\holding.graph"
	Exists(Path) => this.Capture.GraphPaths.Has(Path)
	Create(Path) {
		if this.Exists(Path)
			return false
		this.Capture.GraphPaths[Path] := 40
		this.Capture.GraphDirectories[40] := true
		return true
	}
	Open(Path, Access, Directory, Sharing := 7) {
		if !this.Exists(Path)
			return 0
		Handle := this.NextHandle++
		this.Capture.GraphHandles[Handle] := this.Capture.GraphPaths[Path]
		return Handle
	}
	Close(Handle) {
		if this.CloseRefused {
			this.Capture.ProbeCloseDebt.Push(Handle)
			return false
		}
		AssertTrue(Handle >= 100, "no original metadata reference can close during fixture transition")
		AssertTrue(this.Capture.GraphHandles.Has(Handle))
		this.Capture.GraphHandles.Delete(Handle)
		return true
	}
	RemoveHolding(Entry) {
		for Path, Id in this.Capture.GraphPaths {
			if SubStr(Path, 1, StrLen(Entry["path"]) + 1) == Entry["path"] . "\"
				return false
		}
		if !this.Close(Entry["handle"])
			return false
		Entry["handle"] := 0
		Entry["retired"] := true
		this.Capture.GraphPaths.Delete(Entry["path"])
		return true
	}
	Rename(Handle, Destination) {
		if this.HasOwnProp("Reentry") && this.Reentry {
			this.Reentry := false
			AssertThrows(ObjBindMethod(this, "Rollback"), "a running mutation cannot borrow its own retained cleanup owner")
			AssertTrue(this.Running)
		}
		this.RenameCalls += 1
		if this.FailurePoint && this.RenameCalls == this.FailurePoint {
			this.FailurePoint := 0
			return false
		}
		if this.Exists(Destination) || !this.Capture.GraphHandles.Has(Handle)
			return false
		Id := this.Capture.GraphHandles[Handle]
		Source := ""
		for Path, PathId in this.Capture.GraphPaths {
			if PathId == Id
				Source := Path
		}
		if Source == ""
			return false
		if this.Capture.GraphDirectories[Id] {
			for Path, ChildId in this.Capture.GraphPaths {
				if SubStr(Path, 1, StrLen(Source) + 1) == Source . "\" {
					for ChildHandle, HeldId in this.Capture.GraphHandles {
						if HeldId == ChildId {
							this.Denials += 1
							return false
						}
					}
				}
			}
		}
		this.Capture.GraphPaths.Delete(Source)
		this.Capture.GraphPaths[Destination] := Id
		return true
	}
}

_CurlCaptureDirectoryMoveGraphCheck(Capture, Root) {
	AssertEqual(10, Capture.GraphPaths[Root], "the original directory identity reaches the exact graph namespace")
	AssertEqual(10, Capture.Directory["handle"], "original root metadata authority stays open")
	for Name, Entry in Capture.Files {
		AssertEqual(Entry["handle"], Capture.GraphPaths[Root . "\" . Name], "each held child identity reaches the requested namespace")
		AssertTrue(Capture.GraphHandles.Has(Entry["handle"]), "every original child metadata handle remains held")
	}
	AssertEqual(0, Capture.ProbeCloseDebt.Length)
}
_CurlCaptureDirectoryMoveGraphCase(Point := 0) {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture, Point)
	try {
		if Point {
			AssertThrows(ObjBindMethod(Owner, "Execute"), "an actual owner transition refusal cannot claim complete setup")
			AssertTrue(Capture.FixtureDirectoryMove == Owner, "the exact partial transition owner remains published")
			AssertFalse(Owner.Closed)
			AssertFalse(Capture.Running, "fixture debt never fabricates production retirement state")
			AssertTrue(_CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner,
				"the exact fixture owner retains incomplete transitions separately")
			AssertEqual(Capture.Path, Owner.Rollback(), "the same owner restores its exact original namespace")
			_CurlCaptureDirectoryMoveGraphCheck(Capture, Capture.Path)
			AssertFalse(Owner.Exists(Owner.Target))
		} else {
			Probe := Owner.Open(Owner.Source, 0x10000, true)
			AssertFalse(Owner.Rename(Probe, Owner.Target), "the original populated-directory graph setup is independently denied")
			AssertTrue(Owner.Close(Probe))
			AssertEqual(1, Owner.Denials)
			Owner.RenameCalls := 0
			AssertTrue(Owner.Execute())
			_CurlCaptureDirectoryMoveGraphCheck(Capture, Owner.Target)
			AssertEqual(9, Owner.RenameCalls, "four staging moves, one empty root move, and four placement moves actually commit")
			AssertFalse(Owner.Exists(Owner.Source))
		}
		AssertTrue(Owner.Closed)
		AssertFalse(Capture.Running)
		AssertEqual(0, Capture.FixtureDirectoryMove)
		AssertFalse(Owner.Exists(Owner.HoldingPath), "the exact empty holding namespace retires only after all children leave")
		AssertEqual(5, Capture.GraphHandles.Count, "only the five original metadata authorities remain")
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: actual fixture owner stages retained children before the empty graph root move",
	_CurlCaptureDirectoryMoveGraphCase)
loop 9
	Test("updater curl capture: exact graph transition " . A_Index . " refusal restores every held identity",
		_CurlCaptureDirectoryMoveGraphCase.Bind(A_Index))

_CurlCaptureDirectoryMoveGraphForeignRollback() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture, 6)
	try {
		AssertThrows(ObjBindMethod(Owner, "Execute"))
		Capture.GraphPaths[Owner.Source] := 999
		Capture.GraphPaths[Owner.Source . "\foreign.bytes"] := 998
		AssertThrows(ObjBindMethod(Owner, "Rollback"), "restoration cannot replace an independently owned foreign namespace")
		AssertEqual(999, Capture.GraphPaths[Owner.Source])
		AssertEqual(998, Capture.GraphPaths[Owner.Source . "\foreign.bytes"])
		AssertFalse(Owner.Closed)
		AssertTrue(Capture.FixtureDirectoryMove == Owner)
		; Only this graph's independent foreign owner removes its own entries.
		Capture.GraphPaths.Delete(Owner.Source . "\foreign.bytes")
		Capture.GraphPaths.Delete(Owner.Source)
		AssertEqual(Capture.Path, Owner.Rollback())
		_CurlCaptureDirectoryMoveGraphCheck(Capture, Capture.Path)
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: a foreign graph rollback target retains every original transition debt",
	_CurlCaptureDirectoryMoveGraphForeignRollback)

_CurlCaptureDirectoryMoveGraphCloseDebt() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture)
	try {
		Owner.CloseRefused := true
		AssertThrows(ObjBindMethod(Owner, "Execute"))
		AssertEqual(1, Capture.ProbeCloseDebt.Length, "the actual owner retains exact failed native closure")
		Calls := Owner.RenameCalls
		AssertThrows(ObjBindMethod(Owner, "Rollback"), "unknown physical closure cannot authorize another mutation")
		AssertEqual(Calls, Owner.RenameCalls)
		AssertFalse(Owner.Closed)
		AssertTrue(Capture.FixtureDirectoryMove == Owner)
		for Name, Entry in Capture.Files
			AssertTrue(Capture.GraphHandles.Has(Entry["handle"]), "original metadata references survive exact close refusal")
	} finally _CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
}
Test("updater curl capture: graph close refusal cannot acknowledge transition cleanup",
	_CurlCaptureDirectoryMoveGraphCloseDebt)

_CurlCaptureDirectoryMoveGraphForeignHolding() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture)
	try {
		Capture.GraphPaths[Owner.NewHoldingPath()] := 999
		AssertThrows(ObjBindMethod(Owner, "Execute"))
		AssertFalse(Owner.HoldingCreated)
		AssertEqual(Capture.Path, Owner.Rollback())
		AssertEqual(999, Capture.GraphPaths[Owner.NewHoldingPath()], "failed exclusive allocation never retires foreign holding data")
		_CurlCaptureDirectoryMoveGraphCheck(Capture, Capture.Path)
		AssertTrue(Owner.Closed)
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: foreign graph holding allocation preserves all foreign identities",
	_CurlCaptureDirectoryMoveGraphForeignHolding)

_CurlCaptureDirectoryMoveGraphReentry() {
	global _CurlCaptureDirectoryMoveFixtureDebt
	Capture := _CurlCaptureDirectoryMoveGraphCapture()
	Owner := _CurlCaptureDirectoryMoveGraph(Capture)
	try {
		Owner.Reentry := true
		AssertTrue(Owner.Execute())
		AssertFalse(Owner.Reentry)
		AssertFalse(Owner.Running)
		_CurlCaptureDirectoryMoveGraphCheck(Capture, Owner.Target)
	} finally {
		if _CurlCaptureDirectoryMoveFixtureDebt.Has(ObjPtr(Capture)) && _CurlCaptureDirectoryMoveFixtureDebt[ObjPtr(Capture)] == Owner
			_CurlCaptureDirectoryMoveFixtureDebt.Delete(ObjPtr(Capture))
	}
}
Test("updater curl capture: graph mutation reentry cannot resume the same running transition",
	_CurlCaptureDirectoryMoveGraphReentry)

; Real in-memory mount-point ABI vectors. No filesystem/handle port is faked.
_CurlCaptureJunctionTargetVector(Target, SubstituteSuffix := false, PrintSuffix := false) {
	Substitute := "\??\" . Target
	SubstitutePlainBytes := StrPut(Substitute, "UTF-16") - 2
	PrintPlainBytes := StrPut(Target, "UTF-16") - 2
	SuffixBytes := StrPut("suffix", "UTF-16") - 2
	SubstituteBytes := SubstitutePlainBytes + (SubstituteSuffix ? 2 + SuffixBytes : 0)
	PrintBytes := PrintPlainBytes + (PrintSuffix ? 2 + SuffixBytes : 0)
	Paths := SubstituteBytes + 2 + PrintBytes + 2
	Data := Buffer(16 + Paths, 0)
	NumPut("UInt", 0xA0000003, "UShort", 8 + Paths, Data, 0)
	NumPut("UShort", 0, "UShort", SubstituteBytes, "UShort", SubstituteBytes + 2, "UShort", PrintBytes, Data, 8)
	StrPut(Substitute, Data.Ptr + 16, SubstitutePlainBytes // 2 + 1, "UTF-16")
	if SubstituteSuffix
		StrPut("suffix", Data.Ptr + 16 + SubstitutePlainBytes + 2, 7, "UTF-16")
	PrintAddress := Data.Ptr + 16 + SubstituteBytes + 2
	StrPut(Target, PrintAddress, PrintPlainBytes // 2 + 1, "UTF-16")
	if PrintSuffix
		StrPut("suffix", PrintAddress + PrintPlainBytes + 2, 7, "UTF-16")
	return Data
}
_CurlCaptureJunctionExactTargetControls() {
	Target := "C:\fixture\original"
	Normal := _CurlCaptureJunctionTargetVector(Target)
	AssertTrue(_CurlCaptureJunctionTargetMatches(Normal, Normal.Size, Target), "the real declared target bytes match")
	SubstituteSuffix := _CurlCaptureJunctionTargetVector(Target, true)
	AssertEqual("\??\" . Target, StrGet(SubstituteSuffix.Ptr + 16,
		NumGet(SubstituteSuffix, 10, "UShort") // 2, "UTF-16"), "positive-length StrGet exposes the old NUL-prefix ambiguity")
	AssertFalse(_CurlCaptureJunctionTargetMatches(SubstituteSuffix, SubstituteSuffix.Size, Target),
		"declared substitute bytes cannot hide a suffix after NUL")
	PrintSuffix := _CurlCaptureJunctionTargetVector(Target, false, true)
	AssertEqual(Target, StrGet(PrintSuffix.Ptr + 16 + NumGet(PrintSuffix, 12, "UShort"),
		NumGet(PrintSuffix, 14, "UShort") // 2, "UTF-16"), "the old print-name copy also loses declared trailing bytes")
	AssertFalse(_CurlCaptureJunctionTargetMatches(PrintSuffix, PrintSuffix.Size, Target),
		"declared print bytes cannot hide a suffix after NUL")
	AssertFalse(_CurlCaptureJunctionTargetMatches(Normal, 15, Target), "partial native header is not an exact target")
	AssertFalse(_CurlCaptureJunctionTargetMatches(Normal, Normal.Size, ""), "empty target cannot request implicit-length copies")
}
Test("updater curl capture: exact declared junction fields cannot lend a NUL-prefix target", _CurlCaptureJunctionExactTargetControls)

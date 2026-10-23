; tests/fixtures/input_probe_clipboard_owner_body.ahk

; Two owned processes exercise actual clipboard mutations, not keyboard input.
; The subject delegates only its late sequence observation; all native values,
; transaction ownership and restore-debt admission remain production code.
#Requires AutoHotkey v2.0

_IPCO_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_IPCO_Publish(Path, Text) {
	_IPCO_Require(!FileExist(Path) && !FileExist(Path . ".pending"), "A private protocol receipt cannot be replaced.")
	FileAppend(Text, Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_IPCO_Wait(Path) {
	Started := A_TickCount
	while !FileExist(Path) && TickElapsed(Started) < 3000
		Sleep(10)
	_IPCO_Require(FileExist(Path), "The exact independent clipboard writer did not acknowledge its phase.")
	return FileRead(Path, "UTF-8")
}

_IPCO_Identity(Text, WithSequence := false) {
	Pattern := WithSequence ? "^([0-9]+)\|([0-9]+)\|([0-9]+)$" : "^([0-9]+)\|([0-9]+)$"
	_IPCO_Require(RegExMatch(Text, Pattern, &Match) > 0, "The writer must publish its actual native identity.")
	Identity := {Pid: Integer(Match[1]), Hwnd: Integer(Match[2]), Sequence: WithSequence ? Integer(Match[3]) : 0}
	Pid := 0
	DllCall("User32\GetWindowThreadProcessId", "Ptr", Identity.Hwnd, "UInt*", &Pid)
	_IPCO_Require(Identity.Pid > 0 && Identity.Pid != DllCall("Kernel32\GetCurrentProcessId", "UInt")
		&& Pid == Identity.Pid, "Only the live independent writer HWND may certify its receipt.")
	return Identity
}

_IPCO_RequestCopy(Phase) {
	global _IPCO
	_IPCO_Require(!_IPCO.Copied, "The controlled external copy must occur exactly once.")
	_IPCO.Armed := false
	_IPCO.Boundary := Phase
	_IPCO_Publish(_IPCO.Root . "\copy.request", "copy")
	Identity := _IPCO_Identity(_IPCO_Wait(_IPCO.Root . "\copy.receipt"), true)
	_IPCO_Require(Identity.Pid == _IPCO.Writer.Pid && Identity.Hwnd == _IPCO.Writer.Hwnd,
		"The copy must come from the originally admitted independent process.")
	_IPCO_Require(CB_Read() == _IPCO.Foreign && Identity.Sequence > 0
		&& CB_GetSequenceNumber() == Identity.Sequence
		&& DllCall("User32\GetClipboardOwner", "Ptr") == Identity.Hwnd,
		"The independent process must actually own the exact newly copied native text.")
	_IPCO.Copied := true
	_IPCO.WriterSequence := Identity.Sequence
}

; Never manufacture a sequence or wrap the CAS coordinator's observation. If a
; future publisher supplies a receipt without this late sample, the same copy
; is scheduled after Hold returns and before Release instead.
_IPCO_HoldSequence() {
	global _IPCO
	if _IPCO.Armed && DllCall("User32\GetOpenClipboardWindow", "Ptr") != A_ScriptHwnd
		_IPCO_RequestCopy("hold-unlocked-sequence")
	_IPCO.DelegatedReads += 1
	_IPCO.ObservedSequence := CB_GetSequenceNumber()
	return _IPCO.ObservedSequence
}

_IPCO_Writer(Root, Mode) {
	Pid := DllCall("Kernel32\GetCurrentProcessId", "UInt")
	_IPCO_Publish(Root . "\writer.ready", Pid . "|" . A_ScriptHwnd)
	Started := A_TickCount
	Copied := false
	loop {
		if FileExist(Root . "\copy.request") && !Copied {
			; This is the actual independent clipboard mutation, not an adapter port.
			A_Clipboard := "input-probe external B é😀 " . Root
			Sequence := DllCall("User32\GetClipboardSequenceNumber", "UInt")
			_IPCO_Require(Sequence > 0 && DllCall("User32\GetClipboardOwner", "Ptr") == A_ScriptHwnd,
				"The writer must really own its published native clipboard.")
			_IPCO_Publish(Root . "\copy.receipt", Pid . "|" . A_ScriptHwnd . "|" . Sequence)
			Copied := true
		}
		if FileExist(Root . "\subject.done")
			break
		_IPCO_Require(TickElapsed(Started) < 12000, "The independent writer must retire within its private protocol deadline.")
		Sleep(10)
	}
	_IPCO_Require(Copied == (Mode == "new-copy-wins"), "The independent writer must perform exactly the requested copy count.")
	FileAppend("PASS input-probe-clipboard-writer " . Mode . " copies=" . (Copied ? 1 : 0) . "`n", "*", "UTF-8-RAW")
}

_IPCO_RestoreIncoming(Snapshot, Held) {
	global _IPCO
	Debt := CBClipboardOwner.restore_debt
	if Debt is Map {
		_IPCO_Require(Held is Map && Debt["owner_token"] == Held["token"],
			"Cleanup cannot detach another transaction's retained restore debt.")
		_IPCO_Require(_CB_SettleRestoreDebt(Debt), "The exact old debt must retire before cleanup admission.")
	}
	if Held is Map && CBClipboardOwner.active.Has(Held["token"])
		_IPCO_Require(CB_EndOwnedTransaction(Held["token"]), "Cleanup must retire only its exact original transaction.")
	; Read first, then authenticate its sequence and real owner under the native
	; lock. A subsequent foreign copy wins the real coordinator's CAS normally.
	Text := CB_Read(), Sequence := CB_GetSequenceNumber()
	KnownText := Text == _IPCO.Seed || Text == _IPCO.Payload || Text == _IPCO.Foreign
	Known := false
	_IPCO_Require(CB_OpenClipboardWithin(A_ScriptHwnd), "Cleanup must acquire its bounded real native lease.")
	try {
		Owner := DllCall("User32\GetClipboardOwner", "Ptr")
		Known := KnownText && Sequence > 0 && CB_GetSequenceNumber() == Sequence
			&& (Owner == A_ScriptHwnd || Owner == _IPCO.Writer.Hwnd)
	} finally {
		_IPCO_Require(DllCall("User32\CloseClipboard", "Int") != 0, "Cleanup must release only its own native lease.")
	}
	if Known {
		CB_RestoreOwnedAllEventually(Snapshot, Sequence, 0, "input_probe_clipboard_fixture", false)
		Started := A_TickCount
		while CBClipboardOwner.restore_debt is Map && TickElapsed(Started) < 3000 {
			CB_RetryRestoreDebt()
			Sleep(10)
		}
		_IPCO_Require(!(CBClipboardOwner.restore_debt is Map), "The exact incoming snapshot must settle or yield to a newer copy.")
	}
	_IPCO_Require(CBClipboardOwner.active.Count == 0 && !CB_IsPasteTransactionActive(),
		"No clipboard transaction may survive the subject.")
	FileAppend("CLEANUP input-probe-clipboard-owner known=" . (Known ? 1 : 0)
		. " unknown_preserved=" . (Known ? 0 : 1) . " debt=0 active=0`n", "*", "UTF-8-RAW")
}

_IPCO_Subject(Root, Mode) {
	global _IPCO, _IPCO_LATE_GETTER_PRESENT
	_IPCO := {Root: Root, Armed: false, Copied: false, Boundary: "none", WriterSequence: 0, DelegatedReads: 0, ObservedSequence: 0,
		Seed: "input-probe original A é😀 " . Root, Payload: "input-probe payload P é😀 " . Root,
		Foreign: "input-probe external B é😀 " . Root}
	Primary := 0, Snapshot := 0, HaveSnapshot := false, Held := 0
	try {
		_IPCO.Writer := _IPCO_Identity(_IPCO_Wait(Root . "\writer.ready"))
		_IPCO_Require(CBClipboardOwner.active.Count == 0 && !CBClipboardOwner.restore_debt
			&& !CBClipboardOwner.observer_active, "A fresh real clipboard owner must have no inherited observer or debt.")
		Snapshot := CB_SaveAll()
		_IPCO_Require(!(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__"), "The incoming opaque clipboard must be captured.")
		HaveSnapshot := true
		_IPCO_Require(CB_Write(_IPCO.Seed) && CB_Read() == _IPCO.Seed, "The real initial clipboard A must be present.")
		_IPCO.Armed := Mode == "new-copy-wins"
		try Held := _IP_HoldClipboard(Map("clipboard", _IPCO.Payload))
		finally _IPCO.Armed := false
		_IPCO_Require(Held is Map && Held["token"] > 0 && CBClipboardOwner.active.Has(Held["token"])
			&& CB_IsPasteTransactionActive(), "The actual input probe must admit its exact real paste transaction.")
		if Mode == "current"
			_IPCO_Require(CB_Read() == _IPCO.Payload && Held["sequence"] > 0,
				"The positive control must genuinely publish the requested temporary payload.")
		else {
			if _IPCO_LATE_GETTER_PRESENT {
				_IPCO_Require(_IPCO.Copied && _IPCO.DelegatedReads == 1
					&& _IPCO.Boundary == "hold-unlocked-sequence"
					&& _IPCO.ObservedSequence == _IPCO.WriterSequence,
					"The present late getter must actually observe the independent copy before returning its native sequence.")
			} else
				_IPCO_RequestCopy("after-hold-before-release")
			_IPCO_Require(CB_Read() == _IPCO.Foreign && CB_GetSequenceNumber() == _IPCO.WriterSequence,
				"The independent newer copy B must really be present immediately before release.")
		}
		_IP_ReleaseClipboard(Held)
		Started := A_TickCount
		while CB_HasRestoreDebtForOwner(Held["token"]) && TickElapsed(Started) < 1000 {
			CB_RetryRestoreDebt()
			Sleep(10)
		}
		_IPCO_Require(!CB_HasRestoreDebtForOwner(Held["token"]) && !CBClipboardOwner.active.Has(Held["token"])
			&& !CB_IsPasteTransactionActive(), "The real release must retire its exact restore debt and paste owner.")
		Observed := CB_Read()
		FileAppend("RECEIPT input-probe-clipboard-owner mode=" . Mode . " pid="
			. DllCall("Kernel32\GetCurrentProcessId", "UInt") . " writer_pid=" . _IPCO.Writer.Pid
			. " boundary=" . _IPCO.Boundary . " late_getter_present=" . _IPCO_LATE_GETTER_PRESENT
			. " getter_fired=" . _IPCO.DelegatedReads . " observed_sequence=" . _IPCO.ObservedSequence . " copied=" . (_IPCO.Copied ? 1 : 0)
			. " expected_sequence=" . Held["sequence"] . " writer_sequence=" . _IPCO.WriterSequence
			. " actual_sequence=" . CB_GetSequenceNumber() . " external_b=" . (Observed == _IPCO.Foreign ? 1 : 0)
			. " restored_a=" . (Observed == _IPCO.Seed ? 1 : 0) . "`n", "*", "UTF-8-RAW")
		_IPCO_Require(Observed == (Mode == "current" ? _IPCO.Seed : _IPCO.Foreign),
			Mode == "current" ? "The current temporary payload must restore its actual original A."
				: "A newer independent copy B must survive the actual input probe release unchanged.")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		_IPCO.Armed := false
		try {
			if HaveSnapshot
				_IPCO_RestoreIncoming(Snapshot, Held)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			try _IPCO_Publish(Root . "\subject.done", "done")
			catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
	}
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS input-probe-clipboard-owner " . Mode . "`n", "*", "UTF-8-RAW")
}

try {
	_IPCO_Require(A_Args.Length == 3 && (A_Args[3] == "current" || A_Args[3] == "new-copy-wins"),
		"The private child requires its explicit role, directory and mode.")
	Critical("Off")
	Suspend(false)
	if A_Args[1] == "writer"
		_IPCO_Writer(A_Args[2], A_Args[3])
	else {
		_IPCO_Require(A_Args[1] == "subject", "Only the two declared private roles may execute.")
		_IPCO_Subject(A_Args[2], A_Args[3])
	}
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n", "*", "UTF-8-RAW")
	ExitApp(1)
}

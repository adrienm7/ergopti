; tests/unit/suite/test_child_receipt_read.ahk

; ==============================================================================
; MODULE: Child Receipt Read Tests
; DESCRIPTION:
; Holds a published receipt open with write access, the way a scanner can hold a
; file a child has just renamed into place, and releases it from a timer. The
; strict reader refuses the held file (positive control); the readiness helper
; waits and returns the complete text once the holder lets go.
; ==============================================================================

#Requires AutoHotkey v2.0

; How long the holder keeps the receipt before its timer releases it.
global _TCRR_HOLD_MS := 150

_TCRR_HeldReceiptIsReadOnceReleased() {
	static GENERIC_WRITE := 0x40000000, FILE_SHARE_READ := 0x1, FILE_SHARE_WRITE := 0x2
	static OPEN_EXISTING := 3
	Directory := A_Temp . "\ergopti_child_receipt_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Path := Directory . "\ready.json"
	Holder := {Handle: -1, Released: 0}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(FSWriteCreateDurable(Path, '{"mode":"held"}'), "the receipt is published closed")
		Holder.Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", GENERIC_WRITE,
			"UInt", FILE_SHARE_READ | FILE_SHARE_WRITE, "Ptr", 0, "UInt", OPEN_EXISTING, "UInt", 0, "Ptr", 0, "Ptr")
		AssertTrue(Holder.Handle != -1, "the holder opens the receipt with write access")
		AssertFalse(FSReadUtf8Exact(Path) is String,
			"positive control: the strict reader refuses a receipt another process holds for writing")
		SetTimer(Release, -_TCRR_HOLD_MS)
		Text := TestAwaitChildReceiptUtf8(Path, () => false)
		AssertEqual(1, Holder.Released, "the read succeeds only after the holder let go")
		AssertEqual('{"mode":"held"}', Text, "the helper returns the complete receipt text")
		AssertEqual("held", JsonParse(Text)["mode"])
		AssertFalse(TestAwaitChildReceiptUtf8(Directory . "\absent.json", () => true),
			"a child that ended without its receipt yields false at once")
	} finally {
		SetTimer(Release, 0)
		Release()
		Critical(PreviousCritical)
		DirDelete(Directory, true)
	}

	Release() {
		if Holder.Handle != -1 {
			DllCall("kernel32\CloseHandle", "Ptr", Holder.Handle)
			Holder.Handle := -1
			Holder.Released += 1
		}
	}
}
Test("suite: a child receipt held by another process is read once released (pac-ready-receipt-race)",
	_TCRR_HeldReceiptIsReadOnceReleased)

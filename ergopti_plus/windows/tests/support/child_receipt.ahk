; tests/support/child_receipt.ahk

; ==============================================================================
; MODULE: Child Receipt Read
; DESCRIPTION:
; A test child process publishes a receipt by renaming a closed file into place,
; so the receipt is complete once its name exists. The strict UTF-8 reader opens
; it sharing read access only, so a process still holding the just-renamed file
; with write or delete access (a scanner, the indexer) makes that read return
; false for a moment. CI run 45363812480 parsed that false as the receipt and
; failed a PAC test on "Expected a String but got an Integer". Readiness is
; therefore a successful read, not a visible name.
; ==============================================================================

#Requires AutoHotkey v2.0

; Waits until the receipt a child publishes reads as UTF-8 text, while pumping
; the native process poller. Stops early when the child ended, after one last
; read, and after TEST_NATIVE_SETTLE_TIMEOUT_MS on a stalled host.
; @param {String} Path - The receipt the child renames into place.
; @param {Func} ChildEnded - Returns true once the child's completion arrived.
; @returns {String|Integer} The receipt text, or false when it never read.
TestAwaitChildReceiptUtf8(Path, ChildEnded) {
	global TEST_NATIVE_SETTLE_TIMEOUT_MS
	Started := A_TickCount
	loop {
		if FSStrictExists(Path) {
			Text := FSReadUtf8Exact(Path)
			if Text is String
				return Text
		}
		if ChildEnded.Call() || TickElapsed(Started) >= TEST_NATIVE_SETTLE_TIMEOUT_MS
			break
		_SR_TreePoll()
		Sleep(10)
	}
	if FSStrictExists(Path) {
		Text := FSReadUtf8Exact(Path)
		if Text is String
			return Text
	}
	return false
}

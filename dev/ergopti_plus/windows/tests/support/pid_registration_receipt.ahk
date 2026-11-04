; tests/support/pid_registration_receipt.ahk
;
; ==============================================================================
; MODULE: PID Registration Receipt Publication
; DESCRIPTION:
; Shared producer and admission boundary for the owned registration observer.
; ==============================================================================

#Requires AutoHotkey v2.0

_PidRegistrationReceiptIsReady(Path) => !!FileExist(Path)

_PidRegistrationPublish(Text, Path, AppendFn := FileAppend) {
	; The final name is the parent's readiness capability. Publish it only
	; after the append operation has closed its private sibling writer.
	Pending := Path . ".pending"
	try {
		AppendFn.Call(Text, Pending, "UTF-8")
		FileMove(Pending, Path, 0)
	} finally {
		if FileExist(Pending)
			FileDelete(Pending)
	}
}

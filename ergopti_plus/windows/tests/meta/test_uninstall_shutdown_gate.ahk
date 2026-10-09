; static/ergopti_plus/windows/tests/meta/test_uninstall_shutdown_gate.ahk
;
; ==============================================================================
; MODULE: Uninstall Shutdown Gate Contract
; DESCRIPTION:
; Reusing the ordinary shutdown coordinator must not turn a veto, reload or
; process crash into permission to remove the portable executable.
; ==============================================================================

_TestUninstallShutdownGate() {
	Body := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	Assert(Body != "", "the real shutdown coordinator must be readable")
	Terminal := InStr(Body, "ShutdownTerminal := true")
	Commit := InStr(Body, "UninstallCommit(reason)")
	Assert(Terminal > 0 && Commit > Terminal, "removal is authorized only after every refusal gate")
	Refusal := _StripFullLineComments(_DriverFuncBody("_LifecycleRefuseShutdown"))
	Assert(Refusal != "", "the refusal owner must be readable")
	AssertContains(Refusal, "UninstallCancel()", "every refusal revokes removal, including forced exit")
}
Test("Uninstall: all shutdown refusals precede removal authority (menu-uninstall)", _TestUninstallShutdownGate)

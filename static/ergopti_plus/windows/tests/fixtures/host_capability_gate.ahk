; static/ergopti_plus/windows/tests/fixtures/host_capability_gate.ahk

; ==============================================================================
; MODULE: Host Capability Gate
; DESCRIPTION:
; A case that needs a feature of the machine it runs on (for example a Windows
; component an image may omit) asks this gate first. Only a probe that positively
; reports the feature "absent" ends the case as NOT EXECUTED; "present" and
; "unknown" both run it, so a failure on a capable or unobservable host stays a
; failure and a case can never turn green by skipping.
; ==============================================================================

#Requires AutoHotkey v2.0

; Ends the current case as NOT EXECUTED when its probe positively reports the
; capability absent.
; @param ProbeFn {Func} Returns a Map with "state" ("present", "absent" or
;                       "unknown"), "name" and "why".
TestRequireHostCapability(ProbeFn) {
	Receipt := ProbeFn.Call()
	if Receipt["state"] == "absent"
		TestNotExecuted("host capability " . Receipt["name"] . " is absent: " . Receipt["why"])
}

; static/ergopti_plus/windows/tests/fixtures/host_capability_gate.ahk

; ==============================================================================
; MODULE: Host Capability Gate
; DESCRIPTION:
; A case that needs a feature of the machine it runs on (for example a Windows
; component an image may omit) asks this gate first. Only a probe that positively
; reports the feature "absent" ends the case as NOT EXECUTED; "present" and
; "unknown" both run it, so a failure on a capable or unobservable host stays a
; failure and a case can never turn green by skipping.
; Hosted CI provisions every declared capability (Kana install, en-US layout,
; symlink privilege), so on GitHub Actions an "absent" receipt is a failure:
; a lane can never skip a case its runner was supposed to provide for.
; ==============================================================================

#Requires AutoHotkey v2.0

; Whether this process runs on a GitHub Actions runner, the one context that
; must never report a case as not executed for a missing capability.
; @return {Boolean}
TestHostIsHostedCi() => StrCompare(EnvGet("GITHUB_ACTIONS"), "true", true) == 0

; Ends the current case as NOT EXECUTED when its probe positively reports the
; capability absent on a developer machine; fails it on hosted CI.
; @param ProbeFn {Func} Returns a Map with "state" ("present", "absent" or
;                       "unknown"), "name" and "why".
; @param HostedCi {Boolean} Test seam; TestHostIsHostedCi() when omitted.
TestRequireHostCapability(ProbeFn, HostedCi := unset) {
	Receipt := ProbeFn.Call()
	State := Receipt["state"]
	if !(State == "present" || State == "absent" || State == "unknown")
		throw ValueError("A host capability receipt state must be present, absent or unknown: " . State)
	if State != "absent"
		return
	if !IsSet(HostedCi)
		HostedCi := TestHostIsHostedCi()
	if HostedCi
		throw Error("hosted CI must provide host capability " . Receipt["name"] . ", which is absent: " . Receipt["why"])
	TestNotExecuted("host capability " . Receipt["name"] . " is absent: " . Receipt["why"])
}

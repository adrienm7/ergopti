; static/ergopti_plus/windows/tests/fixtures/host_capability_gate.ahk

; ==============================================================================
; MODULE: Host Capability Gate
; DESCRIPTION:
; A case that needs a feature of the machine it runs on (for example a Windows
; component an image may omit) asks this gate first. Only a probe that positively
; reports the feature "absent" ends the case as NOT EXECUTED; "present" and
; "unknown" both run it, so a failure on a capable or unobservable host stays a
; failure and a case can never turn green by skipping.
; A receipt whose "hosted_ci" is "required" names a capability hosted CI
; provisions (en-US layout, symlink privilege): on GitHub Actions its "absent"
; is a failure, so a lane can never skip a case its runner was supposed to
; provide for. Without it the receipt keeps the original rule everywhere: a
; case designed to be absent on an unattended runner (the CurrentUser root
; admission) is not executed there either.
; ==============================================================================

#Requires AutoHotkey v2.0

; Whether this process runs on a GitHub Actions runner, the one context that
; must never report a case as not executed for a missing capability.
; @return {Boolean}
TestHostIsHostedCi() => StrCompare(EnvGet("GITHUB_ACTIONS"), "true", true) == 0

; Ends the current case as NOT EXECUTED when its probe positively reports the
; capability absent; fails it instead on hosted CI when the receipt requires it.
; @param ProbeFn {Func} Returns a Map with "state" ("present", "absent" or
;                       "unknown"), "name", "why" and optionally "hosted_ci"
;                       ("required").
; @param HostedCi {Boolean} Test seam; TestHostIsHostedCi() when omitted.
TestRequireHostCapability(ProbeFn, HostedCi := unset) {
	Receipt := ProbeFn.Call()
	State := Receipt["state"]
	if !(State == "present" || State == "absent" || State == "unknown")
		throw ValueError("A host capability receipt state must be present, absent or unknown: " . State)
	HostedCiRule := Receipt.Get("hosted_ci", "")
	if !(HostedCiRule == "" || HostedCiRule == "required")
		throw ValueError("A host capability receipt hosted_ci must be absent or required: " . HostedCiRule)
	if State != "absent"
		return
	if !IsSet(HostedCi)
		HostedCi := TestHostIsHostedCi()
	if HostedCi && HostedCiRule == "required"
		throw Error("hosted CI must provide host capability " . Receipt["name"] . ", which is absent: " . Receipt["why"])
	TestNotExecuted("host capability " . Receipt["name"] . " is absent: " . Receipt["why"])
}

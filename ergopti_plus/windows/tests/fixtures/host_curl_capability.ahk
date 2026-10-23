; tests/fixtures/host_curl_capability.ahk

; ==============================================================================
; MODULE: Host Curl Capability Probe
; DESCRIPTION:
; Observes the features of the System32 curl.exe that the managed transport
; launches (ergopti_curl_attempt.ps1 and its capability worker resolve the same
; path), so a case that needs a real NTLM proxy handshake reports that this host
; cannot run it instead of failing for a reason no code change can fix.
;
; FEATURES & RATIONALE:
; 1. Fail closed: only a well-formed `curl --version` that lists its Features
;    without NTLM yields "no_ntlm". A failed launch, a nonzero exit, any stderr
;    or a malformed receipt is "unknown", and the case runs.
; 2. Same parse as the production capability worker: the version from the
;    first line, exactly one "Features: " line, NTLM as an exact feature token.
; 3. One observation per runner process: the binary cannot change mid-suite.
; ==============================================================================

#Requires AutoHotkey v2.0

; Classifies a captured `curl --version` run.
; @param ExitCode {Integer} The child's exit status.
; @param Stdout {String} Its complete standard output.
; @param Stderr {String} Its complete standard error.
; @returns {Map} "state" ("ntlm", "no_ntlm" or "unknown") and "version".
HostCurlParseNtlmCapability(ExitCode, Stdout, Stderr) {
	Unknown := Map("state", "unknown", "version", "")
	if !(ExitCode is Integer) || ExitCode != 0 || !(Stdout is String) || !(Stderr is String) || Stderr != ""
		return Unknown
	Lines := StrSplit(StrReplace(Stdout, "`r`n", "`n"), "`n")
	if Lines.Length < 2 || !RegExMatch(Lines[1], "^curl ([0-9]+\.[0-9]+\.[0-9]+)[-A-Za-z0-9.]* ", &Header)
		return Unknown
	Features := ""
	FeatureLines := 0
	for Line in Lines {
		if SubStr(Line, 1, 10) == "Features: " {
			FeatureLines += 1
			Features := SubStr(Line, 11)
		}
	}
	if FeatureLines != 1 || !RegExMatch(Features, "^[A-Za-z0-9 -]+$")
		return Unknown
	for Feature in StrSplit(Features, " ") {
		if Feature == "NTLM"
			return Map("state", "ntlm", "version", Header[1])
	}
	return Map("state", "no_ntlm", "version", Header[1])
}

; Observes the System32 curl once per runner process.
; @returns {Map} The HostCurlParseNtlmCapability receipt of the real binary.
HostCurlNtlmCapability() {
	static Cached := 0
	if Cached is Map
		return Cached
	Curl := A_WinDir . "\System32\curl.exe"
	Base := A_Temp . "\ergopti_host_curl_" . ProcessExist() . "_" . A_TickCount
	OutPath := Base . ".out", ErrPath := Base . ".err"
	Receipt := Map("state", "unknown", "version", "")
	try {
		ExitCode := RunWait(A_ComSpec . ' /d /c ""' . Curl . '" --disable --version > "' . OutPath
			. '" 2> "' . ErrPath . '""', , "Hide")
		Receipt := HostCurlParseNtlmCapability(ExitCode, FileRead(OutPath, "UTF-8"), FileRead(ErrPath, "UTF-8"))
	} catch {
		; An unobservable binary is an unknown capability: the case runs.
		Receipt := Map("state", "unknown", "version", "")
	} finally {
		for Path in [OutPath, ErrPath]
			if FileExist(Path)
				FileDelete(Path)
	}
	Cached := Receipt
	return Cached
}

; Ends the current case as NOT EXECUTED when the host curl positively lacks NTLM.
; A curl that lists NTLM, or one whose features are unknown, runs the case, so
; a failure there stays a failure.
; @param CapabilityFn {Func} Observation port; the probe's own tests replace it.
TestRequireHostCurlNtlm(CapabilityFn := unset) {
	Receipt := IsSet(CapabilityFn) ? CapabilityFn.Call() : HostCurlNtlmCapability()
	if Receipt["state"] == "no_ntlm"
		TestNotExecuted("host curl " . Receipt["version"]
			. " lists no NTLM; needs the owned SSPI curl (TODO item 62)")
}

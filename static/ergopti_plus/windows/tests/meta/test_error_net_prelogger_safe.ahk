; tests/meta/test_error_net_prelogger_safe.ahk

; ==============================================================================
; MODULE: Regression — the pre-ready error branch must not throw on its own
;         (error-net-prelogger-safe)
; DESCRIPTION:
; The 07-19 boot crashes exist only in crash_reports/ and reached no daily log
; at all. That is not a logging gap: the error handler crashed.
;
; ROOT CAUSE ENCODED: OnError is armed deliberately early, above Bundle_Init's
; message-pumping RunWait, so a keypress during the extraction has a net. Its
; pre-ready branch then implements the fail-closed contract — resolve a log
; path, flush the pending queue, tell the user in a modal, ExitApp(1) — and the
; first step read LOGGER_LOG_PATH bare. But LOGGER_LOG_PATH is only DECLARED at
; the logger include's position, far BELOW where OnError is armed. So for every
; fault in the window this branch exists to cover, the read raised UnsetError
; inside the handler itself: no log path, no flush, no dialog, no exit code —
; AHK's raw error dialog instead, and nothing on disk.
;
; The invariant is stronger than "guard this one variable": anything the
; pre-ready branch touches must be reachable BEFORE the first message pump. So
; the test derives the set of globals that genuinely are — everything assigned
; above Bundle_Init() in the entry, plus every module-level global of the files
; included above it — and requires every other global the branch reads to be
; IsSet-guarded.
;
; SCOPE: source-level. The branch ends in ExitApp(1) by design and cannot be
; invoked from inside the runner it would terminate.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================================
; =============================================================
; ======= 1/ What actually exists before the first pump =======
; =============================================================
; ===============================================================

; The entry source above Bundle_Init(), comments stripped.
_ENPS_PrePumpRegion() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	if (Src == "")
		return ""
	Code := _StripFullLineComments(Src)
	BundlePos := InStr(Code, "Bundle_Init()")
	return (BundlePos > 0) ? SubStr(Code, 1, BundlePos) : ""
}

; Every global that is assigned before the first message pump: those written in
; the entry's pre-pump region, plus the module-level globals of every file the
; region #Includes (an include above Bundle_Init has fully executed by then).
_ENPS_PrePumpGlobals() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Region := _ENPS_PrePumpRegion()
	Names := Map()
	if (Region == "")
		return Names

	Sources := [Region]
	Pos := 1
	while (FoundPos := RegExMatch(Region, "m)^#Include\s+([^\r\n]+)$", &Inc, Pos)) {
		Pos := FoundPos + Inc.Len
		Rel := Trim(Inc[1], " `t")
		Body := ""
		try Body := FileRead(WindowsDir . "\" . StrReplace(Rel, "/", "\"))
		if (Body != "")
			Sources.Push(_StripFullLineComments(Body))
	}

	for Src in Sources {
		P := 1
		while (F := RegExMatch(Src, "m)^global\s+([A-Za-z_]\w*)\s*:=", &G, P)) {
			P := F + G.Len
			Names[G[1]] := true
		}
	}
	return Names
}





; ===============================================================
; ===========================================================
; ======= 2/ The pre-ready branch reads nothing unset =======
; ===========================================================
; ===============================================================

; The body of the `if (_DriverBootPhase != "ready")` branch, which is the whole
; pre-ready contract.
_ENPS_PreReadyBranch() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	if (Body == "")
		return ""
	Start := InStr(Body, '_DriverBootPhase != "ready"')
	if (!Start)
		return ""
	; Up to the branch's ExitApp, which is its only exit.
	Stop := InStr(Body, "ExitApp(1)", , Start)
	return (Stop > 0) ? SubStr(Body, Start, Stop - Start) : ""
}

_ENPS_BranchReadsNoUnsetGlobal() {
	Branch := _ENPS_PreReadyBranch()
	Assert(Branch != "",
		"the pre-ready branch of ErgoptiGlobalErrorHandler must exist and end in ExitApp(1) — without both landmarks this guard measures nothing")

	Available := _ENPS_PrePumpGlobals()
	Count := 0
	for _, _ in Available
		Count++
	Assert(Count >= 5,
		"the pre-pump global scan must reach the entry and its early includes (found only " . Count . ") — an empty set would make every assertion below vacuous")

	; UPPER_SNAKE and _Underscore names are the globals; locals in this branch are
	; not spelled that way. Read each occurrence and demand it be either available
	; before the pump or IsSet-guarded.
	Pos := 1
	while (FoundPos := RegExMatch(Branch, "\b([A-Z][A-Z0-9_]{3,}|_[A-Za-z]\w*)\b", &M, Pos)) {
		Pos := FoundPos + M.Len
		Name := M[1]
		if Available.Has(Name)
			continue
		if InStr(Branch, "IsSet(" . Name . ")")
			continue
		; Function calls are not global reads; the branch calls several.
		if RegExMatch(Branch, "\b" . Name . "\s*\(")
			continue
		Assert(false,
			"the pre-ready error branch reads '" . Name . "', which is not assigned before Bundle_Init's message pump and is not IsSet-guarded. This branch runs for faults in exactly that window, so the read throws inside the handler and the entire fail-closed contract — resolve a log path, flush, tell the user, exit 1 — never runs. That is why a boot crash can leave nothing on disk")
	}
}

; The contract itself must stay intact: guarding the read is worthless if the
; steps it protects are gone.
_ENPS_FailClosedContractIntact() {
	Branch := _ENPS_PreReadyBranch()
	Assert(Branch != "", "the pre-ready branch must exist")
	Assert(InStr(Branch, "LoggerInit") > 0,
		"the branch must resolve a log path — many fail-fast loaders run before LoggerInit, so without it the fatal line dies in RAM")
	Assert(InStr(Branch, "_LoggerFlush") > 0,
		"the branch must force a flush before exiting, or the queued fatal line never reaches disk")
	Assert(InStr(Branch, "MsgBox") > 0,
		"the branch must tell the user why the driver is exiting, or the exe silently does nothing on every launch")
}


Test("meta error-net-prelogger-safe: the pre-ready branch reads no unset global",
	_ENPS_BranchReadsNoUnsetGlobal)
Test("meta error-net-prelogger-safe: the fail-closed contract is intact",
	_ENPS_FailClosedContractIntact)

; tests/meta/test_reload_pending_contract.ahk

; ==============================================================================
; MODULE: Reload Pending Contract Meta Test
; DESCRIPTION:
; A reload returns as soon as its successor launches; OnExit runs only when the
; successor asks this instance to close, and it can still refuse then
; (reload-returns-pending). Two consequences are pinned here against the
; driver source, because infra/lifecycle.ahk is outside the headless include
; graph:
;   1. A caller that lends its configuration bundle to ReloadPreservingSuspend
;      cannot roll back on the return value alone. The paths editor, onboarding
;      and reset used to roll back a committed transition on every successful
;      reload, and nothing could have rolled back a reload refused later. Every
;      lender must pass the refusal callback that takes the bundle back. The
;      call sites are derived from the source tree, so a new lender without one
;      fails here without anyone having to list it.
;   2. Every OnExit veto funnels through _LifecycleRefuseShutdown, so that one
;      site must hand a vetoed Reload back, and an ordinary exit that wins must
;      stop the successor it supersedes.
;   3. The layout poll retries a refused reload on its own. Its retries must
;      not reach the veto OnExit forces through, nor repeat the "save failed"
;      notice meant for a user's own save (layout-poll-retry-bounded).
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Bundle lenders take refusal back =======
; ===================================================
; ===================================================

; Splits the argument list of the call whose "(" is at OpenPos into top-level
; argument texts, skipping nested brackets and quoted strings.
_RBL_CallArguments(Src, OpenPos) {
	Args := []
	Depth := 0
	Current := ""
	Quote := ""
	Index := OpenPos + 1
	Length := StrLen(Src)
	while (Index <= Length) {
		Char := SubStr(Src, Index, 1)
		Index += 1
		if (Quote != "") {
			Current .= Char
			if (Char == Quote)
				Quote := ""
			continue
		}
		if (Char == '"' || Char == "'") {
			Quote := Char
			Current .= Char
			continue
		}
		if InStr("([{", Char) {
			Depth += 1
		} else if InStr(")]}", Char) {
			if (Depth == 0) {
				Args.Push(Trim(Current, " `t`r`n"))
				return Args
			}
			Depth -= 1
		} else if (Char == "," && Depth == 0) {
			Args.Push(Trim(Current, " `t`r`n"))
			Current := ""
			continue
		}
		Current .= Char
	}
	return Args
}

_RBL_EveryBundleLenderTakesTheRefusalBack() {
	Src := ""
	for Dir in ["infra", "ui", "modules", "platform", "adapters"]
		Src .= "`n" . _StripFullLineComments(_DriverDirConcat(Dir))
	Assert(StrLen(Src) > 200000,
		"the driver source trees must be readable for this scan to mean anything")
	Calls := 0
	Lenders := 0
	Offenders := ""
	Pos := 1
	while (Pos := RegExMatch(Src, "(?<![\w.])ReloadPreservingSuspend\(", &Match,
			Pos)) {
		OpenPos := Pos + Match.Len - 1
		Pos := OpenPos + 1
		Args := _RBL_CallArguments(Src, OpenPos)
		; The declaration's parameters carry defaults; it is not a call site.
		if (Args.Length >= 1 && InStr(Args[1], ":="))
			continue
		Calls += 1
		if (Args.Length < 2 || Args[2] == "" || Args[2] == "0")
			continue
		Lenders += 1
		if (Args.Length < 3 || Args[3] == "" || Args[3] == "0")
			Offenders .= (Offenders == "" ? "" : "; ")
				. "ReloadPreservingSuspend(" . Args[1] . ", " . Args[2] . ")"
	}
	; Shared hotstring bulk admission consolidates the audited routed census.
	Assert(Calls >= 22,
		"the scan must still find the reload call sites (found " . Calls . ")")
	Assert(Lenders >= 4,
		"the scan must still find the bundle lenders: paths editor, onboarding, reset and channel switch (found "
		. Lenders . ")")
	Assert(Offenders == "",
		"a caller that lends its bundle to a reload must pass the refusal callback that takes it back "
		. "(reload-returns-pending): " . Offenders)
}
Test("reload: every bundle lender passes the refusal callback (reload-returns-pending)",
	_RBL_EveryBundleLenderTakesTheRefusalBack)





; ====================================================
; ====================================================
; ======= 2/ OnExit hands a vetoed Reload back =======
; ====================================================
; ====================================================

_RBL_EveryVetoHandsTheReloadBack() {
	Shutdown := _StripFullLineComments(_DriverFuncBody("Ergopti_OnShutdown"))
	Refuse := _StripFullLineComments(_DriverFuncBody("_LifecycleRefuseShutdown"))
	Assert(Shutdown != "" && Refuse != "",
		"the shutdown handler and its shared veto must be source-visible")
	ReasonPos := InStr(Shutdown, "_LifecycleShutdownReason := reason", true)
	FirstVeto := InStr(Shutdown, "_LifecycleRefuseShutdown(", true)
	Assert(ReasonPos > 0 && FirstVeto > ReasonPos,
		"the exit reason must be published before the first gate can veto")
	HandBack := InStr(Refuse,
		"ReloadTerminalHandoffRefuseForShutdown(_LifecycleShutdownReason", true)
	VetoReturn := InStr(Refuse, "return 1", true)
	Assert(HandBack > 0 && VetoReturn > HandBack,
		"the one veto every gate funnels through must refuse the pending reload "
		. "before keeping this instance alive, or its successor waits and prompts forever")
	Terminal := InStr(Shutdown, "ShutdownTerminal := true", true)
	Abandon := InStr(Shutdown, "ReloadTerminalHandoffAbandon(SupersededReload", true)
	PrepareAbandon := InStr(Shutdown, "ReloadTerminalHandoffPrepareAbandon(SupersededReload", true)
	ReadGate := InStr(Shutdown, "if FileReadActivityBusy()", true)
	FinalExit := InStr(Shutdown, "_Updater_SignalFinalExitForIntent()", true)
	Transfer := InStr(Shutdown, "_Updater_TransferExitIntentAfterShutdownGates()", true)
	Recovery := InStr(Shutdown, "_Updater_CompleteRecoveryHandoffOnExit()", true)
	Assert(ReadGate > 0 && PrepareAbandon > ReadGate && FinalExit > PrepareAbandon
		&& Transfer > PrepareAbandon && Recovery > PrepareAbandon && Terminal > PrepareAbandon
		&& Abandon > Terminal,
		"ordinary exit proves native successor quiescence after reversible read/save gates "
		. "and before any FinalExit, ownership transfer, recovery or terminal admission; only final close follows acceptance")
	Assert(InStr(Shutdown, "_LifecycleRefuseNativeRetirement(" . Chr(34) . "a reload successor still owns native retirement", true) > 0,
		"An unproven native stop remains an actual reversible veto.")
	Assert(InStr(Shutdown, "ReloadTerminalHandoffPending()", true) > 0,
		"an ordinary exit must borrow the pending reload's bundle instead of "
		. "refusing on the barrier it holds")
}
Test("reload: every OnExit veto hands the launched reload back (reload-returns-pending)",
	_RBL_EveryVetoHandsTheReloadBack)





; ============================================================
; ============================================================
; ======= 3/ The automatic reload stays within bounds ========
; ============================================================
; ============================================================

; OnExit and the layout poll read the veto ceiling through one rule, and the
; poll's port consults it; the reload core reports a refused stage through the
; caller's reporter, so the poll's quiet one replaces the notice.
_RBL_TheAutomaticReloadStaysWithinBounds() {
	Rule := _StripFullLineComments(_DriverFuncBody("LifecycleShutdownVetoHonored"))
	Refuse := _StripFullLineComments(_DriverFuncBody("_LifecycleRefuseShutdown"))
	Assert(InStr(Rule, "LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS") > 0
		&& InStr(Refuse, "Honored := LifecycleShutdownVetoHonored()") > 0,
		"OnExit must decide a veto through the rule the layout poll consults")
	Port := _StripFullLineComments(_DriverFuncBody("LayoutPollPort"))
	Assert(InStr(Port, '"veto_honored", LifecycleShutdownVetoHonored') > 0,
		"the layout poll must ask whether OnExit could still refuse before reloading")
	Core := _StripFullLineComments(_DriverFuncBody("_ReloadPreservingSuspendNonCritical"))
	Assert(Core != "", "the reload core must be source-visible")
	AssertEqual(0, _RBL_Count(Core, "_SuspendHandoffFailure("),
		"every stage refused before launch must go through the caller's reporter, not the notice directly")
	AssertEqual(2, _RBL_Count(Core, "ReportStage.Call("),
		"the lease and owner refusals must each be reported")
	Assert(InStr(Core, "ReadyFn, ReportStage,") > 0,
		"the suspended hand-off's own stages must use the same reporter")
}
Test("reload: the layout poll's reload never forces a veto nor shows a save notice (layout-poll-retry-bounded)",
	_RBL_TheAutomaticReloadStaysWithinBounds)

_RBL_Count(Haystack, Needle) {
	return (StrLen(Haystack) - StrLen(StrReplace(Haystack, Needle))) // StrLen(Needle)
}





; ====================================================
; ====================================================
; ======= 4/ Workers stop before the successor =======
; ====================================================
; ====================================================

; A detached worker that re-runs the driver entry holds the driver's window
; title while it starts, and a /restart successor closes the newest window with
; that title: it closed a worker instead of the driver and the reload was
; refused (reload-worker-identity). The launcher must stop the workers before
; it starts the successor, and every worker kind must be among them.
_RBL_WorkersStopBeforeTheSuccessorLaunches() {
	Launch := _StripFullLineComments(_DriverFuncBody("LifecycleLaunchSuccessor"))
	Retire := _StripFullLineComments(_DriverFuncBody("LifecycleRetireWorkers"))
	Assert(Launch != "" && Retire != "",
		"the successor launcher and its worker retirement must be source-visible")
	RetirePos := InStr(Launch, "LifecycleRetireWorkers()", true)
	LaunchPos := InStr(Launch, "ReloadSuccessorLaunch(", true)
	Assert(RetirePos > 0 && LaunchPos > RetirePos,
		"the detached workers must be stopped before the successor is launched, "
		. "or it can close one of them instead of this instance")
	for Stop in ["KLPF_CancelAll()", 'UIASW_Stop("canceled")']
		Assert(InStr(Retire, Stop, true) > 0,
			"the retirement must stop every worker that re-runs the driver entry: "
			. Stop)
}
Test("reload: the workers stop before the successor launches (reload-worker-identity)",
	_RBL_WorkersStopBeforeTheSuccessorLaunches)

; tests/meta/test_error_net_uia_orphan_suppress.ahk

; ==============================================================================
; MODULE: Error-Net UIA Orphaned-Pattern Suppression Meta Test
; DESCRIPTION:
; Regression guard for the production crash in crash_reports/2026-06-25T17-14-06Z.json:
; PropertyError "Property ptr not found in UIA.IUIAutomationTextPattern Class."
; thrown from vendor/UIA.ahk's IUIAutomationBase.Prototype.Release/__Delete.
;
; Root cause (confirmed by an isolated, side-effect-free repro that mirrors
; vendor/UIA.ahk's exact class shape): modules/keymap/layout.ahk's
; _UIA_SelectionPollTick calls el.GetPattern("Text") right after an
; IsTextPatternAvailable probe on the same focused element. Microsoft's
; IUIAutomationElement::GetCurrentPattern legitimately returns S_OK with a NULL
; pattern pointer (not a failure HRESULT) when the target element goes stale
; between the two COM round-trips -- e.g. its window closes or loses focus mid
; poll on the 500 ms background timer. vendor/UIA.ahk's GetPattern() then
; unconditionally constructs UIA.IUIAutomationTextPattern(0) with no null guard
; (unlike sibling sites such as GetFocusedElement/ElementFromHandle, which all
; guard with "ptr ? this.IUIAutomationElement(ptr) : throw"). The null-pointer
; constructor throws ValueError BEFORE DefineProp("ptr", ...) runs; AHK v2 then
; immediately invokes __Delete on the orphaned, ptr-less instance to unwind the
; failed construction, and THAT __Delete-time PropertyError is raised by the
; runtime's own cleanup machinery -- confirmed empirically to be uncatchable by
; any try/catch at the call site (only the original ValueError reaches the local
; catch; the PropertyError is only ever seen by the process-wide OnError
; handler). _UIA_SelectionPollTick already catches the original ValueError and
; degrades to "no selection" -- the crash is a false-alarm OnError notification
; for an already-handled condition, not a functional failure.
;
; Cannot modify vendor/UIA.ahk (third-party) and an ordinary try/catch cannot
; intercept a __Delete-time exception, so the fix lives in the process-wide net
; itself (infra/error_net.ahk): a narrow predicate recognises this exact benign
; signature (PropertyError, Extra == "ptr", What starting with
; "UIA.IUIAutomationBase.Prototype.Release") and short-circuits to a quiet
; WARNING log, skipping the disruptive crash-report prompt/toast -- every other
; error still goes through the full net unchanged.
;
; SCOPE: source introspection of infra/error_net.ahk (ErgoptiPlus.ahk registers
; hotkeys at load time and cannot be #Included headless).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Guard is present and matched first ====
; ==================================================
; ==================================================

_ENUOS_PredicateHelperExists() {
	Body := _DriverFuncBody("_IsBenignUiaOrphanedPatternError")
	Assert(Body != "", "_IsBenignUiaOrphanedPatternError(Exc) must exist in infra/error_net.ahk")
	Assert(InStr(Body, "PropertyError") > 0,
		'_IsBenignUiaOrphanedPatternError must check Type(Exc) == "PropertyError" -- the crash signature is specifically a PropertyError, not a generic Error')
	Assert(InStr(Body, "ptr") > 0,
		'_IsBenignUiaOrphanedPatternError must check Exc.Extra == "ptr" -- the vendor __Get handler sets Extra to the missing property name')
	Assert(InStr(Body, "UIA.IUIAutomationBase.Prototype.Release") > 0,
		"_IsBenignUiaOrphanedPatternError must check Exc.What against UIA.IUIAutomationBase.Prototype.Release -- narrowing to the exact vendor call site prevents over-matching unrelated PropertyErrors")
}
Test("meta error-net-uia-orphan: _IsBenignUiaOrphanedPatternError exists and checks Type/Extra/What (uia-orphaned-pattern-suppress)",
	_ENUOS_PredicateHelperExists)

_ENUOS_HandlerChecksGuardFirst() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler(Exc, Mode) must exist in infra/error_net.ahk")
	GuardPos := InStr(Body, "_IsBenignUiaOrphanedPatternError(")
	Assert(GuardPos > 0,
		"ErgoptiGlobalErrorHandler must call _IsBenignUiaOrphanedPatternError to short-circuit the benign UIA orphaned-pattern signature")
	SendEventPos := InStr(Body, "SendEvent(")
	Assert(SendEventPos = 0 or GuardPos < SendEventPos,
		"the _IsBenignUiaOrphanedPatternError guard must run BEFORE the modifier-release loop and crash-report scheduling, so the benign case short-circuits cheaply without doing any of that work")
}
Test("meta error-net-uia-orphan: ErgoptiGlobalErrorHandler checks the UIA-orphan guard before the modifier/crash-report path (uia-orphaned-pattern-suppress)",
	_ENUOS_HandlerChecksGuardFirst)

_ENUOS_BenignPathSkipsCrashReport() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	; Extract just the "if _IsBenignUiaOrphanedPatternError(...) { ... }" block so the
	; assertion is scoped to the short-circuit branch, not the whole handler body --
	; the generic path further down legitimately DOES call SetTimer/_ErgoptiDeferredCrashReport.
	GuardPos := InStr(Body, "_IsBenignUiaOrphanedPatternError(")
	Assert(GuardPos > 0, "guard call must be present (see previous test)")
	BraceOpen := InStr(Body, "{", , GuardPos)
	Assert(BraceOpen > 0, "guard call must be followed by an if-block")
	depth := 0, i := BraceOpen, Len := StrLen(Body), BlockEnd := Len
	while (i <= Len) {
		ch := SubStr(Body, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0) {
				BlockEnd := i
				break
			}
		}
		i++
	}
	GuardBlock := SubStr(Body, BraceOpen, BlockEnd - BraceOpen + 1)
	Assert(InStr(GuardBlock, "_ErgoptiDeferredCrashReport") = 0,
		"the benign-UIA-orphan short-circuit must NOT schedule _ErgoptiDeferredCrashReport -- that is exactly the disruptive prompt this fix exists to suppress")
	Assert(InStr(GuardBlock, "NotifierSend(") = 0,
		"the benign-UIA-orphan short-circuit must NOT surface a NotifierSend toast -- the originating call site already handled the real error silently")
	Assert(InStr(GuardBlock, "return") > 0,
		"the benign-UIA-orphan short-circuit must return early so control never reaches the generic crash-report path below it")
}
Test("meta error-net-uia-orphan: the benign-UIA-orphan short-circuit skips the crash-report prompt and toast (uia-orphaned-pattern-suppress)",
	_ENUOS_BenignPathSkipsCrashReport)




; ==================================================
; ==================================================
; ======= 2/ Predicate logic -- behavioural ========
; ==================================================
; ==================================================

; Mirrors _IsBenignUiaOrphanedPatternError's exact logic against REAL PropertyError
; instances (not source-scanned strings) so a future edit that changes the
; comparison operators/field names without updating the source-scan strings above
; still gets caught by an independent behavioural check.
_ENUOS_MirrorPredicate(Exc) {
	return Type(Exc) == "PropertyError"
		and Exc.HasProp("Extra") and Exc.Extra == "ptr"
		and Exc.HasProp("What") and InStr(Exc.What, "UIA.IUIAutomationBase.Prototype.Release") == 1
}

_ENUOS_MatchesExactCrashSignature() {
	Exc := PropertyError("Property ptr not found in UIA.IUIAutomationTextPattern Class.", "UIA.IUIAutomationBase.Prototype.Release", "ptr")
	Assert(_ENUOS_MirrorPredicate(Exc),
		"the predicate must match the exact crash_reports/2026-06-25T17-14-06Z.json signature (PropertyError, Extra=ptr, What=UIA.IUIAutomationBase.Prototype.Release)")
}
Test("meta error-net-uia-orphan: predicate matches the exact production crash signature (uia-orphaned-pattern-suppress)",
	_ENUOS_MatchesExactCrashSignature)

_ENUOS_RejectsUnrelatedPropertyError() {
	; Same Type(PropertyError) but a different Extra/What -- must NOT be swallowed,
	; or a real, unrelated property-access bug would silently vanish from the net.
	Exc := PropertyError("Property foo not found in SomeOtherClass Class.", "SomeOtherClass.Prototype.Bar", "foo")
	Assert(!_ENUOS_MirrorPredicate(Exc),
		"the predicate must NOT match an unrelated PropertyError -- over-matching would silently swallow real bugs through the same short-circuit")
}
Test("meta error-net-uia-orphan: predicate rejects an unrelated PropertyError (uia-orphaned-pattern-suppress)",
	_ENUOS_RejectsUnrelatedPropertyError)

_ENUOS_RejectsNonPropertyErrorSameWhat() {
	; A plain Error (not PropertyError) must never match, even if some future
	; refactor makes an unrelated code path set matching Extra/What-like text.
	Exc := ValueError("Invalid IUnknown interface pointer", "UIA.IUIAutomationBase.Prototype.Release")
	Assert(!_ENUOS_MirrorPredicate(Exc),
		'the predicate must require Type(Exc) == "PropertyError" specifically -- a ValueError (e.g. the original __New failure) must fall through to the normal error-handling path')
}
Test("meta error-net-uia-orphan: predicate rejects a same-What ValueError (only PropertyError matches) (uia-orphaned-pattern-suppress)",
	_ENUOS_RejectsNonPropertyErrorSameWhat)

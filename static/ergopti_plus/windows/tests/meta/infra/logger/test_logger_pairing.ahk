; tests/meta/infra/logger/test_logger_pairing.ahk

; ==============================================================================
; MODULE: Logger Lifecycle Pairing Test
; DESCRIPTION:
; For each production AHK source file, counts LoggerStart vs LoggerSuccess and
; LoggerTrace vs LoggerDone occurrences. A lifecycle opener with no terminal,
; or more TRACE operations than DONE terminals, fails the suite. The generated
; TOML fast path historically returned after TRACE while an unrelated fallback
; DONE made the old presence-only gate pass. (AHK-28.)
; ==============================================================================

#Requires AutoHotkey v2.0

; Files whose lifecycle pair legitimately closes in ANOTHER file, which a
; per-file count cannot see. Each entry is verified, not assumed — keep this
; list minimal and justify every addition, because every entry is a place the
; gate stops looking.
;
;   modules/gestures/actions.ahk — opens "Capturing screen to…" and hands the
;   completion to GestureScreenshotComplete, which closes it at
;   modules/gestures/screenshots.ahk:155 and :158. Genuinely asynchronous: the
;   PowerShell worker must finish before success can be asserted, and the old
;   code's bug was announcing success BEFORE the worker ran.
_MetaLoggerPairingExempt(Rel) {
	static Exempt := Map("modules/gestures/actions.ahk", true)
	return Exempt.Has(Rel)
}





; ======================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; ======================================

_MetaLoggerReadSources(Root := unset) {
	Census := _DriverProductionSourceCensus(Root?)
	Prefix := RTrim(StrReplace(Census.Root, "\", "/"), "/") . "/"
	Sources := Map()
	for Path in Census.Paths {
		Relative := SubStr(StrReplace(Path, "\", "/"), StrLen(Prefix) + 1)
		if Relative == "" || Sources.Has(Relative)
			throw Error("The logger census must retain distinct relative source identities.")
		; A listed source is part of the subject: failed reads must fail the test.
		Sources[Relative] := FileRead(Path, "UTF-8")
	}
	return Sources
}

_MetaLoggerCallCount(Body, Name) {
	Code := _DriverMaskNonCode(&Body)
	return _MetaCountPattern(Code, "i)\b" . Name . "\s*\(")
		- _DriverTopLevelDefinitionCount(&Code, Name)
}


_MetaCountPattern(Body, Pattern) {
	N := 0
	Pos := 1
	while RegExMatch(Body, Pattern, , Pos) {
		N++
		Pos := RegExMatch(Body, Pattern, &M, Pos) + StrLen(M[0])
		if Pos <= 1 {
			break
		}
	}
	return N
}

_MetaLifecycleHasShortfall(OpenCount, CloseCount) {
	return OpenCount > CloseCount
}





; =====================================
; =====================================
; ======= 2/ Test registrations =======
; =====================================
; =====================================

_MetaLoggerCheckPairing(Root := unset) {
	Sources := _MetaLoggerReadSources(Root?)
	Imbalanced := 0
	Producers := 0
	Report := ""
	for Relative, Body in Sources {
		if _MetaLoggerPairingExempt(Relative)
			continue
		NStart := _MetaLoggerCallCount(Body, "LoggerStart")
		NSuccess := _MetaLoggerCallCount(Body, "LoggerSuccess")
		NTrace := _MetaLoggerCallCount(Body, "LoggerTrace")
		NDone := _MetaLoggerCallCount(Body, "LoggerDone")
		Producers += NStart + NTrace
		if NStart > 0 && NSuccess == 0 {
			Imbalanced++
			Report .= "`n" . Relative . " has " . NStart . " LoggerStart but no LoggerSuccess"
		}
		if _MetaLifecycleHasShortfall(NTrace, NDone) {
			Imbalanced++
			Report .= "`n" . Relative . " has " . NTrace . " LoggerTrace but " . NDone . " LoggerDone"
		}
	}
	Assert(Producers > 0, "the logger pairing census must inspect actual lifecycle producers")
	Assert(Imbalanced == 0,
		"unpaired lifecycle logs: " . Report)
	return Map("files", Sources.Count, "producers", Producers)
}

_MetaLoggerPairingAssert() {
	_MetaLoggerCheckPairing()
}
Test("meta logger pairing: no file opens a lifecycle pair it never closes",
	_MetaLoggerPairingAssert)


_MetaLoggerPairingRejectsPartialTracePair() {
	Assert(_MetaLifecycleHasShortfall(2, 1),
		"two TRACE operations with one DONE terminal must be rejected, even though both tokens exist")
	Assert(!_MetaLifecycleHasShortfall(1, 1),
		"a balanced TRACE/DONE operation count must remain accepted")
}
Test("meta logger pairing: partial TRACE/DONE pairs fail (logger-partial-pairing)",
	_MetaLoggerPairingRejectsPartialTracePair)

_MetaTomlGeneratedLoaderClosesTrace() {
	Body := _DriverFuncBody("LoadHotstringsSection")
	Assert(Body != "", "LoadHotstringsSection must exist for the generated-loader lifecycle guard")

	TracePos := InStr(Body, 'LoggerTrace("TomlLoader", "Using generated loader')
	CallPos := InStr(Body, "GeneratedFn(", , TracePos)
	ReturnPos := InStr(Body, "return", , CallPos)
	DonePos := InStr(Body, 'LoggerDone("TomlLoader"', , CallPos)
	Assert(TracePos > 0 && CallPos > TracePos && ReturnPos > CallPos,
		"the generated-loader fast path must remain structurally reachable")
	Assert(DonePos > CallPos && DonePos < ReturnPos,
		"the generated-loader fast return must close its TRACE with DONE after registration succeeds")
}
Test("toml loader: generated fast path closes TRACE before return (toml-generated-loader-pairing)",
	_MetaTomlGeneratedLoaderClosesTrace)

; F-L08: a LoggerStart immediately before Reload() leaves a START with no reachable
; SUCCESS — the process restarts before the pair closes, so it reads as a silent failure
; to anyone auditing the prior process's rolled-over log. Guard the whole driver source.
_MetaLoggerCheckReload(Root := unset) {
	Sources := _MetaLoggerReadSources(Root?)
	Offenders := ""
	Starts := 0
	Reloads := 0
	for Relative, Body in Sources {
		Starts += _MetaLoggerCallCount(Body, "LoggerStart")
		Reloads += _MetaLoggerCallCount(Body, "Reload")
		Code := _DriverMaskNonCode(&Body)
		if RegExMatch(Code, "i)LoggerStart\([^\r\n]*\)\s*\r?\n\s*Reload")
			Offenders .= "`n  " . Relative
	}
	Assert(Starts > 0 && Reloads > 0, "the reload census must inspect actual lifecycle and reload producers")
	Assert(Offenders == "",
		"A LoggerStart must not immediately precede Reload: " . Offenders)
	return Map("files", Sources.Count, "starts", Starts, "reloads", Reloads)
}

_MetaNoStartBeforeReload() {
	_MetaLoggerCheckReload()
}
Test("logger: no LoggerStart immediately precedes Reload (dangling-start-before-reload)", _MetaNoStartBeforeReload)

; F-L09: the updater one-click up-to-date branch is a successful completion of the check,
; so it must close its START with LoggerSuccess, not LoggerInfo.
_MetaUpdaterUpToDateLogsSuccess() {
	SplitPath(A_ScriptDir, , &Root)
	src := FileRead(StrReplace(Root, "\", "/") . "/modules/updater/changelog.ahk")
	Assert(InStr(src, "already up to date") > 0, "sanity: the up-to-date message must exist in changelog.ahk")
	Assert(RegExMatch(src, "LoggerInfo\([^\r\n]*already up to date") == 0,
		"the one-click up-to-date path must close its START with LoggerSuccess, not LoggerInfo (updater-up-to-date-pairing)")
}
Test("logger: updater one-click up-to-date path closes START with SUCCESS (updater-up-to-date-pairing)", _MetaUpdaterUpToDateLogsSuccess)

; F34 (audit 2026-07-20): §4.4 — log messages are developer-facing and must be in
; English. A French LoggerStart literal ("Enregistrement des hotkeys configurables…")
; sat on the START half of an otherwise correctly paired START/SUCCESS lifecycle,
; where the grep-based pairing audits key on English message patterns.
_MetaLifecycleLogsAreEnglish() {
	Src := _DriverSourceNoComments()
	; A few unmistakably French tokens that only ever appear in prose, never in an
	; identifier — cheap and specific enough to catch a regression without false hits.
	for Token in ["Enregistrement des", "Chargement des", "Suppression des", "Démarrage du"] {
		Assert(InStr(Src, 'Logger') > 0, "driver source must contain Logger calls")
		Assert(InStr(Src, Token) = 0,
			"log messages must be written in English (§4.4) — found French prose token: " . Token)
	}
}
Test("logger: lifecycle log messages are written in English (§4.4)", _MetaLifecycleLogsAreEnglish)


; Native private source files qualify the scanner, including its refusal paths.
_MLP_ExpectedRefusal(Check, Root, ErrorType, Fragment := "") {
	Observed := false
	try Check.Call(Root)
	catch as Err {
		Observed := true
		AssertEqual(ErrorType, Type(Err), "the actual scanner must fail at the intended boundary")
		if Fragment != ""
			AssertTrue(InStr(Err.Message, Fragment) > 0, "the refusal must identify its actual failed invariant")
	}
	AssertTrue(Observed, "a failed source scan cannot certify a clean lifecycle census")
}

_MLP_Source(Kind) {
	if Kind == "unbalanced" || Kind == "adapter" {
		return 'Probe() {`n LoggerStart("Audit", "Started.")`n Text := "LoggerSuccess(noise)"`n}`n'
	}
	if Kind == "reload" {
		return 'Probe() {`n LoggerStart("Audit", "Started.")`n Reload()`n}`n'
	}
	if Kind == "no-producer"
		return '; LoggerStart(noise)`n; LoggerSuccess(noise)`nProbe() {`n Text := "LoggerTrace(noise)"`n}`n'
	Source := 'Probe() {`n LoggerStart("Audit", "Started.")`n LoggerSuccess("Audit", "Finished.")`n'
		. ' LoggerTrace("Audit", "Started.")`n LoggerDone("Audit", "Finished.")`n'
	if Kind != "no-reload"
		Source .= ' Reload()`n'
	return Source . ' Text := "LoggerStart(noise)"`n}`n; LoggerTrace(noise)`n'
}

_MLP_CensusCase(Kind) {
	; Resolve real helpers before entering any expected-error boundary.
	Pairing := _MetaLoggerCheckPairing
	ReloadCheck := _MetaLoggerCheckReload
	Root := A_Temp . "\ergopti_logger_census_" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	DirCreate(Root)
	Handle := 0
	try {
		if Kind == "empty" {
			_MLP_ExpectedRefusal(Pairing, Root, "ValueError", "no authored AHK files")
			_MLP_ExpectedRefusal(ReloadCheck, Root, "ValueError", "no authored AHK files")
			return
		}
		if Kind == "missing" {
			_MLP_ExpectedRefusal(Pairing, Root . "\missing", "ValueError", "existing directory")
			_MLP_ExpectedRefusal(ReloadCheck, Root . "\missing", "ValueError", "existing directory")
			return
		}
		Directory := Root . (Kind == "adapter" || Kind == "balanced" ? "\adapters" : "\infra")
		DirCreate(Directory)
		Path := Directory . "\source.ahk"
		FileAppend(_MLP_Source(Kind), Path, "UTF-8")
		if Kind == "read-error" {
			Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000, "UInt", 0,
				"Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
			AssertTrue(Handle != -1, "the fixture must hold an actual share-denied source handle")
			_MLP_ExpectedRefusal(Pairing, Root, "OSError")
			_MLP_ExpectedRefusal(ReloadCheck, Root, "OSError")
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle), "the private source lock must retire")
			Handle := 0
			AssertEqual(1, Pairing.Call(Root)["files"], "the same real source succeeds after its read lock is released")
			return
		}
		if Kind == "unbalanced" || Kind == "adapter" {
			_MLP_ExpectedRefusal(Pairing, Root, "Error", "unpaired lifecycle logs")
			return
		}
		if Kind == "no-producer" {
			_MLP_ExpectedRefusal(Pairing, Root, "Error", "actual lifecycle producers")
			return
		}
		if Kind == "reload" {
			_MLP_ExpectedRefusal(ReloadCheck, Root, "Error", "immediately precede Reload")
			return
		}
		if Kind == "no-reload" {
			_MLP_ExpectedRefusal(ReloadCheck, Root, "Error", "actual lifecycle and reload producers")
			return
		}
		for Excluded in ["tests", "vendor", "build", "_generated"] {
			DirCreate(Root . "\" . Excluded)
			FileAppend(_MLP_Source("unbalanced"), Root . "\" . Excluded . "\ignored.ahk", "UTF-8")
		}
		Receipt := Pairing.Call(Root)
		AssertEqual(1, Receipt["files"], "the canonical production predicate must exclude nonproduction trees")
		AssertEqual(2, Receipt["producers"], "only real START and TRACE calls count, never comments or strings")
		Receipt := ReloadCheck.Call(Root)
		AssertEqual(1, Receipt["files"])
		AssertEqual(1, Receipt["starts"])
		AssertEqual(1, Receipt["reloads"])
	} finally {
		if Handle && Handle != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Handle)
		DirDelete(Root, true)
	}
}
for _MLP_Kind in ["empty", "missing", "read-error", "unbalanced", "adapter", "no-producer", "reload", "no-reload", "balanced"]
	Test("logger census: actual " . _MLP_Kind . " source behavior (logger-census-failure)", _MLP_CensusCase.Bind(_MLP_Kind))


_MLP_SourceRootAlias(Kind) {
	Stem := "ergopti_logger_alias_" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	Root := A_Temp . "\" . Stem
	PreviousDirectory := A_WorkingDir
	DirCreate(Root . "\adapters")
	try {
		FileAppend(_MLP_Source("reload"), Root . "\adapters\a_bad.ahk", "UTF-8")
		FileAppend(_MLP_Source("balanced"), Root . "\adapters\z_good.ahk", "UTF-8")
		if Kind == "dot"
			Alias := Root . "\."
		else if Kind == "parent"
			Alias := Root . "\..\" . Stem
		else {
			SetWorkingDir(A_Temp)
			Alias := Stem
		}
		Census := _DriverProductionSourceCensus(Alias)
		AssertEqual(2, Census.Paths.Length, "the native census must retain both real files")
		Sources := _MetaLoggerReadSources(Alias)
		AssertEqual(2, Sources.Count, "an existing-directory alias cannot collapse distinct source identities")
		AssertTrue(Sources.Has("adapters/a_bad.ahk"))
		AssertTrue(Sources.Has("adapters/z_good.ahk"))
		_MLP_ExpectedRefusal(_MetaLoggerCheckPairing, Alias, "Error", "unpaired lifecycle logs")
		_MLP_ExpectedRefusal(_MetaLoggerCheckReload, Alias, "Error", "immediately precede Reload")
	} finally {
		SetWorkingDir(PreviousDirectory)
		DirDelete(Root, true)
	}
}
for _MLP_Alias in ["dot", "parent", "relative"]
	Test("logger census: actual " . _MLP_Alias . " root retains both source identities (logger-source-root-alias)",
		_MLP_SourceRootAlias.Bind(_MLP_Alias))


_MLP_CallCase(Kind) {
	Root := A_Temp . "\ergopti_logger_case_" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	DirCreate(Root . "\adapters")
	try {
		; This real balanced file keeps both producer floors meaningful.
		FileAppend(_MLP_Source("balanced"), Root . "\adapters\good.ahk", "UTF-8")
		Text := Kind == "trace"
			? 'Bad() {`n lOgGeRtRaCe("Audit", "Started.")`n}`n'
			: 'Bad() {`n loggerstart("Audit", "Started.")`n rElOaD()`n}`n'
		FileAppend(Text, Root . "\adapters\bad.ahk", "UTF-8")
		AssertEqual(2, _MetaLoggerReadSources(Root).Count, "both real sources must reach the case guard")
		if Kind == "trace"
			_MLP_ExpectedRefusal(_MetaLoggerCheckPairing, Root, "Error", "unpaired lifecycle logs")
		else
			_MLP_ExpectedRefusal(_MetaLoggerCheckReload, Root, "Error", "immediately precede Reload")
	} finally DirDelete(Root, true)
}
for _MLP_CallKind in ["trace", "reload"]
	Test("logger census: actual " . _MLP_CallKind . " call casing retains violations (logger-call-case)",
		_MLP_CallCase.Bind(_MLP_CallKind))

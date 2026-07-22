; tests/meta/test_logger_pairing.ahk

; ==============================================================================
; MODULE: Logger Lifecycle Pairing Test
; DESCRIPTION:
; For each AHK source file in lib/ and modules/, counts LoggerStart vs
; LoggerSuccess and LoggerTrace vs LoggerDone occurrences. Imbalances are
; flagged as warnings (not errors) because legitimate early-return control
; flow can produce natural asymmetries.
;
; The test always passes; its value is the OutputDebug report attached to
; CI logs so reviewers can spot unpaired lifecycle calls at a glance.
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





; =====================================
; ======================================
; ======= 1/ File listing helper =======
; ======================================
; =====================================

_MetaListAhkFilesLogger(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_logger.txt"
	try FileDelete(TempFile)
	RunWait('cmd /c dir /b /s /a-d "' . Dir . '" > "' . TempFile . '"', , "Hide")
	try {
		Raw := FileRead(TempFile)
	} catch {
		return Files
	}
	for Line in StrSplit(Raw, "`n", "`r") {
		Line := Trim(Line)
		if Line = "" {
			continue
		}
		Line := StrReplace(Line, "\", "/")
		if not Line ~= "i)\.ahk$" {
			continue
		}
		if Line ~= "i)/tests/" {
			continue
		}
		Files.Push(Line)
	}
	return Files
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





; =====================================
; =====================================
; ======= 2/ Test registrations =======
; =====================================
; =====================================

_MetaRunLoggerPairingTests() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	Imbalanced := 0
	Report := ""

	for Sub in ["lib", "modules", "ui"] {
		for AbsPath in _MetaListAhkFilesLogger(StrReplace(DriverRoot . Sub, "/", "\")) {
			try {
				Body := FileRead(StrReplace(AbsPath, "/", "\"))
			} catch {
				continue
			}
			NormRoot := StrReplace(DriverRoot, "\", "/")
			Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)

			NStart   := _MetaCountPattern(Body, "LoggerStart\(")
			NSuccess := _MetaCountPattern(Body, "LoggerSuccess\(")
			NTrace   := _MetaCountPattern(Body, "LoggerTrace\(")
			NDone    := _MetaCountPattern(Body, "LoggerDone\(")

			if _MetaLoggerPairingExempt(Rel)
				continue

			if NStart > 0 and NSuccess = 0 {
				Imbalanced++
				Report .= (Report == "" ? "" : "; ") . Rel . " has " . NStart . " LoggerStart but 0 LoggerSuccess"
			}
			if NTrace > 0 and NDone = 0 {
				Imbalanced++
				Report .= (Report == "" ? "" : "; ") . Rel . " has " . NTrace . " LoggerTrace but 0 LoggerDone"
			}
		}
	}

	; The scan used to report through OutputDebug and register a Test whose body
	; was EMPTY, so it could not fail — it occupied the name "logger pairing" in
	; the suite while asserting nothing, which is worse than having no test at
	; all: it deterred anyone from writing a real one. OutputDebug does not reach
	; CI either, so the warnings went nowhere.
	_MetaLoggerPairingAssert() {
		Assert(Imbalanced == 0,
			"unpaired lifecycle logs (a START with no reachable SUCCESS is this project's designated signal of a silent failure path): " . Report)
	}
	Test("meta logger pairing: no file opens a lifecycle pair it never closes",
		_MetaLoggerPairingAssert)
}

_MetaRunLoggerPairingTests()

; F-L08: a LoggerStart immediately before Reload() leaves a START with no reachable
; SUCCESS — the process restarts before the pair closes, so it reads as a silent failure
; to anyone auditing the prior process's rolled-over log. Guard the whole driver source.
_MetaNoStartBeforeReload() {
	SplitPath(A_ScriptDir, , &Root)
	Root := StrReplace(Root, "\", "/")
	offenders := ""
	for Sub in ["lib", "modules", "ui"] {
		Loop Files, Root . "/" . Sub . "/*.ahk", "FR" {
			src := FileRead(A_LoopFileFullPath)
			if RegExMatch(src, "LoggerStart\([^\r\n]*\)\s*\r?\n\s*Reload")
				offenders .= "`n  " . A_LoopFileFullPath
		}
	}
	Assert(offenders == "",
		"A LoggerStart must not immediately precede Reload() — the paired SUCCESS never fires (dangling-start-before-reload). Use LoggerInfo/LoggerSuccess before Reload. Offenders:" . offenders)
}
Test("logger: no LoggerStart immediately precedes Reload (dangling-start-before-reload)", _MetaNoStartBeforeReload)

; F-L09: the updater one-click up-to-date branch is a successful completion of the check,
; so it must close its START with LoggerSuccess, not LoggerInfo.
_MetaUpdaterUpToDateLogsSuccess() {
	SplitPath(A_ScriptDir, , &Root)
	src := FileRead(StrReplace(Root, "\", "/") . "/lib/updater/changelog.ahk")
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

; tests/meta/test_persist_result_not_discarded.ahk

; ==============================================================================
; MODULE: Regression — a failed config write must never be silent
;         (persist-result-not-discarded)
; DESCRIPTION:
; Toggle an LLM setting from the tray while config.toml cannot be replaced — a
; read-only profile, an antivirus lock, an interrupted cloud sync — and every
; visible signal reported success. The menu redrew with the new value, the
; engine was re-initialised with it, and nothing was logged. The setting then
; silently reverted on the next restart.
;
; ROOT CAUSE ENCODED: TOML_BatchWrite fails WITHOUT THROWING. It returns false
; when the staging file cannot be opened, when writing it throws, or when the
; atomic replace is refused. All three branches returned that false with no log
; line at all, and SaveFullConfig discarded the boolean, so the failure had no
; representation anywhere by the time it reached a caller.
;
; The LLM live toggles are where this hurts most, because they are the one
; family that never reaches a Reload: they mutate memory, re-init the engine and
; rebuild the menu in place. The bulk togglers and the gesture/metrics toggles
; end in an unconditional Reload, which re-reads the truth from disk and heals
; the desync by accident — which is precisely why the bug stayed invisible.
;
; SCOPE: source-level for the call-site policy (a real write failure needs a
; locked or read-only target the runner cannot create for every site);
; behavioural for the boolean contract itself.
; ==============================================================================

#Requires AutoHotkey v2.0

; No production call site is exempt: every full save must consume its boolean.
; Keeping the explicit empty list makes a future exception a reviewed diff
; rather than an ad-hoc weakening inside the scanner.
global _PRND_DISCARD_ALLOWED := []




; ==================================================================
; ==================================================================
; ======= 1/ The writer reports its failures ======================
; ==================================================================
; ==================================================================

; Three branches fail without throwing. Each must say so, or the boolean is the
; only evidence that the write did not happen — and this whole finding is about
; that boolean being dropped.
_PRND_WriterLogsEveryFailureBranch() {
	Body := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Body != "", "_TOML_BatchWriteImpl() must exist in the driver source")

	; Count the non-throwing failure exits and require a log for each.
	Returns := 0
	Logged  := 0
	Lines := StrSplit(Body, "`n", "`r")
	for Idx, Line in Lines {
		if !RegExMatch(Trim(Line, " `t"), "^return false")
			continue
		Returns += 1
		; The ERROR belongs in the same block, immediately above the return.
		Window := ""
		Start := Max(1, Idx - 4)
		Loop Idx - Start {
			Window .= Lines[Start + A_Index - 1] . "`n"
		}
		if InStr(Window, "LoggerError")
			Logged += 1
	}
	Assert(Returns >= 3,
		"the scan must reach TOML_BatchWrite's non-throwing failure exits (found only " . Returns . ") — a scan that matches nothing cannot fail")
	Assert(Logged == Returns,
		"every non-throwing failure exit of TOML_BatchWrite must log an ERROR (" . Logged . " of " . Returns . " do). Returning false in silence leaves the caller's discarded boolean as the only trace that the user's setting never reached disk")
}

; The refusal that protects an unreadable file is a legitimate silent-ish exit
; only because it logs too — assert it still does, so the count above cannot be
; satisfied by removing a guard rather than adding a log.
_PRND_UnreadableRefusalStillLogs() {
	Body := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(InStr(Body, "ReadFailed") > 0,
		"TOML_BatchWrite must still refuse to rebuild a file it could not read")
}




; ==================================================================
; ==================================================================
; ======= 2/ No caller drops the result ============================
; ==================================================================
; ==================================================================

; Every SaveFullConfig call site left after removing the exact bodies of the
; reviewed best-effort functions. Removing the bodies before scanning matters:
; the old implementation noticed that *some* allowlisted body contained a bare
; call, then accidentally exempted every bare call anywhere in the driver.
_PRND_SaveCallLines(Src := "") {
	if (Src = "")
		Src := _DriverSourceNoComments()
	Lines := []
	for Line in StrSplit(Src, "`n", "`r") {
		Trimmed := Trim(Line, " `t")
		if !RegExMatch(Trimmed, "\bSaveFullConfig\s*\(")
			continue
		; The definition, not a call.
		if RegExMatch(Line, "^SaveFullConfig\s*\(")
			continue
		Lines.Push(Trimmed)
	}
	return Lines
}

_PRND_EverySaveCallSiteConsumesTheResult() {
	global _PRND_DISCARD_ALLOWED
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the persistence caller scan must read production source")
	for FuncName in _PRND_DISCARD_ALLOWED {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", "reviewed discard function '" . FuncName . "' must still exist")
		Assert(RegExMatch(Body, "\bSaveFullConfig\s*\(") > 0,
			"reviewed discard function '" . FuncName . "' must still contain the call it exempts")
		Assert(!RegExMatch(Body, ":=\s*SaveFullConfig\s*\(")
			and !RegExMatch(Body, "i)\bif\b[^\r\n]*SaveFullConfig\s*\(")
			and !RegExMatch(Body, "i)\breturn\b[^\r\n]*SaveFullConfig\s*\("),
			"reviewed function '" . FuncName . "' no longer discards SaveFullConfig; remove its stale exemption")
		Src := StrReplace(Src, Body, "")
	}
	Calls := _PRND_SaveCallLines(Src)
	Assert(Calls.Length >= 1,
		"the scan must reach a real non-exempt SaveFullConfig call site — a scan that matches nothing cannot fail")
	Assert(RegExMatch(_DriverFuncBody("LLM_Menu_SaveConfig"),
		"\bSaveFullConfig\s*\(") > 0,
		"the positive-control LLM full-save caller must remain inside the scanned production source")

	for Line in Calls {
		Consumed := RegExMatch(Line, ":=\s*SaveFullConfig\s*\(")
			or RegExMatch(Line, "i)\bif\b[^\r\n]*SaveFullConfig\s*\(")
			or RegExMatch(Line, "i)\breturn\b[^\r\n]*SaveFullConfig\s*\(")
		if Consumed
			continue
		Assert(false,
			"this SaveFullConfig call discards its result: '" . Line . "'. It fails without throwing, so a dropped boolean is a setting the user saw applied, saw in the menu, and will lose at the next restart with nothing in the log. Consume it, or add the enclosing function to _PRND_DISCARD_ALLOWED with the reason")
	}
}

; The LLM live toggles are the family with no Reload to heal them, so their
; persist path must both surface the failure and re-synchronise.
_PRND_LlmSaveSurfacesAndRecovers() {
	Body := _DriverFuncBody("LLM_Menu_SaveConfig")
	Assert(Body != "", "LLM_Menu_SaveConfig() must exist in the driver source")
	Assert(RegExMatch(Body, "i)\b\w+\s*:=\s*SaveFullConfig\s*\(")
		and InStr(Body, "CONFIG_SAVE_OK") > 0
		and InStr(Body, "CONFIG_SAVE_DEFERRED") > 0,
		"LLM_Menu_SaveConfig must capture and classify every typed SaveFullConfig result — the LLM toggles never reach a Reload, so nothing else can notice the write failed")
	Assert(InStr(Body, "LoggerError") > 0,
		"a failed LLM persist must be logged at ERROR: the user's setting is gone and every other signal reported success")
	; Any of the driver's reload entry points satisfies this: what matters is that
	; the process re-reads the file, not which helper does it. Pinning the literal
	; "Reload()" started failing the moment the call became
	; ReloadPreservingSuspend(), which re-synchronises exactly the same way and
	; additionally carries the user's pause state across the restart — a strictly
	; better answer that the old spelling-based assertion called a regression.
	Assert(InStr(Body, "Reload()") > 0 or InStr(Body, "ReloadPreservingSuspend()") > 0,
		"a failed LLM persist must re-synchronise from disk. Without it memory, engine and menu keep agreeing on a state that exists nowhere, which is a lie the user only discovers at the next restart")
}

; The two siblings that had the same shape.
_PRND_SiblingWritersSurfaceTheirFailure() {
	for FuncName in ["_HS_TryLiveToggleV2"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . "() must exist in the driver source")
		Assert(InStr(Body, "LoggerError") > 0,
			FuncName . " must surface a failed persist at ERROR. It applies its change live and then writes; a dropped write result means the running driver and the file disagree, and the setting reverts at the next restart with nothing to explain it")
	}
	LoggerBody := _DriverFuncBody("LoggerSetLevel")
	Assert(LoggerBody != "", "LoggerSetLevel() must exist in the driver source")
	CommitPos := InStr(LoggerBody, "ConfigCommitUpdates(")
	PublishPos := InStr(LoggerBody, "_LoggerSetLevelPublish.Bind(Level)")
	ErrorPos := InStr(LoggerBody, "LoggerError")
	Assert(CommitPos > 0 and PublishPos > CommitPos and ErrorPos > PublishPos,
		"LoggerSetLevel must transact disk before live publication and visibly reject failures")
}


Test("meta persist-result-not-discarded: the writer logs every failure branch",
	_PRND_WriterLogsEveryFailureBranch)
Test("meta persist-result-not-discarded: the unreadable-file refusal is intact",
	_PRND_UnreadableRefusalStillLogs)
Test("meta persist-result-not-discarded: every SaveFullConfig call site consumes the result",
	_PRND_EverySaveCallSiteConsumesTheResult)
Test("meta persist-result-not-discarded: the LLM persist surfaces and recovers",
	_PRND_LlmSaveSurfacesAndRecovers)
Test("meta persist-result-not-discarded: the sibling writers surface their failure",
	_PRND_SiblingWritersSurfaceTheirFailure)

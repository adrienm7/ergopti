; tests/meta/test_no_coauthor_in_commits.ahk

; ==============================================================================
; MODULE: Commit Hygiene Test
; DESCRIPTION:
; Verifies new commits (those not yet on origin/dev) don't include
; `Co-Authored-By` trailers, in line with the project's commit conventions
; (no LLM/tool credits in commit messages).
;
; Scoping to `origin/dev..HEAD` means only commits authored as part of the
; current work-in-progress are inspected. Without an upstream, inspect up to
; twenty available commits. Git failures are audit failures, never empty success.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

; AHK v2 fat-arrow lambdas do not support try/catch, for-with-break, or
; multi-statement if blocks — extract everything into named functions.
_MetaResolveGitRange() {
	Head := _MetaGitRead("rev-parse --verify HEAD")
	AssertEqual(0, Head.code, "commit audit requires Git and a readable HEAD")
	for Ref in ["origin/dev", "origin/main"] {
		Check := _MetaGitRead("rev-parse --verify --quiet " . Ref)
		if Check.code = 0
			return Ref . "..HEAD"
		AssertEqual(1, Check.code, "only an absent upstream may select the local-history fallback")
	}
	return "--max-count=20 HEAD"
}

; Arguments are fixed audit commands, never repository text. Each invocation
; owns its receipt so concurrent worktrees cannot substitute stale Git output.
_MetaGitRead(Arguments) {
	TempFile := _FSWL_Path()
	try {
		Code := RunWait('cmd /d /c git ' . Arguments . ' > "' . TempFile . '" 2>nul', , "Hide")
		return {code: Code, output: FileRead(TempFile, "UTF-8")}
	} finally {
		if FileExist(TempFile)
			FileDelete(TempFile)
	}
}

_MetaCheckNoCoauthor() {
	Result := _MetaGitRead("log " . _MetaResolveGitRange() . " --format=%B")
	AssertEqual(0, Result.code, "git log must succeed before commit content can be audited")
	Body := Result.output
	if Body = ""
		return

	; Strip meta-reference lines (lines that mention this test or document the rule)
	Cleaned := ""
	for Line in StrSplit(Body, "`n", "`r") {
		Lower := StrLower(Line)
		IsMeta := InStr(Lower, "test_no_coauthor")
			or InStr(Lower, "free of co-authored-by")
			or InStr(Lower, "forbidden by conventions")
			or InStr(Lower, "co-authored-by trailer")
			or InStr(Lower, "no co-authored-by")
			or InStr(Lower, "co-authored-by in")
		if not IsMeta
			Cleaned .= Line . "`n"
	}

	Assert(not InStr(StrLower(Cleaned), "co-authored-by"),
		"Found 'Co-Authored-By' trailer in new commits (forbidden by conventions)")
}

Test("meta: no Co-Authored-By trailers in new commits", _MetaCheckNoCoauthor)

_MetaCoauthorFixture(Scenario) {
	Root := _FSWL_Path() . "-commit-check"
	PreviousDirectory := A_WorkingDir
	OwnsRoot := false
	try {
		AssertFalse(DirExist(Root))
		DirCreate(Root)
		OwnsRoot := true
		if Scenario != "missing" {
			AssertEqual(0, RunWait('git init -q "' . Root . '"', , "Hide"))
			MessageFile := Root . "\message.txt"
			Message := "test: synthetic fixture`n"
			if Scenario = "forbidden"
				Message .= "`nCo-Authored-By: Fixture <fixture@example.invalid>`n"
			FileAppend(Message,
				MessageFile, "UTF-8-RAW")
			AssertEqual(0, RunWait('git -c user.name=Fixture -c user.email=fixture@example.invalid -C "'
				. Root . '" commit -q --allow-empty -F "' . MessageFile . '"', , "Hide"))
			if Scenario = "synced"
				AssertEqual(0, RunWait('git -C "' . Root . '" update-ref refs/remotes/origin/dev HEAD', , "Hide"))
		}
		SetWorkingDir(Root)
		if Scenario = "forbidden" || Scenario = "missing"
			AssertThrows(_MetaCheckNoCoauthor,
				Scenario = "forbidden" ? "a short fresh clone must still inspect its commit" : "Git failure must not count as a passing audit")
		else
			_MetaCheckNoCoauthor()
	} finally {
		SetWorkingDir(PreviousDirectory)
		if OwnsRoot && DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("commit audit: short history cannot bypass trailers (commit-audit-fail-closed)",
	_MetaCoauthorFixture.Bind("forbidden"))
Test("commit audit: missing repository is a failure (commit-audit-fail-closed)",
	_MetaCoauthorFixture.Bind("missing"))
Test("commit audit: short clean history is accepted (commit-audit-fail-closed)",
	_MetaCoauthorFixture.Bind("clean"))
Test("commit audit: successful empty upstream range is accepted (commit-audit-fail-closed)",
	_MetaCoauthorFixture.Bind("synced"))

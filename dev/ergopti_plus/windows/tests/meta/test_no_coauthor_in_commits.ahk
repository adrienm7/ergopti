; tests/meta/test_no_coauthor_in_commits.ahk

; ==============================================================================
; MODULE: Commit Hygiene Test
; DESCRIPTION:
; Verifies new commits (those not yet on origin/dev) don't include
; `Co-Authored-By` trailers, in line with the project's commit conventions
; (no LLM/tool credits in commit messages).
;
; Scoping to `origin/dev..HEAD` means only commits authored as part of the
; current work-in-progress are inspected. Silently passes when git or the
; upstream ref is unavailable so the suite still works on fresh clones.
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
	for Ref in ["origin/dev", "origin/main"] {
		CheckFile := A_Temp . "\meta_git_ref.txt"
		try FileDelete(CheckFile)
		RunWait('cmd /c git rev-parse --verify ' . Ref . ' > "' . CheckFile . '" 2>nul', , "Hide")
		try {
			RefOut := Trim(FileRead(CheckFile))
			if StrLen(RefOut) > 0
				return Ref . "..HEAD"
		}
	}
	return "HEAD~20..HEAD"
}

_MetaCheckNoCoauthor() {
	TempFile := A_Temp . "\meta_git_log.txt"
	try FileDelete(TempFile)

	Range := _MetaResolveGitRange()
	RunWait('cmd /c git log ' . Range . ' --format=%B > "' . TempFile . '" 2>nul', , "Hide")
	try {
		Body := FileRead(TempFile)
	} catch {
		; Git unavailable — skip silently
		return
	}
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

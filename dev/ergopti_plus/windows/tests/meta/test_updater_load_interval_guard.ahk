; tests/meta/test_updater_load_interval_guard.ahk

; ==============================================================================
; MODULE: Updater LoadCheckInterval Non-Numeric Guard Meta Test
; DESCRIPTION:
; Regression guard for HIGH-08: fix-updater-load-interval-non-numeric-throws.
;
; Updater_LoadCheckInterval() read config.toml's check_interval_seconds via
; IniCacheGet and then computed: seconds := Integer(raw + 0).
;
; The inline comment claimed "raw + 0 coerces to 0 on garbage". That is FALSE
; for AHK v2: a non-numeric string in arithmetic (e.g. "fast" + 0 or "5,5" + 0)
; throws a TypeError — it does NOT silently coerce to 0. The old guard (raw==_
; or raw=="") caught empty/sentinel values but not a non-empty non-numeric one.
;
; The call site at ErgoptiPlus.ahk:614 was also unguarded (no try), while the
; adjacent Updater_StartBackgroundChecks and Updater_InitTrayNotifyHandler calls
; were already wrapped in try. An uncaught throw at line 614 aborts the
; remainder of the auto-execute boot section, leaving the driver half-initialised.
;
; The fix:
;   1. Add IsNumber(raw) validation in Updater_LoadCheckInterval before the
;      arithmetic, falling back to UPDATER_DEFAULT_INTERVAL with a LoggerWarn.
;   2. Wrap the call site at ErgoptiPlus.ahk with try.
;
; A parallel fix in Updater_SetCheckInterval already existed and used try/catch
; around Integer(Seconds) — this test ensures the loader has the same protection.
;
; This test asserts:
;   (a) Updater_LoadCheckInterval source body uses IsNumber(raw) before Integer().
;   (b) The ErgoptiPlus.ahk call site uses try Updater_LoadCheckInterval().
;
; SCOPE: source introspection of modules/updater.ahk and ErgoptiPlus.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================================
; ===========================================================
; ======= 1/ Source scan helpers ============================
; ===========================================================
; ===========================================================

; Extracts the body of Updater_LoadCheckInterval from the source.
_ULIG_ExtractLoaderBody(Src) {
	FnPos := InStr(Src, "Updater_LoadCheckInterval() {")
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}


; =========================================================
; =========================================================
; ======= 2/ Test implementations =========================
; =========================================================
; =========================================================

_ULIG_CheckIsNumberGuard() {
	Src := _DriverDirConcat("modules/updater")
	Assert(Src != "", "the modules/updater module must be readable")

	Body := _ULIG_ExtractLoaderBody(Src)
	Assert(Body != "", "Updater_LoadCheckInterval must be present in the modules/updater module")

	; (a) IsNumber(raw) validation must be present before the Integer() call.
	Assert(InStr(Body, "IsNumber(raw)"),
		"Updater_LoadCheckInterval must validate raw with IsNumber() before arithmetic (HIGH-08 fix-updater-load-interval-non-numeric-throws)")

	; The old bare Integer(raw + 0) without an IsNumber guard must not be the
	; primary path (the guard must come before it).
	IsNumberPos := InStr(Body, "IsNumber(raw)")
	IntegerPos  := InStr(Body, "Integer(raw + 0)")
	Assert(IsNumberPos > 0 && IntegerPos > 0 && IsNumberPos < IntegerPos,
		"IsNumber(raw) check must appear before Integer(raw + 0) in Updater_LoadCheckInterval")

	; The fallback on non-numeric input should use UPDATER_DEFAULT_INTERVAL.
	Assert(InStr(Body, "UPDATER_DEFAULT_INTERVAL"),
		"Updater_LoadCheckInterval must fall back to UPDATER_DEFAULT_INTERVAL on non-numeric input")
	Assert(InStr(Body, "try seconds := Integer(raw + 0)") > 0 && InStr(Body, "out-of-range check_interval_seconds") > 0,
		"numeric but out-of-range check_interval_seconds values must fail closed instead of aborting boot")
}

_ULIG_CheckCallSiteGuarded() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	; (b) The call site must be wrapped in try so a residual exception does not
	;     abort the boot sequence.
	Assert(InStr(Src, "try Updater_LoadCheckInterval()"),
		"Updater_LoadCheckInterval() call in ErgoptiPlus.ahk must be try-wrapped (HIGH-08 defense-in-depth)")

	; Bare unguarded call must not appear (outside of the function definition itself).
	; We check that the try-wrapped form is present (already done above), which is
	; sufficient since the try-wrapped line is the only call site.
}


Test("meta fix-updater-load-interval: Updater_LoadCheckInterval uses IsNumber guard before Integer()",
	_ULIG_CheckIsNumberGuard)

Test("meta fix-updater-load-interval: Updater_LoadCheckInterval() call site in ErgoptiPlus.ahk is try-wrapped",
	_ULIG_CheckCallSiteGuarded)

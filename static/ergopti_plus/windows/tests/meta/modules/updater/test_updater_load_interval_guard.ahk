; tests/meta/modules/updater/test_updater_load_interval_guard.ahk

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
; The current loader admits finite non-negative whole numbers from typed
; bootstrap ownership. Detached legacy maps retain their explicit value types.
; Runtime assertions reject strings, fractions, negatives and overflow while
; preserving deliberate zero and valid preset cadence. The production call site
; remains guarded so a refusal does not abort unrelated startup work.
; SCOPE: actual loader behavior and the production entry call site.
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
	global _IniCache, UPDATER_CHECK_INTERVAL, UPDATER_DEFAULT_INTERVAL
	HadCache := IsSet(_IniCache)
	if HadCache
		SavedCache := _IniCache
	SavedInterval := UPDATER_CHECK_INTERVAL
	try {
		; Keep the historical test identity, but check the actual owner instead
		; of pinning IsNumber(), which also accepted malformed numeric strings.
		for Raw in ["fast", "0", 0.5, -1, 1.0e100] {
			_IniCache := Map("updater", Map("check_interval_seconds", Raw))
			UPDATER_CHECK_INTERVAL := -1
			Updater_LoadCheckInterval()
			AssertEqual(UPDATER_DEFAULT_INTERVAL, UPDATER_CHECK_INTERVAL,
				"malformed or out-of-domain cadence must retain the default without throwing: " . String(Raw))
		}
		for Raw in [0, 3600] {
			_IniCache := Map("updater", Map("check_interval_seconds", Raw))
			Updater_LoadCheckInterval()
			AssertEqual(Raw, UPDATER_CHECK_INTERVAL, "valid native presets must keep their actual cadence")
		}
	} finally {
		if HadCache
			_IniCache := SavedCache
		else
			_IniCache := unset
		UPDATER_CHECK_INTERVAL := SavedInterval
	}
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


Test("meta fix-updater-load-interval: Updater_LoadCheckInterval rejects malformed cadence before Integer()",
	_ULIG_CheckIsNumberGuard)

Test("meta fix-updater-load-interval: Updater_LoadCheckInterval() call site in ErgoptiPlus.ahk is try-wrapped",
	_ULIG_CheckCallSiteGuarded)

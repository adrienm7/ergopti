; tests/meta/test_require_state_pattern.ahk

; ==============================================================================
; MODULE: Guard Pattern Enforcement Ratchet
; DESCRIPTION:
; Stateful AHK modules MUST protect their public functions with a guard check
; (conventions 5.3 / 5.8), so a call landing before init fails loudly instead of
; reading half-built state.
;
; THIS GATE WAS EFFECTIVELY VACUOUS. Measured before the rewrite: it scanned
; THREE files and reported zero violations, out of 77 that carry module-level
; state. Three scope collapses compounded:
;
;   1. The scan root was hardcoded to modules/. The tree has since been
;      reorganised and most stateful code moved out — lib/, ui/ and adapters/
;      hold the majority, and this gate had never looked at any of them.
;   2. The statefulness predicate matched only `global _x := false` and
;      `global _x := unset`, so a module holding a Map, an array, 0 or "" was
;      invisible to it.
;   3. `if A_IsSuspended` counted as a guard. A pause check says nothing about
;      whether init has run; accepting it let modules pass with no state guard
;      at all.
;
; On top of that, NINE of the twenty-one allowlist entries named files that no
; longer exist. They suppressed nothing, and hid the fact that their real
; successors were never re-triaged.
;
; WHY A RATCHET RATHER THAN A CLEAN GATE. Widening all three axes surfaces 38
; genuine violations. Adding a guard to a module is a BEHAVIOURAL change — it
; introduces an early return on a path that currently proceeds — so applying 38
; of them mechanically would be reckless. This adopts the shape the driver
; already uses for comparable debt (test_ahk_os_purity_ratchet.ahk): count the
; violations, fail when the count RISES, drive the baseline down over time.
;
; That is deliberately NOT the same as re-widening the allowlist to silence
; them. Every offender is enumerated in the failure message, and a newly added
; stateful module with no guard fails immediately.
;
; NEVER raise the baseline to make a change pass. Lower is better; zero is the
; target.
; ==============================================================================

#Requires AutoHotkey v2.0

; Modules deliberately exempt. Kept SMALL and re-verified — an entry naming a
; file that does not exist suppresses nothing and merely hides that its
; successor was never triaged. Every path below was confirmed to exist.
_REQUIRE_STATE_ALLOWLIST := Map(
	"modules/llm/api_common.ahk", true,
	"modules/llm/api_ollama/init.ahk", true,
	"modules/llm/api_remote.ahk", true,
	"modules/llm/models.ahk", true,
	"modules/llm/profiles.ahk", true,
	"modules/keylogger/keylogger_hook.ahk", true,
	"lib/tap_hold/tap_hold_loader.ahk", true,
	"modules/keymap/llm_bridge.ahk", true,
	"ui/tray_menu.ahk", true,
	"modules/gestures/actions.ahk", true,
	"modules/llm/ollama_deps_checker.ahk", true,
	"modules/keymap/layout.ahk", true
)

; Captured 2026-07-21 by this scanner's own first widened run. Drive it DOWN by
; adding guards; never up. See the module header for why this is a ratchet.
_REQUIRE_STATE_BASELINE := 38

_MetaListAhkFilesGuardV2(Dir) {
	Files := []
	TempFile := A_Temp . "\meta_dir_guard_v2.txt"
	try FileDelete(TempFile)
	RunWait('cmd /c dir /b /s /a-d "' . Dir . '" > "' . TempFile . '"', , "Hide")
	try {
		Raw := FileRead(TempFile)
	} catch {
		return Files
	}
	for Line in StrSplit(Raw, "`n", "`r") {
		Line := Trim(Line)
		if (Line = "")
			continue
		Line := StrReplace(Line, "\", "/")
		if !(Line ~= "i)\.ahk$")
			continue
		if (Line ~= "i)/tests/")
			continue
		if (Line ~= "i)/vendor/") or (Line ~= "i)/_generated/")
			continue
		Files.Push(Line)
	}
	return Files
}

_MetaRunRequireStateTestsV2() {
	global _REQUIRE_STATE_ALLOWLIST, _REQUIRE_STATE_BASELINE
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	Violations := []
	ScannedCount := 0

	; All four trees that hold production code. modules/ alone was the original
	; blind spot: the stateful code largely lives elsewhere now.
	for SubDir in ["modules", "lib", "adapters", "ui"] {
		for AbsPath in _MetaListAhkFilesGuardV2(StrReplace(DriverRoot . SubDir, "/", "\")) {
			try {
				Body := FileRead(StrReplace(AbsPath, "/", "\"))
			} catch {
				continue
			}
			NormRoot := StrReplace(DriverRoot, "\", "/")
			Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)
			if (_REQUIRE_STATE_ALLOWLIST.Has(Rel))
				continue

			; Any module-level underscore-prefixed global counts as state.
			; Restricting this to false/unset hid every module holding a Map, an
			; array, 0 or "".
			IsStateful := (Body ~= "im)^global\s+_\w+\s*:=")
			if (!IsStateful)
				continue
			ScannedCount++

			; A_IsSuspended is deliberately NOT accepted as a guard.
			HasGuard := (Body ~= "i)if\s*\(!_\w") or (Body ~= "i)if\s+!_\w")
			if (!HasGuard)
				Violations.Push(Rel)
		}
	}

	Offenders := ""
	for Rel in Violations
		Offenders .= (Offenders == "" ? "" : ", ") . Rel

	ViolCount := Violations.Length
	ScannedLabel := ScannedCount
	_MetaGuardRatchet() {
		Assert(ScannedLabel >= 60,
			"the guard scan must reach the whole driver (only " . ScannedLabel . " stateful files seen) — it previously scanned 3 and was therefore incapable of failing")
		Assert(ViolCount <= _REQUIRE_STATE_BASELINE,
			"unguarded stateful modules rose to " . ViolCount . " (baseline " . _REQUIRE_STATE_BASELINE . "). Add a require_state-style guard to the new module; do NOT raise the baseline and do NOT add it to the allowlist. Offenders: " . Offenders)
	}
	Test("meta require_state: unguarded stateful modules do not increase (" . ViolCount . "/" . ScannedLabel . ")",
		_MetaGuardRatchet)
}

_MetaRunRequireStateTestsV2()

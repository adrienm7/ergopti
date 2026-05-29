; tests/meta/test_require_state_pattern.ahk

; ==============================================================================
; MODULE: Guard Pattern Enforcement Test
; DESCRIPTION:
; Stateful AHK modules (those that declare a module-level guard variable with
; `global _XXX := false` or `global _XXX := unset`) MUST protect their public
; functions with a guard check (`if !_XXX` or `if (!_XXX)`) before accessing
; the guarded state. This is the AHK equivalent of the Lua `require_state`
; pattern described in convention section 5.3 (fail fast, no silent failures).
;
; Unlike the previous heuristic-only version this test FAILS when a new stateful
; module does not expose a guard check. Modules that are architecturally exempt
; (e.g. they use a different lifecycle model) must be explicitly listed in the
; ALLOWLIST below with a justification comment.
;
; DETECTION HEURISTIC:
; A file is "stateful" if it contains `global _VarName := false` or
; `global _VarName := unset` at the top level (module init flag pattern).
; A file "has a guard" if it contains `if !_` or `if (!_` anywhere in its body
; (checking a private global variable as a precondition).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ==============================
; ======= 1/ Allow-list =======
; ==============================
; ==============================

; Modules exempt from the guard-pattern requirement.
; Each key is a relative path (forward slashes, no leading slash).
_REQUIRE_STATE_ALLOWLIST := Map(
	; api_common.ahk uses `if !IsSet(_LLM_COMMON_INFERENCE)` — lazy-load guard,
	; not a lifecycle flag. The `if !IsSet(` pattern differs from `if !_`.
	"modules/llm/api_common.ahk", true,

	; api_ollama / api_remote guard state via per-callback counters and closures,
	; not a single boolean lifecycle flag.
	"modules/llm/api_ollama.ahk", true,
	"modules/llm/api_remote.ahk", true,

	; models.ahk and profiles.ahk use `if !IsSet(_LLM_*Cache)` lazy-cache guards.
	"modules/llm/models.ahk", true,
	"modules/llm/profiles.ahk", true,

	; ollama_deps_checker.ahk: `_LLM_Deps_Checking := false` is a concurrency
	; mutex, not a lifecycle init guard — functions run independently, the flag
	; prevents re-entrant installs. `_LLM_Deps_PollTimer := unset` is a timer
	; handle, not a lifecycle state. Architecture intentional; reviewed safe.
	"modules/llm/ollama_deps_checker.ahk", true,

	; gestures.ahk: `_GestureCycling := False` is a re-entrancy mutex that
	; prevents the WinEvent hook from reacting to synthetic activations it
	; triggers itself. The `if (_GestureCycling)` check is an early-exit on
	; the mutex being SET (truthy), not a guard that blocks access when state
	; is absent — the opposite polarity of a lifecycle init flag. Architecture
	; reviewed safe; no public functions depend on a single init call.
	"modules/gestures.ahk", true,
)




; ======================================
; ======================================
; ======= 2/ File listing helper =======
; ======================================
; ======================================

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
		if Line = ""
			continue
		Line := StrReplace(Line, "\", "/")
		if not Line ~= "i)\.ahk$"
			continue
		if Line ~= "i)/tests/"
			continue
		Files.Push(Line)
	}
	return Files
}




; =====================================
; =====================================
; ======= 3/ Test registrations =======
; =====================================
; =====================================

_MetaRunRequireStateTestsV2() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"

	Violations   := []
	ScannedCount := 0

	for AbsPath in _MetaListAhkFilesGuardV2(StrReplace(DriverRoot . "modules", "/", "\")) {
		try {
			Body := FileRead(StrReplace(AbsPath, "/", "\"))
		} catch {
			continue
		}

		NormRoot := StrReplace(DriverRoot, "\", "/")
		Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)

		if _REQUIRE_STATE_ALLOWLIST.Has(Rel)
			continue

		; "Stateful" heuristic: file declares a module-level boolean/unset init flag
		IsStateful := (Body ~= "im)^global\s+_\w+\s*:=\s*false\b")
			or (Body ~= "im)^global\s+_\w+\s*:=\s*unset\b")

		if not IsStateful
			continue

		ScannedCount++

		; Guard presence: `if !_VarName` or `if (!_VarName)` — real AHK guard checks
		HasGuard := (Body ~= "i)if\s*\(!_\w") or (Body ~= "i)if\s+!_\w")

		if not HasGuard
			Violations.Push(Rel)
	}


	; ===================================================
	; ===== 3.1) One failing test per violation ========
	; ===================================================

	for Rel in Violations {
		RelCopy := Rel
		_MetaGuardViolation() {
			Assert(false, "Stateful module '" . RelCopy . "' has no `if !_VarName` guard. "
				. "Add a guard before public functions access the state, "
				. "or add the file to the ALLOWLIST with a justification.")
		}
		Test("meta require_state: MISSING guard — " . Rel, _MetaGuardViolation)
	}


	; ================================================
	; ===== 3.2) Summary pass/fail ===================
	; ================================================

	ScannedLabel  := ScannedCount
	ViolCount     := Violations.Length

	_MetaGuardSummary() {
		Assert(ViolCount = 0,
			ViolCount . " stateful module(s) lack a guard. See MISSING tests above.")
		Assert(ScannedLabel > 0,
			"No stateful modules found — check heuristic or directory path.")
	}
	Test("meta require_state: all " . ScannedLabel . " stateful module(s) guarded (" . ViolCount . " violation(s))", _MetaGuardSummary)
}

_MetaRunRequireStateTestsV2()

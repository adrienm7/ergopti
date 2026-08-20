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
;      reorganised and most stateful code moved out — infra/, ui/ and adapters/
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
; WHAT THE NUMBER ACTUALLY MEANS — read this before acting on it.
;
; The count is NOT a defect count, and an earlier version of this file wrongly
; said it was. It is a DRIFT DETECTOR: the number of production files holding
; module-level mutable state that do not use the `if !_x` init-guard idiom.
;
; Spot-checking the flagged files found none of the sampled ones to be genuine
; conventions-5.8 violations. They were lazy caches (_TimingsCache,
; _ParseTomlCache, _TrayTitleCache), self-initialising flags
; (_AltGrShortcutsRegistered, _LLM_AcceptInProgress), lazily-created handles
; behind their own guards (_WebView_SharedEnv and its _Creating flag), and one
; deliberate TEST SEAM (_HotstringRegistrar, which defaults to 0 and whose
; consumers already branch on that).
;
; The underlying reason is architectural: conventions 5.8 describes the Lua /
; Hammerspoon module shape — a state table injected by M.init(), with every
; public function gated by require_state. The AHK driver is not built that way.
; It uses auto-execute globals, lazy caches and explicit handle checks, so a
; mechanical sweep adding require_state guards here would add meaningless early
; returns to functions that need none — HotPath_Now(), which runs on every
; keystroke, was among the files flagged.
;
; So this stays a ratchet, and the value is drift: a NEW module that introduces
; injected state without a guard raises the count and fails here, at which point
; a human decides whether it is a real violation or another cache. Do not
; "fix" the existing entries by bolting guards onto them.
;
; NEVER raise the baseline to make a change pass.
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
	"platform/remap/tap_hold_loader.ahk", true,
	"modules/keymap/llm_bridge.ahk", true,
	"ui/tray_menu.ahk", true,
	"modules/gestures/actions.ahk", true,
	"modules/llm/ollama_deps_checker.ahk", true,
	"modules/keymap/layout.ahk", true,
	; _HardwareCapsLockOn — a self-initialising flag, not injected state. It is
	; seeded from the real toggle at its declaration and thereafter written only
	; by ToggleCapsLock, so there is no init to guard: a require_state early
	; return would sit in UpdateCapsLockLED, which runs on the CapsWord path.
	; It exists precisely BECAUSE the previous design had no such variable and
	; re-derived the hardware intent from GetKeyState — the bit the same function
	; writes — which made the CapsLock LED self-latching.
	"modules/shortcuts/capsword.ahk", true
)

; Captured 2026-07-21 after excluding UPPER_SNAKE constants from the state
; predicate. See the module header: this is a drift baseline, not a defect count.
_REQUIRE_STATE_BASELINE := 27

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
	for SubDir in ["modules", "infra", "platform", "adapters", "ui"] {
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

			; Module-level MUTABLE state. Constants are UPPER_SNAKE by
			; convention and are excluded: counting _HOTPATH_SLOW_MS or
			; _HS_RELOAD_ONLY_GROUPS as "state needing an init guard" is what
			; made the first widened count meaningless.
			; Case-SENSITIVE on purpose — note the absence of the i flag. With it,
			; [A-Z0-9_] also matches lowercase, so the lookahead swallows every
			; name, the predicate never fires, and the scan silently reports 0/0.
			IsStateful := (Body ~= "m)^global\s+_(?![A-Z0-9_]+\s*:=)\w+\s*:=")
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
		; Non-vacuity floor. The original scan saw THREE files and could not
		; fail; anything in this range proves it is still reaching the whole
		; driver. Set below the current 59 so excluding a few more constants
		; from the predicate does not trip it.
		Assert(ScannedLabel >= 50,
			"the guard scan must reach the whole driver (only " . ScannedLabel . " files with module-level state seen) — it previously scanned 3 and was therefore incapable of failing")
		Assert(ViolCount <= _REQUIRE_STATE_BASELINE,
			"files with unguarded module-level state rose to " . ViolCount . " (baseline " . _REQUIRE_STATE_BASELINE . "). This is a DRIFT signal, not a proven defect: check whether the new entry holds genuinely injected state (guard it) or is another lazy cache or flag (then it belongs in the allowlist WITH a reason). Do not raise the baseline. Offenders: " . Offenders)
	}
	Test("meta require_state: module-level state without an init guard does not increase (" . ViolCount . "/" . ScannedLabel . ")",
		_MetaGuardRatchet)
}

_MetaRunRequireStateTestsV2()

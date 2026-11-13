; tests/meta/suite/test_require_state_pattern.ahk

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
	"ai/engine/api/common.ahk", true,
	"ai/engine/api_ollama/init.ahk", true,
	"ai/engine/api/remote.ahk", true,
	"ai/engine/settings/models.ahk", true,
	"ai/engine/settings/profiles.ahk", true,
	"metrics/engine/capture/hook.ahk", true,
	"platform/remap/tap_hold_loader.ahk", true,
	"ai/engine/bridge.ahk", true,
	"menu/ui/tray_menu.ahk", true,
	"gestures/engine/actions.ahk", true,
	"ai/engine/ollama/deps_checker.ahk", true,
	"layouts/engine/layout.ahk", true,
	; _HardwareCapsLockOn — a self-initialising flag, not injected state. It is
	; seeded from the real toggle at its declaration and thereafter written only
	; by ToggleCapsLock, so there is no init to guard: a require_state early
	; return would sit in UpdateCapsLockLED, which runs on the CapsWord path.
	; It exists precisely BECAUSE the previous design had no such variable and
	; re-derived the hardware intent from GetKeyState — the bit the same function
	; writes — which made the CapsLock LED self-latching.
	"modules/shortcuts/capsword.ahk", true,
	; _ComposerCheckBusy — a re-entrancy flag, not injected state. It starts false
	; at its declaration, ComposerCheck_Run sets it for the one running check and
	; that check's terminal step clears it; there is no init for a guard to wait on.
	"layouts/ui/layout_manager/composer_check.ahk", true,
	; _ProxyOverrideDeclaration is a lazy cache of a shipped file and _ProxyOverrideStored
	; is written with the published value; a reader before boot sees "automatic", the
	; declared empty value, by design. There is no injected state for a guard to wait on.
	"core/network/adapters/proxy_override.ahk", true
)

; Captured 2026-07-21 after excluding UPPER_SNAKE constants from the state
; predicate. See the module header: this is a drift baseline, not a defect count.
; Lowered to 25 on 2026-11-12 once a duplicate-start rejection counted as a
; guard (diagnostics/engine/field_run/field_run.ahk already rejected one).
_REQUIRE_STATE_BASELINE := 25

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

; Runs inside its test: scanning the tree at registration taxed every runner boot.
; Whether a stateful file guards its state: a lazy check on a private global
; (if !_X), or an owner start that rejects a duplicate initialization
; (if IsObject(_X) followed by a throw), as AGENTS.md asks of a stateful module.
; @param Body {String} The file's source.
; @returns {Boolean}
_MetaRequireStateHasGuard(Body) {
	return (Body ~= "i)if\s*\(!_\w") or (Body ~= "i)if\s+!_\w")
		or (Body ~= "im)^\s*if\s*\(?\s*IsObject\(_\w+\)\s*\)?[ \t]*\r?\n\s*throw\b")
}

_MetaGuardRatchet() {
	global _REQUIRE_STATE_ALLOWLIST, _REQUIRE_STATE_BASELINE
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	Violations := []
	ScannedCount := 0

	; All four trees that hold production code. modules/ alone was the original
	; blind spot: the stateful code largely lives elsewhere now.
	for SubDir in ["modules", "infra", "platform", "adapters", "ui", "core", "settings", "menu", "tray", "ai", "apps", "clipboard", "diagnostics", "gestures", "hotstrings", "keyboard", "layouts", "metrics", "onboarding"] {
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
			if (!_MetaRequireStateHasGuard(Body))
				Violations.Push(Rel)
		}
	}

	Offenders := ""
	for Rel in Violations
		Offenders .= (Offenders == "" ? "" : ", ") . Rel

	; Non-vacuity floor. The original scan saw THREE files and could not
	; fail; anything in this range proves it is still reaching the whole
	; driver. Set below the current 59 so excluding a few more constants
	; from the predicate does not trip it.
	Assert(ScannedCount >= 50,
		"the guard scan must reach the whole driver (only " . ScannedCount . " files with module-level state seen) — it previously scanned 3 and was therefore incapable of failing")
	Assert(Violations.Length <= _REQUIRE_STATE_BASELINE,
		"files with unguarded module-level state rose to " . Violations.Length . " (baseline " . _REQUIRE_STATE_BASELINE . "). This is a DRIFT signal, not a proven defect: check whether the new entry holds genuinely injected state (guard it) or is another lazy cache or flag (then it belongs in the allowlist WITH a reason). Do not raise the baseline. Offenders: " . Offenders)
}
Test("meta require_state: module-level state without an init guard does not increase", _MetaGuardRatchet)

; A duplicate-start rejection is a guard; an IsObject check that only branches is not.
_MetaRequireStateGuardShapes() {
	AssertTrue(_MetaRequireStateHasGuard('Start() {`n`tif IsObject(_Owner)`n`t`tthrow Error("started")`n}'))
	AssertTrue(_MetaRequireStateHasGuard("Get() {`n`tif (!_Cache)`n`t`t_Cache := Map()`n}"))
	AssertFalse(_MetaRequireStateHasGuard('Stop() {`n`tif IsObject(_Owner)`n`t`t_Owner := ""`n}'))
	AssertFalse(_MetaRequireStateHasGuard("Read() {`n`treturn _Owner`n}"))
}
Test("meta require_state: a duplicate-start rejection counts as an init guard", _MetaRequireStateGuardShapes)

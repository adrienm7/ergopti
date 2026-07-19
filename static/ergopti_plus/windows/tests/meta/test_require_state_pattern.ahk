; tests/meta/test_require_state_pattern.ahk

; ==============================================================================
; MODULE: Guard Pattern Enforcement Test
; DESCRIPTION:
; Stateful AHK modules MUST protect their public functions with a guard check.
; ==============================================================================

#Requires AutoHotkey v2.0

_REQUIRE_STATE_ALLOWLIST := Map(
	"modules/llm/api_common.ahk", true,
	"modules/llm/api_ollama/init.ahk", true,
	"modules/llm/api_remote.ahk", true,
	"modules/llm/models.ahk", true,
	"modules/llm/profiles.ahk", true,
	"modules/hotstrings/hotstring_prefix_watcher.ahk", true,
	"modules/gestures.ahk", true,
	"modules/keylogger/keylogger_hook.ahk", true,
	"modules/hotstrings/personal_toml_editor.ahk", true,
	"lib/tap_hold/tap_hold_loader.ahk", true,
	"modules/keymap/llm_bridge.ahk", true,
	"modules/metrics/metrics_shortcuts.ahk", true,
	"ui/tray_menu.ahk", true,
	"modules/keylogger/aggregator.ahk", true,
	"modules/keylogger/rotation.ahk", true,
	"modules/keylogger/kc_bridge.ahk", true,
	"modules/gestures/actions.ahk", true,
	"lib/adapters/secure_field_detector.ahk", true,
	"modules/llm/ollama_deps_checker.ahk", true,
	"lib/healthcheck.ahk", true,
	"modules/keymap/layout.ahk", true
)

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
		Files.Push(Line)
	}
	return Files
}

_MetaRunRequireStateTestsV2() {
	SplitPath(A_ScriptDir, , &_DriverRootRaw)
	DriverRoot := StrReplace(_DriverRootRaw, "\", "/") . "/"
	Violations := []
	ScannedCount := 0
	for AbsPath in _MetaListAhkFilesGuardV2(StrReplace(DriverRoot . "modules", "/", "\")) {
		try {
			Body := FileRead(StrReplace(AbsPath, "/", "\"))
		} catch {
			continue
		}
		NormRoot := StrReplace(DriverRoot, "\", "/")
		Rel := SubStr(StrReplace(AbsPath, "\", "/"), StrLen(NormRoot) + 1)
		if (_REQUIRE_STATE_ALLOWLIST.Has(Rel))
			continue
		IsStateful := (Body ~= "im)^global\s+_\w+\s*:=\s*false\b") or (Body ~= "im)^global\s+_\w+\s*:=\s*unset\b")
		if (!IsStateful)
			continue
		ScannedCount++
		HasGuard := (Body ~= "i)if\s*\(!_\w") or (Body ~= "i)if\s+!_\w") or (Body ~= "i)if\s+A_IsSuspended\b")
		if (!HasGuard)
			Violations.Push(Rel)
	}
	for Rel in Violations {
		RelCopy := Rel
		_MetaGuardViolation() {
			Assert(false, "Stateful module '" . RelCopy . "' has no guard.")
		}
		Test("meta require_state: MISSING guard - " . Rel, _MetaGuardViolation)
	}
	ScannedLabel := ScannedCount
	ViolCount := Violations.Length
	_MetaGuardSummary() {
		Assert(ViolCount = 0, ViolCount . " violations. See above.")
		Assert(ScannedLabel > 0, "No stateful modules found.")
	}
	Test("meta require_state: summary (" . ScannedLabel . " scanned)", _MetaGuardSummary)
}

_MetaRunRequireStateTestsV2()

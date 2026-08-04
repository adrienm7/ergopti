; static/ergopti_plus/windows/tests/meta/test_menu_top_level_drift_gate.ahk

; ==============================================================================
; MODULE: Menu Top-Level Drift Gate (AHK)
; DESCRIPTION:
; Asserts that the menu_manifest.json top_level tail (from global_actions
; onwards, filtered for the AHK platform) matches the canonical ids the
; dispatch table in _MI_AppendTail() handles.  Prevents silent drift between
; the shared manifest and the driver without a test failure.
;
; The macOS half lives in macos/tests/meta/test_menu_top_level_drift_gate.lua.
;
; WHEN THIS CAN BE RETIRED, and it is not yet — measured 2026-08-04.
; The stated precondition is that the tail becomes typed manifest rows with
; registry-validated ids, and that a Linux twin exists first. Neither holds:
; the tail rows carry only { id, platforms } and no type field, so BOTH drivers
; dispatch them through a hardcoded if/elseif chain, and the only id-validating
; gate skips every row whose type is not action/dynamic.
;
; What DID land is the better half of the same idea, and it is what will make
; this file redundant: tools/test/test-menu-top-level-parity.cjs now reads both
; dispatch chains and compares them to the manifest projection in both
; directions. This gate pins the manifest against a HAND-TYPED list, so it
; alarms on a manifest edit and says nothing about the driver; that one reads
; the driver. Retire this once the parity gate also covers what this pins,
; rather than on a date.
; ==============================================================================

; Canonical ids in manifest order -- AHK platform (suspend present, karabiner absent)
global _DG_AHK_IDS := [
	"---",
	"global_actions",
	"language",
	"config_folder",
	"setup_wizard",
	"about",
	"---",
	"suspend",
	"reload",
	"quit",
	"debug",
]

_DriftGateAhkRun() {
	SplitPath(A_ScriptDir, , &_DGWinDir)
	SplitPath(_DGWinDir, , &_DGEpDir)
	ManifestPath := _DGEpDir . "\_shared\modules\menu\menu_manifest.json"

	Raw := ""
	try Raw := FileRead(ManifestPath, "UTF-8")
	if Raw == "" {
		_DGReadFail() {
			Assert(false, "Cannot read menu_manifest.json at " . ManifestPath)
		}
		Test("menu drift gate (AHK): manifest readable", _DGReadFail)
		return
	}

	Root := ""
	try Root := JsonParse(Raw)
	if !(Root is Map) || !Root.Has("top_level") {
		_DGParseFail() {
			Assert(false, "menu_manifest.json root is not a Map or missing top_level")
		}
		Test("menu drift gate (AHK): manifest parseable", _DGParseFail)
		return
	}

	TopLevel := Root["top_level"]

	; Locate the start of the tail (first global_actions entry)
	TailStart := 0
	for Idx, Entry in TopLevel {
		if !(Entry is Map)
			continue
		if (Entry.Has("id") && Entry["id"] == "global_actions") {
			TailStart := Idx
			break
		}
	}
	if TailStart == 0 {
		_DGNoGaFail() {
			Assert(false, "top_level has no global_actions entry in menu_manifest.json")
		}
		Test("menu drift gate (AHK): global_actions present in top_level", _DGNoGaFail)
		return
	}

	; Pull in the separator immediately preceding global_actions, mirroring
	; MenuManifest_LoadTopLevelTail()'s leading-separator inclusion.
	if (TailStart > 1) {
		PrevEntry := TopLevel[TailStart - 1]
		if (PrevEntry is Map) && (PrevEntry.Has("id")) && (PrevEntry["id"] == "---") {
			TailStart := TailStart - 1
		}
	}

	; Collect the AHK tail with platform filter
	AhkTail := []
	Loop TopLevel.Length - TailStart + 1 {
		Entry := TopLevel[TailStart + A_Index - 1]
		if !(Entry is Map)
			continue
		Id := Entry.Has("id") ? Entry["id"] : ""
		if Id == ""
			continue
		if Entry.Has("platforms") && (Entry["platforms"] is Array) {
			IsForAhk := false
			for P in Entry["platforms"] {
				if P == "ahk" {
					IsForAhk := true
					break
				}
			}
			if !IsForAhk
				continue
		}
		AhkTail.Push(Id)
	}

	; Test 1 -- count
	ExpectedCount := _DG_AHK_IDS.Length
	ActualCount   := AhkTail.Length
	_DGCountResult() {
		Assert(ActualCount == ExpectedCount,
			"AHK tail has " . ActualCount . " item(s), expected " . ExpectedCount)
	}
	Test("menu drift gate (AHK): tail has " . ExpectedCount . " items", _DGCountResult)

	; Test 2 -- canonical order
	MinLen := Min(ActualCount, ExpectedCount)
	Mismatches := ""
	I := 1
	while I <= MinLen {
		if AhkTail[I] != _DG_AHK_IDS[I]
			Mismatches .= "`n  [" . I . "] got '" . AhkTail[I] . "', expected '" . _DG_AHK_IDS[I] . "'"
		I++
	}
	_DGOrderResult() {
		Assert(Mismatches == "", "AHK tail ids mismatched:" . Mismatches)
	}
	Test("menu drift gate (AHK): tail ids match canonical order", _DGOrderResult)
}

_DriftGateAhkRun()

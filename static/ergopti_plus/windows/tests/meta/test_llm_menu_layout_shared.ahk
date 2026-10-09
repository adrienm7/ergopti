; tests/meta/test_llm_menu_layout_shared.ahk

; ==============================================================================
; MODULE: Shared LLM Menu Layout Contract Test
; DESCRIPTION:
; The IA submenu's row ORDER and disabled-when-off POLICY are a single shared
; source of truth — the menu manifest's ``llm_menu`` key — consumed by BOTH the
; Windows renderer (LLM_Menu_Build via _LLM_Menu_EmitRow) and the macOS renderer
; (init.lua build_item). This test pins that contract so the two menus can never
; drift again (a greying mismatch between them was the bug that motivated it):
;
;   1. The manifest declares exactly the canonical rows, in order, with the
;      correct disabled_when_off policy (backend + model usable while off; the
;      rest greyed).
;   2. The Windows built-in fallback (_LLM_MenuLayout_Fallback) mirrors the
;      manifest exactly — a second copy that exists only for resilience must not
;      drift.
;   3. LLM_Menu_Build is actually spec-DRIVEN (loops _LLM_MenuLayout_Rows() and
;      dispatches via _LLM_Menu_EmitRow) rather than hardcoding the row list.
;   4. _LLM_Menu_EmitRow answers every canonical id, so a renamed row cannot
;      silently fall through to the "unknown row id" branch and vanish.
;   5. The retired second description has not come back.
;
; MOVED 2026-08-07: this contract used to read _shared/modules/llm/menu_layout.json,
; a spec file of its own. One menu therefore had TWO shared descriptions — that
; file and the manifest's ``llm_menu`` key, which described a two-row menu only
; Linux drew — and neither mentioned the other. The rows now live in the manifest
; with the rest of the menu tree, and assertion 5 below is what stops a second
; description from being reintroduced.
;
; The macOS conformance half lives in macos/tests/test_llm_menu_layout_shared.lua.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ======= 1/ Canonical contract (the truth) ========
; ==================================================

; The canonical row order + greying policy. Index order IS the menu order.
; disabled_when_off: false = stays usable while the feature is off (configure
; before enabling), true = greyed while off. Mirrors macOS is_disabled vs paused.
_LMLS_Canonical() {
	return [
		Map("id", "llm_backend",             "off", false, "dot", false),
		Map("id", "llm_model",               "off", false, "dot", true),
		Map("id", "llm_profile",             "off", true,  "dot", false),
		Map("id", "llm_trigger",             "off", true,  "dot", false),
		Map("id", "llm_generation_settings", "off", true,  "dot", false),
		Map("id", "llm_display",             "off", true,  "dot", false),
		Map("id", "llm_navigation",          "off", true,  "dot", false)
	]
}

_LMLS_SharedDir() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	return WindowsDir . "\..\_shared"
}

; The manifest rows this platform renders: the declared ``dynamic`` and ``group`` rows of
; llm_menu that are visible on "ahk". Linux's two inline `list` rows and the
; separator between them are not settings rows and are filtered out here exactly
; as _LLM_MenuLayout_Rows() filters them at runtime.
_LMLS_ManifestRows(Source := unset) {
	path := _LMLS_SharedDir() . "\modules\menu\menu_manifest.json"
	content := IsSet(Source) ? Source : ""
	if !IsSet(Source)
		try content := FileRead(path, "UTF-8")
	Assert(content != "", "_shared/modules/menu/menu_manifest.json must be readable")
	parsed := JsonParse(content)
	Assert(parsed is Map && parsed.Has("llm_menu"), "menu_manifest.json must have an 'llm_menu' array")
	Rows := []
	for _, Entry in parsed["llm_menu"] {
		if !(Entry is Map) or !Entry.Has("type") or (Entry["type"] != "dynamic" && Entry["type"] != "group")
			continue
		Visible := true
		if Entry.Has("platforms") {
			Visible := false
			for _, P in Entry["platforms"] {
				if (P == "ahk") {
					Visible := true
					break
				}
			}
		}
		if Visible
			Rows.Push(Entry)
	}
	return Rows
}




; ==================================================
; ======= 2/ Contract assertions ===================
; ==================================================

; The manifest must declare exactly the canonical rows, in order, with the
; correct policy — this is the source of truth both platforms read.
_LMLS_ManifestMatchesCanonical() {
	rows := _LMLS_ManifestRows()
	canon := _LMLS_Canonical()
	Assert(rows.Length == canon.Length,
		"llm_menu must declare exactly " . canon.Length . " Windows row(s) — found " . rows.Length)
	for i, c in canon {
		Assert(rows[i]["id"] == c["id"],
			"llm_menu row " . i . " must be '" . c["id"] . "' (order is the menu order)")
		Assert((rows[i]["disabled_when_off"] = true) == (c["off"] = true),
			"llm_menu row '" . c["id"] . "' disabled_when_off must be " . (c["off"] ? "true" : "false")
			. " (backend/model stay usable while off; the rest grey out — macOS parity)")
		Assert((rows[i]["health_dot"] = true) == (c["dot"] = true),
			"llm_menu row '" . c["id"] . "' health_dot must be " . (c["dot"] ? "true" : "false")
			. " — exactly one row carries the backend-reachability dot, and the manifest is what says which")
	}
}
Test("llm-menu-layout-shared: the manifest matches the canonical row order + greying policy", _LMLS_ManifestMatchesCanonical)

; The Windows fallback array must mirror the manifest exactly — it exists only so
; a missing/corrupt manifest still renders a menu, and must never become a 2nd truth.
_LMLS_FallbackMirrorsManifest() {
	Seg := _DriverFuncBody("_LLM_MenuLayout_Fallback")
	Assert(Seg != "", "_LLM_MenuLayout_Fallback() must exist in menu_main.ahk")
	for _, c in _LMLS_Canonical() {
		; Tolerate variable inner spacing: assert the id and its bool co-occur in the body.
		idTok  := '"id", "' . c["id"] . '"'
		boolTok := '"disabled_when_off", ' . (c["off"] ? "true" : "false")
		dotTok  := '"health_dot", ' . (c["dot"] ? "true" : "false")
		Assert(InStr(Seg, idTok) > 0,
			"_LLM_MenuLayout_Fallback must contain row id '" . c["id"] . "'")
		Assert(InStr(Seg, idTok) > 0 and InStr(Seg, boolTok) > 0,
			"_LLM_MenuLayout_Fallback row '" . c["id"] . "' must carry disabled_when_off=" . (c["off"] ? "true" : "false") . " (mirror the manifest)")
		Assert(InStr(Seg, idTok) > 0 and InStr(Seg, dotTok) > 0,
			"_LLM_MenuLayout_Fallback row '" . c["id"] . "' must carry health_dot=" . (c["dot"] ? "true" : "false") . " (mirror the manifest)")
	}
}
Test("llm-menu-layout-shared: Windows fallback mirrors the manifest", _LMLS_FallbackMirrorsManifest)

; Row construction must be spec-DRIVEN: it loops the shared rows and dispatches
; each via _LLM_Menu_EmitRow, rather than hardcoding the settings-row list
; inline. Rows live in LLM_Menu_BuildSubmenu (LLM_Menu_Build only publishes).
_LMLS_BuildIsSpecDriven() {
	Seg := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Assert(Seg != "", "LLM_Menu_BuildSubmenu() must exist in menu_main.ahk")
	Assert(InStr(Seg, "_LLM_MenuLayout_Rows()") > 0,
		"LLM_Menu_BuildSubmenu must read the row list from _LLM_MenuLayout_Rows() (the shared spec) — not hardcode it")
	Captured := _DriverFuncBody("_LLM_Menu_EmitCapturedRow")
	Assert(Captured != "", "the bound native row owner must exist")
	Assert(_LMLS_ExecutableCall(Seg, "MenuRenderer_Build"), "actual canonical orchestration must execute")
	Assert(_LMLS_ExecutableCall(Seg, "_LLM_Menu_EmitCapturedRow.Bind"), "row binding must be executable source")
	Assert(_LMLS_ExecutableCall(Captured, "_LLM_Menu_EmitRow"), "the captured callback reaches the actual native dispatch")
	Assert(InStr(Seg, "_LLM_Menu_EmitCapturedRow.Bind(") > 0 && InStr(_DriverFuncBody("_LLM_Menu_EmitCapturedRow"), "_LLM_Menu_EmitRow(") > 0,
		"LLM_Menu_BuildSubmenu must dispatch each row via _LLM_Menu_EmitRow so order + greying come from the shared spec")
}
Test("llm-menu-layout-shared: LLM_Menu_Build is driven by the shared layout spec", _LMLS_BuildIsSpecDriven)

; Every declared row must have a case in the dispatch. Without this, renaming a
; row in the manifest leaves the driver answering nothing for it: the row falls
; through to the "unknown row id" warning and simply disappears from the menu,
; which is silent to a user who never reads the log.
_LMLS_DispatchAnswersEveryRow() {
	Seg := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Seg != "", "_LLM_Menu_EmitRow() must exist in menu_main.ahk")
	for _, c in _LMLS_Canonical() {
		Assert(InStr(Seg, 'case "' . c["id"] . '":') > 0,
			"_LLM_Menu_EmitRow must answer the declared row '" . c["id"]
			. "' — an unanswered id is dropped with only a log line to show for it")
	}
}
Test("llm-menu-layout-shared: the dispatch answers every declared row", _LMLS_DispatchAnswersEveryRow)

; The declared health_dot must REACH the row. A field the manifest declares and
; no driver reads is worse than no field: editing it moves nothing and there is
; nothing to read that says so.
_LMLS_HealthDotIsRead() {
	Build := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Assert(InStr(Build, '_MR_Get(_row, "health_dot"') > 0,
		"LLM_Menu_BuildSubmenu must pass each row's declared health_dot into _LLM_Menu_EmitRow")
	Emit := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(InStr(Emit, "has_health_dot && llm_is_operational") > 0,
		"_LLM_Menu_EmitRow must gate the dot on the declared flag, not on the row id alone")
}
Test("llm-menu-layout-shared: the declared health_dot reaches the row", _LMLS_HealthDotIsRead)

; The retired spec file must stay retired. Two shared descriptions of one menu is
; the state this migration ended; a reintroduced menu_layout.json would drift from
; the manifest with nothing comparing them.
_LMLS_NoSecondDescription() {
	path := _LMLS_SharedDir() . "\modules\llm\menu_layout.json"
	Assert(!FileExist(path),
		"_shared/modules/llm/menu_layout.json must not exist — the IA menu is described in the "
		. "menu manifest's llm_menu key, and a second shared description would drift from it")
}
Test("llm-menu-layout-shared: the retired second description has not come back", _LMLS_NoSecondDescription)

; AHK identifiers accept all non-ASCII code units; quoted data is not authority.
_LMLS_ExecutableCall(Source, Name) {
	Code := _DriverMaskNonCode(&Source)
	Identifier := "A-Za-z0-9_\x{80}-\x{10FFFF}"
	return RegExMatch(Code, "(?<![" . Identifier . ".])\Q" . Name . "\E(?![" . Identifier . "])[ \t]*\(") > 0
}
_LMLS_CurrentGroupSourceAndDataControls() {
	Build := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Capture := _DriverFuncBody("_LLM_Menu_EmitCapturedRow")
	Assert(_LMLS_ExecutableCall(Build, "MenuRenderer_Build"))
	Assert(_LMLS_ExecutableCall(Capture, "_LLM_Menu_EmitRow"))
	for Name in ["MenuRenderer_Build", "_LLM_Menu_EmitRow"] {
		AssertFalse(_LMLS_ExecutableCall('; ' . Name . '()`nreturn false', Name), "commented source cannot credit a native owner")
		AssertFalse(_LMLS_ExecutableCall('Value := "' . Name . '()"`nreturn false', Name), "quoted source cannot credit a native owner")
		AssertFalse(_LMLS_ExecutableCall('Unrelated' . Name . '()', Name), "a longer native callable cannot borrow identity")
		AssertTrue(_LMLS_ExecutableCall(Name . '()', Name), "the same canonical callable remains admitted")
	}
	_LMLS_CurrentRowTypesPolicy(_LMLS_ManifestRows())
}

; The four fixed parents are declared groups; backend/model/profile remain native.
_LMLS_CurrentRowTypesPolicy(Rows) {
	Groups := 0
	for Row in Rows {
		if Row["id"] == "llm_trigger" || Row["id"] == "llm_display" || Row["id"] == "llm_navigation"
			|| Row["id"] == "llm_generation_settings" {
			AssertEqual("group", Row["type"], "fixed LLM parents require shared group ownership")
			Groups += 1
		} else AssertEqual("dynamic", Row["type"], "other native dynamic domains retain their existing API")
	}
	AssertEqual(4, Groups, "exactly the selected genuine fixed parents have shared group ownership")
}
Test("llm-menu-layout-shared: true canonical groups require executable native source owners", _LMLS_CurrentGroupSourceAndDataControls)


; Withdraw each current row's declared route without deriving expected types.
_LMLS_CurrentRowTypeWithdrawalControls() {
	_LMLS_ManifestMatchesCanonical()
	Rows := _LMLS_ManifestRows()
	AssertEqual(7, Rows.Length, "all current Windows settings rows enter the route controls")
	_LMLS_CurrentInventoryPolicy(Rows)
	AssertEqual(_LMLS_Canonical().Length, Rows.Length, "all current Windows settings rows enter the route controls")
	_LMLS_CurrentRowTypesPolicy(Rows)
	for Index, Original in Rows {
		Mutant := []
		for Row in Rows
			Mutant.Push(Row.Clone())
		Mutant[Index]["type"] := Original["type"] == "group" ? "dynamic" : "group"
		ExpectedMessage := Original["type"] == "group"
			? "fixed LLM parents require shared group ownership - expected: <group>, actual: <dynamic>"
			: "other native dynamic domains retain their existing API - expected: <dynamic>, actual: <group>"
		Refused := false
		try _LMLS_CurrentRowTypesPolicy(Mutant)
		catch as PolicyFailure {
			if Type(PolicyFailure) != "Error" || PolicyFailure.Message != ExpectedMessage
				throw PolicyFailure
			Refused := true
		}
		AssertTrue(Refused, "changing one current row's declared route must be refused: " . Original["id"])
	}
}
Test("llm-menu-layout-shared: every current declared native route rejects its type withdrawal", _LMLS_CurrentRowTypeWithdrawalControls)

; The published removal left seven handwritten canonical rows, not eight.
; Pin their complete inventory before withdrawing any genuine current route.
_LMLS_CurrentInventoryPolicy(Rows) {
	Canonical := _LMLS_Canonical()
	Types := ["dynamic", "dynamic", "dynamic", "group", "group", "group", "group"]
	AssertEqual(7, Canonical.Length, "the independently handwritten canonical inventory remains seven")
	AssertEqual(Canonical.Length, Rows.Length, "current LLM inventory row count")
	for Index, Expected in Canonical {
		AssertEqual(Expected["id"], Rows[Index]["id"], "current LLM inventory IDs and order")
		AssertEqual(Types[Index], Rows[Index]["type"], "current LLM inventory exact route type")
		AssertEqual(Expected["off"], Rows[Index]["disabled_when_off"], "current LLM inventory exact off policy")
		AssertEqual(Expected["dot"], Rows[Index]["health_dot"], "current LLM inventory exact health-dot policy")
	}
}

; Locate mutation targets in real captured JSON; expected IDs never come from it.
_LMLS_SourceRowIndex(Parts, Id) {
	for Index, Part in Parts {
		Entry := JsonParse(Part["text"])
		if Entry is Map && Entry.Has("id") && Entry["id"] == Id
			return Index
	}
	throw Error("The genuine source lacks the independently selected fixture target: " . Id)
}

_LMLS_InventorySourceControl(Kind) {
	Path := _LMLS_SharedDir() . "\modules\menu\menu_manifest.json"
	Source := FileRead(Path, "UTF-8")
	_LMLS_CurrentInventoryPolicy(_LMLS_ManifestRows(Source))
	if Kind == "current"
		return
	Member := JsonObjectMemberSpans(Source)["llm_menu"]
	Parts := JsonArrayElementSpans(Member["text"])
	Profile := _LMLS_SourceRowIndex(Parts, "llm_profile")
	Backend := _LMLS_SourceRowIndex(Parts, "llm_backend")
	Model := _LMLS_SourceRowIndex(Parts, "llm_model")
	Trigger := _LMLS_SourceRowIndex(Parts, "llm_trigger")
	Values := []
	for Part in Parts
		Values.Push(Part["text"])
	switch Kind {
		case "revived":
			; Independently retained row removed by published dd8bd7554.
			Retired := '{"type":"group","id":"llm_live_mode","i18n":"menu.llm.live_mode_title",'
				. '"disabled_when_off":true,"health_dot":false,"platforms":["ahk","hs","linux"]}'
			Values.InsertAt(Trigger + 1, Retired)
			ExpectedMessage := "current LLM inventory row count - expected: <7>, actual: <8>"
		case "missing":
			Values.RemoveAt(Profile)
			ExpectedMessage := "current LLM inventory row count - expected: <7>, actual: <6>"
		case "duplicate":
			; Retain seven rows and four groups: cardinality alone must not admit this.
			Values[Model] := Values[Profile]
			ExpectedMessage := "current LLM inventory IDs and order - expected: <llm_model>, actual: <llm_profile>"
		case "reordered":
			OldBackend := Values[Backend]
			Values[Backend] := Values[Model], Values[Model] := OldBackend
			ExpectedMessage := "current LLM inventory IDs and order - expected: <llm_backend>, actual: <llm_model>"
		default:
			throw ValueError("Unknown inventory source control")
	}
	ArraySource := "["
	for Index, Value in Values
		ArraySource .= (Index == 1 ? "" : ",") . Value
	ArraySource .= "]"
	MutantSource := SubStr(Source, 1, Member["start"] - 1) . ArraySource
		. SubStr(Source, Member["start"] + Member["length"])
	Rows := _LMLS_ManifestRows(MutantSource)
	Refused := false
	try _LMLS_CurrentInventoryPolicy(Rows)
	catch as InventoryFailure {
		if Type(InventoryFailure) != "Error" || InventoryFailure.Message != ExpectedMessage
			throw InventoryFailure
		Refused := true
	}
	AssertTrue(Refused, "a real-source inventory mutation must refuse for its independent contract reason: " . Kind)
	AssertEqual(Source, FileRead(Path, "UTF-8"), "source controls never modify the canonical manifest")
}

Test("llm-menu-layout-shared: genuine current source retains the complete seven-row inventory",
	_LMLS_InventorySourceControl.Bind("current"))
Test("llm-menu-layout-shared: revived retired live row cannot join the current source inventory",
	_LMLS_InventorySourceControl.Bind("revived"))
Test("llm-menu-layout-shared: missing real-source row refuses before route withdrawal",
	_LMLS_InventorySourceControl.Bind("missing"))
Test("llm-menu-layout-shared: duplicate real-source ID cannot borrow seven-row cardinality",
	_LMLS_InventorySourceControl.Bind("duplicate"))
Test("llm-menu-layout-shared: reordered real-source IDs cannot borrow current route types",
	_LMLS_InventorySourceControl.Bind("reordered"))

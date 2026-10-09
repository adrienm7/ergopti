; tests/meta/test_llm_menu_disabled_greyed.ahk

; ==============================================================================
; MODULE: LLM Menu Disabled-State Full-Greyed Render Meta Test
; DESCRIPTION:
; Regression for the "menu IA vide quand desactive" report: when the LLM feature
; is OFF, the IA submenu must still render the FULL set of rows (so the enable
; toggle is always reachable) with every settings row greyed out — mirroring the
; macOS menu's is_disabled pattern (ui/menu/menu_llm/init.lua).
;
; Two root causes are guarded here:
;   1. LLM_Deps_IsReady() was called UNGUARDED at the top of LLM_Menu_Build();
;      a throw (deps subsystem not ready while the feature is off) aborted the
;      build BEFORE the enable toggle was added, leaving the submenu empty with
;      no visible control to switch the feature back on.
;   2. Settings rows were added with no disabled flag, so there was no greying
;      (and no macOS parity) when the feature was off.
;
; Meta-static (source introspection) because the LLM tray modules register
; top-level state plus an OnMessage hook the headless runner cannot load.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================
; ==============================================
; ======= 1/ Source-introspection guards =======
; ==============================================
; ==============================================

; Guard 1 — the deps probe must be wrapped so it can never abort the build
; before the enable toggle is added (the empty-IA-submenu regression).
; Row construction lives in LLM_Menu_BuildSubmenu (LLM_Menu_Build only
; publishes), so the guard scans the extractor.
_LMDG_BuildGuardsDepsProbe() {
	Seg := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Assert(Seg != "", "LLM_Menu_BuildSubmenu() declaration must exist in menu_main.ahk")
	Assert(InStr(Seg, "try _deps_ready := LLM_Deps_IsReady()") > 0,
		"LLM_Menu_BuildSubmenu must probe LLM_Deps_IsReady() inside a try (guarded) so a throw cannot abort the build before the enable toggle is added")
	Assert(InStr(Seg, '_llm_is_operational := (_LLM_Menu["enabled"] && LLM_Deps_IsReady())') == 0,
		"LLM_Menu_BuildSubmenu must NOT call LLM_Deps_IsReady() unguarded inline — that throw left the IA submenu empty when the feature was off")
}
Test("menu_main: LLM_Menu_Build guards the deps probe so the toggle always renders (llm-menu-disabled-greyed)", _LMDG_BuildGuardsDepsProbe)

; Guard 2 — the SETTINGS rows grey out when off and the enable toggle is added
; unconditionally. Greying is now driven through the shared layout spec: the build
; computes _disabled from the enabled flag and resolves each row's flag against the
; spec's disabled_when_off policy (`_row["disabled_when_off"] ? _disabled : false`).
; The per-row policy itself (backend/model stay usable, the rest grey) lives in
; the menu manifest's llm_menu key and is asserted by test_llm_menu_layout_shared.
_LMDG_BuildGreysRowsWhenOff() {
	Seg := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Assert(Seg != "", "LLM_Menu_BuildSubmenu() declaration must exist in menu_main.ahk")
	Assert(InStr(Seg, '_disabled := !_LLM_Menu["enabled"]') > 0,
		"LLM_Menu_BuildSubmenu must compute _disabled from the enabled flag to grey settings rows when off")
	Assert(InStr(Seg, '_row["disabled_when_off"] ? _disabled : false') > 0,
		"LLM_Menu_BuildSubmenu must resolve each row's greying against the shared spec policy (disabled_when_off ? _disabled : false) — so backend/model stay usable while the rest grey out")
	Assert(_LMDG_ToggleRoute(Seg, _DriverFuncBody("MenuRenderer_Build")),
		"LLM_Menu_BuildSubmenu must always add the manifest's IA switch through the genuine shared renderer")
	Toggle := _MR_GetMenuDef("llm_menu")[1]
	AssertEqual("toggle", Toggle["type"])
	AssertEqual("llm_toggle", Toggle["id"])
	AssertEqual("menu.llm.enable", Toggle["i18n"])
	AssertEqual(1, Toggle["checked_when"].Length)
	AssertEqual("llm_enabled", Toggle["checked_when"][1])
	AssertEqual(1, Toggle["disabled_when"].Length)
	AssertEqual("llm_toggle_ready", Toggle["disabled_when"][1])
	Assert(_MR_IsForAhk(Toggle), "the genuine first toggle is available on Windows")
}
Test("menu_main: LLM_Menu_Build greys the settings rows when the feature is off (llm-menu-disabled-greyed)", _LMDG_BuildGreysRowsWhenOff)

; Guard 2b — every row emitted by _LLM_Menu_EmitRow honours the resolved greying
; flag (passes `disabled` through to _LLM_Menu_AddRow), so the shared spec's policy
; actually takes effect at render. The backend/model "stay enabled while off"
; guarantee itself is the spec's disabled_when_off=false, pinned by
; test_llm_menu_layout_shared — this guard just proves the renderer applies it.
_LMDG_EmitRowAppliesGreying() {
	Seg := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Seg != "", "_LLM_Menu_EmitRow() must exist in menu_main.ahk")
	Assert(_LMDG_BackendFrameGreyingRoute(Seg, _DriverFuncBody("_LLM_Menu_BackendParentRows")),
		"_LLM_Menu_EmitRow must emit the actual backend frame so its greying follows the spec-resolved flag")
	Assert(InStr(Seg, "model_menu, disabled)") > 0,
		"_LLM_Menu_EmitRow must emit the model row with the resolved 'disabled' flag (not a hardcoded value) so the spec policy drives greying")
}
Test("menu_main: _LLM_Menu_EmitRow applies the spec-resolved greying flag (llm-menu-disabled-greyed)", _LMDG_EmitRowAppliesGreying)

; Guard 3 — the row helper greys a row when its disabled flag is set.
_LMDG_AddRowHelperDisables() {
	Seg := _DriverFuncBody("_LLM_Menu_AddRow")
	Assert(Seg != "", "_LLM_Menu_AddRow(label, target, disabled) helper must exist in menu_main.ahk")
	Assert(InStr(Seg, ".Add(label, target)") > 0,
		"_LLM_Menu_AddRow must always Add the row so it is present at a stable position")
	Assert(InStr(Seg, "if disabled") > 0 and InStr(Seg, ".Disable(label)") > 0,
		"_LLM_Menu_AddRow must Disable() the row when disabled is true (grey it — macOS is_disabled parity)")
}
Test("menu_main: _LLM_Menu_AddRow greys a row when disabled (llm-menu-disabled-greyed)", _LMDG_AddRowHelperDisables)

; Guard 4 — the parent IA tray check follows user intent alone. Backend
; readiness already owns the health dot and the install warning row; folding
; it into this checkbox repeated the fixed inner-toggle bug one level up:
; enabled with Ollama missing rendered unchecked, reading as "IA is off".
; Scanned comment-stripped so prose can never satisfy the assertions.
_LMDG_ParentCheckFollowsIntent() {
	Seg := _DriverFuncBody("LLM_Menu_Build")
	Assert(Seg != "", "LLM_Menu_Build() declaration must exist in menu_main.ahk")
	Code := _StripFullLineComments(Seg)
	Assert(InStr(Code, 'if (_LLM_Menu["enabled"]) {') > 0,
		"the parent IA tray check must follow the enabled flag alone so intent, not backend reachability, drives the checkbox")
	Assert(InStr(Code, 'if (_LLM_Menu["enabled"] && _backend_ready) {') == 0,
		"the parent IA tray check must not require backend readiness - that left the entry visually OFF while Ollama was missing")
}
Test("menu_main: parent IA check follows intent, not backend readiness (llm-parent-check-intent)", _LMDG_ParentCheckFollowsIntent)


; Pins the actual executable route, not copied call text in comments or strings.
_LMDG_Statement(Code, Pattern, Depth) {
	Masked := _DriverMaskNonCode(&Code)
	if !RegExMatch(Code, Pattern, &Found)
		return 0
	Position := Found.Pos(1), Token := Found[1]
	if SubStr(Masked, Position, StrLen(Token)) != Token
		return 0
	Prefix := SubStr(Masked, 1, Position - 1), CurrentDepth := 0
	if RegExMatch(RTrim(Prefix, " `t`r`n"), 'i)(?:^|\n)[ \t]*(?:if|else|for|while|loop|catch|try|finally)\b[^\r\n{]*$')
		return 0
	Loop Parse Prefix {
		if A_LoopField == "{"
			CurrentDepth++
		else if A_LoopField == "}"
			CurrentDepth--
	}
	return CurrentDepth == Depth ? Position : 0
}

_LMDG_ToggleRoute(Build, Render) {
	Command := _LMDG_Statement(Build,
		'm)^[ \t]*(Commands)\["llm_toggle"\] := LLM_Menu_OnToggle[ \t]*$', 2)
	Reader := _LMDG_Statement(Build,
		'm)^[ \t]*(StateGetters) := Map\("llm_enabled", \(\) => _LLM_Menu\["enabled"\],[ \t]*\n[ \t]*"llm_toggle_ready", \(\) => !A_IsSuspended\)', 2)
	Publish := _LMDG_Statement(Build,
		'm)^[ \t]*(MenuRenderer_Build)\("llm_menu", "LLM", DynamicHandlers, _LLM_Menu_GroupBuilders\(\),[ \t]*\n[ \t]*"", Commands, StateGetters, StagedHandle, GroupDisabled\)', 2)
	if !(Command && Reader && Publish && Command < Reader && Reader < Publish)
		return false
	Stage := _LMDG_Statement(Build, 'm)^[ \t]*(try) \{[ \t]*$', 1)
	if !(Stage && Stage < Command)
		return false
	Masked := _DriverMaskNonCode(&Build)
	StageBody := SubStr(Masked, Stage), StageDepth := 1, StageEnd := 0
	Loop Parse StageBody {
		if A_LoopField == "{"
			StageDepth++
		else if A_LoopField == "}" {
			StageDepth--
			if StageDepth == 1 {
				StageEnd := Stage + A_Index - 1
				break
			}
		}
	}
	if !(StageEnd > Publish)
		return false
	if RegExMatch(SubStr(Masked, 1, Publish - 1), '\breturn\b')
		return false
	Branch := _LMDG_Statement(Render,
		'm)^[ \t]*(if) ItemType == "toggle" \{[ \t]*\n[ \t]*ItemCount \+= _MR_RenderToggle\(Result, Item, ManifestKey, Commands, StateGetters\)', 2)
	Call := _LMDG_Statement(Render,
		'm)^[ \t]*(ItemCount) \+= _MR_RenderToggle\(Result, Item, ManifestKey, Commands, StateGetters\)', 3)
	return Branch && Call && Branch < Call
}

_LMDG_ToggleRouteRefusesDecoy(Kind) {
	Build := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Render := _DriverFuncBody("MenuRenderer_Build")
	Assert(_LMDG_ToggleRoute(Build, Render), "actual current native bodies publish the shared toggle")
	if Kind == "missing-command"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', 'Commands["other_toggle"] := LLM_Menu_OnToggle')
	else if Kind == "wrong-reader"
		Build := StrReplace(Build, '"llm_toggle_ready", () => !A_IsSuspended', '"llm_toggle_ready", () => _LLM_Menu["enabled"]')
	else if Kind == "conditional-command"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', 'if _LLM_Menu["enabled"] {`nCommands["llm_toggle"] := LLM_Menu_OnToggle`n}')
	else if Kind == "outer-conditional" {
		Build := StrReplace(Build, "try {", 'if _LLM_Menu["enabled"] {')
		Build := StrReplace(Build, "} catch as e {", "} else {")
	} else if Kind == "unbraced-command"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', 'if _LLM_Menu["enabled"]`nCommands["llm_toggle"] := LLM_Menu_OnToggle')
	else if Kind == "comment-command"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', '; Commands["llm_toggle"] := LLM_Menu_OnToggle')
	else if Kind == "string-command"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', "Audit := '(`nCommands[" . Chr(34) . "llm_toggle" . Chr(34) . "] := LLM_Menu_OnToggle`n)'")
	else if Kind == "string-renderer"
		Render := "Decoy() {`nAudit := '(`nif ItemType == " . Chr(34) . "toggle" . Chr(34) . " {`nItemCount += _MR_RenderToggle(Result, Item, ManifestKey, Commands, StateGetters)`n}`n)'`n}"
	else if Kind == "wrong-target"
		Build := StrReplace(Build, '"", Commands, StateGetters, StagedHandle, GroupDisabled)', '"", Commands, StateGetters, OtherHandle, GroupDisabled)')
	else if Kind == "early-return"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', 'if !_LLM_Menu["enabled"]`nreturn StagedHandle`nCommands["llm_toggle"] := LLM_Menu_OnToggle')
	else if Kind == "comment-renderer"
		Render := StrReplace(Render, 'if ItemType == "toggle" {', '; if ItemType == "toggle" {')
	else if Kind == "missing-renderer"
		Render := StrReplace(Render, '_MR_RenderToggle(Result, Item, ManifestKey, Commands, StateGetters)', '_MR_RenderChoice(Result, Item, ManifestKey, Commands, StateGetters)')
	else
		throw Error("Unknown toggle route decoy")
	Assert(!_LMDG_ToggleRoute(Build, Render), "data, conditional or unrelated source cannot supply the IA switch: " . Kind)
}
for Kind in ["missing-command", "wrong-reader", "conditional-command", "outer-conditional", "unbraced-command", "comment-command",
	"string-command", "string-renderer", "wrong-target", "missing-renderer", "early-return", "comment-renderer"]
	Test("shared IA toggle route refuses " . Kind, _LMDG_ToggleRouteRefusesDecoy.Bind(Kind))

; Actual backend data/GroupRow/template publication transports the same resolved greying flag.
_LMDG_BackendFrameGreyingRoute(Emit, Helper) {
	if Emit == "" || Helper == ""
		return false
	Call := _LMDG_Statement(Emit,
		'm)^[ \t]*(BackendRows) := _LLM_Menu_BackendParentRows\(BackendMenu, BackendCaption, disabled, WarningRows\)', 3)
	Consumer := _LMDG_Statement(Emit,
		'm)^[ \t]*(MenuRenderer_AppendRows)\(_LLM_Menu_Handle, "llm_menu", "llm_backend_parent_frame_ahk", BackendRows\)', 3)
	Getter := _LMDG_Statement(Helper,
		'm)^[ \t]*(Getters) := Map\("llm_backend_parent_caption", \(\*\) => Caption,[ \t]*\n[ \t]*"llm_backend_parent_ready", \(\*\) => !Disabled,', 1)
	Parent := _LMDG_Statement(Helper,
		'm)^[ \t]*(Parent) := MenuRenderer_GroupRow\("llm_backend_parent_ahk", "llm_backend_parent", NativeChild, Getters\)', 1)
	Handoff := _LMDG_Statement(Helper,
		'm)^[ \t]*(ParentRows) := \[Parent\][ \t]*$', 1)
	ListConsumer := _LMDG_Statement(Helper,
		'm)^[ \t]*(Map)\("llm_backend_parent_rows", \(\*\) => ParentRows,[ \t]*$', 1)
	Frame := _LMDG_Statement(Helper,
		'm)^[ \t]*(Rows) := MenuRenderer_TemplateRows\("llm_backend_parent_frame_ahk", Map\(\), Getters,[ \t]*\n'
		. '[ \t]*Map\("llm_backend_parent_rows", \(\*\) => ParentRows,[ \t]*\n'
		. '[ \t]*"llm_backend_warning_rows", \(\*\) => Admission\["warning_rows"\]\)\)', 1)
	ResultReturn := _LMDG_Statement(Helper, 'm)^[ \t]*(return) Rows[ \t]*$', 1)
	return Call && Consumer && Call < Consumer && Getter && Parent && Handoff && ListConsumer && Frame && ResultReturn
		&& Getter < Parent && Parent < Handoff && Handoff < Frame && Frame < ListConsumer && ListConsumer < ResultReturn
}

_LMDG_BackendFrameGreyingDecoy(Kind) {
	Emit := _DriverFuncBody("_LLM_Menu_EmitRow"), Helper := _DriverFuncBody("_LLM_Menu_BackendParentRows")
	Assert(_LMDG_BackendFrameGreyingRoute(Emit, Helper), "the genuine current backend parent consumes resolved off-state policy")
	if Kind == "wrong-flag"
		Emit := StrReplace(Emit, 'BackendMenu, BackendCaption, disabled, WarningRows)', 'BackendMenu, BackendCaption, false, WarningRows)')
	else if Kind == "wrong-reader"
		Helper := StrReplace(Helper, '"llm_backend_parent_ready", (*) => !Disabled,', '"llm_backend_parent_ready", (*) => true,')
	else if Kind == "commented-call"
		Emit := StrReplace(Emit, 'BackendRows := _LLM_Menu_BackendParentRows(', '; BackendRows := _LLM_Menu_BackendParentRows(')
	else if Kind == "foreign-group"
		Helper := StrReplace(Helper, 'Parent := MenuRenderer_GroupRow(', 'Parent := Foreign.MenuRenderer_GroupRow(')
	else if Kind == "wrong-consumer"
		Emit := StrReplace(Emit, '"llm_backend_parent_frame_ahk", BackendRows)', '"llm_backend_parent_frame_ahk", ForeignRows)')
	else if Kind == "discarded-parent"
		Helper := StrReplace(Helper, 'ParentRows := [Parent]', 'ParentRows := [Map("label", Caption, "submenu", NativeChild)]')
	else if Kind == "foreign-parent"
		Helper := StrReplace(Helper, 'ParentRows := [Parent]', 'ParentRows := [ForeignParent]')
	else if Kind == "wrong-list-consumer"
		Helper := StrReplace(Helper, '"llm_backend_parent_rows", (*) => ParentRows,', '"llm_backend_parent_rows", (*) => [],')
	else if Kind == "commented-handoff"
		Helper := StrReplace(Helper, 'ParentRows := [Parent]', '; ParentRows := [Parent]')
	else if Kind == "commented-list-consumer"
		Helper := StrReplace(Helper, 'Map("llm_backend_parent_rows", (*) => ParentRows,', '; Map("llm_backend_parent_rows", (*) => ParentRows,')
	else if Kind == "wrong-return"
		Helper := StrReplace(Helper, 'return Rows', 'return ForeignRows')
	else
		throw Error("Unknown backend parent off-state counterexample")
	Assert(!_LMDG_BackendFrameGreyingRoute(Emit, Helper), "foreign or fixed-flag source cannot supply actual backend greying: " . Kind)
}
for Kind in ["wrong-flag", "wrong-reader", "commented-call", "foreign-group", "wrong-consumer", "wrong-return",
	"discarded-parent", "foreign-parent", "wrong-list-consumer", "commented-handoff", "commented-list-consumer"]
	Test("shared backend parent off-state route refuses " . Kind, _LMDG_BackendFrameGreyingDecoy.Bind(Kind))

; tests/meta/modules/llm/menu/test_llm_menu_disabled_greyed.ahk

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
	Assert(_LMDG_ToggleRoute(Seg, _DriverFuncBody("MenuRenderer_Build"),
		_DriverFuncBody("_LLM_Menu_StateGetters")),
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

; Guard 3 — the model selector button greys with the spec-resolved flag: the
; readiness predicate the shared renderer reads carries `disabled` from live
; code, not from a comment or string.
_LMDG_SelectorButtonGreys() {
	Seg := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Seg != "", "_LLM_Menu_EmitRow() must exist in menu_main.ahk")
	Code := Seg
	Masked := _DriverMaskNonCode(&Code)
	Key := '"llm_model_selector_ready"', Predicate := ", (*) => !disabled"
	Position := InStr(Code, Key . Predicate)
	Assert(Position > 0, "the selector button's readiness must read the resolved greying flag")
	; The mask blanks strings and comments: the key is a string, the predicate
	; after it must survive as code.
	AssertEqual(Predicate, SubStr(Masked, Position + StrLen(Key), StrLen(Predicate)),
		"the readiness predicate must be live code")
	Rows := _MR_GetMenuDef("llm_model_selector_commands")
	Assert(Rows.Length == 1 && Rows[1]["disabled_when"].Length == 1
		&& Rows[1]["disabled_when"][1] == "llm_model_selector_ready",
		"the shared declaration greys the button through llm_model_selector_ready")
}
Test("menu_main: the model selector button greys with the resolved flag (llm-menu-disabled-greyed)", _LMDG_SelectorButtonGreys)

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

_LMDG_ToggleRoute(Build, Render, Getters) {
	Command := _LMDG_Statement(Build,
		'm)^[ \t]*(Commands)\["llm_toggle"\] := LLM_Menu_OnToggle[ \t]*$', 2)
	Reader := _LMDG_Statement(Build,
		'm)^[ \t]*(StateGetters) := _LLM_Menu_StateGetters\(\)[ \t]*$', 2)
	Publish := _LMDG_Statement(Build,
		'm)^[ \t]*(MenuRenderer_Build)\("llm_menu", "LLM", Map\(\), _LLM_Menu_GroupBuilders\(\),[ \t]*\n[ \t]*ListProviders, Commands, StateGetters, StagedHandle, GroupDisabled\)', 2)
	; The factored getter must retain both pause and genuine full-state admission.
	Ready := _LMDG_Statement(Getters,
		'm)^[ \t]*(return) Map\("llm_enabled", \(\) => _LLM_Menu\["enabled"\],[ \t]*\n[ \t]*"llm_toggle_ready", \(\) => !A_IsSuspended && ConfigFullStateCanPersist\(\),[ \t]*$', 1)
	if !(Command && Reader && Ready && Publish && Command < Reader && Reader < Publish)
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
	; The row loop sits inside the build-memo try of MenuRenderer_Build (the
	; write-admission memo lives for one outermost build), one block deeper
	; than the function body.
	Branch := _LMDG_Statement(Render,
		'm)^[ \t]*(if) ItemType == "toggle" \{[ \t]*\n[ \t]*ItemCount \+= _MR_RenderToggle\(Result, Item, ManifestKey, Commands, StateGetters\)', 3)
	Call := _LMDG_Statement(Render,
		'm)^[ \t]*(ItemCount) \+= _MR_RenderToggle\(Result, Item, ManifestKey, Commands, StateGetters\)', 4)
	return Branch && Call && Branch < Call
}

_LMDG_ToggleRouteRefusesDecoy(Kind) {
	Build := _DriverFuncBody("LLM_Menu_BuildSubmenu")
	Render := _DriverFuncBody("MenuRenderer_Build")
	Getters := _DriverFuncBody("_LLM_Menu_StateGetters")
	Assert(_LMDG_ToggleRoute(Build, Render, Getters), "actual current native bodies publish the shared toggle")
	if Kind == "missing-command"
		Build := StrReplace(Build, 'Commands["llm_toggle"] := LLM_Menu_OnToggle', 'Commands["other_toggle"] := LLM_Menu_OnToggle')
	else if Kind == "wrong-reader"
		Getters := StrReplace(Getters,
			'"llm_toggle_ready", () => !A_IsSuspended && ConfigFullStateCanPersist()',
			'"llm_toggle_ready", () => _LLM_Menu["enabled"]')
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
	Assert(!_LMDG_ToggleRoute(Build, Render, Getters), "data, conditional or unrelated source cannot supply the IA switch: " . Kind)
}
for Kind in ["missing-command", "wrong-reader", "conditional-command", "outer-conditional", "unbraced-command", "comment-command",
	"string-command", "string-renderer", "wrong-target", "missing-renderer", "early-return", "comment-renderer"]
	Test("shared IA toggle route refuses " . Kind, _LMDG_ToggleRouteRefusesDecoy.Bind(Kind))

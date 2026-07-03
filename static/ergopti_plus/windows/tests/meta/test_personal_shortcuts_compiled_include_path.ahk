; tests/meta/test_personal_shortcuts_compiled_include_path.ahk

; ==============================================================================
; MODULE: Personal Shortcuts Compiled-Mode Include Path Test
; DESCRIPTION:
; Regression guard for a silent (non-crashing) sibling of the
; A_LocalAppData startup crash (see meta/test_bundle_resolve_dir_local_appdata.ahk):
; the compiled-mode ``#Include *i ...personal_shortcuts.ahk`` line in
; ErgoptiPlus.ahk referenced ``%A_LocalAppData%``, which is not a recognised
; token for #Include's load-time ``%...%`` substitution (it is neither one of
; the handful of built-ins that directive supports, nor a real environment
; variable — the actual variable is named ``LOCALAPPDATA``). The substitution
; silently resolved to an empty/garbage prefix, so the ``*i`` (include-if-
; exists) flag never found the stub that ``EnsurePersonalShortcutsFile()``
; writes to ``%LOCALAPPDATA%\Ergopti\_generated\personal_shortcuts.ahk`` —
; the compiled .exe's personal shortcuts were silently never loaded, with no
; error anywhere. #Include directives are resolved at load time (regardless
; of their textual position relative to runtime statements), so this could
; not be caught by a runtime call — only source inspection of the exact
; directive text works here.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_PSCIP_CheckCompiledIncludeUsesRealEnvVar() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	Assert(!InStr(Src, "%A_LocalAppData%"),
		"ErgoptiPlus.ahk must not reference %A_LocalAppData% in a #Include directive — "
		. "it is not a recognised #Include substitution token nor a real environment "
		. "variable, so the personal-shortcuts stub silently never loads in the compiled exe")

	Assert(InStr(Src, "#Include *i %LocalAppData%\Ergopti\_generated\personal_shortcuts.ahk"),
		"ErgoptiPlus.ahk must #Include the compiled-mode personal-shortcuts stub via "
		. "%LocalAppData% — matching the path EnsurePersonalShortcutsFile() actually writes to")
}

Test("meta personal-shortcuts: compiled-mode #Include uses the real %LocalAppData% env var",
	_PSCIP_CheckCompiledIncludeUsesRealEnvVar)

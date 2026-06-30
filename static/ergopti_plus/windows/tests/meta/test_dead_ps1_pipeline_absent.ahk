; tests/meta/test_dead_ps1_pipeline_absent.ahk

; ==============================================================================
; MODULE: Dead PS1 Output Pipeline Absent Meta Test
; DESCRIPTION:
; Regression guard for AHK-29: after the winget refactor replaced the
; hidden-PS1 installer, five functions that parsed the PS1 stdout file and
; drove the now-removed WebView2 progress window remained in
; ollama_deps_checker.ahk as unreachable dead code (rule 5.6 violation).
;
; Dead code removed by the AHK-29 fix:
;   - LLM_Deps_PollFile          — polled the PS1 stdout file; no callers.
;   - _LLM_Deps_OnPs1Exit_Result — PS1 exit callback; only called from PollFile.
;   - LLM_Deps_DrainOutputFile   — file tail helper; only called from PollFile.
;   - LLM_Deps_HandleLine        — PS1 line router; only called from DrainOutputFile.
;   - LLM_Deps_TryParseProgress  — "ollama pull" progress parser; only called
;                                   from HandleLine.
;   - LLM_Deps_OnUserCancel      — cancel handler registered via OllamaWV_Show,
;                                   which is no longer called; no active callers.
;
; Live OllamaWV_* calls also removed from reachable functions (the install no
; longer drives a WebView2 window):
;   - OllamaWV_IsAlive / OllamaWV_Close from _LLM_Deps_DoCheck_Result.
;   - OllamaWV_Close from _LLM_Deps_OnPollProbeResult.
;   - OllamaWV_SetError / OllamaWV_Done from LLM_Deps_Fail.
;
; This test asserts (source introspection on ollama_deps_checker.ahk):
;   (a) All six dead functions are absent.
;   (b) OllamaWV_SetError and OllamaWV_Done no longer appear — they were only
;       referenced inside the now-removed dead functions and LLM_Deps_Fail.
;   (c) LLM_Deps_Fail, LLM_Deps_Cancel, and LLM_Deps_DoCheck are still present
;       (active code must not be removed).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TDPPA_CheckDeadPipelineAbsent() {
	Src := ""
	SrcPath := A_ScriptDir . "\..\modules\llm\ollama_deps_checker.ahk"
	try Src := FileRead(SrcPath, "UTF-8")
	Assert(Src != "", "ollama_deps_checker.ahk must be readable at " . SrcPath)

	; (a) Dead functions must be absent
	Assert(!InStr(Src, "LLM_Deps_PollFile("),
		"AHK-29: LLM_Deps_PollFile must be absent from ollama_deps_checker.ahk — it was the PS1-output polling callback, unreachable since the winget refactor replaced the hidden-PS1 installer")
	Assert(!InStr(Src, "_LLM_Deps_OnPs1Exit_Result("),
		"AHK-29: _LLM_Deps_OnPs1Exit_Result must be absent — it was only called from LLM_Deps_PollFile (now removed)")
	Assert(!InStr(Src, "LLM_Deps_DrainOutputFile("),
		"AHK-29: LLM_Deps_DrainOutputFile must be absent — it was the PS1 file-tail helper, only called from LLM_Deps_PollFile (now removed)")
	Assert(!InStr(Src, "LLM_Deps_HandleLine("),
		"AHK-29: LLM_Deps_HandleLine must be absent — it routed PS1 output to WebView2, only called from DrainOutputFile (now removed)")
	Assert(!InStr(Src, "LLM_Deps_TryParseProgress("),
		"AHK-29: LLM_Deps_TryParseProgress must be absent — it parsed ollama pull progress lines for the WebView2 window, only called from HandleLine (now removed)")
	Assert(!InStr(Src, "LLM_Deps_OnUserCancel("),
		"AHK-29: LLM_Deps_OnUserCancel must be absent — it was registered as the WebView2 cancel callback; with OllamaWV_Show no longer called there are no active callers (rule 5.6)")

	; (b) Dead WebView2 progress calls removed from reachable functions
	Assert(!InStr(Src, "OllamaWV_SetError"),
		"AHK-29: OllamaWV_SetError must be absent from ollama_deps_checker.ahk — the install no longer drives a WebView2 window, so this call in LLM_Deps_Fail was dead output")
	Assert(!InStr(Src, "OllamaWV_Done"),
		"AHK-29: OllamaWV_Done must be absent — it was only called from LLM_Deps_Fail and the removed _LLM_Deps_OnPs1Exit_Result")

	; (c) Active functions must still be present
	Assert(InStr(Src, "LLM_Deps_Fail("),
		"AHK-29: LLM_Deps_Fail must still exist — it is still called from LLM_Deps_RunInstaller and LLM_Deps_DoCheck paths")
	Assert(InStr(Src, "LLM_Deps_Cancel("),
		"AHK-29: LLM_Deps_Cancel must still exist — it is called from actions.ahk and LLM_Deps_CheckAndInstall")
	Assert(InStr(Src, "LLM_Deps_DoCheck("),
		"AHK-29: LLM_Deps_DoCheck must still exist — it is the async reachability-check entry point")
}


Test("meta ahk-29: dead PS1-output-pipeline functions absent from ollama_deps_checker.ahk after winget refactor",
	_TDPPA_CheckDeadPipelineAbsent)

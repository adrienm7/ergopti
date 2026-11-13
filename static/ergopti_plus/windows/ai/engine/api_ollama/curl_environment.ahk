; ai/engine/api_ollama/curl_environment.ahk

; ==============================================================================
; MODULE: Curl Child Environment
; DESCRIPTION:
; Builds a private Unicode environment for native curl command launches without
; mutating parent variables or exposing literal paths to shell expansion.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLM_CurlBuildEnvironment(Overrides) {
	return ShellRunner_BuildEnvironment(Overrides)
}

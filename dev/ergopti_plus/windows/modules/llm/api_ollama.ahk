; modules/llm/api_ollama.ahk

; ==============================================================================
; MODULE: Ollama API — Redirect Shim
; DESCRIPTION:
; Compatibility shim: the Ollama API implementation has been split into
; sub-files under api_ollama/. This file simply forwards the include so all
; existing callers (#Include modules/llm/api_ollama.ahk) need no changes.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include api_ollama/init.ahk
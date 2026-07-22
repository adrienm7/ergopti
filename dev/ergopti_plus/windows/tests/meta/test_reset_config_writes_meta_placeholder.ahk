; tests/meta/test_reset_config_writes_meta_placeholder.ahk

; ==============================================================================
; MODULE: Reset-Config Meta Placeholder Guard Meta Test
; DESCRIPTION:
; Static source guards for the "reset to defaults" -> onboarding interaction. The
; tray item menu.global.reset_defaults calls ReloadWithDefaultConfig (lib/
; config_io.ahk), which deletes config.toml and Reloads. On the next boot
; Onboarding_Run() (ui/onboarding/core.ahk) gates the first-run wizard purely on
; FileExist(ConfigurationFile), preferring the shared WebView2 host
; (_Onboarding_TryWeb, ui/onboarding/webview.ahk) with the native pages as a
; fallback. A bare delete of config.toml would therefore re-launch the wizard
; unconditionally, which is NOT what "reset to defaults" means -- a separate
; "Setup wizard" tray item re-runs the first-run flow on demand. The fix writes a
; minimal "[_meta]" placeholder config.toml AFTER the delete and BEFORE the
; Reload so the gate stays satisfied and the wizard stays closed.
;
; ROOT CAUSES ENCODED:
;   1. ReloadWithDefaultConfig must write the "[_meta]" schema_version
;      placeholder, after deleting the config files and before Reload, so a reset
;      does not silently re-trigger onboarding.
;   2. Onboarding_Run must gate the WebView2 wizard on
;      FileExist(ConfigurationFile) and return before _Onboarding_TryWeb -- the
;      invariant the placeholder relies on.
;
; SCOPE: source introspection only -- exercising a real reset needs a live driver
; boot and a WebView2 runtime unavailable in the headless harness (same rationale
; as tests/meta/test_onbweb_singleton_guard.ahk).
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================================
; =======================================================
; ======= 1/ Reset writes the [_meta] placeholder =======
; =======================================================
; =======================================================

_RCMP_ReloadBody() {
	return _DriverFuncBody("ReloadWithDefaultConfig")
}

_RCMP_WritesMetaPlaceholder() {
	Body := _RCMP_ReloadBody()
	Assert(Body != "", "ReloadWithDefaultConfig must be defined in lib/config_io.ahk")

	Assert(InStr(Body, "FileDelete(") > 0,
		"ReloadWithDefaultConfig must delete the stale config files on reset")

	Assert(InStr(Body, "[_meta]") > 0,
		"ReloadWithDefaultConfig must write a '[_meta]' placeholder so Onboarding_Run's FileExist(ConfigurationFile) gate stays satisfied and the first-run wizard stays closed after a reset")

	Assert(InStr(Body, "schema_version") > 0,
		"the '[_meta]' placeholder must carry a schema_version so the reloaded config parses as a valid v2 config instead of an empty stub")
}
Test("reset_config: ReloadWithDefaultConfig writes a [_meta] placeholder config", _RCMP_WritesMetaPlaceholder)


_RCMP_PlaceholderAfterDeleteBeforeReload() {
	Body := _RCMP_ReloadBody()
	Assert(Body != "", "ReloadWithDefaultConfig must be defined in lib/config_io.ahk")

	IdxDelete := InStr(Body, "FileDelete(")
	IdxMeta   := InStr(Body, "[_meta]")
	; The function is literally named ReloadWithDefaultConfig, so a bare "Reload"
	; also matches its own signature at position 1 -- search for the trailing
	; Reload statement starting AFTER the placeholder write instead
	IdxReload := InStr(Body, "Reload", , IdxMeta)

	Assert(IdxDelete > 0 and IdxMeta > 0 and IdxReload > 0 and IdxDelete < IdxMeta and IdxMeta < IdxReload,
		"ReloadWithDefaultConfig must write the '[_meta]' placeholder AFTER FileDelete and BEFORE Reload -- writing it before the delete would be clobbered, and a missing or late write lets the deleted config.toml re-trigger the onboarding wizard")
}
Test("reset_config: the [_meta] placeholder is written after the delete and before Reload", _RCMP_PlaceholderAfterDeleteBeforeReload)





; ==============================================
; ==============================================
; ======= 2/ Onboarding config-file gate =======
; ==============================================
; ==============================================

_RCMP_OnboardingGatesOnConfigFile() {
	Body := _DriverFuncBody("Onboarding_Run")
	Assert(Body != "", "Onboarding_Run must be defined in ui/onboarding/core.ahk")

	Assert(InStr(Body, "FileExist(ConfigurationFile)") > 0,
		"Onboarding_Run must gate the first-run wizard on FileExist(ConfigurationFile) -- this is the invariant ReloadWithDefaultConfig's '[_meta]' placeholder relies on to keep the WebView2 wizard closed after a reset")

	IdxGate   := InStr(Body, "FileExist(ConfigurationFile)")
	IdxReturn := InStr(Body, "return", , IdxGate)
	IdxTryWeb := InStr(Body, "_Onboarding_TryWeb")
	Assert(IdxGate > 0 and IdxReturn > 0 and IdxTryWeb > 0 and IdxReturn < IdxTryWeb,
		"Onboarding_Run must return from the FileExist(ConfigurationFile) gate BEFORE reaching _Onboarding_TryWeb -- otherwise the placeholder written on reset would not stop the WebView2 wizard from launching")
}
Test("reset_config: Onboarding_Run gates the WebView2 wizard on FileExist(ConfigurationFile)", _RCMP_OnboardingGatesOnConfigFile)

; platform/remap/nav_layer.ahk
; Requires: TextSender, platform/remap/nav_layer_table.ahk

; ==============================================================================
; MODULE: Tap-Holds — Navigation Layer
; DESCRIPTION:
; The layer the configured hold key enters. What each key does there is data:
; the user's layers.toml in the configuration folder, registered at boot by
; platform/remap/nav_layer_table.ahk as one hotkey per bound key under the
; LayerEnabled gate. Without a layers.toml nothing is bound and every key keeps
; its normal behaviour while the layer is held; Ergopti's own layer is
; _shared/keymap/layers.recommended.toml, which reaches layers.toml through the
; first-run wizard or "Restore recommended values".
;
; What stays here is the code no binding can express: how a hold key ENTERS the
; layer. Those fixes are static hotkeys, created when the script loads and so
; before the table's variants: AutoHotkey fires the earliest-created eligible
; variant, so each fix wins over whatever layers.toml binds on the same key.
; ==============================================================================

#Requires AutoHotkey v2.0

; Raise the per-interval hotkey limit once at load time so rapid wheel events
; never trigger the "too many hotkeys" warning before the first WheelUp/Down
; fires. Single-sourced from infra/nav_layer_helpers.ahk (loaded earlier, see
; ErgoptiPlus.ahk's #Include order) so ActivateLayer/DisableLayer restore
; this exact same ceiling instead of drifting to a different hardcoded number.
A_MaxHotkeysPerInterval := NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL





; ==========================================
; ==========================================
; ======= 1/ Entering the layer ============
; ==========================================
; ==========================================

; ActivateLayer, DisableLayer, ResetNumberOfRepetitions, SetNumberOfRepetitions,
; and ActionLayer are defined in infra/nav_layer_helpers.ahk and loaded globally.

; Fix when LAlt triggers the layer
#HotIf (
		_LAltIsBackspaceLayer()
		and LayerEnabled
)
*SC038:: TapHoldSyntheticKeyUp("LAlt") ; Necessary to do this, otherwise multicursor trigger in VSCode when scrolling in the layer and then leaving it
#HotIf





; ==========================================
; ==========================================
; ======= 2/ The layer's bindings ==========
; ==========================================
; ==========================================

; Registered here, at this file's #Include position: after the layout
; emulation and the shortcuts have created their own variants. None of those
; can compete with the layer — the emulation's plain remaps are global variants
; (always the lowest precedence) and its CapsLock layer excludes LayerEnabled.
NavLayer_Init(_SharedDir, _ConfigDir)

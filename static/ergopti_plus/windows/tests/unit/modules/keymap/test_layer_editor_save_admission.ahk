; tests/unit/modules/keymap/test_layer_editor_save_admission.ahk

; ==============================================================================
; MODULE: Layer Editor Save Admission Tests
; DESCRIPTION:
; The public host opens in the existing isolated native readiness child. Its
; genuine init offers the retained file before the registered SDK callback and
; actual message timer can save it. A real START logger admits the same native
; timer/pause cutpoint; only apply/reload is passive. No opening receipt,
; writer, source policy or dispatcher is fabricated.
; ==============================================================================

_LESA_Case(Mode) {
	return _LRDT_Case("save-admission-" . Mode)
}

for _LESA_Mode in ["pause-during", "already-paused", "live"]
	Test("Layer editor save: " . _LESA_Mode . " respects native admission (layer-editor-save-admission)",
		_LESA_Case.Bind(_LESA_Mode))

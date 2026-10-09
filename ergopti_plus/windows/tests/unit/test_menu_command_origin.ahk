; tests/unit/test_menu_command_origin.ahk

; ==============================================================================
; MODULE: Menu Command Origin Regression Tests
; DESCRIPTION:
; Proves a BN_CLICKED notification cannot enter the menu retry path even when
; its LOWORD identifier is identical to a registered menu command identifier.
; ==============================================================================

#Requires AutoHotkey v2.0+





; ===========================================
; ===========================================
; ======= 1/ Forced identifier collision ====
; ===========================================
; ===========================================

_MCO_ForcedControlIdCollision() {
	Fixture := Gui()
	try {
		Button := Fixture.AddButton(, "Collision fixture")
		ControlId := DllCall("GetDlgCtrlID", "Ptr", Button.Hwnd, "Int")
		Assert(ControlId > 0, "the integration fixture must own a native control identifier")

		MenuWParam := ControlId
		ClickedWParam := ControlId | (0 << 16) ; BN_CLICKED = 0.
		AssertEqual(true, MenuCommandOrigin_IsMenuSelection(MenuWParam, 0),
			"the registered LOWORD with lParam zero must remain a menu command")
		AssertEqual(false, MenuCommandOrigin_IsMenuSelection(ClickedWParam, Button.Hwnd),
			"the identical LOWORD with a control HWND must not dispatch as a menu command")
	} finally {
		Fixture.Destroy()
	}
}

_MCO_AcceleratorIsNotMenuSelection() {
	AcceleratorWParam := 11003 | (1 << 16)
	AssertEqual(false, MenuCommandOrigin_IsMenuSelection(AcceleratorWParam, 0),
		"an accelerator notification must remain outside the menu retry path")
}

Test("menu command origin: BN_CLICKED cannot impersonate a colliding menu ID (ahk-044)",
	_MCO_ForcedControlIdCollision)
Test("menu command origin: accelerator remains outside menu retry path (ahk-044)",
	_MCO_AcceleratorIsNotMenuSelection)

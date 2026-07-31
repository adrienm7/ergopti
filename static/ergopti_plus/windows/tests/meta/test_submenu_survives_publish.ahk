; tests/meta/test_submenu_survives_publish.ahk

; ==============================================================================
; MODULE: Submenu Registration Survival Meta Test
; DESCRIPTION:
; TrayMenuStage_Publish states its intent in its own comment: "Invalidate retries
; for the retired tree, but RETAIN dispatcher entries for detached child menus
; that were registered during staging." A_TrayMenu.Delete() clears only the top
; level; child Menu objects survive with their native IDs, and
; MenuDispatcher_BeginReplacement deliberately does NOT clear the token maps.
;
; The registration-time epoch check in _TrackedDispatch contradicted all of that.
; Submenu items are registered BEFORE the bump — RebuildTrayMenu calls
; InitSubMenus, then initMenu reaches Publish — and initMenu is also called ALONE
; from the updater's tray refresh (modules/updater/core.ahk) and from lifecycle. So
; every submenu item sat at the previous epoch and had its native dispatch
; rejected.
;
; The symptom was not a dead menu. The 60 ms retry rescued each click, so the
; real damage was to the diagnostics: every submenu click paid that delay AND
; logged "AHK drop detected", which is the one signal this module exists to
; produce. A genuine AHK drop became indistinguishable from an epoch-fenced
; no-op — the module was lying about the exact thing it was built to measure.
;
; FEATURES & RATIONALE:
; 1. Pins the INTENT (child registrations survive a publish) rather than any one
;    mechanism, so a future fence cannot quietly reintroduce the rejection.
; 2. Pins that the epoch is still used where it IS meaningful — in the retry
;    path, where it is captured at click time and correctly voids a retry that
;    spans a rebuild. Removing it there would be a different regression.
;
; SCOPE: source introspection of lib/menu_dispatcher.ahk and ui/menu/menu_rebuild.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ Child registrations survive ==========
; =================================================
; =================================================

_SSP_PublishRetainsChildRegistrations() {
	Publish := _DriverFuncBody("TrayMenuStage_Publish")
	Assert(Publish != "", "TrayMenuStage_Publish() must exist")

	; The token maps must NOT be cleared on a publish — that retention is the
	; whole basis for child menus continuing to work.
	Assert(InStr(Publish, "MenuDispatcher_BeginReplacement()") > 0,
		"the publish must still invalidate retries for the retired tree")

	Begin := _DriverFuncBody("MenuDispatcher_BeginReplacement")
	Assert(Begin != "", "MenuDispatcher_BeginReplacement() must exist")
	Assert(InStr(Begin, "_MenuDispatchTokens") == 0,
		"BeginReplacement must NOT clear the dispatcher token map — detached child menus keep their native IDs across a publish, and clearing it would make every submenu item a native-dispatch-only entry")
}

; The dispatch fence may not reject a registration merely for predating the
; current epoch. Submenu items always predate it.
_SSP_DispatchDoesNotFenceOnRegistrationEpoch() {
	Body := _DriverFuncBody("_TrackedDispatch")
	Assert(Body != "", "_TrackedDispatch() must exist")

	Assert(InStr(Body, "_MenuDispatchTokens[TrackedObj.ItemId] = TrackedObj.Token") > 0,
		"the fence must compare the registration token — that is what stops a stale callback mutating a newer registration")
	Assert(InStr(Body, "TrackedObj.Epoch = _MenuDispatcherEpoch") == 0,
		"the fence must NOT compare the registration-time epoch: every submenu item is registered before the publish bump, so this rejects it, downgrades the click to the 60 ms retry, and makes the retry log a false 'AHK drop detected' on every single submenu click")
}

; The epoch is still correct where it is captured at CLICK time. Removing it
; there would let a retry fire against a tree that has since been rebuilt.
_SSP_RetryPathKeepsItsEpoch() {
	Body := _DriverFuncBody("_DispatchIfMissed")
	Assert(Body != "", "_DispatchIfMissed() must exist")
	Assert(InStr(Body, "ExpectedEpoch != _MenuDispatcherEpoch") > 0,
		"the retry path must keep its epoch check — unlike the registration-time one it is captured when the click happens, so it correctly voids a retry that spans a rebuild")
}


Test("meta menu: a publish retains detached child-menu registrations",
	_SSP_PublishRetainsChildRegistrations)
Test("meta menu: native dispatch is not fenced on the registration epoch",
	_SSP_DispatchDoesNotFenceOnRegistrationEpoch)
Test("meta menu: the retry path keeps its click-time epoch check",
	_SSP_RetryPathKeepsItsEpoch)

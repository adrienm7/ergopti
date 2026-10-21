; tests/unit/platform/network/test_managed_render_timer_lifetime.ahk

; ==============================================================================
; MODULE: Managed Failure Render Callback Lifetime
; DESCRIPTION:
; Retired rendering work can remain externally readable without retaining its
; old window through a self-bound acknowledgement timer. Cancellation failures
; must not restore that retired callback graph.
; ==============================================================================

#Requires AutoHotkey v2.0

class _MRT_LifetimeWindow extends ManagedDownloadFailureWindow {
	__New(Receipt) {
		this.Receipt := Receipt
	}
	__Delete() {
		this.Receipt["released"] += 1
	}
}

_MRT_RefuseCancellation(*) {
	throw Error("Controlled rendering timer cancellation refusal")
}

_MRT_RetiredWorkReleasesWindow(FinishClose, RefuseCancellation := false) {
	Receipt := Map("released", 0)
	Host := _MRT_LifetimeWindow(Receipt)
	Work := {}
	Work.ack_timer := Host._RenderAcknowledgementExpired.Bind(Host, Work)
	Host.RenderWork := Work
	if RefuseCancellation
		Host.TimerFn := _MRT_RefuseCancellation
	else
		SetTimer(Work.ack_timer, -60000)
	if FinishClose {
		Host.RenderWork := 0
		Host._FinishClose({ work: Work, closed_fn: 0, building: false, gui: 0 })
	} else {
		AssertEqual(!RefuseCancellation, Host._CancelRenderAcknowledgement())
		AssertEqual(0, Host.RenderWork)
	}
	Host := 0
	AssertEqual(1, Receipt["released"], "retaining an old work receipt must not retain its window")
	AssertFalse(Work.HasOwnProp("ack_timer"), "retired work must not retain a callback back to its host")
}
Test("managed rendering: acknowledgement cancellation releases the old window (managed-render-timer-release)",
	_MRT_RetiredWorkReleasesWindow.Bind(false))
Test("managed rendering: window closure releases its detached work callback (managed-render-timer-release)",
	_MRT_RetiredWorkReleasesWindow.Bind(true))
Test("managed rendering: cancellation refusal leaves no self-bound callback (managed-render-timer-release)",
	_MRT_RetiredWorkReleasesWindow.Bind(false, true))

; tests/unit/ui/webview/test_webview_core_identity.ahk

; ==============================================================================
; MODULE: WebView Core Identity Controls
; DESCRIPTION:
; Exact retained passive views keep their original admission contract. Distinct
; plain objects cannot borrow COM authority through copied pointers or URLs.
; Actual same/different native Core coverage belongs to the sender fixtures.
; ==============================================================================

#Requires AutoHotkey v2.0

class _WVCI_Probe {
	Reads := 0
	Ptr {
		get {
			this.Reads += 1
			throw Error("A plain object's native pointer must never be queried.")
		}
	}
	Source {
		get {
			this.Reads += 1
			return "https://same.invalid/"
		}
	}
}

_WVCI_ExactView() {
	View := _WVCI_Probe()
	AssertTrue(WebView_SameCore(View, View), "the exact admitted passive view remains usable")
	AssertEqual(0, View.Reads, "a passive view's properties cannot grant COM authority")
}

_WVCI_DistinctViews() {
	Sender := _WVCI_Probe(), Expected := _WVCI_Probe()
	AssertFalse(WebView_SameCore(Sender, Expected))
	AssertEqual(0, Sender.Reads + Expected.Reads,
		"distinct non-Core objects must be refused before touching native-looking properties")
}

_WVCI_CopiedPointer() {
	Sender := {Ptr: 1, Source: "https://same.invalid/"}
	Expected := {Ptr: 1, Source: Sender.Source}
	AssertFalse(WebView_SameCore(Sender, Expected),
		"copied pointers and matching URLs cannot replace a real vendor Core identity")
}

_WVCI_NonObjects() {
	for Value in [0, 1, "", "same"]
		AssertFalse(WebView_SameCore(Value, Value), "equal scalar values cannot be a browser")
}

_WVCI_MixedValues() {
	View := _WVCI_Probe()
	AssertFalse(WebView_SameCore(View, 0))
	AssertFalse(WebView_SameCore(0, View))
	AssertEqual(0, View.Reads)
}

Test("WebView identity: exact retained passive view remains admitted (webview-core-identity)", _WVCI_ExactView)
Test("WebView identity: distinct passive views are refused before property access (webview-core-identity)", _WVCI_DistinctViews)
Test("WebView identity: copied raw pointer and URL do not grant native authority (webview-core-identity)", _WVCI_CopiedPointer)
Test("WebView identity: equal nonobjects never identify a browser (webview-core-identity)", _WVCI_NonObjects)
Test("WebView identity: mixed object and scalar values are refused (webview-core-identity)", _WVCI_MixedValues)

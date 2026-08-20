; static/ergopti_plus/windows/tests/meta/test_audit_2026_07_20_batch4.ahk

; ==============================================================================
; MODULE: Audit 2026-07-20 (second pass) — F-14, F-15, F-16, F-17, F-24, F-31
; DESCRIPTION:
; F-14  PrefixWatcherSuppress never touched HSE_Suppressed, though four comments
;       in hotstring_dispatch.ahk state it holds BOTH counters. HSE_Suppressed
;       therefore sat permanently at 0 and three guards built on it were inert.
;       It cost nothing on the OnChar path (which feeds IsPhysical := true and
;       bypasses the check), but left a removed safety net reading as present
;       for any caller dispatching from OUTSIDE the InputHook.
; F-15  _SaveGlobalKey used a bare `try` with no catch, no Close and no return,
;       so a read-only or cloud-locked config file made every observable signal
;       say "saved" while the setting silently reverted at next boot.
; F-16  _MG_LoadSubCategories re-read and re-parsed a 12.5 KB manifest on every
;       call, including on the live-toggle path that F-01 runs under Critical.
; F-17  TOOLTIP_POSITION_CACHE_MS (150) was SHORTER than the combined debounce
;       gating the preview path (150 + 75 = ~225 ms), so the cache was always
;       past its expiry when consulted and never hit — every preview render in a
;       caret-less app paid a fresh out-of-proc UIA COM round-trip.
; F-24  The metrics dashboard navigated to file://, an opaque origin from which
;       window.chrome.webview does not reliably deliver. postMessage returned
;       undefined (so the page looked healthy) while nothing arrived host-side:
;       every interactive control was dead and the loader spun forever.
; F-31  TapHoldDuration returned the raw TOML value straight into a KeyWait
;       option string; a non-numeric entry produced "Tabc" and KeyWait THREW on
;       the hook thread, with a synthetic modifier already armed.
; ==============================================================================

#Requires AutoHotkey v2.0

; F-14 RESOLUTION, corrected by the suite. The audit offered two options:
; make the delegation real, or delete the dead guards and the comments claiming
; it. Attempting the first turned test_hse_physical_input_provenance red — that
; test asserts the delegation is ABSENT, because the two counters are separate
; ON PURPOSE: the engine window filters the engine's own SendInput output, and
; physical input declares itself with IsPhysical=true instead (F46). Delegating
; would drop a physical character typed inside a nearby output transaction.
;
; So the correct resolution was the second option, and what remains to pin is
; that the separation is DOCUMENTED where a reader will meet it, rather than
; contradicted. The behavioural half is already pinned by the provenance test;
; this asserts the explanation sits next to the code.
_A0720B4_SuppressSeparationIsDocumented() {
	Body := _DriverFuncBody("PrefixWatcherSuppress")
	Assert(Body != "", "PrefixWatcherSuppress must exist in infra/hotstrings/hotstring_inputhook.ahk")
	Assert(InStr(Body, "HSE_Suppress(YesNo)") = 0,
		"PrefixWatcherSuppress must NOT delegate to HSE_Suppress — the render guard and the engine suppression window are deliberately separate, and delegating drops physical input typed near an output transaction (F46)")
}
Test("hotstrings: the render guard stays separate from engine suppression (F-14)",
	_A0720B4_SuppressSeparationIsDocumented)


_A0720B4_GlobalKeyWriteFailureIsSurfaced() {
	Body := _DriverFuncBody("_SaveGlobalKey")
	Assert(Body != "", "_SaveGlobalKey must exist in infra/hotstrings/hotstrings_io.ahk")
	Assert(InStr(Body, "HotstringsSetWordDelimiters(") > 0
		and InStr(Body, "HotstringsSetConsumedDelimiters(") > 0,
		"_SaveGlobalKey must delegate both historical keys to the shared delimiter transaction instead of retaining a second writer")
	Assert(InStr(Body, "FileOpen(") = 0,
		"_SaveGlobalKey must not truncate the live override file; the whole-file serializer owns the one staged atomic replacement")
	Transaction := _DriverFuncBody("HotstringsCommitDelimiterUpdate")
	Assert(Transaction != "", "HotstringsCommitDelimiterUpdate must exist")
	LeasePos := InStr(Transaction, "_HotstringsOverrideLeaseAcquire(")
	BuildPos := InStr(Transaction, "BuildFn.Call(")
	WritePos := InStr(Transaction, "_SaveOverrides(")
	PublishPos := InStr(Transaction, "_HotstringsPublishDelimiterCandidate.Bind(")
	Assert(LeasePos > 0 and BuildPos > LeasePos and WritePos > BuildPos
		and PublishPos > WritePos,
		"delimiter writes must acquire before candidate construction and hand detached live publication to the atomic whole-file writer")
	Writer := _DriverFuncBody("_SaveOverrides")
	Assert(Writer != "", "_SaveOverrides must exist")
	AuthorizePos := InStr(Writer, "AuthorizeFn.Call()")
	ReplacePos := InStr(Writer, "FSAtomicMoveReplace(")
	PublishCallPos := InStr(Writer, "PublishFn.Call()")
	Assert(AuthorizePos > 0 and ReplacePos > AuthorizePos
		and PublishCallPos > ReplacePos,
		"the complete stage must be re-authorized, atomically replaced, and projected live in that order")
	Publisher := _DriverFuncBody("_HotstringsPublishDelimiterCandidate")
	Assert(Publisher != ""
		and InStr(Publisher, "_HotstringsWordDelimiters :=") > 0
		and InStr(Publisher, "_HotstringsConsumedDelimiters :=") > 0,
		"one publisher must project both delimiter caches together")
}
Test("hotstrings: global-key writes share the admitted atomic transaction (F-15)", _A0720B4_GlobalKeyWriteFailureIsSurfaced)


; F-16 RESOLUTION, also corrected by the suite. Memoizing the manifest read was
; tried and reverted: it defeats the fail-fast contract that an INVALID canonical
; manifest must throw on every call, which test_master_gates.ahk pins. The
; re-read was only harmful because ToggleCategoryAllFeatures ran it under
; Critical — and F-01 removed that Critical span, so the cost no longer sits on
; the keyboard-hook starvation path. Correctness beat the micro-optimisation.
_A0720B4_SubCategoryManifestStaysFailFast() {
	Body := _DriverFuncBody("_MG_LoadSubCategories")
	Assert(Body != "", "_MG_LoadSubCategories must exist in infra/master_gates.ahk")
	Assert(InStr(Body, "static _Cache") = 0,
		"_MG_LoadSubCategories must NOT memoize its parsed result — an invalid canonical manifest has to fail fast on every call, and a cache would return the last good value instead of throwing")

	; The reason the cache is unnecessary: the read is no longer on a Critical path.
	Toggle := _DriverFuncBody("ToggleCategoryAllFeatures")
	if (Toggle != "") {
		RelPos := InStr(Toggle, "Critical(_TcafCrit)")
		GatesPos := InStr(Toggle, "ApplyMasterGatesToFeatures(")
		Assert(RelPos > 0 and GatesPos > 0 and GatesPos < RelPos,
			"the master-gate application must stay inside the (short, in-memory) Critical window while the rebuild that follows runs outside it — that is what makes an uncached manifest read affordable here (F-01)")
	}
}
Test("master-gates: the sub-category manifest stays fail-fast, uncached (F-16)",
	_A0720B4_SubCategoryManifestStaysFailFast)


; Root cause: a cache TTL shorter than the minimum interval between two
; consultations is dead code. Derives all three constants from source so a future
; debounce change re-checks the relationship instead of silently breaking it.
_A0720B4_PositionCacheOutlivesTheDebounce() {
	Src := _DriverSourceNoComments()
	Get(Name) {
		Assert(RegExMatch(Src, Name . "\s*:=\s*(\d+)", &M) > 0, Name . " must be a numeric global")
		return M[1] + 0
	}
	CacheMs   := Get("TOOLTIP_POSITION_CACHE_MS")
	PrefixMs  := Get("_PREFIX_RENDER_DEBOUNCE_MS")
	RenderMs  := Get("TOOLTIP_RENDER_DEBOUNCE_MS")

	Assert(CacheMs > PrefixMs + RenderMs,
		"TOOLTIP_POSITION_CACHE_MS (" . CacheMs . ") must EXCEED the combined debounce gating the preview path (_PREFIX_RENDER_DEBOUNCE_MS " . PrefixMs . " + TOOLTIP_RENDER_DEBOUNCE_MS " . RenderMs . "). Otherwise the cache is always past its expiry when consulted and never hits, so every preview render in a caret-less app pays a fresh unbounded out-of-proc UIA COM round-trip on the thread that serves the keyboard hook")
}
Test("tooltip: the position cache outlives the debounce that gates it (F-17)",
	_A0720B4_PositionCacheOutlivesTheDebounce)


_A0720B4_DashboardUsesAVirtualHost() {
	Body := _DriverFuncBody("KLWV_AssetUrl")
	Assert(Body != "", "KLWV_AssetUrl must exist in modules/keylogger/keylogger_webview.ahk")
	Assert(InStr(Body, "file:///") = 0,
		"KLWV_AssetUrl must not serve the dashboard from file:// — Chromium treats every file:// document as a unique opaque origin, so window.chrome.webview does not reliably deliver: postMessage returns undefined and the page looks healthy while nothing arrives host-side, leaving every interactive control dead")
	Assert(InStr(Body, "https://") > 0,
		"KLWV_AssetUrl must serve the dashboard over the virtual host")

	Loc := _DriverFuncBody("KLWV_LocalesUrl")
	Assert(Loc != "" and InStr(Loc, "file:///") = 0,
		"KLWV_LocalesUrl must use the same virtual host — a file:// locales fetch hits the same opaque-origin restriction")

	Open := _DriverFuncBody("KLWV_Open")
	Assert(Open != "", "KLWV_Open must exist")
	MapPos := InStr(Open, "SetVirtualHostNameToFolderMapping")
	NavPos := InStr(Open, "webview.Navigate(")
	Assert(MapPos > 0, "KLWV_Open must map the virtual host")
	Assert(NavPos > 0 and MapPos < NavPos,
		"the virtual-host mapping must be installed BEFORE Navigate — the mapping has to exist when the document is created or the https:// URL cannot resolve")
}
Test("keylogger-webview: the dashboard is served from a virtual host (F-24)",
	_A0720B4_DashboardUsesAVirtualHost)


_A0720B4_TapHoldDurationIsValidated() {
	Body := _DriverFuncBody("TapHoldDuration")
	Assert(Body != "", "TapHoldDuration must exist in platform/remap/tap_hold_loader.ahk")
	Assert(InStr(Body, "IsNumber(") > 0,
		"TapHoldDuration must type-check the TOML value: it is concatenated into a KeyWait option string, so a non-numeric entry produces an invalid timeout and KeyWait THROWS on the hook thread with a synthetic modifier already armed")
	Assert(InStr(Body, "TAPHOLD_MAX_ACTIVATION_SECONDS") > 0,
		"TapHoldDuration must range-check against a named upper bound, not just reject non-numbers")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"an invalid tap-hold duration must be logged, not silently coerced — the failure was invisible precisely because the throw was absorbed by the global error net")
}
Test("tap-holds: the activation time is validated at the loader boundary (F-31)",
	_A0720B4_TapHoldDurationIsValidated)


; F-32: the safety flush must be the SAME work as the real ready handler. It
; latched _LLM_MBW_Ready while skipping the catalogue injection, so once it ran
; no later message could re-trigger it and the model table stayed empty forever.
_A0720B4_SafetyFlushMatchesReadyHandler() {
	Flush := _DriverFuncBody("_LLM_MBW_SafetyFlush")
	Assert(Flush != "", "_LLM_MBW_SafetyFlush must exist in ui/model_browser/init.ahk")
	Assert(InStr(Flush, "_LLM_MBW_OnPageReady()") > 0,
		"_LLM_MBW_SafetyFlush must route through the shared _LLM_MBW_OnPageReady() rather than re-implementing part of it — it previously flushed the queue but skipped _LLM_MBW_InjectCatalogue while still latching Ready, leaving the model table permanently empty")

	Ready := _DriverFuncBody("_LLM_MBW_OnPageReady")
	Assert(Ready != "", "_LLM_MBW_OnPageReady must exist as the single definition of page-up")
	Assert(InStr(Ready, "_LLM_MBW_FlushQueue()") > 0 and InStr(Ready, "_LLM_MBW_InjectCatalogue()") > 0,
		"_LLM_MBW_OnPageReady must both flush the queue AND inject the catalogue")

	Handler := _DriverFuncBody("_LLM_MBW_OnWebMessage")
	ReadyPos := InStr(Handler, "_LLM_MBW_OnPageReady()")
	GuardPos := InStr(Handler, "A_IsSuspended")
	Assert(ReadyPos > 0 and GuardPos > 0 and ReadyPos < GuardPos,
		"the `ready` page-lifecycle signal must be handled BEFORE the suspend guard — gating it is what made the SafetyFlush fallback reachable in the first place")
}
Test("model-browser: the safety flush does the same work as ready (F-32)",
	_A0720B4_SafetyFlushMatchesReadyHandler)

; tests/meta/test_tooltip_position_cache_receipt_wiring.ahk

#Requires AutoHotkey v2.0+

_TPCRW_ResolverUsesEnvironmentReceipt() {
	Resolver := _DriverFuncBody("_TooltipResolvePosition")
	Assert(Resolver != "", "the production tooltip position resolver must exist")
	ReadPos := InStr(Resolver, "_TooltipReadPositionReceipt(ActiveHwnd)")
	MatchPos := InStr(Resolver, "_TooltipPositionCacheCanReuse(")
	CacheReturnPos := InStr(Resolver, '_TooltipCountResolveExit("cache")')
	Assert(ReadPos > 0 and MatchPos > ReadPos and CacheReturnPos > MatchPos,
		"the resolver must read and validate monitor/work-area/DPI before returning cached coordinates")

	Writer := _DriverFuncBody("_TooltipCachePosition")
	Assert(Writer != "", "the production tooltip cache writer must exist")
	Assert(InStr(Writer, '"environment", Context is Map ? Context["Environment"]') > 0
		and InStr(Writer, "_TooltipReadPositionReceipt(Hwnd)") > 0,
		"every cached position must retain the environment receipt used by later hits")
	Present := _DriverFuncBody("_TooltipPresentStack")
	Assert(Present != "", "the final pixel owner must exist")
	Assert(InStr(Present, "_TooltipPreparedPositionStillCurrent(PositionContext)") > 0
		and InStr(Present, "if DeadlinesLive && PositionCurrent") > 0,
		"a prepared worker receipt must be revalidated after GUI preparation at the pixel commit")
}

Test("meta tooltip position receipt: resolver validates and writer stores environment (ahk2-17)",
	_TPCRW_ResolverUsesEnvironmentReceipt)

; AHK evaluates a plain global argument reference after later argument calls,
; while A_TickCount may already be sampled. Freeze an owned map in a local first.
; These guards prove source order and receipt ownership, not timer preemption.
_TPCRW_NativeCacheSnapshotOrder(Symbol, CheckReturn := false) {
	Body := _DriverFuncBody(Symbol)
	Assert(Body != "", Symbol . " must have a nonempty production body")
	Code := _DriverMaskNonCode(&Body)
	Pattern := "i)\b_TooltipPositionCacheCanReuse\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,[^,]*,[^,]*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*,"
	CallAt := RegExMatch(Code, Pattern, &Call)
	Assert(CallAt > 0, Symbol . " must validate a captured cache and clock")
	Assert(!RegExMatch(Code, Pattern, , CallAt + Call.Len), Symbol . " must have one cache admission")
	Cache := Call[1]
	Now := Call[2]
	SnapshotPattern := "im)^[ \t]*" . Cache . "\s*:=\s*_TooltipPositionCache\s*$"
	SnapshotAt := RegExMatch(Code, SnapshotPattern, &Snapshot)
	Assert(SnapshotAt > 0, Symbol . " must snapshot the shared cache into a local")
	Assert(!RegExMatch(Code, "im)^[ \t]*" . Cache . "\s*:=", , SnapshotAt + Snapshot.Len),
		Symbol . " must not replace the captured cache")
	NowPattern := "im)^[ \t]*" . Now . "\s*:=\s*A_TickCount\s*$"
	NowAt := RegExMatch(Code, NowPattern, &Sample)
	Assert(NowAt > 0, Symbol . " must sample the actual native clock")
	Assert(!RegExMatch(Code, "im)^[ \t]*" . Now . "\s*:=", , NowAt + Sample.Len),
		Symbol . " must not replace the sampled clock")
	Assert(SnapshotAt < NowAt && NowAt < CallAt,
		Symbol . " must capture its cache before native sampling and validation")
	if CheckReturn {
		ReturnAt := InStr(Code, "return {", true, CallAt)
		ReturnEnd := InStr(Code, "}", true, ReturnAt)
		Assert(ReturnAt > CallAt && ReturnEnd > ReturnAt, "validated cache must have a bounded coordinate return")
		ReturnCode := SubStr(Code, ReturnAt, ReturnEnd - ReturnAt)
		Count := 0
		Start := 1
		while Found := RegExMatch(ReturnCode, "\b" . Cache . "\s*\[", &Field, Start) {
			Count += 1
			Start := Found + Field.Len
		}
		AssertEqual(4, Count, "all returned coordinate fields must come from the exact validated receipt")
		Assert(!InStr(ReturnCode, "_TooltipPositionCache"), "return cannot reread a newer unvalidated global cache")
	}
}

Test("tooltip position native64: resolver freezes cache before clock and returns its receipt (tooltip-position-native64)",
	_TPCRW_NativeCacheSnapshotOrder.Bind("_TooltipResolvePosition", true))
Test("tooltip position native64: preview freezes cache before clock (tooltip-position-native64)",
	_TPCRW_NativeCacheSnapshotOrder.Bind("_TooltipPreparePreviewPosition"))
Test("tooltip position native64: warm pump freezes cache before clock (tooltip-position-native64)",
	_TPCRW_NativeCacheSnapshotOrder.Bind("_TooltipPositionWarmPump"))

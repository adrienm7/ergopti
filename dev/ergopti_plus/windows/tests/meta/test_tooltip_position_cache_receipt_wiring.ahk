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
	Assert(InStr(Writer, '"environment", _TooltipReadPositionReceipt(Hwnd)') > 0,
		"every cached position must retain the environment receipt used by later hits")
}

Test("meta tooltip position receipt: resolver validates and writer stores environment (ahk2-17)",
	_TPCRW_ResolverUsesEnvironmentReceipt)

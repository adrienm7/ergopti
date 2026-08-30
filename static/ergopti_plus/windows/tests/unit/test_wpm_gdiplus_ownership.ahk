; tests/unit/test_wpm_gdiplus_ownership.ahk

; ==============================================================================
; MODULE: WPM GDI+ ownership tests
; DESCRIPTION:
; Injects native acquisition and cleanup failures into the process-lifetime WPM
; graphics transaction without loading or allocating real GDI+ resources.
; ==============================================================================

#Requires AutoHotkey v2.0

class _WPMGO_Native {
	static Events := []
	static FailAt := ""
	static CleanupFailAt := ""

	static Reset(FailAt := "", CleanupFailAt := "") {
		this.Events := []
		this.FailAt := FailAt
		this.CleanupFailAt := CleanupFailAt
	}

	static LoadModule() {
		this.Events.Push("load")
		return this.FailAt == "load" ? 0 : 101
	}

	static FreeModule(Module) {
		this.Events.Push("free:" . Module)
		return this.CleanupFailAt != "free"
	}

	static Startup(StartupInput, &Token) {
		this.Events.Push("startup")
		Token := this.FailAt == "startup" ? 0 : 202
		return this.FailAt == "startup" ? 1 : 0
	}

	static Shutdown(Token) {
		this.Events.Push("shutdown:" . Token)
		return this.CleanupFailAt != "shutdown"
	}

	static CreateFamily(Name, &Family) {
		this.Events.Push("family:" . Name)
		if (this.FailAt == "segoe" and Name == "Segoe UI") {
			Family := 0
			return 1
		}
		if (this.FailAt == "family") {
			Family := 0
			return 1
		}
		Family := 303
		return 0
	}

	static DeleteFamily(Family) {
		this.Events.Push("delete-family:" . Family)
		return this.CleanupFailAt == "family" ? 1 : 0
	}

	static CreateFont(Family, LabelPx, &Font) {
		this.Events.Push("font:" . Family . ":" . LabelPx)
		Font := this.FailAt == "font" ? 0 : 404
		return this.FailAt == "font" ? 1 : 0
	}

	static DeleteFont(Font) {
		this.Events.Push("delete-font:" . Font)
		return this.CleanupFailAt == "font" ? 1 : 0
	}

	static CreateFormat(&FormatHandle) {
		this.Events.Push("format")
		FormatHandle := this.FailAt == "format" ? 0 : 505
		return this.FailAt == "format" ? 1 : 0
	}

	static DeleteFormat(FormatHandle) {
		this.Events.Push("delete-format:" . FormatHandle)
		return this.CleanupFailAt == "format" ? 1 : 0
	}

	static SetFormatAlign(FormatHandle) {
		this.Events.Push("align:" . FormatHandle)
		return this.FailAt == "align" ? 1 : 0
	}

	static SetFormatLineAlign(FormatHandle) {
		this.Events.Push("line-align:" . FormatHandle)
		return this.FailAt == "line-align" ? 1 : 0
	}
}

_WPMGO_Join(Values) {
	Output := ""
	for Value in Values
		Output .= (Output == "" ? "" : ",") . Value
	return Output
}





_WPMGO_StartupFailureReleasesLoadedModule() {
	_WPMGO_Native.Reset("startup")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertFalse(Result["ok"])
	AssertFalse(Result["receipt"] is Map,
		"a successful rollback must leave no retained cleanup receipt")
	AssertEqual("load,startup,free:101", _WPMGO_Join(_WPMGO_Native.Events),
		"startup refusal must balance the already loaded module")
}
Test("wpm GDI+ ownership: startup failure releases the module",
	_WPMGO_StartupFailureReleasesLoadedModule)

_WPMGO_FontFailureReleasesDependenciesInReverse() {
	_WPMGO_Native.Reset("font")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertFalse(Result["ok"])
	AssertEqual("load,startup,family:Segoe UI,font:303:15,delete-family:303,shutdown:202,free:101",
		_WPMGO_Join(_WPMGO_Native.Events),
		"font refusal must release family, token, and module in reverse order")
}
Test("wpm GDI+ ownership: font failure rolls back every dependency",
	_WPMGO_FontFailureReleasesDependenciesInReverse)

_WPMGO_FormatSetupFailureReleasesEveryHandle() {
	_WPMGO_Native.Reset("line-align")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertFalse(Result["ok"])
	AssertEqual("load,startup,family:Segoe UI,font:303:15,format,align:505,line-align:505,delete-format:505,delete-font:404,delete-family:303,shutdown:202,free:101",
		_WPMGO_Join(_WPMGO_Native.Events),
		"format setup refusal must release the complete partial graph transaction")
}
Test("wpm GDI+ ownership: format setup failure releases every handle",
	_WPMGO_FormatSetupFailureReleasesEveryHandle)

_WPMGO_CleanupRefusalRetainsExactDebt() {
	_WPMGO_Native.Reset("", "font")
	Result := _WPMGdipAcquire(15, _WPMGO_Native)
	AssertTrue(Result["ok"], "setup must create a complete ownership receipt")
	Receipt := Result["receipt"]
	AssertFalse(_WPMGdipRelease(Receipt, _WPMGO_Native),
		"the first injected font deletion must remain unresolved")
	AssertEqual(0, Receipt["format"],
		"successfully deleted children must retire from the receipt")
	AssertEqual(404, Receipt["font"],
		"the refused font and all its dependencies must remain owned")
	AssertEqual(303, Receipt["family"])
	AssertEqual(202, Receipt["token"])
	AssertEqual(101, Receipt["module"])
	_WPMGO_Native.CleanupFailAt := ""
	AssertTrue(_WPMGdipRelease(Receipt, _WPMGO_Native),
		"the exact retained receipt must be retryable")
	for Key in ["format", "font", "family", "token", "module"]
		AssertEqual(0, Receipt[Key], "successful retry must retire " . Key)
}
Test("wpm GDI+ ownership: cleanup refusal retains exact retry debt",
	_WPMGO_CleanupRefusalRetainsExactDebt)

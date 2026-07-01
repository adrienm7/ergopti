; tests/meta/test_open_downloads_catch.ahk

; ==============================================================================
; MODULE: OpenDownloads Bare-Try Meta Test (Pattern 3)
; DESCRIPTION:
; Regression guard for the documented "bare try with no catch" anti-pattern
; (docs/PROJECT_MEMORY.md's project-ahk-invariant-incomplete-application).
; OpenDownloads scans existing Explorer windows via Shell.Application COM
; enumeration to reuse one already showing Downloads; both the outer
; enumeration and each per-window body were bare try with no catch and no
; logging, so any throw (a window closing mid-scan, a COM re-init race)
; silently made Win+D always open a fresh window with zero diagnostic trace.
;
; SCOPE: source introspection of modules/shortcuts/win.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Outer COM-enumeration try has a catch ===========
; ============================================================
; ============================================================

_ODC_CheckOuterCatchPresent() {
	Body := _DriverFuncBody("OpenDownloads")
	Assert(Body != "", "OpenDownloads must exist in modules/shortcuts/win.ahk")

	OuterTryPos := InStr(Body, 'ComObject("Shell.Application")')
	Assert(OuterTryPos > 0, 'OpenDownloads must enumerate via ComObject("Shell.Application").Windows')

	; The outer try's catch is the FIRST "} catch" AFTER the inner per-window
	; try/catch closes — find the inner catch first so we don't match it twice.
	InnerCatchPos := InStr(Body, "} catch", , OuterTryPos)
	Assert(InnerCatchPos > 0,
		"OpenDownloads: the per-window try must have a catch clause (see the inner-try assertion below)")

	OuterCatchPos := InStr(Body, "} catch", , InnerCatchPos + 1)
	Assert(OuterCatchPos > 0,
		"OpenDownloads: the outer Shell.Application enumeration try must have its own catch clause — a bare try with no catch silently masks a COM enumeration failure (project-ahk-invariant-incomplete-application)")

	OuterCatchBody := SubStr(Body, OuterCatchPos, 250)
	Assert(InStr(OuterCatchBody, "Logger") > 0,
		"OpenDownloads: the outer catch must log the enumeration failure so it is diagnosable instead of silently invisible")
}
Test("shortcuts: OpenDownloads's outer Shell.Application enumeration try has a logging catch (bare-try-anti-pattern)",
	_ODC_CheckOuterCatchPresent)




; ============================================================
; ============================================================
; ======= 2/ Inner per-window try has a catch =================
; ============================================================
; ============================================================

_ODC_CheckInnerCatchPresent() {
	Body := _DriverFuncBody("OpenDownloads")

	InnerTryPos := InStr(Body, "DOMPathToFilesystem(Win.LocationURL)")
	Assert(InnerTryPos > 0, "OpenDownloads must inspect Win.LocationURL per enumerated window")

	InnerCatchPos := InStr(Body, "} catch", , InnerTryPos)
	Assert(InnerCatchPos > 0,
		"OpenDownloads: the per-window try must have a catch clause — a bare try with no catch aborts the whole scan when one window's COM properties throw (project-ahk-invariant-incomplete-application)")

	InnerCatchBody := SubStr(Body, InnerCatchPos, 250)
	Assert(InStr(InnerCatchBody, "continue") > 0,
		"OpenDownloads: the per-window catch must continue the loop so one window's exception does not abort the whole Explorer scan")
}
Test("shortcuts: OpenDownloads's per-window try has a catch that continues the scan (bare-try-anti-pattern)",
	_ODC_CheckInnerCatchPresent)

; tests/unit/test_healthcheck_os_name_windows11.ahk

; ==============================================================================
; MODULE: Windows 11 Product Name In Every Diagnostic Surface
; DESCRIPTION:
; The registry's ProductName still reads "Windows 10 …" on Windows 11, whose
; builds start at 22000. The boot snapshot line corrected it; the healthcheck
; window and the crash report read the raw value through their own probe
; copies, so the same machine was "Windows 11 Home" in the log and "Windows 10
; Home" in the diagnostic a user copies into a bug report. The correction is
; now one pure function and both surfaces reuse the snapshot's probe.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ The pure product-name correction =======
; ===================================================
; ===================================================

_TestWin11_ProductNameCorrection() {
	AssertEqual("Windows 11 Home", DiagSnapshot_WindowsProductName("Windows 10 Home", "26100"),
		"build 26100 is Windows 11 even though ProductName says Windows 10")
	AssertEqual("Windows 11 Pro", DiagSnapshot_WindowsProductName("Windows 10 Pro", "22000"),
		"22000 is the first Windows 11 build")
	AssertEqual("Windows 10 Pro", DiagSnapshot_WindowsProductName("Windows 10 Pro", "19045"),
		"a real Windows 10 build keeps its name")
	AssertEqual("Windows Server 2022 Datacenter",
		DiagSnapshot_WindowsProductName("Windows Server 2022 Datacenter", "20348"),
		"a server name is never rewritten")
	AssertEqual("Windows 10 Home", DiagSnapshot_WindowsProductName("Windows 10 Home", "not-a-build"),
		"a malformed build number leaves the name untouched")
}

Test("Diagnostics: ProductName is corrected to Windows 11 from the build number (win11-name)",
	_TestWin11_ProductNameCorrection)





; ==================================================
; ==================================================
; ======= 2/ One probe set for every surface =======
; ==================================================
; ==================================================

_TestWin11_HealthcheckUsesSnapshotProbe() {
	Expected := DiagSnapshot_OsInfo()
	Assert(Expected["os"] != "", "the snapshot probe must name the OS")
	System := _HealthCheck_System(false, 0)
	AssertEqual(Trim(Expected["os"] . " " . Expected["os_version"]), System["os"],
		"the healthcheck must report the same corrected OS name and build as the boot snapshot")
}

Test("Diagnostics: the healthcheck reports the boot snapshot's OS name (win11-name)",
	_TestWin11_HealthcheckUsesSnapshotProbe)


_TestWin11_CrashReportUsesSnapshotProbe() {
	Expected := DiagSnapshot_OsInfo()
	Sys := _CrashReport_SysInfo()
	AssertEqual(Expected["os"], Sys["os_name"],
		"the crash report must report the same corrected OS name as the boot snapshot")
	AssertEqual(Expected["os_version"], Sys["os_build"],
		"the crash report must report the same build as the boot snapshot")
}

Test("Diagnostics: the crash report reports the boot snapshot's OS name (win11-name)",
	_TestWin11_CrashReportUsesSnapshotProbe)


; The whole class, not the two sites that were found: any other raw read of
; ProductName would reintroduce a second, uncorrected answer.
_TestWin11_SingleProductNameProbe() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the ProductName probe scan")
	Count := 0
	Pos := 1
	while (Pos := InStr(Src, '"ProductName"', true, Pos)) {
		Count += 1
		Pos += 1
	}
	AssertEqual(1, Count,
		"exactly one ProductName registry read (DiagSnapshot_OsInfo) may exist in the driver")
}

Test("Diagnostics: ProductName is read by one probe only (win11-name)",
	_TestWin11_SingleProductNameProbe)

; static/ergopti_plus/windows/tests/bench_boot_hotstrings.ahk

; ==============================================================================
; MODULE: Boot Hotstrings Micro-Benchmark
; DESCRIPTION:
; Headless profiler for the generated-hotstring registration cost that
; dominates driver boot (the "~800 ms B4 generated loaders" item). It loads the
; exact production registration path — ``CreateHotstring`` ->
; ``_MirrorRegistrationToHSE`` -> ``HSE_Register`` plus the memoised
; ``HotstringsResolve`` priority/delay cascade — with ``_HotstringRegistrar`` left
; at its production value of 0 (the native AHK ``Hotstring()`` is never called for
; HSE-managed hotstrings), so the numbers it prints are representative of the real
; boot work, broken down per generated category.
;
; It is NOT a test (no ``Test()`` cases, not included by run_all.ahk); it is a
; diagnostic tool run on demand:
;     "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" bench_boot_hotstrings.ahk
; Results go to stdout and to %TEMP%\ergopti_bench_boot.txt.
;
; FEATURES & RATIONALE:
; 1. Production-faithful path: reuses the same lib include chain as run_all.ahk
;    (minus the test framework / hook install) so what it times is what boots.
; 2. Sub-millisecond timing via QueryPerformanceCounter — A_TickCount's 16 ms
;    granularity is too coarse for the small categories.
; ==============================================================================

#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; Stubs provide ScriptInformation["MagicKey"], Features and _SharedDir (pointing
; at the real bundled shared/ dir) so HotstringsResolve reads the production TOML
; meta exactly as it does at boot. InstallHotstringHooks is only a function here —
; we deliberately never call it, leaving _HotstringRegistrar at 0 (production).
#Include test_stubs.ahk

; ── Production lib files in dependency order (mirrors run_all.ahk) ──
#Include ../lib/app_state.ahk
#Include ../lib/ui_style.ahk
#Include ../lib/logger.ahk
#Include ../lib/toml/toml_helpers.ahk
#Include ../lib/active_app_cache.ahk
#Include ../lib/window_utils.ahk
#Include ../lib/string_utils.ahk
#Include ../lib/nav_layer_helpers.ahk
#Include ../lib/hotstrings/hotstring_engine.ahk
#Include ../lib/hotstrings/hotstring_engine_main.ahk
#Include ../lib/hotstrings/hotstring_live_toggle.ahk
#Include ../lib/hotstrings/hotstring_prefix_watcher.ahk
#Include ../lib/master_gates.ahk
#Include ../_generated/terminators.ahk
#Include ../lib/toml/toml_loader.ahk
#Include ../lib/toml/toml_config_loader.ahk
#Include ../lib/tap_hold/tap_hold_loader.ahk
#Include ../_generated/features_manifest.ahk
#Include ../lib/manifest_reader.ahk
#Include ../lib/hotstrings/hotstrings_config.ahk
#Include ../lib/hotstrings/personal_toml_editor.ahk
#Include ../lib/registry.ahk
#Include ../lib/json.ahk
#Include ../lib/i18n.ahk

; The generated loaders + per-category maps (_GENERATED_HOTSTRINGS_*).
#Include ../lib/hotstrings/hotstrings_generated.ahk





; ============================================
; ============================================
; ======= 1/ High-resolution stopwatch =======
; ============================================
; ============================================

global _QPF := 0
DllCall("QueryPerformanceFrequency", "Int64*", &_QPF)

; Current QueryPerformanceCounter tick.
_Now() {
	local c := 0
	DllCall("QueryPerformanceCounter", "Int64*", &c)
	return c
}

; Milliseconds between two QPC ticks, rounded to 0.01 ms.
_Ms(a, b) {
	global _QPF
	return Round((b - a) * 1000.0 / _QPF, 2)
}

_OUT := A_Temp . "\ergopti_bench_boot.txt"
_Emit(Line) {
	global _OUT
	FileAppend(Line . "`r`n", "*")
	try FileAppend(Line . "`r`n", _OUT, "UTF-8")
}





; ===============================================
; =================================================
; ======= 2/ Per-category registration time =======
; =================================================
; ===============================================

; Register every section of one generated category map and report the wall time,
; the number of HSE registrations (HSE_SeqCounter delta) and the per-registration
; cost. FeatureConfig carries only TimeActivationSeconds, mirroring what
; RegisterAllHotstrings hands the loaders for a default (un-overridden) section.
_RunCat(Name, CatMap) {
	global HSE_SeqCounter
	Fc := { TimeActivationSeconds: 0 }
	S0 := HSE_SeqCounter
	T0 := _Now()
	for _Key, Loader in CatMap {
		; Survive a loader that needs a stub we did not provide (e.g. emoji maps);
		; report it so the category total stays meaningful instead of aborting.
		try {
			Loader(Fc)
		} catch as e {
			_Emit(Format("   ! loader {1} threw: {2}", _Key, e.Message))
		}
	}
	T1 := _Now()
	N := HSE_SeqCounter - S0
	Total := _Ms(T0, T1)
	Per := (N > 0) ? Round(Total / N, 4) : 0
	_Emit(Format("{1:-20}{2:9} ms   {3:5} regs   {4:8} ms/reg", Name, Total, N, Per))
	return Total
}

; Per-section breakdown of a single category, sorted by descending wall time, so
; the heaviest section inside the dominant category is named explicitly.
_RunCatBySection(Name, CatMap) {
	global HSE_SeqCounter
	Fc := { TimeActivationSeconds: 0 }
	Rows := []
	for _Key, Loader in CatMap {
		S0 := HSE_SeqCounter
		T0 := _Now()
		try {
			Loader(Fc)
		} catch as e {
			_Emit(Format("   ! loader {1} threw: {2}", _Key, e.Message))
		}
		T1 := _Now()
		Rows.Push({ key: _Key, ms: _Ms(T0, T1), regs: HSE_SeqCounter - S0 })
	}
	; Simple insertion sort by descending ms (tiny arrays, clarity over speed).
	Loop Rows.Length {
		i := A_Index
		Loop Rows.Length - i {
			j := A_Index
			if (Rows[j].ms < Rows[j + 1].ms) {
				Tmp := Rows[j], Rows[j] := Rows[j + 1], Rows[j + 1] := Tmp
			}
		}
	}
	_Emit("")
	_Emit(Format("--- {1}: top sections by wall time ---", Name))
	Loop Math_Min(8, Rows.Length) {
		R := Rows[A_Index]
		_Emit(Format("   {1:-32}{2:8} ms   {3:5} regs", R.key, R.ms, R.regs))
	}
}

Math_Min(a, b) => (a < b) ? a : b

_Emit("=== ergopti boot hotstrings micro-bench ===")
_Emit(Format("AutoHotkey {1}   QPC freq {2}", A_AhkVersion, _QPF))
_Emit("")
_Emit("category               wall        regs       per-reg")
_Emit("-----------------------------------------------------------")

; Production registration order: distances+SFBs, rolls, autocorrection, magickey.
GrandTotal := 0
GrandTotal += _RunCat("distancesreduction", _GENERATED_HOTSTRINGS_DISTANCESREDUCTION)
GrandTotal += _RunCat("sfbsreduction", _GENERATED_HOTSTRINGS_SFBSREDUCTION)
GrandTotal += _RunCat("rolls", _GENERATED_HOTSTRINGS_ROLLS)
GrandTotal += _RunCat("autocorrection", _GENERATED_HOTSTRINGS_AUTOCORRECTION)
GrandTotal += _RunCat("magickey", _GENERATED_HOTSTRINGS_MAGICKEY)

_Emit("-----------------------------------------------------------")
_Emit(Format("{1:-20}{2:9} ms   {3:5} regs", "TOTAL", Round(GrandTotal, 2), HSE_SeqCounter))

; Drill into the dominant category to name the heaviest section(s).
_RunCatBySection("autocorrection", _GENERATED_HOTSTRINGS_AUTOCORRECTION)
_Emit("")
_Emit("Note: cold run = first boot (HotstringsResolve cache empty, TOML meta read")
_Emit("from disk once per section). _HotstringRegistrar = 0, matching production.")

ExitApp(0)

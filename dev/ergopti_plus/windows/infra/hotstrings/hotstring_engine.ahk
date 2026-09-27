; infra/hotstrings/hotstring_engine.ahk

; ==============================================================================
; MODULE: Hotstring Engine
; DESCRIPTION:
; Core hotstring engine used by ErgoptiPlus: low-level send primitives,
; hotstring builders (case-insensitive and case-sensitive variants), and the
; shared ``HotstringHandler`` that performs the backspace/replace dance.
;
; FEATURES & RATIONALE:
; 1. Send primitives (``SendNewResult`` / ``SendFinalResult`` / ``SendInstant``)
;    wrap ``SendEvent`` / ``SendInput`` so the rest of the codebase never has
;    to worry about mode selection, nested hotstring triggering, or the
;    clipboard dance used by ``SendInstant`` for large payloads.
; 2. ``CreateHotstring`` and ``CreateCaseSensitiveHotstrings`` are the only two
;    public entry points every feature module should use to register a
;    hotstring — they guarantee consistent flags (``B0O``), a shared options
;    schema, and the Windows-11 Notepad workaround.
; 3. ``HotstringHandler`` centralises the replacement logic so adding a new
;    quirk (e.g. a new mis-triggering app) only touches one place.
; 4. ``GenerateUppercaseVariants`` / ``StrTitle`` / ``GetLastSentCharacterAt``
;    are shared text helpers kept close to the engine because every caller
;    sits either in this module or in a feature file that depends on it.
;
; DEPENDENCIES:
; The engine references the following globals/functions provided by the main
; ErgoptiPlus script: ``ScriptInformation`` (for the magic key), the
; ``UpdateLastSentCharacter`` function and its ``LastSentCharacterKeyTime``
; backing global. The last-character ring buffer (``_LSC_*``) lives in this
; file (see section 4). AHK v2 resolves these across the whole compilation
; unit, so the ``#Include`` ordering is irrelevant as long as all files are
; part of the same script.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================


; Delay (ms) after Ctrl+V in SendInstant to let the paste settle before
; the clipboard is restored. 200 ms was tuned empirically and handles
; slow paste targets (Teams/Word) without blocking perceptibly.
global SEND_INSTANT_PASTE_DELAY_MS := 200

; The adapter's CB_TryBeginPasteTransaction owns the process-wide clipboard
; lease across this complete deferred interval. A contender must take its
; clipboard-free path before snapshotting or publishing another payload.

; Timeout (s) for ClipWait in GetSelection. A real selection copies in
; <100 ms; GetSelection runs on the keyboard thread (case-conversion /
; web-search chords), so this doubles as a LowLevelHooksTimeout exposure
; window. 0.5 s is a tight interactive ceiling: long enough for any
; responsive app, short enough that a non-responsive one cannot stall input
; for seconds. On timeout GetSelection returns "" and callers no-op.
global GET_SELECTION_TIMEOUT_SEC := 0.5

; Delay (ms) used by ActivateHotstrings between the Space poke and the
; BackSpace. Kept explicit so we can tune it in one place without
; chasing magic numbers across hot paths.
global ACTIVATE_HOTSTRINGS_DELAY_MS := 50

; ── Test seams (production = 0, tests can swap them with a recorder). ──
; ``_HotstringRegistrar`` intercepts the AHK ``Hotstring()`` registration
; call; ``_SendHook`` intercepts every send primitive (SendNewResult,
; SendFinalResult, SendInstant). Both default to 0 so the production
; runtime path is bit-for-bit identical to before.
global _HotstringRegistrar := 0
global _SendHook := 0

; Whether AltGr needs the synthetic Up injection in HotstringHandler is the
; AltGr family (infra/altgr_family.ahk) — auto-detected via a reverse VK→SC
; probe (KS_ProbeAltGrLayout), with a manual TOML override
; (ScriptInformation["AltGrIsKanaRemap"]) that always wins — decided at boot
; and then following the foreground window's layout.
; Keeping the resolved bool in a global lets the hot path skip a Map lookup
; and a truthy test on every hotstring firing.
; The `global _ALTGR_KANA_FIXUP := False` initializer deliberately does NOT live
; here: a parse-time #HotIf (platform/remap/altgr.ahk) reads it in FIRST
; position, and this file's include position is far below the first message pump,
; so the global would still be unset when that #HotIf is evaluated. It is seeded in
; the pre-pump block of ErgoptiPlus.ahk instead (single source, §5.2);
; HotstringEngineInit() resolves the real value later.

; Returns the HKL the user is typing with in the foreground window, or 0 when
; there is no foreground window. That is the layout of the thread owning the
; foreground window's focused control, which AutoHotkey's own Send and hook use
; too (keyboard_mouse.cpp GetFocusedCtrlThread): in a UWP app the top-level
; frame belongs to ApplicationFrameHost while the focused CoreWindow runs on the
; app's own thread, so the frame's layout was read and the AltGr family could be
; decided from the wrong layout. The top-level thread's layout is kept when the
; thread reports no focused control. Used by the boot layout probe and the
; layout-change watcher in ErgoptiPlus.ahk so both observe the same value.
; @param Port {Map} Test seam: "foreground", "thread_of", "focus_of" and
;        "layout_of" callables; production uses _ForegroundLayoutPort().
; @return {Integer} The HKL, or 0.
GetForegroundKeyboardLayout(Port := 0) {
		if !IsObject(Port)
				Port := _ForegroundLayoutPort()
		HWND := Port["foreground"].Call()
		if (HWND = 0) {
				return 0
		}
		TID := Port["thread_of"].Call(HWND)
		if (TID = 0) {
				return 0
		}
		Focus := Port["focus_of"].Call(TID)
		if (Focus != 0) {
				FocusTID := Port["thread_of"].Call(Focus)
				if (FocusTID != 0)
						TID := FocusTID
		}
		return Port["layout_of"].Call(TID)
}

; The Win32 calls behind GetForegroundKeyboardLayout.
_ForegroundLayoutPort() {
		static Port := Map(
				"foreground", () => DllCall("GetForegroundWindow", "Ptr"),
				"thread_of", (Hwnd) => DllCall("GetWindowThreadProcessId", "Ptr", Hwnd, "Ptr", 0, "UInt"),
				"focus_of", _ForegroundFocusedControl,
				"layout_of", (Tid) => DllCall("GetKeyboardLayout", "UInt", Tid, "Ptr"))
		return Port
}

; The focused control of thread Tid (GUITHREADINFO.hwndFocus), or 0 when the
; thread has none or GetGUIThreadInfo fails.
_ForegroundFocusedControl(Tid) {
		Info := Buffer(8 + 6 * A_PtrSize + 16, 0)
		NumPut("UInt", Info.Size, Info, 0)
		if !DllCall("GetGUIThreadInfo", "UInt", Tid, "Ptr", Info)
				return 0
		return NumGet(Info, 8 + A_PtrSize, "Ptr")
}

; Read the manual TOML override from ScriptInformation. Returns "" when the
; key is missing or set to the sentinel "auto"; "true" / "false" when forced.
_ReadKanaTomlOverride() {
		if !IsSet(ScriptInformation) or !ScriptInformation.Has("AltGrIsKanaRemap") {
				return ""
		}
		Val := ScriptInformation["AltGrIsKanaRemap"]
		if (Val == true or Val == 1 or Val == "1" or Val == "true" or Val == "True") {
				return "true"
		}
		if (Val == false or Val == 0 or Val == "0" or Val == "false" or Val == "False") {
				return "false"
		}
		return ""  ; "auto" or unrecognised → defer to detection
}

; Decide the boot AltGr family from one layout read and one probe, and keep the
; record of what decided it in _ALTGR_LAYOUT_PROBE (infra/altgr_family.ahk).
; The AltGrDetect log line, the magic-key scan, the layout poll's baseline and
; the Kana AltGr's send name all read that record: each used to read the layout
; again, so a layout switch during the seconds of boot left the family decided
; on one layout while the poll's baseline already held the next one. The TOML
; override still decides the family, but the layout is read and probed all the
; same for the record. When no layout can be read at all, nothing is probed
; (HKL 0 would probe another loaded layout), and a layout that knows no AltGr
; key either way is not taken for a Kana one: the family stays the standard
; one, recorded as "unresolved" for the boot log. After boot the family follows
; the foreground window's layout without a reload (AltGrFamilyFollow).
; @param ResolveFn {Func} Test seam, KS_ResolveKeyboardLayout by default.
; @param ProbeFn {Func} Test seam, KS_ProbeAltGrLayout by default.
HotstringEngineInit(ResolveFn := 0, ProbeFn := 0) {
		if !IsObject(ResolveFn)
				ResolveFn := KS_ResolveKeyboardLayout
		AltGrFamilyResetProbes(ProbeFn)
		AltGrFamilyPublish(AltGrFamilyDecide(ResolveFn.Call()))
}





#Include hotstring_send.ahk
#Include hotstring_builder.ahk

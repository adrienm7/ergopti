; lib/hotstrings/hotstring_engine.ahk

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

; Process-wide reentrancy guard for SendInstant's clipboard dance. The
; deferred restore (SetTimer above) keeps A_Clipboard = payload for
; SEND_INSTANT_PASTE_DELAY_MS; if a second SendInstant fires in that window
; (e.g. a fast follow-up wrap key) it would overwrite A_Clipboard before the
; first paste settled, racing the not-yet-restored clipboard and corrupting
; the user's data. While this flag is true a second SendInstant skips the
; clipboard route entirely (send-instant-sleep-clipboard-on-keyboard-thread).
global _SEND_INSTANT_CLIP_BUSY := false

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

; Boot-time resolution of whether AltGr needs the synthetic Up injection in
; HotstringHandler — auto-detected via a reverse VK→SC probe, with a manual
; TOML override (ScriptInformation["AltGrIsKanaRemap"]) that always wins.
; Caching the resolved bool at boot lets the hot path skip a Map lookup and
; a truthy test on every hotstring firing.
; The `global _ALTGR_KANA_FIXUP := False` initializer deliberately does NOT live
; here: a parse-time #HotIf (modules/tap_holds/altgr.ahk) reads it in FIRST
; position, and this file's include position is far below the first message pump,
; so the global would still be unset when that #HotIf is evaluated. It is seeded in
; the pre-pump block of ErgoptiPlus.ahk instead (single source, §5.2);
; HotstringEngineInit() resolves the real value later.

; Win32 constants for MapVirtualKeyEx — see learn.microsoft.com/en-us/
; windows/win32/api/winuser/nf-winuser-mapvirtualkeyexw.
global _MAPVK_VK_TO_VSC_EX := 4
global _VK_RMENU := 0xA5

; Returns the HKL of the foreground window's thread, or 0 if the call chain
; fails. Used by both DetectAltGrKanaRemap and the layout-change watcher in
; ErgoptiPlus.ahk so both observe the same value.
GetForegroundKeyboardLayout() {
    HWND := DllCall("GetForegroundWindow", "Ptr")
    if (HWND = 0) {
        return 0
    }
    TID := DllCall("GetWindowThreadProcessId", "Ptr", HWND, "Ptr", 0, "UInt")
    if (TID = 0) {
        return 0
    }
    return DllCall("GetKeyboardLayout", "UInt", TID, "Ptr")
}

; Probe the active layout in REVERSE direction: does VK_RMENU have a scancode?
;
; On vanilla AltGr layouts (bépo, US-International, AZERTY, …) the RAlt key
; is mapped to VK_RMENU, so MapVirtualKeyExW(VK_RMENU, VK_TO_VSC_EX) returns
; the RAlt extended scancode (typically 0xE038). On custom KbdEdit/MSKLC
; remaps where AltGr is reassigned to a different VK (VK_KANA, VK_OEM_8,
; VK_LMENU, …), VK_RMENU has no scancode → the probe returns 0.
;
; The reverse direction proves more reliable than the SC→VK probe used in
; earlier revisions: that one needed an E0-encoded scancode and behaved
; inconsistently across bépo HKLs (returning VK_LMENU or 0 instead of
; VK_RMENU), wrongly flagging bépo as a Kana layout.
DetectAltGrKanaRemap() {
    HKL := GetForegroundKeyboardLayout()
    if (HKL = 0) {
        HKL := DllCall("GetKeyboardLayout", "UInt", 0, "Ptr")
    }
    SC := DllCall("MapVirtualKeyExW",
        "UInt", _VK_RMENU,
        "UInt", _MAPVK_VK_TO_VSC_EX,
        "Ptr", HKL,
        "UInt")
    return (SC == 0)
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

HotstringEngineInit() {
    global _ALTGR_KANA_FIXUP
    Override := _ReadKanaTomlOverride()
    if (Override == "true") {
        _ALTGR_KANA_FIXUP := True
        return
    }
    if (Override == "false") {
        _ALTGR_KANA_FIXUP := False
        return
    }
    _ALTGR_KANA_FIXUP := DetectAltGrKanaRemap()
}





#Include hotstring_send.ahk
#Include hotstring_builder.ahk
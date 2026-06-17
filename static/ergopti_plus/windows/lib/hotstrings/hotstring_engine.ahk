; drivers/autohotkey/lib/hotstring_engine.ahk

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





; =======================================
; ============================
; ======= 1/ Constants =======
; ============================
; =======================================

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
global _ALTGR_KANA_FIXUP := False

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





; =======================================
; =======================================
; ======= 2/ Low-level send layer =======
; =======================================
; =======================================

; Internal — the production-lean registration path used by every CreateHotstring
; / CreateCaseSensitiveHotstrings / CreateRawCallbackHotstring call. It hands the
; already-known matching flags (the ``*?C`` subset) straight to HSE_Register,
; skipping the ``:flags:B0O:abbrev`` string build AND the matching
; ``_MirrorRegistrationToHSE`` re-parse that the old per-call path incurred on
; every one of the ~3700 boot registrations.
;
; ``Rec`` is the resolved ``_HotstringRegistrar`` (0 in production). When a test
; has installed a recorder, the caller passes the assembled trigger-spec string
; and a real per-spec callback, which we forward to the recorder so the
; introspection tests (registration counts, spec strings, direct callback
; invocation) keep working byte-for-byte. In production Rec is 0, so callers pass
; "" / 0 for those two: HSE_DispatchMatch dispatches via ``Spec.Replacement`` and
; never invokes the callback, so building either would be pure boot-time waste.
_RegisterHotstringFast(Rec, HseFlags, Abbrev, TrigSpec, Callback, Meta := unset) {
    if Rec {
        Rec(TrigSpec, Callback)
    }
    if IsSet(Meta) {
        HSE_Register(HseFlags, Abbrev, Callback, Meta)
    } else {
        HSE_Register(HseFlags, Abbrev, Callback)
    }
}

; Extract just the matching-relevant flag letters (``*``, ``?``, ``C``) in
; canonical order from an AHK option string — the exact subset HSE_Register
; needs, identical to what ``_MirrorRegistrationToHSE`` recovered by re-parsing
; the assembled spec. Computing it directly at the call site is what lets the
; production path skip building and re-parsing the ``:flags:B0O:abbrev`` string.
_HseFlagSubset(Flags) {
    Out := ""
    if InStr(Flags, "*") {
        Out .= "*"
    }
    if InStr(Flags, "?") {
        Out .= "?"
    }
    if InStr(Flags, "C") {
        Out .= "C"
    }
    return Out
}

; Parse the AHK ``:flags:abbrev`` trigger spec and forward to HSE_Register.
; Flag letters that HSE understands (``*``, ``?``, ``C``) are passed
; through verbatim; the rest (``B0``, ``O`` — both irrelevant to matching)
; are dropped. Abbreviations are registered as-is so the HSE bucket
; index stays in lockstep with the upstream registration call.
_MirrorRegistrationToHSE(TriggerSpec, Callback, Meta := unset) {
    ; Parse the ``:<flags>:<abbrev>`` spec with InStr rather than a per-call
    ; RegExMatch: this runs once for EVERY hotstring registered at boot (~5400
    ; calls), and the abbreviation was just assembled by the caller — a regex to
    ; pull it back apart is pure overhead on the startup hot path. Semantics match
    ; the old ``^:([^:]*):(.+)$``: flags hold no colon, the abbreviation is
    ; everything after the second colon and must be non-empty.
    if (SubStr(TriggerSpec, 1, 1) != ":") {
        return
    }
    SecondColon := InStr(TriggerSpec, ":", true, 2)
    if (!SecondColon) {
        return
    }
    RawFlags := SubStr(TriggerSpec, 2, SecondColon - 2)
    Abbrev := SubStr(TriggerSpec, SecondColon + 1)
    if (Abbrev == "") {
        return
    }
    HseFlags := ""
    if InStr(RawFlags, "*") {
        HseFlags .= "*"
    }
    if InStr(RawFlags, "?") {
        HseFlags .= "?"
    }
    if InStr(RawFlags, "C") {
        HseFlags .= "C"
    }
    if IsSet(Meta) {
        HSE_Register(HseFlags, Abbrev, Callback, Meta)
    } else {
        HSE_Register(HseFlags, Abbrev, Callback)
    }
}

; Hotstrings will still be triggered downstream, so SendNewResult("a") can
; cascade a ➜ b ➜ c (final result). OnlyText=true wraps the payload in {Text}
; to avoid modifier side effects on symbols like ', ", accents.
SendNewResult(Text, OnlyText := True) {
    if _SendHook {
        Hook := _SendHook
        Hook("SendNewResult", Text, OnlyText)
    } else {
        if OnlyText {
            SendEvent("{Text}" Text)
        } else {
            SendEvent(Text)
        }
    }
    UpdateLastSentCharacter(SubStr(Text, -1))
}

; SendInput prevents other hotstrings/hotkeys from activating, so this is the
; "final" result — used when we do not want cascading expansion.
SendFinalResult(Text, OnlyText := False) {
    if _SendHook {
        Hook := _SendHook
        Hook("SendFinalResult", Text, OnlyText)
        return
    }
    if OnlyText {
        SendInput("{Text}" Text)
    } else {
        SendInput(Text)
    }
}

_SendInstant_RestoreClipboard(OldClip) {
	global _SEND_INSTANT_CLIP_BUSY
	A_Clipboard := OldClip
	; Release the reentrancy guard only after the original clipboard is back,
	; so the next SendInstant sees a quiescent clipboard before it dances again.
	_SEND_INSTANT_CLIP_BUSY := false
}

SendInstant(Text) {
	; Function for sending immediately a big text without typing it letter by letter.
	; Uses try so the user's clipboard is restored even on error/crash.
	global _SEND_INSTANT_CLIP_BUSY
	if _SendHook {
		Hook := _SendHook
		Hook("SendInstant", Text)
		return
	}
	; Reentrancy guard: a previous SendInstant's deferred restore has not run
	; yet, so the clipboard still holds its payload. Touching A_Clipboard now
	; would race the in-flight paste/restore — fall back to the clipboard-free
	; {Text} route so the two dances never interleave.
	; SendInput (not SendEvent) is used here to stay atomic and avoid interleaving
	; with the InputHook, which processes SendEvent characters as physical input.
	if _SEND_INSTANT_CLIP_BUSY {
		SendInput("{Text}" Text)
		return
	}
	OldClipboard := ClipboardAll()
	_SEND_INSTANT_CLIP_BUSY := true
	try {
		A_Clipboard := Text
		SendInput("^v")
		SetTimer(_SendInstant_RestoreClipboard.Bind(OldClipboard), -SEND_INSTANT_PASTE_DELAY_MS)
	} catch {
		A_Clipboard := OldClipboard
		_SEND_INSTANT_CLIP_BUSY := false
	}
}

; Commit any pending end-char hotstring before the next symbol is emitted.
; The space/backspace dance pokes the engine: the injected space round-trips
; through the prefix-watcher InputHook, fires any end-char-gated trigger, then
; the backspace removes it. The Sleep gives the OS message loop time to deliver
; the space's char event to the InputHook before the backspace lands.
;
; That Sleep parks the keyboard dispatch thread for ACTIVATE_HOTSTRINGS_DELAY_MS
; on EVERY Shift French-punctuation key — a hot, default key set. Gate the whole
; dance on there actually being a pending abbreviation in the engine buffer: when
; HSE_Buffer is empty (the common case — punctuation typed at a word boundary or
; after a space) there is nothing to commit, so we skip the space/backspace pair
; AND its blocking Sleep entirely. IsSet guards the load order: the engine buffer
; global lives in hotstring_engine_main.ahk, included alongside this file.
ActivateHotstrings() {
    ; Nothing to flush — no pending abbreviation, so skip the costly poke + Sleep.
    if (IsSet(HSE_Buffer) and HSE_Buffer == "") {
        return
    }
    SendNewResult(" ")
    if !_SendHook {
        Sleep(ACTIVATE_HOTSTRINGS_DELAY_MS)
    }
    SendNewResult("{BackSpace}", False)
}

GetSelection() {
    ; Save/restore the user's clipboard around a Ctrl+C capture of the current selection.
    ; Wrapped in try/finally so the clipboard is restored even on error/timeout.
    OldClipboard := ClipboardAll()
    Text := ""
    try {
        A_Clipboard := ""
        SendEvent("^c")
        ; Fail FAST: if the app never answered the Ctrl+C within the interactive
        ; window, ClipWait returns 0. Treat that as "no selection" and return ""
        ; so callers no-op — otherwise we would paste whatever stale content the
        ; restored clipboard holds, duplicating old text on a timeout.
        ; The second arg 1 makes ClipWait accept ANY clipboard format (images,
        ; files, native objects), not just text. Without it, a selected image
        ; causes ClipWait to time out after GET_SELECTION_TIMEOUT_SEC regardless
        ; and freezes the UI for 500ms (getselection-clipwait-binary-freeze fix).
        if !ClipWait(GET_SELECTION_TIMEOUT_SEC, 1) {
            LoggerWarn("hotstring_engine",
                "GetSelection: ClipWait timed out after {1}s; returning empty selection.",
                GET_SELECTION_TIMEOUT_SEC)
            return ""
        }
        Text := A_Clipboard
    } finally {
        A_Clipboard := OldClipboard
        OldClipboard := ""
    }
    return Text
}

; Set of Microsoft Office (and Teams) executable names.
global MICROSOFT_OFFICE_EXES := Map(
	"Teams.exe", true,
	"ms-teams.exe", true,
	"ONENOTE.exe", true,
	"olk.exe", true,
	"OUTLOOK.EXE", true,
	"WINWORD.EXE", true,
	"EXCEL.EXE", true,
	"POWERPNT.EXE", true,
)

MicrosoftApps() {
    try {
        exe := (IsSet(KLHook) and KLHook.HasOwnProp("prev_app")) ? KLHook.prev_app : WinGetProcessName("A")
        return MICROSOFT_OFFICE_EXES.Has(exe)
    }
    return false
}





; ============================================
; ============================================
; ======= 3/ Hotstring builders & core =======
; ============================================
; ============================================

; Resolve the collision priority to register a hotstring at, for the case where
; the caller did NOT pass an explicit ``Priority`` in its options. The hand loader
; (LoadHotstringsSection) always passes the fully resolved cascade value
; (individual > section > file > source) and never reaches here. The GENERATED-loader
; path only carries Category/Section, so fold in the section/file/source override
; cascade via HotstringsResolve so the ~3000 bundled hotstrings honour a user's
; per-section priority override instead of always landing at the common tier (10).
; HotstringsConfigInit runs long before RegisterAllHotstrings, so the override file
; is loaded here; HotstringsResolve is memoised per (category, section) so this stays
; cheap across thousands of entries. Falls back to HSE_PRIORITY_COMMON when no
; category context is available. NB: takes Category/Section, NOT the options Map —
; callers omit ``options`` entirely (declared ``options := unset``), and passing an
; unset variable as an argument throws UnsetError at the call site in AHK v2, so the
; ``IsSet(options)`` guard MUST live in the caller, never in a parameter here.
_HSE_ResolveRegistrationPriority(Category, Section) {
    global HSE_PRIORITY_COMMON
    if (Category != "") {
        Resolved := HotstringsResolve(Category, Section)
        if (Resolved.HasOwnProp("Priority") and Resolved.Priority != "") {
            return Resolved.Priority
        }
    }
    return HSE_PRIORITY_COMMON
}

; Public hotstring factory. The Map-based options API is kept because this
; runs once at startup (cold path); internally the options are decomposed
; into positional booleans AND the per-firing string ``BackSpaceSeq`` is
; pre-computed so the hot-path dispatcher ``_HotstringDispatch`` never has
; to run ``StrLen`` or concatenate on every keystroke.
CreateHotstring(Flags, Abbreviation, Replacement, options := unset) {
    OnlyText := (IsSet(options) and options.Has("OnlyText")) ? options["OnlyText"] : True
    FinalResult := (IsSet(options) and options.Has("FinalResult")) ? options["FinalResult"] : False
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options[
        "TimeActivationSeconds"] : 0
    IsRepeat := (IsSet(options) and options.Has("IsRepeat")) ? options["IsRepeat"] : False
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""
    ; An explicit Priority (passed by the hand loader) always wins; otherwise resolve
    ; the override cascade from Category/Section. The IsSet(options) guard MUST be here
    ; — passing the unset ``options`` variable into the helper would throw UnsetError.
    Priority := (IsSet(options) and options.Has("Priority"))
        ? options["Priority"]
        : _HSE_ResolveRegistrationPriority(Category, Section)

    ; HSE_DispatchMatch fires via Spec.Replacement, so the per-spec callback closure
    ; is only needed when a test has installed _HotstringRegistrar (it records and may
    ; invoke it). In production (Rec == 0) we skip building the closure and the
    ; ":flags:B0O:abbrev" string — both pure boot-time waste. The ternaries
    ; short-circuit, so neither is constructed unless a recorder is present.
    Rec := _HotstringRegistrar
    _RegisterHotstringFast(
        Rec, _HseFlagSubset(Flags), Abbreviation,
        Rec ? (":" Flags "B0O:" Abbreviation) : "",
        Rec ? _MakeHotstringCallback(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, Category, Section) : 0,
        _MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat, Category, Section, Priority)
    )
}

; Register a "raw callback" hotstring: the callback does ALL of its own
; conditional, variable-length sending/backspacing and returns a { Bs, Ins }
; effect (Bs chars removed from the buffer's right, Ins appended) for HSE buffer
; resync — see _HSE_DispatchRawCallback. Used by the formerly-native E-circumflex
; deadkey + "..." ellipsis so no AHK-native Hotstring() (hence no A_InputLevel
; dependency) remains. The B0O flag suffix matches CreateHotstring: the engine
; never auto-backspaces — the callback owns the screen edit.
CreateRawCallbackHotstring(Flags, Abbreviation, Callback, options := unset) {
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options["TimeActivationSeconds"] : 0
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""
    Priority := (IsSet(options) and options.Has("Priority"))
        ? options["Priority"]
        : _HSE_ResolveRegistrationPriority(Category, Section)
    ; The callback IS the dispatch here (HSE_DispatchMatch routes RawCallback specs
    ; to it), so it is always passed; only the recorder string is gated on Rec.
    Rec := _HotstringRegistrar
    _RegisterHotstringFast(
        Rec, _HseFlagSubset(Flags), Abbreviation,
        Rec ? (":" Flags "B0O:" Abbreviation) : "",
        Callback,
        { RawCallback: true, TimeActivationSeconds: TimeActivationSeconds, PrevCharKey: SubStr(Abbreviation, -2, 1), Category: Category, Section: Section, Priority: Priority }
    )
}

; Build the dispatch-metadata object HSE_DispatchMatch consumes. Kept next
; to the callback factory so the two stay in lockstep — every field used
; by the dispatcher has a clear origin in the original options dict.
; Priority defaults to 10 here — the literal mirrors HSE_PRIORITY_COMMON, which
; an AHK v2 default-parameter expression cannot reference. Both callers
; (CreateHotstring / CreateCaseSensitiveHotstrings) always pass the resolved
; value, so this default only guards a hypothetical third caller.
_MakeHotstringMeta(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat := false, Category := "", Section := "", Priority := 10) {
    static _NextSeq := 0
    _NextSeq += 1
    return {
        Replacement: Replacement,
        Trigger: Abbreviation,
        Length: StrLen(Abbreviation),
        OnlyText: OnlyText,
        FinalResult: FinalResult,
        TimeActivationSeconds: TimeActivationSeconds,
        PrevCharKey: SubStr(Abbreviation, -2, 1),
        IsRepeat: IsRepeat,
        Category: Category,
        Section: Section,
        Priority: Priority,
        Seq: _NextSeq
    }
}

; Builds the per-keystroke callback for a single hotstring variant. Computes
; ``BackSpaceSeq`` / ``PrevCharKey`` once at registration time and closes
; over both plus the positional option booleans. Each call produces a fresh
; closure with its own captures — safe to call in a loop over variants.
_MakeHotstringCallback(Replacement, Abbreviation, OnlyText, FinalResult, TimeActivationSeconds, Category := "", Section := "") {
    BackSpaceSeq := "{BackSpace " . StrLen(Abbreviation) . "}"
    AbbreviationLen := StrLen(Abbreviation)
    PrevCharKey := SubStr(Abbreviation, -2, 1)
    return (*) => _HotstringDispatch(Replacement, A_EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult,
        TimeActivationSeconds, AbbreviationLen, Abbreviation, Category, Section)
}

; Hot path — runs on every hotstring firing. ``BackSpaceSeq`` and
; ``PrevCharKey`` are pre-computed at registration time so this function
; does zero allocation / string work before dispatching the three sends.
_HotstringDispatch(Replacement, EndChar, BackSpaceSeq, PrevCharKey, OnlyText, FinalResult, TimeActivationSeconds, AbbreviationLen := 0, Trigger := "", Category := "", Section := "") {
    if IsTimeActivationExpired(PrevCharKey, TimeActivationSeconds) {
        return
    }
    ; Yield to a longer registered trigger that covers the same suffix.
    ; AHK native dispatches the most-recently-registered hotstring when two
    ; triggers overlap (e.g. "t★" fires before "@dt★" because the repeat
    ; section is registered last). HSE_LastMatch holds the longest match
    ; found by HSE_FeedChar on the same keystroke — if it is longer than our
    ; abbreviation, a better callback will fire (or already fired): abort.
    if (AbbreviationLen > 0 and HSE_LastMatch != ""
        and HSE_LastMatch.HasOwnProp("Length")
        and HSE_LastMatch.Length > AbbreviationLen) {
        return
    }
    ; Allow Replacement to be a zero-argument callable — resolved at fire time
    ; so dynamic values (dates, live data) are computed on each keystroke.
    if HasMethod(Replacement)
        Replacement := Replacement()

    if _ALTGR_KANA_FIXUP {
        ; Only needed when AltGr (SC138) is remapped to Kana at the driver
        ; level — without that remap the Up is a wasted SendEvent on the
        ; hottest path. ``HotstringEngineInit`` sets the flag at boot.
        SendEvent("{SC138 Up}")
    }

    ; Mute the prefix watcher's InputHook for the duration of the send burst.
    ; SendEvent re-injects characters that the hook would otherwise observe
    ; in pass-through mode, polluting the buffer with our own replacement
    ; (typing ``ct`` then ★ would surface a ``Taïwan`` preview right after
    ; the expansion because ``c'était`` ends with ``tai``). The release is
    ; deferred via SetTimer so any character still queued in the OS message
    ; loop is silently dropped before observation resumes.
    if IsSet(PrefixWatcherSuppress) {
        try PrefixWatcherSuppress(true)
    }

    ; Tag the backspace+replacement burst as synthetic so the keylogger keeps
    ; it out of the manual `chars` count and attributes the resulting n-grams
    ; to the hotstring source (esrc). Released on the same deferred timer as
    ; the prefix-watcher suppression so it covers the OS message-loop flush.
    try KL_MarkSynthetic("hotstring")

    try {
        isNotepad := false
        try {
            exe := (IsSet(KLHook) and KLHook.HasOwnProp("prev_app")) ? KLHook.prev_app : WinGetProcessName("A")
            isNotepad := (exe = "notepad.exe")
        }
        if isNotepad {
            ; Windows 11 Notepad mis-handles hotstrings (Windows bug, not AHK),
            ; so we route replacement through the clipboard.
            SendNewResult(BackSpaceSeq, False)
            SendInstant(Replacement . EndChar)
        } else if FinalResult {
            SendFinalResult(BackSpaceSeq, False)
            SendFinalResult(Replacement, OnlyText)
            SendFinalResult(EndChar, False)
        } else {
            SendNewResult(BackSpaceSeq, False)
            SendNewResult(Replacement, OnlyText)
            SendNewResult(EndChar, False)
        }
    }
    finally {
        ; 60 ms is enough margin for the OS to flush the SendEvent bursts
        ; into the InputHook before observation resumes. Tested against the
        ; longest replacements we ship (~30 chars) and against the Notepad
        ; clipboard path which is slower than the direct event injection.
        if IsSet(PrefixWatcherSuppress) {
            SetTimer((*) => PrefixWatcherSuppress(false), -60)
        }
        ; Release the synthetic flag on the same flush window — clearing it
        ; inline would let trailing replacement keystrokes look manual.
        SetTimer((*) => KL_ClearSynthetic(), -60)
    }
    ; Notify the WPM widget for end-char fires only — star (immediate) fires
    ; are already logged by the prefix watcher via HSE_DispatchMatch.
    ; KL_LogHotstring is guarded by Keylogger.initialized — safe to call here.
    if (EndChar != "") and (Trigger != "") and (Category != "") {
        repl_str := HasMethod(Replacement) ? "" : Replacement
        if IsSet(KL_LogHotstring) {
            try KL_LogHotstring(Trigger, repl_str, "endchar", "", Category, Section)
        } else if IsSet(WPMWidget_Push) {
            repl_len := HasMethod(Replacement) ? 1 : StrLen(repl_str)
            Loop repl_len
                try WPMWidget_Push(true, false, false, Category, Section)
        }
    }
}

IsTimeActivationExpired(PreviousCharacter, OptionTimeActivationSeconds) {
    ; Don't activate the hotstring if taped too slowly
    Now := A_TickCount
    if OptionTimeActivationSeconds > 0 {
        ; Fail CLOSED: a missing timestamp means we cannot prove the prior char
        ; was typed recently (it may have been pruned by LAST_SENT_KEY_TIME_MAX_AGE_MS
        ; after a long pause), so the time gate must treat it as expired rather
        ; than defaulting to "now" — which would let a deliberately-paused trigger
        ; fire as if it had just been typed.
        if !LastSentCharacterKeyTime.Has(PreviousCharacter) {
            return True
        }
        CharacterSentTime := LastSentCharacterKeyTime[PreviousCharacter]
        ; We need to convert into milliseconds, hence the multiplication by 1000
        if (Now - CharacterSentTime > OptionTimeActivationSeconds * 1000) {
            return True
        }
    }
    return False
}

CreateCaseSensitiveHotstrings(Flags, Abbreviation, Replacement, options := unset) {
    OnlyText := (IsSet(options) and options.Has("OnlyText")) ? options["OnlyText"] : True
    FinalResult := (IsSet(options) and options.Has("FinalResult")) ? options["FinalResult"] : False
    TimeActivationSeconds := (IsSet(options) and options.Has("TimeActivationSeconds")) ? options[
        "TimeActivationSeconds"] : 0
    IsRepeat := (IsSet(options) and options.Has("IsRepeat")) ? options["IsRepeat"] : False
    Category := (IsSet(options) and options.Has("Category")) ? options["Category"] : ""
    Section  := (IsSet(options) and options.Has("Section"))  ? options["Section"]  : ""
    ; An explicit Priority (passed by the hand loader) always wins; otherwise resolve
    ; the override cascade from Category/Section. The IsSet(options) guard MUST be here
    ; — passing the unset ``options`` variable into the helper would throw UnsetError.
    Priority := (IsSet(options) and options.Has("Priority"))
        ? options["Priority"]
        : _HSE_ResolveRegistrationPriority(Category, Section)

    Rec := _HotstringRegistrar

    ; Order matters: nbsp abbreviations must trigger before bare punctuation
    ; so the engine can delete the preceding non-breaking space correctly.
    ; The apostrophe key uses Chr(0x27) via a helper because AHK v2 parses
    ; a bare ' inside Map() as a string delimiter, causing a parse error.
    static UppercasedSymbols := _BuildUppercasedSymbols()

    ; Only the lowercase forms are needed to decide and take the case-conform fast
    ; path below; the Title / UPPER forms (4 StrXxx calls) serve solely the
    ; explicit-variant path, so they are computed only after the conform return.
    AbbreviationLowerCase := StrLower(Abbreviation)
    ReplacementLowerCase := StrLower(Replacement)

    ; ── Case-conform fast path ──────────────────────────────────────────────
    ; For a star trigger with no shift-symbol char (the common case — every
    ; magic-key text-expansion entry), register ONE case-INSENSITIVE spec instead
    ; of the lower/UPPER/Title explicit variants. HSE_DispatchMatch conforms the
    ; replacement casing to how the trigger was typed (see _HSE_ConformReplacement),
    ; roughly halving the magic-key registration with no observable change.
    ; Triggers containing "," or "'" KEEP the explicit path: their UPPER forms are
    ; DIFFERENT characters (shifted nbsp + ;/:/?) a case-insensitive match cannot
    ; reproduce — exactly the set _BuildUppercasedSymbols enumerates.
    IsStarTrigger := InStr(Flags, "*") > 0
    HasShiftSymbol := false
    for _, _ConformChar in StrSplit(Abbreviation) {
        if UppercasedSymbols.Has(_ConformChar) {
            HasShiftSymbol := true
            break
        }
    }
    if (IsStarTrigger and !HasShiftSymbol) {
        ; A 1-char abbreviation (before the magic key) has no distinct UPPER form.
        ConformOneChar := StrLen(RTrim(Abbreviation, ScriptInformation["MagicKey"])) == 1
        ; Drop the "C" flag so any-case typing matches the single registered spec.
        ConformFlags := StrReplace(Flags, "C")
        ConformMeta := _MakeHotstringMeta(ReplacementLowerCase, AbbreviationLowerCase, OnlyText,
            FinalResult, TimeActivationSeconds, IsRepeat, Category, Section, Priority)
        ConformMeta.CaseConform := true
        ConformMeta.ConformOneChar := ConformOneChar
        _RegisterHotstringFast(
            Rec, _HseFlagSubset(ConformFlags), AbbreviationLowerCase,
            Rec ? (":" ConformFlags "B0O:" AbbreviationLowerCase) : "",
            Rec ? _MakeHotstringCallback(ReplacementLowerCase, AbbreviationLowerCase, OnlyText, FinalResult, TimeActivationSeconds, Category, Section) : 0,
            ConformMeta
        )
        return
    }

    ; ── Explicit-variant path ───────────────────────────────────────────────
    ; Reached only for triggers that cannot use the conform fast path (non-star,
    ; or containing a shift-symbol char). The Title / UPPER case forms and the
    ; "C"-flag spec string are needed from here on, so they are built now rather
    ; than for every conform registration above.
    FlagsPortion := ":" Flags "CB0O:" ; O omits the ending character from the abbreviation
    AbbreviationTitleCase := StrTitle(Abbreviation)
    AbbreviationUpperCase := StrUpper(Abbreviation)
    FirstChar := SubStr(Abbreviation, 1, 1)
    ReplacementTitleCase := StrTitle(Replacement)
    ReplacementUpperCase := StrUpper(Replacement)

    ; Helper closure: installs one hotstring variant with positional args
    ; baked in, plus the pre-computed ``BackSpaceSeq`` / ``PrevCharKey`` so
    ; ``_HotstringDispatch`` skips the StrLen + SubStr work on every firing.
    ; Must be a fat-arrow lambda so it closes over the outer locals; nested
    ; ``f() {}`` functions in AHK v2 do not capture the enclosing scope.
    RegisterVariant := (Abbr, Repl) => _RegisterHotstringFast(
        Rec, _HseFlagSubset(Flags "C"), Abbr,
        Rec ? (FlagsPortion Abbr) : "",
        Rec ? _MakeHotstringCallback(Repl, Abbr, OnlyText, FinalResult, TimeActivationSeconds, Category, Section) : 0,
        _MakeHotstringMeta(Repl, Abbr, OnlyText, FinalResult, TimeActivationSeconds, IsRepeat, Category, Section, Priority)
    )

    RegisterVariant(AbbreviationLowerCase, ReplacementLowerCase)

    ; When an abbreviation is only one character, titlecase = uppercase
    if StrLen(RTrim(Abbreviation, ScriptInformation["MagicKey"])) == 1 {
        RegisterVariant(AbbreviationTitleCase, ReplacementTitleCase)
        return
    }

    if (StrLen(Abbreviation) >= 2) {
        for _, variant in GenerateUppercaseVariants(AbbreviationUpperCase, UppercasedSymbols) {
            RegisterVariant(variant, ReplacementUpperCase)
        }

        ; Titlecase: first letter uppercase, rest lowercase
        if !(StrLower(FirstChar) == StrUpper(FirstChar)) {
            RegisterVariant(AbbreviationTitleCase, ReplacementTitleCase)
        } else if UppercasedSymbols.Has(FirstChar) {
            for _, UppercasedSymbol in UppercasedSymbols[FirstChar] {
                RegisterVariant(UppercasedSymbol . SubStr(AbbreviationLowerCase, 2), ReplacementTitleCase)
            }
        }
    }
}





; =====================================================
; ==================================================
; ======= 4/ Last-sent-character ring buffer =======
; ==================================================
; =====================================================

; Fixed-capacity ring of the last N characters emitted by the driver, used by
; hotstrings / rolls / deadkeys to peek at what the user just typed without
; calling back into Win32. The ring avoids the O(n) ``RemoveAt(1)`` memmove
; the previous Array-based implementation performed on every keystroke.
;
; Indexing contract (unchanged for callers of ``GetLastSentCharacterAt``):
;   - Negative offset -k returns the k-th character from the NEWEST
;     (offset -1 = just-pushed char, offset -2 = the one before, …).
;   - Positive offset +k returns the k-th character from the OLDEST
;     still in the buffer (offset +1 = oldest).
;   - Any offset beyond the current fill count returns "".
global _LSC_CAP := 5
global _LSC_RING := ["", "", "", "", ""]
global _LSC_CURSOR := 0  ; 1-based index of the most recently written slot
global _LSC_LEN := 0     ; number of populated slots, saturates at _LSC_CAP

; Push a new character; O(1), no reallocation after boot.
_LSCPush(Char) {
    global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
    _LSC_CURSOR := Mod(_LSC_CURSOR, _LSC_CAP) + 1
    _LSC_RING[_LSC_CURSOR] := Char
    if _LSC_LEN < _LSC_CAP {
        _LSC_LEN += 1
    }
}

; Reset the ring to a known sequence (oldest-first). Kept as a thin wrapper
; so tests can seed state without reaching into globals.
_LSCResetFrom(Chars) {
    global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
    _LSC_RING := []
    loop _LSC_CAP {
        _LSC_RING.Push("")
    }
    _LSC_CURSOR := 0
    _LSC_LEN := 0
    for c in Chars {
        _LSCPush(c)
    }
}





; ==========================================
; =========================================
; ======= 5/ Text & history helpers =======
; =========================================
; ==========================================

; Build the UppercasedSymbols Map used by CreateCaseSensitiveHotstrings.
; Extracted into a function so the apostrophe key can be written as Chr(0x27)
; rather than a literal ' inside Map(), which AHK v2 would misparse as a
; string delimiter.
;
; CRITICAL — the "uppercase" form of a comma/apostrophe is NOT a plain ASCII
; space + punctuation. On the Ergopti Shift layer the comma key emits a NARROW
; no-break space (NNBSP, U+202F) followed by ";" and the period key emits a
; full no-break space (NBSP, U+00A0) followed by ":" — French typography pairs
; ";" with the narrow space and ":" with the full one (see layout_shift_caps.ahk).
; The deadkey path can also emit either no-break space. So a case-sensitive
; hotstring whose trigger contains a comma must generate its shifted variants
; with an nbsp/nnbsp prefix — exactly what the user types via Shift+comma /
; Shift+period. Using a plain ASCII space here was a bug on two counts:
; (1) "nbsp + : + D" never matched the generated trigger (so ",d → ds" never
; produced "DS" in caps), and (2) a plain "<space>:D" emoji typed after a normal
; word DID match and got swallowed into "DS". The variant set below is
; deliberately LENIENT — it pairs both no-break spaces with both ";" and ":" so
; the "DS" expansion fires regardless of which no-break space landed in the
; buffer, while a bare ":D" emoji (plain space) stays untouched.
_BuildUppercasedSymbols() {
    NNBSP := Chr(0x202F)  ; U+202F — narrow no-break space (Shift+comma, before ";")
    NBSP  := Chr(0xA0)    ; U+00A0 — full no-break space (Shift+period, before ":")
    m := Map(",", [NNBSP Chr(0x3B), NNBSP ":", NBSP Chr(0x3B), NBSP ":"])
    m[Chr(0x27)] := [NNBSP "?", NBSP "?"]
    return m
}

StrTitle(Text) {
    if (StrLen(Text) > 0) {
        return StrUpper(SubStr(Text, 1, 1)) StrLower(SubStr(Text, 2))
    } else {
        return Text
    }
}

; Case-conform a replacement to the way the user actually typed the trigger. This
; replaces the old explicit lower/UPPER/Title variant registrations:
; CreateCaseSensitiveHotstrings now registers ONE case-insensitive spec (for star
; triggers without a shift-symbol char), and HSE_DispatchMatch calls this at fire
; time to pick the output casing — roughly halving the magic-key registration
; (~2119 -> ~1000 specs) with no observable change.
;   - ``Repl``      the registered (lowercase) replacement.
;   - ``Typed``     the trigger exactly as typed (the matched buffer suffix).
;   - ``Canonical`` the registered (lowercase) trigger.
;   - ``OneChar``   true when the abbreviation is a single character before the
;                   magic key — such a trigger has no distinct UPPER form (the old
;                   code registered lowercase + Title only, Title == Upper for one
;                   letter), so a typed capital maps to the Title replacement.
; Comparisons use ``==`` (case-SENSITIVE in AHK v2). Sets ``DoFire := false`` and
; returns "" when the typed case is not a clean lower / UPPER / Title form: the old
; code registered no variant for mixed case, so the hotstring must NOT fire then.
_HSE_ConformReplacement(Repl, Typed, Canonical, OneChar, &DoFire) {
    DoFire := true
    if (Typed == Canonical) {
        return Repl
    }
    TitleForm := StrTitle(Canonical)
    ; "!==" is case-SENSITIVE inequality — plain "!=" is case-insensitive in AHK v2
    ; and would treat "Ab" and "ab" as equal, collapsing the Title branch.
    if (Typed == TitleForm and TitleForm !== Canonical) {
        return StrTitle(Repl)
    }
    if (Typed == StrUpper(Canonical)) {
        return OneChar ? StrTitle(Repl) : StrUpper(Repl)
    }
    DoFire := false
    return ""
}

GenerateUppercaseVariants(AbbreviationUpperCase, UppercasedSymbols) {
    Variants := [AbbreviationUpperCase]
    if !(UppercasedSymbols is Map) {
        return Variants
    }
    for i, Char in StrSplit(AbbreviationUpperCase) {
        if UppercasedSymbols.Has(Char) {
            for UpperSymbol in UppercasedSymbols[Char] {
                AbbreviationUpperCaseVariant :=
                    SubStr(AbbreviationUpperCase, 1, i - 1)
                    . UpperSymbol
                    . SubStr(AbbreviationUpperCase, i + 1)
                Variants.Push(AbbreviationUpperCaseVariant)
            }
        }
    }
    return Variants
}

GetLastSentCharacterAt(Offset) {
    global _LSC_RING, _LSC_CAP, _LSC_CURSOR, _LSC_LEN
    if _LSC_LEN == 0 {
        return ""
    }
    if Offset < 0 {
        K := -Offset
        if K > _LSC_LEN {
            return ""
        }
        Idx := Mod(_LSC_CURSOR - K + _LSC_CAP, _LSC_CAP) + 1
        return _LSC_RING[Idx]
    }
    if Offset > 0 {
        if Offset > _LSC_LEN {
            return ""
        }
        ; Oldest slot is cursor + 1 wrapped when the buffer is full, otherwise slot 1.
        OldestIdx := (_LSC_LEN < _LSC_CAP) ? 1 : (Mod(_LSC_CURSOR, _LSC_CAP) + 1)
        Idx := Mod(OldestIdx - 1 + (Offset - 1), _LSC_CAP) + 1
        return _LSC_RING[Idx]
    }
    return ""
}

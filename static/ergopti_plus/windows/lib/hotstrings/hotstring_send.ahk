; lib/hotstrings/hotstring_send.ahk

; ==============================================================================
; MODULE: Hotstring Engine — Low-level Send & Ring Buffer
; DESCRIPTION:
; Low-level send primitives (SendNewResult, SendFinalResult, SendInstant,
; ActivateHotstrings, GetSelection) and the last-sent-character ring buffer
; (_LSC_*) used by time-gated triggers and deadkey sequences.
;
; Included by lib/hotstrings/hotstring_engine.ahk after the constants section.
; ==============================================================================





; =======================================
; =======================================
; ======= 1/ Low-level send layer =======
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
; to avoid modifier side effects on symbols like ', ", accents. UpdateRing
; controls whether Text feeds the last-sent-character ring: pass false for a
; backspace-only call (e.g. the Notepad clipboard branch's pre-paste erase),
; where Text is a control sequence ("{BackSpace 5}") rather than a real
; emitted character — SubStr(Text, -1) on that sequence would record its
; trailing "}" instead of what actually landed on screen.
SendNewResult(Text, OnlyText := True, UpdateRing := True) {
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
    if UpdateRing {
        UpdateLastSentCharacter(SubStr(Text, -1))
    }
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

SendInstant(Text, Prefix := "") {
	; Sends a large text through the clipboard while keeping Prefix (typically the
	; hotstring erase sequence) in the SAME SendInput burst as Ctrl+V. Splitting
	; these two injections lets a physical key land between erase and paste.
	; Uses try so the user's clipboard is restored even on error/crash.
	global _SEND_INSTANT_CLIP_BUSY
	if _SendHook {
		Hook := _SendHook
		Hook("SendInstant", Text, Prefix)
		return
	}
	; Reentrancy guard: a previous SendInstant's deferred restore has not run
	; yet, so the clipboard still holds its payload. Touching A_Clipboard now
	; would race the in-flight paste/restore — fall back to the clipboard-free
	; {Text} route so the two dances never interleave.
	; SendInput (not SendEvent) is used here to stay atomic and avoid interleaving
	; with the InputHook, which processes SendEvent characters as physical input.
	if _SEND_INSTANT_CLIP_BUSY {
		SendInput(Prefix . "{Text}" . Text)
		return
	}
	OldClipboard := ClipboardAll()
	_SEND_INSTANT_CLIP_BUSY := true
	try {
		A_Clipboard := Text
		; Prefix and Ctrl+V are one kernel injection transaction. Critical callers
		; therefore cannot be interrupted after the erase but before the paste.
		SendInput(Prefix . "^v")
		SetTimer(_SendInstant_RestoreClipboard.Bind(OldClipboard), -SEND_INSTANT_PASTE_DELAY_MS)
	} catch {
		A_Clipboard := OldClipboard
		_SEND_INSTANT_CLIP_BUSY := false
	}
}

; Commit any pending end-char hotstring before the next symbol is emitted.
; The space/backspace dance pokes the engine: the injected space round-trips
; through the prefix-watcher InputHook, fires any end-char-gated trigger, then
; the backspace removes it. SendEvent delivers the synthetic char during this
; call; yielding with Sleep here let a physical key land between the two sends.
;
; That Sleep parks the keyboard dispatch thread for ACTIVATE_HOTSTRINGS_DELAY_MS
; on EVERY Shift French-punctuation key — a hot, default key set. Gate the whole
; dance on there actually being a pending abbreviation in the engine buffer: when
; HSE_Buffer is empty (the common case — punctuation typed at a word boundary or
; after a space) there is nothing to commit, so we skip the space/backspace pair
; AND its former blocking delay entirely. IsSet guards the load order: the engine buffer
; global lives in hotstring_engine_main.ahk, included alongside this file.
ActivateHotstrings() {
    ; Nothing to flush — no pending abbreviation, so skip the costly poke.
    if (IsSet(HSE_Buffer) and HSE_Buffer == "") {
        return
    }
    previous_critical := Critical("On")
    try {
        SendNewResult(" ")
        SendNewResult("{BackSpace}", False)
    } finally {
        Critical(previous_critical)
    }
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





; ==================================================
; ==================================================
; ======= 2/ Last-sent-character ring buffer =======
; ==================================================
; ==================================================

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

; modules/keymap/layout/layout_altgr.ahk

; ==============================================================================
; MODULE: AltGr Layer Tables
; DESCRIPTION:
; The AltGr layer of the emulated Ergopti layout, built from the Ergopti
; .keylayout (layout_ergopti.ahk) and registered here. Each scan code is mapped
; to a ``{Plain, Shifted}`` pair of zero-argument callables which the shared
; dispatcher runs depending on the current Shift state.
;
; FEATURES & RATIONALE:
; 1. Lookup is O(1) Map vs. AHK’s individual hotkey-variant matching, and the
;    repeated 5-line ``if Shift then X else Y`` block from the original
;    layout.ahk is collapsed into a single dispatcher function.
; 2. The three logical sub-layers are kept as separate tables so the original
;    registration order is preserved bit-for-bit (ErgoptiPlus overrides →
;    ErgoptiAltGr Number row → ErgoptiAltGr base rows, then the two rolls in
;    modules/keymap/layout.ahk). AutoHotkey fires the earliest-created eligible
;    variant of a hotkey (project-ahk-hotkey-variant-precedence), so flattening
;    the tables would change which binding fires when several Layout
;    sub-features are enabled.
; 3. No character is written here: the tables follow the .keylayout, so a
;    layout change is a new .keylayout, not an edit of this file.
; 4. Action callables are built with ``Bind`` (ErgoptiLayout_Action) — this
;    avoids the per-press cost of compiling a fat-arrow lambda.
;
; DEPENDENCIES:
; The callables bind ``SendNewResult``, ``WrapTextIfSelected``, ``DeadKey``
; and ``SpaceAroundSymbols`` (modules/keymap/layout.ahk). AHK v2 resolves these
; lazily so the ``#Include`` order only needs to guarantee that everything is
; part of the same compilation unit before ``RegisterAltGrLayer`` is called.
; ==============================================================================





; ===============================
; ===============================
; ======= 1/ Layer tables =======
; ===============================
; ===============================

; The AltGr tables come from the Ergopti layout tables read from the .keylayout
; (layout_ergopti.ahk), built by ``_BuildAltGrTables`` when the layer
; registers, once those tables are loaded.

global ALTGR_PLUS_OVERRIDES := ""
global ALTGR_NUMBER_ROW := ""
global ALTGR_BASE_ROWS := ""
global CTRL_ALT_NUMPAD := ""

; The physical-state port is shared by captured criteria and direct gate calls.
global _ALTGR_PHYSICAL_STATE_QUERY := KS_IsDown

; ``{Plain, Shifted}`` callables of every key of two parallel spec tables.
_AltGrTableFromSpec(Plain, Shifted, DeadTables) {
    Table := Map()
    for SC, Descriptor in Plain {
        if !Shifted.Has(SC)
            throw ValueError("An AltGr key has no Shift+AltGr entry.", -1, SC)
        Table[SC] := { Plain: ErgoptiLayout_Action(Descriptor, DeadTables),
                       Shifted: ErgoptiLayout_Action(Shifted[SC], DeadTables) }
    }
    return Table
}

_BuildAltGrTables() {
    global ALTGR_PLUS_OVERRIDES, ALTGR_NUMBER_ROW, ALTGR_BASE_ROWS, CTRL_ALT_NUMPAD

    Spec := ErgoptiLayout_Spec()
    Levels := Spec["levels"]
    DeadTables := Spec["dead_keys"]

    ; Ergopti+ keys: what the Ergopti+ .keylayout changes on AltGr (« % », « où »
    ; followed by the space-around-symbols setting, « ! »).
    ALTGR_PLUS_OVERRIDES := _AltGrTableFromSpec(Levels["altgr_plus"], Levels["altgr_plus_shift"], DeadTables)

    ; Number row: superscripts, subscripts, € and the currency dead key.
    ALTGR_NUMBER_ROW := _AltGrTableFromSpec(Levels["altgr_number_row"], Levels["altgr_number_row_shift"], DeadTables)

    ; ===============================================================
    ; Ctrl + Alt different from AltGr — programs like Google Docs use
    ; Ctrl + Alt + Numpad N for heading levels and similar bindings.
    ; ===============================================================
    CTRL_ALT_NUMPAD := Map(
        "SC002", "^!{Numpad1}",
        "SC003", "^!{Numpad2}",
        "SC004", "^!{Numpad3}",
        "SC005", "^!{Numpad4}",
        "SC006", "^!{Numpad5}",
        "SC007", "^!{Numpad6}",
        "SC008", "^!{Numpad7}",
        "SC009", "^!{Numpad8}",
        "SC00A", "^!{Numpad9}",
        "SC00B", "^!{Numpad0}",
    )

    ; Every other row, the space bar and the dead keys (superscript, Greek,
    ; diaeresis, double-struck, currency, circumflex, subscript).
    ALTGR_BASE_ROWS := _AltGrTableFromSpec(Levels["altgr_rows"], Levels["altgr_rows_shift"], DeadTables)
}





; ===============================================
; ===============================================
; ======= 2/ Dispatchers and registration =======
; ===============================================
; ===============================================

; Discriminate a real AltGr/Kana keypress from a ghost SC138 prefix injected
; by an OS keyboard driver (e.g. Bépo) around AltGr-mapped keys like `'`.
;
; Two valid scenarios must be allowed through:
;   1. Vanilla AltGr layouts (Bépo, US-International, …): AltGr is physical
;      RAlt. The OS injects a ghost LCtrl+RAlt prefix around AltGr-mapped
;      keys; that ghost releases RAlt before the next key, so requiring
;      GetKeyState("RAlt","P") filters it out reliably.
;   2. AltGr-as-Kana driver remap (KbdEdit/MSKLC): AltGr is mapped to the
;      Kana virtual key, which sends SC138 with no LCtrl/RAlt modifiers.
;      Physical RAlt is never down, so the gate must accept SC138 directly.
;
; The discriminator is _ALTGR_KANA_FIXUP, auto-detected via a reverse
; VK_RMENU→SC probe (infra/altgr_family.ahk), at boot and then on every change
; of the foreground window's layout, without a reload. Manual TOML override
; available via ScriptInformation["AltGrIsKanaRemap"] in case the probe ever
; misfires.
; PhysicalStateFn optionally replaces the KeyState port for a direct call.
IsRealAltGrPress(PhysicalStateFn := unset) {
    global _ALTGR_KANA_FIXUP, _OB_ALTGR_PASSTHROUGH, _ALTGR_PHYSICAL_STATE_QUERY
    Query := IsSet(PhysicalStateFn) ? PhysicalStateFn : _ALTGR_PHYSICAL_STATE_QUERY
    if !HasMethod(Query, "Call")
        throw TypeError("AltGr eligibility requires a physical-state query.")
    ; While the onboarding wizard is on screen the user has not yet committed
    ; any Ergopti feature, so every SC138-prefixed hotkey in the driver must
    ; defer to the host Windows layout. Returning false here neutralises every
    ; #HotIf that gates on IsRealAltGrPress(), which is the gate used by every
    ; static SC138 combo in the codebase. SC138 still stays an armed prefix:
    ; the always-eligible "~SC138 & ~F24" anchor (platform/remap/altgr.ahk)
    ; has no criterion. AutoHotkey reads SC138 as the RAlt modifier and never
    ; suppresses a modifier prefix that no variant fires for (hook.cpp Case #1,
    ; "this_key.as_modifiersLR"), so the native AltGr press reaches the
    ; wizard. The flag flips back automatically when the wizard committed
    ; (Reload) or when the user closed it (ExitApp).
    if (IsSet(_OB_ALTGR_PASSTHROUGH) and _OB_ALTGR_PASSTHROUGH) {
        return false
    }
    ; AltGr held as another modifier or a layer is that modifier or layer, on
    ; every layout: AltGr+C held as Ctrl is Ctrl+C. On a Kana layout the combos
    ; stayed eligible and took the key instead (the AltGr layer's character, or
    ; a script chord for Enter).
    if !AltGrKeyIsAltGr() {
        return false
    }
    if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
        ; AHK can retain a Kana prefix after release. Reject it before the
        ; suffix is captured; the callback's later guard cannot restore it.
        ; The unconditional prefix anchor still arms SC138 on its own press.
        return Query.Call("SC138")
    }
    ; Vanilla AltGr: real press keeps RAlt physically held; ghost releases it.
    return Query.Call("RAlt")
}

; #HotIf of the script chords (AltGr+Escape quits, +Enter toggles the pause,
; +BackSpace reloads, +Delete opens the personal shortcuts), running and paused
; (infra/script_altgr_hotkeys.ahk). On QWERTY the AltGr key is a plain right
; Alt, and the always-eligible prefix anchor arms SC138 on its first press:
; RAlt+Esc, Windows' Alt+Esc, quit the driver. These chords are destructive, so
; they need a layout whose AltGr key is an AltGr; on QWERTY those keys stay
; native Alt chords.
; @param AltGrPressed {Boolean} The chord's own AltGr check.
; @return {Boolean}
ScriptAltGrChordIsLive(AltGrPressed) {
    return AltGrPressed and KS_LayoutHasAltGr()
}

; #HotIf of the script chords' suffix-only twins on a Kana-style layout
; (infra/script_altgr_hotkeys.ahk): there the chord runs from Enter, BackSpace,
; Delete or Escape alone while SC138 is physically down. They are registered on
; every layout and read the family here, per press: the family follows the
; foreground window's layout, so a registration decided at boot would miss a
; Kana window opened later or keep firing in a standard one. They stand down
; with the combinations when the AltGr key holds another modifier or a layer
; (AltGrKeyIsAltGr): AltGr+Enter held as Ctrl is Ctrl+Enter, not a script chord.
; @param AltGrDown {Boolean} SC138 physically down.
; @return {Boolean}
ScriptAltGrKanaChordIsLive(AltGrDown) {
    global _ALTGR_KANA_FIXUP
    return AltGrDown and IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP and AltGrKeyIsAltGr()
}

; The #HotIf of each script chord hotkey, bound to its slot by
; ScriptAltGrChordPlan: the chord's AltGr check, then whether the slot runs an
; action now (ScriptShortcutSlotRunsAction). Without the second half an
; unassigned slot still took AltGr+Enter and retyped a bare Enter
; (script-chord-slot-2026-09-30). The trailing parameter swallows the hotkey
; name AutoHotkey passes to a criterion.
; @param Slot {String} The SCRIPT_SHORTCUT_SLOTS id the hotkey runs.
; @return {Boolean}
ScriptAltGrChordRunsSlot(Slot, *) {
    return ScriptAltGrChordIsLive(IsRealAltGrPress()) and ScriptShortcutSlotRunsAction(Slot)
}

; The Kana-style twin: the suffix alone while SC138 is physically down.
ScriptAltGrKanaChordRunsSlot(Slot, *) {
    return ScriptAltGrKanaChordIsLive(GetKeyState("SC138", "P")) and ScriptShortcutSlotRunsAction(Slot)
}

; The paused twin: while paused the combinations cannot arm (the prefix anchor
; is suspended with every hotkey), so the chord runs from the suffix alone.
ScriptAltGrPausedChordRunsSlot(Slot, *) {
    return ScriptAltGrChordIsLive(A_IsSuspended and GetKeyState("SC138", "P")) and ScriptShortcutSlotRunsAction(Slot)
}

; The script chord hotkeys, three per slot, each with the criterion bound to
; its slot (infra/script_altgr_hotkeys.ahk registers them in this order).
; - "SC138 & <key>": the AltGr key by its scan code only. "RAlt & Enter" and
;   "^!Enter" twins were dead: the SC138 hotkeys route every right Alt event to
;   the scan code's record, and the suffix scan-code hotkeys route those keys'
;   events to theirs, so a twin named by a virtual key was never looked up
;   (hook.cpp: sc_takes_precedence). ScriptAltGrChordIsLive keeps them, running
;   and paused, off a layout whose AltGr key is a plain Alt: on QWERTY RAlt+Esc
;   must stay Alt+Esc, not quit the driver.
; - "$<key>": the Kana-style twin, registered on every layout: the AltGr family
;   follows the foreground window's layout (infra/altgr_family.ahk), so the
;   criterion decides per press whether this layout is a Kana one.
; - "$*<key>": the paused twin. With * it also matches under the LCtrl+RAlt an
;   AltGr layout holds: without it, AltGr+Enter could not unpause there.
; @param Slots {Array} The slot ids, in registration order.
; @param ScanCodes {Map} Slot id -> scan code of the key AltGr modifies.
; @return {Array} Maps of "slot", "scan_code", "hotkey" and "criterion".
ScriptAltGrChordPlan(Slots, ScanCodes) {
    if (ScanCodes.Count != Slots.Length)
        throw ValueError("Every script chord slot needs exactly one scan code.", -1)
    Plan := []
    for Slot in Slots {
        if !ScanCodes.Has(Slot)
            throw ValueError("A script chord slot has no scan code.", -1, Slot)
        Sc := ScanCodes[Slot]
        if !RegExMatch(Sc, "^SC[0-9A-F]{3}$")
            throw ValueError("A script chord scan code is malformed.", -1, Sc)
        Plan.Push(Map("slot", Slot, "scan_code", Sc,
            "hotkey", "SC138 & " . Sc, "criterion", ScriptAltGrChordRunsSlot.Bind(Slot)))
        Plan.Push(Map("slot", Slot, "scan_code", Sc,
            "hotkey", "$" . Sc, "criterion", ScriptAltGrKanaChordRunsSlot.Bind(Slot)))
        Plan.Push(Map("slot", Slot, "scan_code", Sc,
            "hotkey", "$*" . Sc, "criterion", ScriptAltGrPausedChordRunsSlot.Bind(Slot)))
    }
    return Plan
}

; Run the Plain or Shifted callable from ``Table[SC]`` depending on the
; current Shift state. The ``*`` parameter swallows the hotkey name that
; AHK passes when invoking a hotkey callback.
;
; IMPORTANT: ``Entry.Plain`` is extracted into a local before the call so
; AHK does not invoke it as a method on ``Entry`` and silently pass ``Entry``
; as an implicit first argument — that would overflow BoundFuncs which
; already have all positional parameters bound (e.g. ``WrapTextIfSelected``).

AltGrShiftDispatch(SC, Table, *) {
    if !Table.Has(SC) {
        return
    }
    ; Regression guard-rail (kept on purpose for future debugging): the AltGr
    ; layer must only ever dispatch while SC138 is PHYSICALLY held. The hotkey
    ; criterion checks that authority on both layout families; this second check
    ; covers a release before the queued callback runs and reports it explicitly.
    if !GetKeyState("SC138", "P") {
        try LoggerWarn("LayoutAltGr",
            "Spurious AltGr dispatch (SC138 not physically held — prefix flag latched?): SC={1}, SC138 logical={2}, suspended={3}.",
            SC, GetKeyState("SC138"), A_IsSuspended)
        ; AHK can retain the custom-combination prefix internally after Suspend
        ; even though the key is physically up.  Never run an AltGr callback in
        ; that state: doing so turns the next ordinary key into an unsolicited
        ; layer character/action. This callback cannot restore a captured key:
        ; the criterion must reject a stale prefix before the suffix is taken.
        return
    }
    ; This dispatcher only runs on a real AltGr/Kana press — the HotIf in
    ; RegisterAltGrLayer guards every SC138 hotkey on IsRealAltGrPress().
    ; Ghost SC138 prefixes (injected by an OS driver for AltGr-mapped keys
    ; like Bépo’s `'`) therefore fall through to the regular *SC<key>/SC<key>
    ; remap hotkeys and produce the correct base-layer character.
    Entry := Table[SC]
    Cb := AltGrLayerEntryCallable(Entry)
    _AtCrit := Critical("On")   ; Serialize the AltGr emit like _RemapEmit
    try {
        AltGrLayerEmit(Cb)
    } finally {
        Critical(_AtCrit)
    }
}

; Whether Shift is held for an AltGr-layer output: physically, or by a
; tap-hold's synthetic hold. The AltGr key held as Shift+AltGr presses its
; Shift synthetically (so do a Space or RShift held as Shift): reading the
; physical Shift alone typed the Plain entry where a physical Shift+AltGr
; typed the Shifted one. Every AltGr-layer output that picks by Shift asks
; this: the table entries, the two rolls and the AltGr+LAlt shortcut.
; @return {Boolean}
AltGrLayerShiftHeld() {
    global _TapHoldKeyIsDown, _TH_SyntheticHeldKeys
    return _TapHoldKeyIsDown.Call("Shift", "P")
        or _TH_SyntheticHeldKeys.Has("LShift") or _TH_SyntheticHeldKeys.Has("RShift")
}

; The callable of an AltGr table entry for the current Shift state.
; @param Entry {Object} A table entry with Plain and Shifted callables.
; @return {Func} Entry.Shifted or Entry.Plain, not invoked.
AltGrLayerEntryCallable(Entry) {
    return AltGrLayerShiftHeld() ? Entry.Shifted : Entry.Plain
}

; Run one AltGr-layer output (a table entry or a roll). An AltGr a tap-hold holds
; synthetically is kept down by AutoHotkey around the output's non-blind Send,
; as every modifier the driver pressed itself: where right Alt is a plain Alt
; (QWERTY) the layer's text then went out under Alt, as menu mnemonics instead
; of characters. That owned key is lifted around the output (masked) and given
; back; an AltGr the user holds is lifted by the Send itself.
; @param EmitFn {Func} Zero-argument output.
AltGrLayerEmit(EmitFn) {
    return TapHoldSendWithOwnedKeyUp(KS_AltGrKeyName(), EmitFn)
}

; Whether a Ctrl+Alt chord is a real Ctrl+Alt, not the layout's AltGr key: the
; physical AltGr key (KS_AltGrKeyName: RAlt, or SC138 on a Kana layout) is up.
; A real AltGr press is taken first by the AltGr layer's "SC138 & X"
; combinations anyway. While the first-run wizard is up every AltGr-looking
; chord stays the host layout's, as IsRealAltGrPress keeps it.
; @return {Boolean}
IsCtrlAltNotAltGr() {
    global _OB_ALTGR_PASSTHROUGH
    if (IsSet(_OB_ALTGR_PASSTHROUGH) and _OB_ALTGR_PASSTHROUGH) {
        return false
    }
    return !GetKeyState(KS_AltGrKeyName(), "P")
}

CtrlAltDispatch(Combo, *) {
    SendFinalResult(Combo)
}

; Register every AltGr-layer hotkey from the three tables, preserving the
; exact same order as the original ``SC138 & SCxxx::`` blocks so AHK’s
; "most-recently-registered variant wins" rule produces identical
; behaviour when several Layout sub-features are simultaneously enabled.
RegisterAltGrLayer(HotkeyFn := Hotkey, HotIfFn := HotIf, DispatchFn := AltGrShiftDispatch, RealAltGrFn := IsRealAltGrPress) {
    if !HasMethod(HotkeyFn, "Call") || !HasMethod(HotIfFn, "Call") || !HasMethod(DispatchFn, "Call") || !HasMethod(RealAltGrFn, "Call")
        throw TypeError("AltGr registration requires callable native registration and dispatch ports.")
    _BuildAltGrTables()
    try LoggerStart("LayoutAltGr", "Registering AltGr layer hotkeys…")

    ; AltGr hotkeys must only fire on a real AltGr/Kana press. The
    ; IsRealAltGrPress() helper accepts physical RAlt (Bépo OS) or any SC138
    ; press without LCtrl held (Kana / custom layouts), and rejects the OS
    ; driver’s ghost SC138 prefix which arrives with LCtrl still held.

    ; try/finally: HotIf sets a PROCESS-WIDE criterion, so a throw before the
    ; reset leaks it into every later Hotkey() call in the driver — silently
    ; gating unrelated layers behind this condition.
    try {
        ; --- ErgoptiPlus overrides (registered first, lowest precedence) ---
        HotIfFn.Call((*) => ErgoptiLayout_PlusIsActive() and RealAltGrFn.Call())
        for SC in ALTGR_PLUS_OVERRIDES {
            HotkeyFn.Call("SC138 & " . SC, DispatchFn.Bind(SC, ALTGR_PLUS_OVERRIDES), "I2")
        }

        ; --- ErgoptiAltGr Number row + Ctrl+Alt Numpad mappings ---
        ; Note: ergopti_base is intentionally NOT required here — superscripts,
        ; subscripts and the € sign are layout-independent and must work even when
        ; the Ergopti keyboard emulation is off.
        HotIfFn.Call((*) => Features["layout"]["ergopti_alt_gr"] and RealAltGrFn.Call())
        for SC in ALTGR_NUMBER_ROW {
            HotkeyFn.Call("SC138 & " . SC, DispatchFn.Bind(SC, ALTGR_NUMBER_ROW), "I2")
        }
        ; A real Ctrl+Alt chord, never the AltGr key: under the AltGr gate above
        ; these needed the physical AltGr, which a Ctrl+Alt chord never holds,
        ; so they were dead on standard layouts and QWERTY.
        HotIfFn.Call((*) => Features["layout"]["ergopti_alt_gr"] and IsCtrlAltNotAltGr())
        for SC, Combo in CTRL_ALT_NUMPAD {
            HotkeyFn.Call("^!" . SC, CtrlAltDispatch.Bind(Combo), "I2")
        }

        ; --- ErgoptiAltGr base rows (registered last, highest precedence) ---
        HotIfFn.Call((*) => Features["layout"]["ergopti_alt_gr"] and RealAltGrFn.Call())
        for SC in ALTGR_BASE_ROWS {
            HotkeyFn.Call("SC138 & " . SC, DispatchFn.Bind(SC, ALTGR_BASE_ROWS), "I2")
        }

    } finally {
        HotIfFn.Call() ; Reset to no condition
    }
    try LoggerSuccess("LayoutAltGr", "AltGr layer registered ({1} entries).",
        ALTGR_PLUS_OVERRIDES.Count + ALTGR_NUMBER_ROW.Count + CTRL_ALT_NUMPAD.Count
        + ALTGR_BASE_ROWS.Count)
}

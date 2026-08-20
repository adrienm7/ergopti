; modules/keymap/layout/layout_altgr.ahk

; ==============================================================================
; MODULE: AltGr Layer Tables
; DESCRIPTION:
; Single source of truth for the AltGr layer of the emulated Ergopti layout.
; Each scan code is mapped to a ``{Plain, Shifted}`` pair of zero-argument
; callables (``BoundFunc`` or fat-arrow ``Func``) which the shared dispatcher
; runs depending on the current Shift state.
;
; FEATURES & RATIONALE:
; 1. Lookup is O(1) Map vs. AHK’s individual hotkey-variant matching, and the
;    repeated 5-line ``if Shift then X else Y`` block from the original
;    layout.ahk is collapsed into a single dispatcher function.
; 2. The three logical sub-layers are kept as separate tables so the original
;    registration order is preserved bit-for-bit (ErgoptiPlus overrides →
;    ErgoptiAltGr Number row → ErgoptiAltGr base rows, then the two rolls
;    LAST in modules/keymap/layout.ahk so the roll variant wins its shared chord —
;    altgr-rolls-dead-precedence). AHK’s most-recently-registered-variant-wins
;    rule depends on this ordering, so flattening the tables would silently
;    change which binding fires when multiple Layout sub-features are enabled.
; 3. Adding a new key on the AltGr layer is a one-line Map entry instead of a
;    six-line ``SC138 & SCxxx::`` block.
; 4. Action callables are built with ``Bind`` whenever possible — this avoids
;    the per-press cost of compiling a fat-arrow lambda and surfaces the
;    intent (a partial application of a known function) directly in the table.
;
; DEPENDENCIES:
; This module references ``SendNewResult``, ``WrapTextIfSelected``, ``DeadKey``,
; the ``DeadkeyMappingX`` Maps and ``SpaceAroundSymbols``, all defined in
; modules/keymap/layout.ahk. AHK v2 resolves these lazily so the ``#Include`` order
; only needs to guarantee that everything is part of the same compilation unit
; before ``RegisterAltGrLayer`` is called.
; ==============================================================================





; ===============================
; ===============================
; ======= 1/ Layer tables =======
; ===============================
; ===============================

; The three tables below are populated lazily — at the time this file is
; loaded, the ``DeadkeyMappingX`` globals and ``SpaceAroundSymbols`` are not
; necessarily defined yet. Building them lazily inside ``_BuildAltGrTables``
; sidesteps any include-order constraint: the function is called from
; ``RegisterAltGrLayer`` after every layout-module global has been initialised.

global ALTGR_PLUS_OVERRIDES := ""
global ALTGR_NUMBER_ROW := ""
global ALTGR_BASE_ROWS := ""
global CTRL_ALT_NUMPAD := ""

_BuildAltGrTables() {
    global ALTGR_PLUS_OVERRIDES, ALTGR_NUMBER_ROW, ALTGR_BASE_ROWS, CTRL_ALT_NUMPAD

    ; ==============================================
    ; ErgoptiPlus overrides for SC012, SC013, SC018
    ; ==============================================
    ; ``SpaceAroundSymbols`` is read at call time so the Plus toggling stays
    ; live across reloads. The captured string is cheap (boot-time computed).
    ALTGR_PLUS_OVERRIDES := Map(
        "SC012", { Plain: WrapTextIfSelected.Bind("%", "%", "%"),
                   Shifted: SendNewResult.Bind("Œ") },
        "SC013", { Plain: () => SendNewResult("où" . SpaceAroundSymbols),
                   Shifted: () => SendNewResult("Où" . SpaceAroundSymbols) },
        "SC018", { Plain: WrapTextIfSelected.Bind("!", "!", "!"),
                   Shifted: SendNewResult.Bind(" !") },
    )

    ; ==============================
    ; ErgoptiAltGr Number row
    ; ==============================
    ALTGR_NUMBER_ROW := Map(
        "SC029", { Plain: SendNewResult.Bind("€"),
                   Shifted: DeadKey.Bind(DeadkeyMappingCurrency) },
        "SC002", { Plain: SendNewResult.Bind("¹"), Shifted: SendNewResult.Bind("₁") },
        "SC003", { Plain: SendNewResult.Bind("²"), Shifted: SendNewResult.Bind("₂") },
        "SC004", { Plain: SendNewResult.Bind("³"), Shifted: SendNewResult.Bind("₃") },
        "SC005", { Plain: SendNewResult.Bind("⁴"), Shifted: SendNewResult.Bind("₄") },
        "SC006", { Plain: SendNewResult.Bind("⁵"), Shifted: SendNewResult.Bind("₅") },
        "SC007", { Plain: SendNewResult.Bind("⁶"), Shifted: SendNewResult.Bind("₆") },
        "SC008", { Plain: SendNewResult.Bind("⁷"), Shifted: SendNewResult.Bind("₇") },
        "SC009", { Plain: SendNewResult.Bind("⁸"), Shifted: SendNewResult.Bind("₈") },
        "SC00A", { Plain: SendNewResult.Bind("⁹"), Shifted: SendNewResult.Bind("₉") },
        "SC00B", { Plain: SendNewResult.Bind("⁰"), Shifted: SendNewResult.Bind("₀") },
        "SC00C", { Plain: SendNewResult.Bind("‰"), Shifted: SendNewResult.Bind("‱") },
        "SC00D", { Plain: SendNewResult.Bind("°"), Shifted: SendNewResult.Bind("ª") },
    )

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

    ; ===========================================================
    ; ErgoptiAltGr base rows (Space, Top, Middle, Bottom + dead-keys)
    ; ===========================================================
    ALTGR_BASE_ROWS := Map(
        ; Space (Shifted is intentionally a no-op).
        "SC039", { Plain: WrapTextIfSelected.Bind("_", "_", "_"),
                   Shifted: () => 0 },

        ; Top row
        "SC010", { Plain: WrapTextIfSelected.Bind('``', '``', '``'),
                   Shifted: SendNewResult.Bind("„") },
        "SC011", { Plain: WrapTextIfSelected.Bind("@", "@", "@"),
                   Shifted: SendNewResult.Bind("€") },
        "SC012", { Plain: SendNewResult.Bind("œ"),
                   Shifted: SendNewResult.Bind("Œ") },
        "SC013", { Plain: SendNewResult.Bind("ù"),
                   Shifted: SendNewResult.Bind("Ù") },
        "SC014", { Plain: WrapTextIfSelected.Bind("« ", "« ", " »"),
                   Shifted: SendNewResult.Bind(Chr(0x201C)) }, ; Left double quotation mark
        "SC015", { Plain: WrapTextIfSelected.Bind(" »", "« ", " »"),
                   Shifted: SendNewResult.Bind(Chr(0x201D)) }, ; Right double quotation mark
        "SC016", { Plain: WrapTextIfSelected.Bind("~", "~", "~"),
                   Shifted: SendNewResult.Bind("≈") },
        "SC017", { Plain: WrapTextIfSelected.Bind("#", "#", "#"),
                   Shifted: SendNewResult.Bind("%") },
        "SC018", { Plain: SendNewResult.Bind("ç"),
                   Shifted: SendNewResult.Bind("Ç") },
        "SC019", { Plain: WrapTextIfSelected.Bind("*", "*", "*"),
                   Shifted: SendNewResult.Bind("×") },
        "SC01A", { Plain: WrapTextIfSelected.Bind("%", "%", "%"),
                   Shifted: SendNewResult.Bind("‰") },
        "SC01B", { Plain: SendNewResult.Bind("-"),
                   Shifted: SendNewResult.Bind("★") },

        ; Middle row
        "SC01E", { Plain: WrapTextIfSelected.Bind("<", "<", ">"),
                   Shifted: SendNewResult.Bind("≤") },
        "SC01F", { Plain: WrapTextIfSelected.Bind(">", "<", ">"),
                   Shifted: SendNewResult.Bind("≥") },
        "SC020", { Plain: WrapTextIfSelected.Bind("{", "{", "}"),
                   Shifted: DeadKey.Bind(DeadkeyMappingSuperscript) },
        "SC021", { Plain: WrapTextIfSelected.Bind("}", "{", "}"),
                   Shifted: DeadKey.Bind(DeadkeyMappingGreek) },
        "SC022", { Plain: WrapTextIfSelected.Bind(":", ":", ":"),
                   Shifted: SendNewResult.Bind("·") },
        "SC023", { Plain: WrapTextIfSelected.Bind("|", "|", "|"),
                   Shifted: SendNewResult.Bind("¦") },
        "SC024", { Plain: WrapTextIfSelected.Bind("(", "(", ")"),
                   Shifted: SendNewResult.Bind("—") },
        "SC025", { Plain: WrapTextIfSelected.Bind(")", "(", ")"),
                   Shifted: SendNewResult.Bind("–") },
        "SC026", { Plain: WrapTextIfSelected.Bind("[", "[", "]"),
                   Shifted: DeadKey.Bind(DeadkeyMappingDiaresis) },
        "SC027", { Plain: WrapTextIfSelected.Bind("]", "[", "]"),
                   Shifted: DeadKey.Bind(DeadkeyMappingR) },
        "SC028", { Plain: SendNewResult.Bind("’"),
                   Shifted: DeadKey.Bind(DeadkeyMappingCurrency) },
        "SC02B", { Plain: WrapTextIfSelected.Bind("!", "!", "!"),
                   Shifted: SendNewResult.Bind("¡") },

        ; Bottom row
        "SC056", { Plain: WrapTextIfSelected.Bind("^", "^", "^"),
                   Shifted: DeadKey.Bind(DeadkeyMappingCircumflex) },
        "SC02C", { Plain: WrapTextIfSelected.Bind("/", "/", "/"),
                   Shifted: SendNewResult.Bind("÷") },
        "SC02D", { Plain: WrapTextIfSelected.Bind("\", "\", "\"),
                   Shifted: DeadKey.Bind(DeadkeyMappingSubscript) },
        "SC02E", { Plain: WrapTextIfSelected.Bind('"', '"', '"'),
                   Shifted: SendNewResult.Bind("j") },
        "SC02F", { Plain: WrapTextIfSelected.Bind(";", ";", ";"),
                   Shifted: SendNewResult.Bind("…") },
        "SC030", { Plain: SendNewResult.Bind("…"),
                   Shifted: SendNewResult.Bind("+") },
        "SC031", { Plain: WrapTextIfSelected.Bind("&", "&", "&"),
                   Shifted: SendNewResult.Bind("−") },
        "SC032", { Plain: WrapTextIfSelected.Bind("$", "$", "$"),
                   Shifted: SendNewResult.Bind("§") },
        "SC033", { Plain: WrapTextIfSelected.Bind("=", "=", "="),
                   Shifted: SendNewResult.Bind("≠") },
        "SC034", { Plain: WrapTextIfSelected.Bind("+", "+", "+"),
                   Shifted: SendNewResult.Bind("±") },
        "SC035", { Plain: WrapTextIfSelected.Bind("?", "?", "?"),
                   Shifted: SendNewResult.Bind("¿") },
    )
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
; The discriminator is _ALTGR_KANA_FIXUP, auto-detected at boot via a reverse
; VK_RMENU→SC probe in infra/hotstring_engine.ahk (re-evaluated on layout switch
; through the watcher’s Reload). Manual TOML override available via
; ScriptInformation["AltGrIsKanaRemap"] in case the probe ever misfires.
IsRealAltGrPress() {
    global _ALTGR_KANA_FIXUP, _OB_ALTGR_PASSTHROUGH
    ; While the onboarding wizard is on screen the user has not yet committed
    ; any Ergopti feature, so every SC138-prefixed hotkey in the driver must
    ; defer to the host Windows layout. Returning false here neutralises every
    ; #HotIf that gates on IsRealAltGrPress(), which is the gate used by every
    ; static SC138 combo in the codebase. AHK’s "all variants false → prefix
    ; reverts to native function" rule then restores native AltGr behaviour
    ; for the duration of the wizard. The flag flips back automatically when
    ; the wizard committed (Reload) or when the user closed it (ExitApp).
    if (IsSet(_OB_ALTGR_PASSTHROUGH) and _OB_ALTGR_PASSTHROUGH) {
        return false
    }
    if (IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP) {
        ; Kana remap: SC138 stands alone, no LCtrl/RAlt — no ghost to filter.
        return true
    }
    ; Vanilla AltGr: real press keeps RAlt physically held; ghost releases it.
    return GetKeyState("RAlt", "P")
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
    ; layer must only ever dispatch while SC138 is PHYSICALLY held. A dispatch
    ; with SC138 up means AHK's custom-combination prefix flag has latched on —
    ; the « AltGr bloqué » bug that a non-keyboard resume used to trigger. It is
    ; prevented at the source now (ToggleSuspend waits for SC138 to lift before
    ; suspending), so this should never fire; logging it loudly as a WARNING means
    ; any future recurrence is caught immediately in ErgoptiPlus_layout.log.
    if !GetKeyState("SC138", "P") {
        try LoggerWarn("LayoutAltGr",
            "Spurious AltGr dispatch (SC138 not physically held — prefix flag latched?): SC={1}, SC138 logical={2}, suspended={3}.",
            SC, GetKeyState("SC138"), A_IsSuspended)
        ; AHK can retain the custom-combination prefix internally after Suspend
        ; even though the key is physically up.  Never run an AltGr callback in
        ; that state: doing so turns the next ordinary key into an unsolicited
        ; layer character/action.  The original physical key event remains
        ; available to the native/base path once this handler returns.
        return
    }
    ; This dispatcher only runs on a real AltGr/Kana press — the HotIf in
    ; RegisterAltGrLayer guards every SC138 hotkey on IsRealAltGrPress().
    ; Ghost SC138 prefixes (injected by an OS driver for AltGr-mapped keys
    ; like Bépo’s `'`) therefore fall through to the regular *SC<key>/SC<key>
    ; remap hotkeys and produce the correct base-layer character.
    Entry := Table[SC]
    Cb := GetKeyState("Shift", "P") ? Entry.Shifted : Entry.Plain
    _AtCrit := Critical("On")   ; Serialize the AltGr emit like _RemapEmit
    try {
        Cb()
    } finally {
        Critical(_AtCrit)
    }
}

CtrlAltDispatch(Combo, *) {
    SendFinalResult(Combo)
}

; Register every AltGr-layer hotkey from the three tables, preserving the
; exact same order as the original ``SC138 & SCxxx::`` blocks so AHK’s
; "most-recently-registered variant wins" rule produces identical
; behaviour when several Layout sub-features are simultaneously enabled.
RegisterAltGrLayer() {
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
        HotIf((*) => Features["layout"]["ergopti_plus"] and IsRealAltGrPress())
        for SC in ALTGR_PLUS_OVERRIDES {
            Hotkey("SC138 & " . SC, AltGrShiftDispatch.Bind(SC, ALTGR_PLUS_OVERRIDES), "I2")
        }

        ; --- ErgoptiAltGr Number row + Ctrl+Alt Numpad mappings ---
        ; Note: ergopti_base is intentionally NOT required here — superscripts,
        ; subscripts and the € sign are layout-independent and must work even when
        ; the Ergopti keyboard emulation is off.
        HotIf((*) => Features["layout"]["ergopti_alt_gr"] and IsRealAltGrPress())
        for SC in ALTGR_NUMBER_ROW {
            Hotkey("SC138 & " . SC, AltGrShiftDispatch.Bind(SC, ALTGR_NUMBER_ROW), "I2")
        }
        for SC, Combo in CTRL_ALT_NUMPAD {
            Hotkey("^!" . SC, CtrlAltDispatch.Bind(Combo), "I2")
        }

        ; --- ErgoptiAltGr base rows (registered last, highest precedence) ---
        HotIf((*) => Features["layout"]["ergopti_alt_gr"] and IsRealAltGrPress())
        for SC in ALTGR_BASE_ROWS {
            Hotkey("SC138 & " . SC, AltGrShiftDispatch.Bind(SC, ALTGR_BASE_ROWS), "I2")
        }

    } finally {
        HotIf() ; Reset to no condition
    }
    try LoggerSuccess("LayoutAltGr", "AltGr layer registered ({1} entries).",
        ALTGR_PLUS_OVERRIDES.Count + ALTGR_NUMBER_ROW.Count + CTRL_ALT_NUMPAD.Count
        + ALTGR_BASE_ROWS.Count)
}

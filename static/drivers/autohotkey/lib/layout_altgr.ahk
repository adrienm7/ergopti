; static/drivers/autohotkey/lib/layout_altgr.ahk

; ==============================================================================
; MODULE: AltGr Layer Tables
; DESCRIPTION:
; Single source of truth for the AltGr layer of the emulated Ergopti layout.
; Each scan code is mapped to a ``{Plain, Shifted}`` pair of zero-argument
; callables (``BoundFunc`` or fat-arrow ``Func``) which the shared dispatcher
; runs depending on the current Shift state.
;
; FEATURES & RATIONALE:
; 1. Lookup is O(1) Map vs. AHK's individual hotkey-variant matching, and the
;    repeated 5-line ``if Shift then X else Y`` block from the original
;    layout.ahk is collapsed into a single dispatcher function.
; 2. The three logical sub-layers are kept as separate tables so the original
;    registration order is preserved bit-for-bit (rolls → ErgoptiPlus
;    overrides → ErgoptiAltGr Number row → ErgoptiAltGr base rows). AHK's
;    most-recently-registered-variant-wins rule depends on this ordering,
;    so flattening the tables would silently change which binding fires when
;    multiple Layout sub-features are simultaneously enabled.
; 3. Adding a new key on the AltGr layer is a one-line Map entry instead of a
;    six-line ``SC138 & SCxxx::`` block.
; 4. Action callables are built with ``Bind`` whenever possible — this avoids
;    the per-press cost of compiling a fat-arrow lambda and surfaces the
;    intent (a partial application of a known function) directly in the table.
;
; DEPENDENCIES:
; This module references ``SendNewResult``, ``WrapTextIfSelected``, ``DeadKey``,
; the ``DeadkeyMappingX`` Maps and ``SpaceAroundSymbols``, all defined in
; modules/layout.ahk. AHK v2 resolves these lazily so the ``#Include`` order
; only needs to guarantee that everything is part of the same compilation unit
; before ``RegisterAltGrLayer`` is called.
; ==============================================================================




; ==========================================
; ==========================================
; ======= 1/ Layer tables =======
; ==========================================
; ==========================================

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
        "SC010", { Plain: WrapTextIfSelected.Bind("``", "``", "``"),
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
        "SC028", { Plain: SendNewResult.Bind("'"),
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




; ==============================================
; ==============================================
; ======= 2/ Dispatchers and registration =======
; ==============================================
; ==============================================

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
    Entry := Table[SC]
    Cb := GetKeyState("Shift", "P") ? Entry.Shifted : Entry.Plain
    Cb()
}

CtrlAltDispatch(Combo, *) {
    SendFinalResult(Combo)
}

; Register every AltGr-layer hotkey from the three tables, preserving the
; exact same order as the original ``SC138 & SCxxx::`` blocks so AHK's
; "most-recently-registered variant wins" rule produces identical
; behaviour when several Layout sub-features are simultaneously enabled.
RegisterAltGrLayer() {
    _BuildAltGrTables()
    try LoggerStart("LayoutAltGr", "Registering AltGr layer hotkeys…")

    ; --- ErgoptiPlus overrides (registered first, lowest precedence) ---
    HotIf((*) => Features["Layout"]["ErgoptiPlus"].Enabled)
    for SC, _ in ALTGR_PLUS_OVERRIDES {
        Hotkey("SC138 & " . SC, AltGrShiftDispatch.Bind(SC, ALTGR_PLUS_OVERRIDES), "I2")
    }

    ; --- ErgoptiAltGr Number row + Ctrl+Alt Numpad mappings ---
    HotIf((*) => Features["Layout"]["ErgoptiAltGr"].Enabled
        and Features["Layout"]["ErgoptiBase"].Enabled)
    for SC, _ in ALTGR_NUMBER_ROW {
        Hotkey("SC138 & " . SC, AltGrShiftDispatch.Bind(SC, ALTGR_NUMBER_ROW), "I2")
    }
    for SC, Combo in CTRL_ALT_NUMPAD {
        Hotkey("^!" . SC, CtrlAltDispatch.Bind(Combo), "I2")
    }

    ; --- ErgoptiAltGr base rows (registered last, highest precedence) ---
    HotIf((*) => Features["Layout"]["ErgoptiAltGr"].Enabled)
    for SC, _ in ALTGR_BASE_ROWS {
        Hotkey("SC138 & " . SC, AltGrShiftDispatch.Bind(SC, ALTGR_BASE_ROWS), "I2")
    }

    HotIf() ; Reset to no condition
    try LoggerSuccess("LayoutAltGr", "AltGr layer registered (%d entries).",
        ALTGR_PLUS_OVERRIDES.Count + ALTGR_NUMBER_ROW.Count + CTRL_ALT_NUMPAD.Count
        + ALTGR_BASE_ROWS.Count)
}

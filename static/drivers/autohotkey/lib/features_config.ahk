; drivers/autohotkey/lib/features_config.ahk

#Include tap_hold_config.ahk

; ==============================================================================
; MODULE: Features Configuration
; DESCRIPTION:
; Single source of truth for which ErgoptiPlus features are enabled by default
; and for their default parameters (patterns, links, letters, tap-hold timeouts).
; Per-group hotstring expansion delays are no longer set here — they live in
; each category TOML's ``[_meta] delay`` field and are resolved at registration
; time via ``HotstringsResolve`` (see ``lib/hotstrings_config.ahk``). The
; ``TimeActivationSeconds`` entries that remain in this file are tap-hold
; activation thresholds (``TapHolds`` category) which serve a different purpose.
;
; FEATURES & RATIONALE:
; 1. ``Features`` is the hierarchical Map consumed by ``ReadConfiguration`` to
;    apply INI overrides, by the tray menu builder to render categories and
;    submenus, and by every feature module to decide whether to activate.
; 2. Descriptions and submenu ordering for TOML-backed categories
;    (Autocorrection, DistancesReduction, MagicKey, Rolls, SFBsReduction) are
;    injected at runtime by ``ApplyTomlMetadataToFeatures`` — keeping the TOML
;    as the source of truth for menu titles and ordering.
; 3. Extracted into its own submodule so the main file is not dominated by a
;    650-line data literal.
; ==============================================================================

global Features := Map(
    "__Order", ["Layout", "DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey",
        "DynamicHotstrings", "Shortcuts", "TapHolds", "Gestures"],
    "DynamicHotstrings", Map(
        "__Order", ["DateLongFr", "DateFr", "Date", "PhonePrefixes", "SsnPrefixes", "IbanPrefixes", "-", "TextExpansionPersonalInformation"],
        "DateFr", {
            Enabled: True,
        },
        "DateLongFr", {
            Enabled: True,
        },
        "Date", {
            Enabled: True,
        },
        "PhonePrefixes", {
            Enabled: True,
        },
        "SsnPrefixes", {
            Enabled: True,
        },
        "IbanPrefixes", {
            Enabled: True,
        },
        "TextExpansionPersonalInformation", {
            Enabled: True,
            PatternMaxLength: 1,
        },
    ),
    "Layout", Map(
        "__Order", ["ErgoptiBase", "DirectAccessDigits", "ErgoptiAltGr", "ErgoptiPlus"],
        "ErgoptiBase", {
            Enabled: True,
        },
        "DirectAccessDigits", {
            Enabled: True,
        },
        "ErgoptiAltGr", {
            Enabled: True,
        },
        "ErgoptiPlus", {
            Enabled: True,
        }
    ),
    "DistancesReduction", Map(
        "QU", {
            Enabled: True,
        },
        "SuffixesA", {
            Enabled: True,
        },
        "CommaJ", {
            Enabled: True,
        },
        "CommaFarLetters", {
            Enabled: True,
        },
        "DeadKeyECircumflex", {
            Enabled: True,
        },
        "ECircumflexE", {
            Enabled: True,
        },
        "SpaceAroundSymbols", {
            Enabled: True,
        },
    ),
    "SFBsReduction", Map(
        "Comma", {
            Enabled: True,
        },
        "ECirc", {
            Enabled: True,
        },
        "EGrave", {
            Enabled: True,
        },
        "BU", {
            Enabled: True,
        },
        "IÉ", {
            Enabled: True,
        },
    ),
    "Rolls", Map(
        "HC", {
            Enabled: True,
        },
        "SX", {
            Enabled: True,
        },
        "CX", {
            Enabled: True,
        },
        "EnglishNegation", {
            Enabled: True,
        },
        "EZ", {
            Enabled: True,
        },
        "CT", {
            Enabled: True,
        },
        "CloseChevronTag", {
            Enabled: True,
        },
        "ChevronEqual", {
            Enabled: True,
        },
        "Comment", {
            Enabled: True,
        },
        "Assign", {
            Enabled: True,
        },
        "NotEqual", {
            Enabled: True,
        },
        "HashtagQuote", {
            Enabled: True,
        },
        "HashtagParenthesis", {
            Enabled: True,
        },
        "HashtagBracket", {
            Enabled: True,
        },
        "EqualString", {
            Enabled: True,
        },
        "LeftArrow", {
            Enabled: True,
        },
        "AssignArrowEqualRight", {
            Enabled: True,
        },
        "AssignArrowEqualLeft", {
            Enabled: True,
        },
        "AssignArrowMinusRight", {
            Enabled: True,
        },
        "AssignArrowMinusLeft", {
            Enabled: True,
        },
    ),
    "Autocorrection", Map(
        "TypographicApostrophe", {
            Enabled: True,
        },
        "Errors", {
            Enabled: True,
        },
        "SuffixesAChaining", {
            Enabled: True,
        },
        "Accents", {
            Enabled: True,
        },
        "Caps", {
            Enabled: True,
        },
        "Names", {
            Enabled: True,
        },
        "Minus", {
            Enabled: True,
        },
        "MinusApostrophe", {
            Enabled: True,
        },
        "OU", {
            Enabled: True,
        },
        "MultiplePunctuationMarks", {
            Enabled: True,
        },
    ),
    "MagicKey", Map(
        "Replace", {
            Enabled: True,
        },
        "Repeat", {
            Enabled: True,
        },
        "TextExpansion", {
            Enabled: True,
        },
        "TextExpansionAuto", {
            Enabled: True,
        },
        "TextExpansionEmojis", {
            Enabled: True,
        },
        "TextExpansionSymbols", {
            Enabled: True,
        },
        "TextExpansionSymbolsTypst", {
            Enabled: True,
        },
    ),
    "Shortcuts", Map(
        "__Order", [
            ">menu.shortcuts.group_accented",
            "EGrave",
            "ECirc",
            "EAcute",
            "AGrave",
            "<",
            "WrapTextIfSelected",
            ">menu.shortcuts.group_modifiers",
            "AltGrLAlt",
            "AltGrCapsLock",
            "LAltCapsLock",
            "<",
        ],
        "EGrave", {
            Enabled: True,
            Letter: "z",
        },
        "ECirc", {
            Enabled: True,
            Letter: "x",
        },
        "EAcute", {
            Enabled: True,
            Letter: "c",
        },
        "AGrave", {
            Enabled: True,
            Letter: "v",
        },
        "WrapTextIfSelected", {
            Enabled: True,
        },
        "MicrosoftBold", {
            Enabled: True,
        },
        "Save", {
            Enabled: False,
        },
        "CtrlJ", {
            Enabled: False,
        },
        "PasteWithoutFormatting", {
            Enabled: False,
        },
        "AltGrLAlt", Map(
            "BackSpace",     { Enabled: False },
            "CapsLock",      { Enabled: False },
            "CapsWord",      { Enabled: False },
            "CtrlBackSpace", { Enabled: True  },
            "CtrlDelete",    { Enabled: False },
            "Delete",        { Enabled: False },
            "Enter",         { Enabled: False },
            "Escape",        { Enabled: False },
            "OneShotShift",  { Enabled: False },
            "Tab",           { Enabled: False },
        ),
        "AltGrCapsLock", Map(
            "BackSpace",     { Enabled: False },
            "CapsLock",      { Enabled: False },
            "CapsWord",      { Enabled: False },
            "CtrlBackSpace", { Enabled: False },
            "CtrlDelete",    { Enabled: True  },
            "Delete",        { Enabled: False },
            "Enter",         { Enabled: False },
            "Escape",        { Enabled: False },
            "OneShotShift",  { Enabled: False },
            "Tab",           { Enabled: False },
        ),
        "LAltCapsLock", Map(
            "BackSpace",     { Enabled: False },
            "CapsLock",      { Enabled: False },
            "CapsWord",      { Enabled: True  },
            "CtrlBackSpace", { Enabled: False },
            "CtrlDelete",    { Enabled: False },
            "Delete",        { Enabled: False },
            "Enter",         { Enabled: False },
            "Escape",        { Enabled: False },
            "OneShotShift",  { Enabled: False },
            "Tab",           { Enabled: False },
        ),
        "WinCapsLock", {
            Enabled: True,
        },
        "SelectLine", {
            Enabled: True,
        },
        "Screen", {
            Enabled: True,
        },
        "GPT", {
            Enabled: True,
            Link: "https://chatgpt.com/",
        },
        "GetHexValue", {
            Enabled: True,
        },
        "TakeNote", {
            Enabled: True,
            DatedNotes: False,
            DestinationFolder: A_Desktop,
        },
        "SurroundWithParentheses", {
            Enabled: True,
        },
        "Move", {
            Enabled: True,
        },
        "Search", {
            Enabled: True,
            SearchEngine: "https://www.google.com",
            SearchEngineURLQuery: "https://www.google.com/search?q=",
        },
        "TitleCase", {
            Enabled: True,
        },
        "Uppercase", {
            Enabled: True,
        },
        "TeleportMouse", {
            Enabled: True,
        },
        "SpotlightMouse", {
            Enabled: True,
        },
        "OpenDownloads", {
            Enabled: True,
        },
        "ScreenInstant", {
            Enabled: True,
        },
    ),
    "TapHolds", _TapHoldsConfig,
    "Gestures", Map(
        "Enabled", {
            Enabled: False,
        },
    ),
)

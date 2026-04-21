; drivers/autohotkey/lib/features_config.ahk

; ==============================================================================
; MODULE: Features Configuration
; DESCRIPTION:
; Single source of truth for which ErgoptiPlus features are enabled by default
; and for their default parameters (``TimeActivationSeconds``, patterns, etc.).
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
    "__Order", ["Layout", "DistancesReduction", "SFBsReduction", "Rolls", "Autocorrection", "MagicKey", "Shortcuts",
        "TapHolds"],
    "Layout", Map(
        "__Order", ["ErgoptiBase", "DirectAccessDigits", "ErgoptiAltGr", "ErgoptiPlus"],
        "ErgoptiBase", {
            Enabled: True,
            Description: "Émuler la couche de base de la disposition Ergopti",
        },
        "DirectAccessDigits", {
            Enabled: True,
            Description: "Chiffres en accès direct sur la rangée du haut",
        },
        "ErgoptiAltGr", {
            Enabled: True,
            Description: "Émuler la couche AltGr de la disposition Ergopti",
        },
        "ErgoptiPlus", {
            Enabled: True,
            Description: "Appliquer les légers changements en AltGr d’Ergopti➕",
        }
    ),
    "DistancesReduction", Map(
        "QU", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "SuffixesA", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "CommaJ", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "CommaFarLetters", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "DeadKeyECircumflex", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "ECircumflexE", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "SpaceAroundSymbols", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
    ),
    "SFBsReduction", Map(
        "Comma", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "ECirc", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "EGrave", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "BU", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "IÉ", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
    ),
    "Rolls", Map(
        "HC", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "SX", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "CX", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "EnglishNegation", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "EZ", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "CT", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "CloseChevronTag", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "ChevronEqual", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "Comment", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "Assign", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "NotEqual", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "HashtagQuote", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "HashtagParenthesis", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "HashtagBracket", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "EqualString", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "LeftArrow", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowEqualRight", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowEqualLeft", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowMinusRight", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
        "AssignArrowMinusLeft", {
            Enabled: True,
            TimeActivationSeconds: 0.5,
        },
    ),
    "Autocorrection", Map(
        "TypographicApostrophe", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "Errors", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "SuffixesAChaining", {
            Enabled: True,
            TimeActivationSeconds: 1,
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
        "PhoneNumberAutoComplete", {
            Enabled: True,
        },
        "OU", {
            Enabled: True,
            TimeActivationSeconds: 1,
        },
        "MultiplePunctuationMarks", {
            Enabled: True,
            TimeActivationSeconds: 1,
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
        "TextExpansionDate", {
            Enabled: True,
        },
        "TextExpansionPersonalInformation", {
            Enabled: True,
            PatternMaxLength: 1,
        },
    ),
    "Shortcuts", Map(
        "__Order", [
            "EGrave",
            "ECirc",
            "EAcute",
            "AGrave",
            "-",
            "WrapTextIfSelected",
            "-",
            "MicrosoftBold",
            "Save",
            "CtrlJ",
            "-",
            "AltGrLAlt",
            "AltGrCapsLock",
            "LAltCapsLock",
            "WinCapsLock",
            "-",
            "SelectLine",
            "Screen",
            "GPT",
            "GetHexValue",
            "TakeNote",
            "SurroundWithParentheses",
            "Move",
            "Search",
            "TitleCase",
            "Uppercase",
            "SelectWord"
        ],
        "EGrave", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche È correspondent à ceux de ",
            Letter: "z",
        },
        "ECirc", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche Ê correspondent à ceux de ",
            Letter: "x",
        },
        "EAcute", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche É correspondent à ceux de ",
            Letter: "c",
        },
        "AGrave", {
            Enabled: True,
            Description: "Tous les raccourcis sur la touche À correspondent à ceux de ",
            Letter: "v",
        },
        "WrapTextIfSelected", {
            Enabled: True,
            Description: "Taper un symbole lors d'une sélection de texte va encadrer celle-ci par le symbole. Fonctionne si émulation et si UIA/Lib/UIA.ahk dans le dossier du script",
        },
        "MicrosoftBold", {
            Enabled: True,
            Description: "Ctrl + B met en gras dans les applications Microsoft (comme Ctrl + G)",
        },
        "Save", {
            Enabled: False,
            Description: "Ctrl + J/" . ScriptInformation["MagicKey"] . " = Ctrl + S. Attention, Ctrl + J est perdu",
        },
        "CtrlJ", {
            Enabled: False,
            Description: "Ctrl + S = Ctrl + J",
        },
        "AltGrLAlt", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = BackSpace",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = CapsLock",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = CapsWord",
            },
            "CtrlBackSpace", {
                Enabled: True,
                Description: "`"AltGr`" + `"LAlt`" = Ctrl + BackSpace",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Ctrl + Delete",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Delete",
            },
            "Enter", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Entrée",
            },
            "Escape", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Échap",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = OneShotShift",
            },
            "Tab", {
                Enabled: False,
                Description: "`"AltGr`" + `"LAlt`" = Tab",
            },
        ),
        "AltGrCapsLock", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = BackSpace",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = CapsLock",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = CapsWord",
            },
            "CtrlDelete", {
                Enabled: True,
                Description: "`"AltGr`" + `"CapsLock`" = Ctrl + Delete",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Ctrl + BackSpace",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Delete",
            },
            "Enter", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Entrée",
            },
            "Escape", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Échap",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = OneShotShift",
            },
            "Tab", {
                Enabled: False,
                Description: "`"AltGr`" + `"CapsLock`" = Tab",
            },
        ),
        "LAltCapsLock", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = BackSpace",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = CapsLock",
            },
            "CapsWord", {
                Enabled: True,
                Description: "`"LAlt`" + `"CapsLock`" = CapsWord",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Ctrl + Delete",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Ctrl + BackSpace",
            },
            "Delete", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Delete",
            },
            "Enter", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Entrée",
            },
            "Escape", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Échap",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = OneShotShift",
            },
            "Tab", {
                Enabled: False,
                Description: "`"LAlt`" + `"CapsLock`" = Tab",
            },
        ),
        "WinCapsLock", {
            Enabled: True,
            Description: "Win + `"CapsLock`" = CapsLock",
        },
        "SelectLine", {
            Enabled: True,
            Description: "Win + A(ll) = Sélection de toute la ligne",
        },
        "Screen", {
            Enabled: True,
            Description: "Win + H (screensHot) = Capture de l’écran (réalise le raccourci Win + Shift + S)",
        },
        "GPT", {
            Enabled: True,
            Description: "Win + G(PT) = Ouverture de ChatGPT (site configurable)",
            Link: "https://chatgpt.com/",
        },
        "GetHexValue", {
            Enabled: True,
            Description: "Win + X (heX) = Copie dans le presse-papiers de la couleur HEX du pixel situé sous le curseur",
        },
        "TakeNote", {
            Enabled: True,
            Description: "Win + N(ote) = Ouverture d’un fichier pour prendre des notes",
            DatedNotes: False,
            DestinationFolder: A_Desktop,
        },
        "SurroundWithParentheses", {
            Enabled: True,
            Description: "Win + O = Entoure de parenthèses la ligne",
        },
        "Move", {
            Enabled: True,
            Description: "Win + M(ove) = Simulation d’une activité en bougeant la souris aléatoirement. Pour désactiver, réitérer le raccourci ou recharger le script",
        },
        "Search", {
            Enabled: True,
            Description: "Win + S(earch) = Recherche de la sélection sur Internet. Dans l’explorateur, récupération du chemin du fichier sélectionné",
            SearchEngine: "https://www.google.com",
            SearchEngineURLQuery: "https://www.google.com/search?q=",
        },
        "TitleCase", {
            Enabled: True,
            Description: "Win + T(itleCase) = Conversion en casse de titre (majuscule à chaque première lettre de mot)",
        },
        "Uppercase", {
            Enabled: True,
            Description: "Win + U(ppercase) = Conversion en majuscules/minuscules la sélection",
        },
        "SelectWord", {
            Enabled: True,
            Description: "Win + W(ord) = Sélection du mot là où se trouve le curseur",
        },
    ),
    "TapHolds", Map(
        "__Order", [
            "CapsLock",
            "LShiftCopy",
            "LCtrlPaste",
            "LAlt",
            "Space",
            "AltGr",
            "RCtrl",
            "TabAlt"
        ],
        "CapsLock", Map(
            "__Configuration", {
                TimeActivationSeconds: 0.35,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"CapsLock`" : BackSpace",
            },
            "BackSpaceCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : BackSpace en tap, Ctrl en hold",
            },
            "CapsLockCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : CapsLock en tap, Ctrl en hold",
            },
            "CapsWordCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : CapsWord en tap, Ctrl en hold",
            },
            "CtrlBackSpaceCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Ctrl + BackSpace en tap, Ctrl en hold",
            },
            "CtrlDeleteCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Ctrl + Delete en tap, Ctrl en hold",
            },
            "DeleteCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Delete en tap, Ctrl en hold",
            },
            "EnterCtrl", {
                Enabled: True,
                Description: "`"CapsLock`" : Entrée en tap, Ctrl en hold",
            },
            "EscapeCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Échap en tap, Ctrl en hold",
            },
            "OneShotShiftCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : OneShotShift en tap, Ctrl en hold",
            },
            "TabCtrl", {
                Enabled: False,
                Description: "`"CapsLock`" : Tab en tap, Ctrl en hold",
            },
        ),
        "LShiftCopy", {
            Enabled: True,
            Description: "`"LShift`" : Ctrl + C en tap, Shift en hold",
            TimeActivationSeconds: 0.35,
        },
        "LCtrlPaste", {
            Enabled: True,
            Description: "`"LCtrl`" : Ctrl + V en tap, Ctrl en hold",
            TimeActivationSeconds: 0.2,
        },
        "LAlt", Map(
            "AltTabMonitor", {
                Enabled: False,
                Description: "`"LAlt`" : Alt+Tab sur le moniteur en tap, Alt en hold",
                TimeActivationSeconds: 0.2,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"LAlt`" : BackSpace. Shift + `"LAlt`" = Delete",
            },
            "BackSpaceLayer", {
                Enabled: True,
                Description: "`"LAlt`" : BackSpace en tap, layer de navigation en hold. Shift + `"LAlt`" = Delete",
                TimeActivationSeconds: 0.2,
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"LAlt`" : OneShotShift en tap, Shift en hold",
            },
            "TabLayer", {
                Enabled: False,
                Description: "`"LAlt`" : Tab en tap, layer de navigation en hold",
                TimeActivationSeconds: 0.2,
            },
        ),
        "Space", Map(
            "Ctrl", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, Ctrl en hold",
                TimeActivationSeconds: 0.15,
            },
            "Layer", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, layer de navigation en hold",
                TimeActivationSeconds: 0.15,
            },
            "Shift", {
                Enabled: False,
                Description: "`"Espace`" : Espace en tap, Shift en hold",
                TimeActivationSeconds: 0.15,
            },
        ),
        "AltGr", Map(
            "__Configuration", {
                TimeActivationSeconds: 0.2,
            },
            "BackSpace", {
                Enabled: False,
                Description: "`"AltGr`" : BackSpace en tap, AltGr en hold",
            },
            "CapsLock", {
                Enabled: False,
                Description: "`"AltGr`" : CapsLock en tap, AltGr en hold",
            },
            "CapsWord", {
                Enabled: False,
                Description: "`"AltGr`" : CapsWord en tap, AltGr en hold",
            },
            "CtrlBackSpace", {
                Enabled: False,
                Description: "`"AltGr`" : Ctrl + BackSpace en tap, AltGr en hold",
            },
            "CtrlDelete", {
                Enabled: False,
                Description: "`"AltGr`" : Ctrl + Delete en tap, AltGr en hold",
            },
            "Delete", {
                Enabled: False,
                Description: "`"AltGr`" : Delete en tap, AltGr en hold",
            },
            "Enter", {
                Enabled: False,
                Description: "`"AltGr`" : Entrée en tap, AltGr en hold",
            },
            "Escape", {
                Enabled: False,
                Description: "`"AltGr`" : Échap en tap, AltGr en hold",
            },
            "OneShotShift", {
                Enabled: False,
                Description: "`"AltGr`" : OneShotShift en tap, AltGr en hold",
            },
            "Tab", {
                Enabled: True,
                Description: "`"AltGr`" : Tab en tap, AltGr en hold",
            },
        ),
        "RCtrl", Map(
            "BackSpace", {
                Enabled: False,
                Description: "`"RCtrl`" : BackSpace. Shift + `"RCtrl`" = Delete"
            },
            "Tab", {
                Enabled: False,
                Description: "`"RCtrl`" : Tab en tap, Ctrl en hold",
                TimeActivationSeconds: 0.2,
            },
            "OneShotShift", {
                Enabled: True,
                Description: "`"RCtrl`" : OneShotShift en tap, Shift en hold",
            },
        ),
        "TabAlt", {
            Enabled: True,
            Description: "`"Tab`" : Alt-Tab sur le moniteur en tap, Alt en hold. À activer pour ne pas perdre Alt",
            TimeActivationSeconds: 0.2,
        },
    ),
)

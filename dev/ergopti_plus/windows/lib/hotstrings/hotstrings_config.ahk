; lib/hotstrings/hotstrings_config.ahk

; ==============================================================================
; MODULE: Hotstrings Config (shim)
; DESCRIPTION:
; Entry-point for the hotstrings configuration subsystem. Declares all
; module-level globals so both sub-modules can reference them without circular
; dependency issues, then loads the sub-modules in order:
;   hotstrings_io.ahk        — boot-time defaults, override file I/O.
;   hotstrings_catalogue.ahk — resolve API and terminator catalogue helpers.
; ==============================================================================

; Ultimate fallback when neither a user override nor a TOML default is set.
; LOADED AT BOOT from the shared cross-driver canon
; (_shared/modules/hotstrings/defaults.toml) by HotstringsConfigLoadSharedDefaults() —
; the SINGLE source shared verbatim with the Hammerspoon driver. They start
; empty so a missing file/key fails fast (rule 5.3) rather than masking driver
; drift behind a hardcoded literal (rules 5.2 / 5.4). ``GLOBAL_DEFAULT_COLOR``
; remains the single source of truth for "no color set" — every per-category
; lookup that finds nothing else lands here.
global GLOBAL_DEFAULT_DELAY := ""
global GLOBAL_DEFAULT_COLOR := ""

; Default activation delay (seconds) for the dynamic hotstrings (dates, phone /
; SSN / IBAN prefixes). Loaded from _shared/modules/hotstrings/defaults.toml
; [delays] dynamichotstrings_sec by HotstringsConfigLoadSharedDefaults() — the
; SINGLE source shared verbatim with the macOS DELAYS_DEFAULT.dynamichotstrings —
; so it can never drift behind a re-typed literal (rules 5.2 / 5.4). Starts empty
; and fails fast on a missing key. It is declared HERE, in the early-loaded config
; layer, because the tray "Delays" submenu reads it while building the menu at
; startup (initMenu); the loader runs before that (ErgoptiPlus.ahk: the
; HotstringsConfigLoadSharedDefaults call precedes the menu build), so the value
; is populated in time. The user's "dynamichotstrings" delay override takes priority.
global DYN_HOTSTRINGS_DEFAULT_DELAY := ""

; Per-category baseline that overrides ``GLOBAL_DEFAULT_COLOR`` only when no
; TOML _meta or user override sets a color. Both baselines load at boot from the
; shared canon — "personal" from _shared/modules/hotstrings/defaults.toml via
; HotstringsConfigLoadSharedDefaults() (kept in lock-step with macOS), and
; "llm_prediction" from the canonical AI loading hex
; (_shared/modules/tooltip/constants.toml [accent_colors] ai_loading_hex, exposed as
; UI_AI_LOADING_HEX) via HotstringsConfigLoadLlmPredictionColor(). They start
; empty so a missing load fails fast (rule 5.3) rather than masking drift behind
; a re-typed literal (rules 5.2 / 5.4).
global HOTSTRINGS_CATEGORY_DEFAULT_COLORS := Map(
    "llm_prediction", "",
)

; Shared terminator catalogue instance — the single source of truth for the
; word-expander LIST (labels, order, separators) AND the default-enabled set,
; generated from _shared/core/domain/Terminators.spec.js and shared verbatim with
; macOS. Both the tray submenu and the config-window checkboxes render
; HSE_Terminators.all() so the catalogue can never drift between the two UIs or
; between drivers. Created once at load — before initMenu and before the default
; strings below read it — so nothing hits an unassigned global. Per-entry
; enabled state is persisted as the word-delimiter string (see
; HotstringsGetWordDelimiters); the catalogue supplies the items, the string
; supplies which are active.
global HSE_Terminators := Terminators()

; Default word-terminator and consumed-delimiter strings — the canonical
; fallbacks applied when no override is stored in hotstrings_config.toml. Both
; are DERIVED from the catalogue's default_enabled / consume flags so the AHK
; defaults are byte-identical to the macOS defaults (one source). Only the basic
; terminators ship on (whitespace + sentence punctuation + the magic key); every
; other slot is available but off by default. See Terminators.spec.js.
global HOTSTRINGS_DEFAULT_WORD_DELIMITERS     := HSE_TerminatorDefaultWordDelimiters()
global HOTSTRINGS_DEFAULT_CONSUMED_DELIMITERS := HSE_TerminatorDefaultConsumedDelimiters()

; Absolute path of the user override file (set by HotstringsConfigInit).
global _HotstringsOverridesPath := ""

; User-overridden word-delimiter string read from [__global__] in the override
; file. Empty string means "use the engine default".
global _HotstringsWordDelimiters := ""

; Chars within the active word-delimiter set that are consumed (not re-injected)
; after an expansion fires. Stored in [__global__] consumed_delimiters in the
; override file. Empty string means "consume nothing" (default behaviour).
global _HotstringsConsumedDelimiters := ""

; In-memory cache of the override file content. Shape mirrors the HS module:
;   Map(category -> { Delay: Number|"", Color: String|"", ShowTooltip: true|"", Sections: Map(name -> { Delay, Color, ShowTooltip }) })
global _HotstringsOverrides := Map()

; Memoisation for HotstringsResolve — the resolved {delay, color, show_tooltip}
; for a (category, section) pair is static between config changes, yet the prefix
; watcher resolves it per candidate on every keystroke while a tooltip is
; eligible. Results are cached and invalidated by bumping a generation counter on
; any override or group-config change; stale entries are ignored and overwritten,
; so the map stays bounded to the live keys.
global _HSResolveCache := Map()
global _HSResolveGen := 0

#Include hotstrings_io.ahk
#Include hotstrings_catalogue.ahk

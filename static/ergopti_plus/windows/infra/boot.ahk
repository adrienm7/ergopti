; infra/boot.ahk

; ==============================================================================
; MODULE: Boot Initialization
; DESCRIPTION:
; The script-management boot block extracted verbatim from ErgoptiPlus.ahk: the
; top-level global initialisation plus the early config/timings/hotstrings
; loading, the tray-icon setup and the config-directory bootstrap. It is pulled
; in by a single #Include at the exact point it used to occupy, so the
; auto-execute order is byte-identical to before the move.
;
; FEATURES & RATIONALE:
; 1. In-place include: AHK runs top-level statements in #Include order, so
;    relocating this block to its own file and #Include-ing it at the original
;    line preserves boot order exactly (same technique as infra/feature_state.ahk).
; 2. Thin entry: keeps ErgoptiPlus.ahk focused on the #Include manifest and the
;    high-level boot orchestration rather than the line-by-line init detail.
; 3. No directives/hotkeys: this block is pure top-level initialisation, so it
;    carries no #HotIf / #InputLevel scope that a move could perturb.
; ==============================================================================

; NOT TO MODIFY
global RemappedList := Map()
global LastSentCharacterKeyTime := Map() ; Tracks the time since a key was pressed
; Any entry older than this many milliseconds is definitionally useless to the
; time-activation check (no hotstring in the codebase uses a window close to
; this). Kept as a constant so pruning is deterministic and easy to tune.
global LAST_SENT_KEY_TIME_MAX_AGE_MS := 60000
; Pruning triggers when the map exceeds this size. ~150 covers ASCII + French
; accents + control-key sentinels ("LAlt", "BackSpace"…) with room to spare.
global LAST_SENT_KEY_TIME_PRUNE_AT := 150
; LastSentCharacters ring buffer lives in infra/hotstring_engine.ahk (_LSC_*).
; Accessed only via UpdateLastSentCharacter / GetLastSentCharacterAt.
; ``CapsWordEnabled`` and ``LayerEnabled`` are initialised at the very top of
; the script (before Bundle_Init) so #HotIf evaluation during early message
; pumping never sees them unset — do not re-declare them here.
global NumberOfRepetitions := 1 ; Same as Vim where 3w does the w action 3 times, we can do the same in the navigation layer
global ActivitySimulation := False
global OneShotShiftEnabled := False

; Read path overrides from paths.toml — same file format as Hammerspoon.
; Auto-generated with defaults if absent.
; In compiled mode the file lives in %APPDATA%\Ergopti\ — a stable location that
; persists across updates. The bundle dir (LocalAppData\Ergopti\bundle\) is wiped
; and re-extracted on every version change, so storing paths.toml there caused
; ConfigDirPath overrides to be lost on every update, which triggered the
; onboarding wizard again even for existing users. The dev-mode fallback keeps
; using A_ScriptDir\_generated\paths.toml.
global _PathsFile := (_DriverStartupSmokeDir != "")
		? (_DriverStartupSmokeDir . "\paths.toml")
		: (A_IsCompiled
				? (A_AppData . "\Ergopti\paths.toml")
				: (A_ScriptDir . "\_generated\paths.toml"))
; A valid transition chooses one complete old/new image before the locator is
; read. Quarantine is visible and fatal: continuing would let a mixed image
; select the wrong config directory and later be persisted as coherent state.
ConfigTransitionRecoverAtBootOrThrow(_PathsFile)
global _PathsOverrides := ReadPathsToml(_PathsFile)

; ConfigDirPath is the single relocatable folder that holds all personal files.
; Defaults to %USERPROFILE%\.config\ergopti_plus\ (mirrors XDG-style on Unix);
; must end with a backslash.
global _DefaultConfigDir := (_DriverStartupSmokeDir != "")
		? (_DriverStartupSmokeDir . "\config\")
		: (EnvGet("USERPROFILE") . "\.config\ergopti_plus\")
global _ConfigDir := (_PathsOverrides.Has("ConfigDirPath") and _PathsOverrides["ConfigDirPath"] != "")
		? _PathsOverrides["ConfigDirPath"]
		: _DefaultConfigDir
if !(_ConfigDir ~= "[/\\]$")
		_ConfigDir .= "\"
if !DirExist(_ConfigDir) {
		try DirCreate(_ConfigDir)
}

; Subfolder name for AHK-specific user files under _ConfigDir. Centralised so
; a future rename only requires changing this one constant.
global _AhkSubDir := "autohotkey\"

; All AHK driver configuration lives in a single unified TOML under the
; driver subfolder: features, script settings, shortcuts, gestures, and
; expert overrides ([script] / [features]) are sections of this one file.
global ConfigurationFile := _ConfigDir . _AhkSubDir . "config.toml"

; Load the cross-driver hotstring resolution defaults (global default delay /
; color / "personal" baseline) from _shared/modules/hotstrings/defaults.toml — the single
; source shared with Hammerspoon. Must precede HotstringsConfigInit and the tray
; menu build (initMenu reads GLOBAL_DEFAULT_DELAY). Fail-fast on a missing key.
HotstringsConfigLoadSharedDefaults()
; Load the shared timing registry, then reassign the keylogger-walker and
; tap-hold timing constants from it (_shared/modules/timings/constants.toml). AHK v2 runs
; static/global initializers before this auto-execute body, so these constants
; start at a sentinel and are sourced here — well before the keylogger hook or
; any tap-hold hotkey arms. Fail-fast on a missing key.
TimingsLoadShared()
KeyloggerWalkerLoadTimings()
TapHoldsLoadTimings()
LLMApiLoadTimings()
LLM_Ollama_LoadDefaults()
; Initialise the hotstrings_config module so per-group delays and tooltip
; colors can be resolved from the TOML metadata + the shared user override
; file. The override file lives in the same shared config directory used by
; Hammerspoon, so edits made from either menu apply to both at next reload.
HotstringsConfigInit(_ConfigDir . "hotstrings_config.toml")
; Load the user's wrap-symbol state (disabled set + custom pairs).
; Must come before HotstringPrefixWatcherInit so _WS_ACTIVE_PAIRS is populated
; before the InputHook starts intercepting keystrokes.
WrapSymbols_Init(_ConfigDir)
; Apply the user's word-delimiter preference so HSE fires on the right chars.
; HotstringsGetWordDelimiters() returns the stored override or the canonical
; default — assigning it here replaces the compile-time constant in the engine.
HSE_WORD_TERMINATORS    := HotstringsGetWordDelimiters()
HSE_CONSUMED_DELIMITERS := HotstringsGetConsumedDelimiters()
; The prefix watcher's boundary set is DERIVED from HSE_WORD_TERMINATORS, so it
; must be recomputed after that assignment. Its own include-position initialiser
; only ever saw the compile-time constant; without this call the preview and the
; matcher anchor on different sets and previewed expansions silently never fire.
TooltipDequeueInit()

; Arm the suspend watchdog so the pause reactor (Ergopti_OnSuspendEnter/Resume)
; fires even when suspend is toggled outside ToggleSuspend. 500 ms is well under
; human perception for the tear-down yet costs nothing while idle.
SUSPEND_WATCHDOG_MS := 500
global _LastSuspendState := A_IsSuspended
SetTimer(_SuspendStateWatchdog, SUSPEND_WATCHDOG_MS)

; _LogoDir: fully-normalized absolute path avoids any '..' traversal that
; TraySetIcon may refuse to resolve on some Windows configurations.
global _LogoDir := _StaticDir . "\img\logo"

; Tray icon paths are deliberately NOT part of ScriptInformation so that
; ReadScriptConfig() cannot override them from a user's [Script] section in
; ErgoptiPlus_Configuration.ini — historical configs still hold stale paths
; pointing at the old static/ergopti_plus/windows/icons/ location and would
; otherwise silently break the tray icon after each project-level move
global IconPath := _LogoDir . "\logo_simple.ico"
global IconPathDisabled := _LogoDir . "\logo_simple_disabled.ico"

; Set the custom tray icon immediately so the default green AHK icon never
; appears — even briefly during the module loading phase that follows.
if FileExist(IconPath)
		TraySetIcon(IconPath)

; Auto-create driver and shared subfolders under _ConfigDir on first launch.
; autohotkey/ holds driver-specific files; hotstrings/ holds the shared TOML
; files so a Mac+PC setup can keep both side by side without name collision.
try DirCreate(_ConfigDir . _AhkSubDir)
try DirCreate(_ConfigDir . "hotstrings")
; Bootstrap an empty personal_hotstrings.toml if it does not exist yet so the
; user always has a file to open rather than a confusing error.
_PersonalTomlBootstrap := _ConfigDir . "hotstrings\personal_hotstrings.toml"
if !FileExist(_PersonalTomlBootstrap)
		try FileAppend("", _PersonalTomlBootstrap)

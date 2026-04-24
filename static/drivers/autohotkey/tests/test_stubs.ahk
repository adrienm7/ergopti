; static/drivers/autohotkey/tests/test_stubs.ahk

; ==============================================================================
; MODULE: Test Stubs
; DESCRIPTION:
; Minimal stubs for the runtime globals and helper functions that the
; production lib/ files reference. Tests need to load those lib files to
; exercise the pure helpers, but the lib files happen to also reference
; functions / Maps initialised by ErgoptiPlus.ahk top-level code (Features,
; ScriptInformation, SendNewResult, …). This file declares dummy versions
; so the tests can ``#Include`` the libs without registering hotkeys or
; touching the file system.
;
; FEATURES & RATIONALE:
; 1. Stubs are global to the test process and used everywhere; loading them
;    once at the top of run_all.ahk is enough.
; 2. Each stub keeps a side-effect log (e.g. ``_Stub_SentText.Push(Text)``)
;    so individual tests can assert that the lib called the stub with the
;    expected arguments — this is how we test Send semantics without an
;    actual keyboard.
; 3. Stubs can be overridden inside a test by reassigning the global; the
;    test framework runs everything in the same compilation unit so the
;    override is visible to the lib code under test.
; ==============================================================================




; ============================================
; ============================================
; ======= 1/ Side-effect recorders =======
; ============================================
; ============================================

global _Stub_SentText := []          ; Recorded SendNewResult / SendInput / SendEvent payloads
global _Stub_LastChars := []         ; Recorded UpdateLastSentCharacter calls
global _Stub_HotstringCalls := []    ; Recorded CreateHotstring / CreateCaseSensitiveHotstrings calls
global _Stub_DeadKeyCalls := []      ; Recorded DeadKey calls

; Recorders consumed by the production ``_HotstringRegistrar`` and ``_SendHook``
; test seams. Populated by InstallHotstringHooks and reset by Reset*Hotstring*.
global _Stub_HotstringRegistrations := []   ; { spec, callback }
global _Stub_RecordedSends := []            ; { fn, args }

ResetStubRecorders() {
	global _Stub_SentText, _Stub_LastChars, _Stub_HotstringCalls, _Stub_DeadKeyCalls
	_Stub_SentText := []
	_Stub_LastChars := []
	_Stub_HotstringCalls := []
	_Stub_DeadKeyCalls := []
}

ResetHotstringRecorders() {
	global _Stub_HotstringRegistrations, _Stub_RecordedSends, _Stub_LastChars
	_Stub_HotstringRegistrations := []
	_Stub_RecordedSends := []
	_Stub_LastChars := []
}




; =====================================
; =====================================
; ======= 2/ Global state stubs =======
; =====================================
; =====================================

; Mimics the user-configurable script identity from ErgoptiPlus.ahk.
global ScriptInformation := Map(
	"MagicKey", "★",
	"PersonalAhkPath", A_ScriptDir . "\..\personal.ahk",
	"PersonalTomlPath", A_ScriptDir . "\..\..\hotstrings\personal.toml",
)

; Empty Features Map so HasAnyEnabled / Features lookups have a target.
global Features := Map(
	"Layout", Map(
		"ErgoptiBase", { Enabled: true },
		"ErgoptiAltGr", { Enabled: true },
		"ErgoptiPlus", { Enabled: false },
	),
	"Shortcuts", Map(
		"AltGrLAlt", Map(
			"BackSpace", { Enabled: false },
			"Tab", { Enabled: true },
		),
		"AltGrCapsLock", Map(
			"BackSpace", { Enabled: false },
			"CapsLock", { Enabled: false },
		),
	),
	"DistancesReduction", Map(
		"SpaceAroundSymbols", { Enabled: false },
	),
)

global ConfigurationFile := A_ScriptDir . "\test_config.ini"
global SpaceAroundSymbols := ""

; Hotstring engine globals normally maintained by modules/layout.ahk.
; The LastSentCharacters ring buffer is defined in lib/hotstring_engine.ahk;
; tests seed it via _LSCResetFrom([...]) instead of touching it directly.
global LastSentCharacterKeyTime := Map()
global RemappedList := Map()
global InDeadKeySequence := false
global LayerEnabled := false
global CapsWordEnabled := false
global OneShotShiftEnabled := false
global NumberOfRepetitions := 1
global ActivitySimulation := false

; Dummy deadkey Maps so layout_altgr.ahk's _BuildAltGrTables can run.
global DeadkeyMappingCircumflex := Map()
global DeadkeyMappingDiaresis   := Map()
global DeadkeyMappingSuperscript := Map()
global DeadkeyMappingSubscript   := Map()
global DeadkeyMappingGreek       := Map()
global DeadkeyMappingR           := Map()
global DeadkeyMappingCurrency    := Map()




; ==================================
; ==================================
; ======= 3/ Function stubs =======
; ==================================
; ==================================

; AHK refuses duplicate function definitions, so we can only stub functions
; that are NOT defined in any included lib/ file. The list below covers the
; functions that production lib/ files reference but live in modules/
; (which run_all.ahk deliberately does not #Include).
; Production helpers like SendNewResult / CreateHotstring / ReloadPersonalSection
; are exercised through their real implementations; their downstream effects
; (notably UpdateLastSentCharacter calls and recorded LastSentCharacters
; updates) are the observable surface we assert against.

WrapTextIfSelected(Symbol, LeftSymbol, RightSymbol) {
	global _Stub_SentText
	_Stub_SentText.Push({ kind: "wrap", symbol: Symbol, left: LeftSymbol, right: RightSymbol })
}

UpdateLastSentCharacter(Character) {
	global _Stub_LastChars, LastSentCharacterKeyTime
	_Stub_LastChars.Push(Character)
	_LSCPush(Character)
	LastSentCharacterKeyTime[Character] := A_TickCount
}

DeadKey(Mapping) {
	global _Stub_DeadKeyCalls
	_Stub_DeadKeyCalls.Push(Mapping)
}

; Toggle helpers consulted by the SIMPLE_ACTIONS / TAPHOLD_ALTGR_ACTIONS Maps.
; Real implementations live in modules/tap_holds.ahk (not included by tests).
ToggleCapsLock() {
	global _Stub_SentText
	_Stub_SentText.Push({ kind: "toggle_capslock" })
}

ToggleCapsWord() {
	global _Stub_SentText
	_Stub_SentText.Push({ kind: "toggle_capsword" })
}

OneShotShift() {
	global _Stub_SentText
	_Stub_SentText.Push({ kind: "one_shot_shift" })
}

DisableCapsWord() {
	global CapsWordEnabled
	CapsWordEnabled := false
}

GetCapsLockCondition() {
	return false
}




; ==========================================
; ==========================================
; ======= 4/ Hotstring engine hooks =======
; ==========================================
; ==========================================

; Recorder consumed by ``_HotstringRegistrar`` once installed. Stores the
; trigger spec (``:flags:abbrev``) and the callback so individual tests can
; both count registrations and invoke the callback directly to drive
; HotstringHandler with controlled inputs.
_HOOK_RecordHotstring(TriggerSpec, Callback) {
	global _Stub_HotstringRegistrations
	_Stub_HotstringRegistrations.Push({ spec: TriggerSpec, callback: Callback })
}

; Recorder consumed by ``_SendHook``. Captures every send primitive call as
; ``{ fn, args }`` where ``args`` is the variadic Array of positional
; arguments after the function name. Tests assert on the ordered sequence
; to verify backspace counts, replacement payloads and end-character emission.
_HOOK_RecordSend(FnName, Args*) {
	global _Stub_RecordedSends
	_Stub_RecordedSends.Push({ fn: FnName, args: Args })
}

; Wire both hooks into the production globals so subsequent CreateHotstring /
; HotstringHandler / Send* calls record instead of touching the OS.
InstallHotstringHooks() {
	global _HotstringRegistrar, _SendHook
	_HotstringRegistrar := _HOOK_RecordHotstring
	_SendHook := _HOOK_RecordSend
}

UninstallHotstringHooks() {
	global _HotstringRegistrar, _SendHook
	_HotstringRegistrar := 0
	_SendHook := 0
}

; ── Active-app cache simulators — bypass GetActiveApp's WinGet* calls so the
; ── Notepad / Office branches of HotstringHandler can be exercised in tests.
SimulateNotepadActive() {
	global _ActiveAppCache
	_ActiveAppCache.ts := A_TickCount
	_ActiveAppCache.Class := "Notepad"
	_ActiveAppCache.Exe := "notepad.exe"
	_ActiveAppCache.IsNotepad := true
	_ActiveAppCache.IsMicrosoftOffice := false
}

SimulateRegularApp() {
	global _ActiveAppCache
	_ActiveAppCache.ts := A_TickCount
	_ActiveAppCache.Class := "TestApp"
	_ActiveAppCache.Exe := "test.exe"
	_ActiveAppCache.IsNotepad := false
	_ActiveAppCache.IsMicrosoftOffice := false
}

SimulateMicrosoftOffice() {
	global _ActiveAppCache
	_ActiveAppCache.ts := A_TickCount
	_ActiveAppCache.Class := "OpusApp"
	_ActiveAppCache.Exe := "WINWORD.EXE"
	_ActiveAppCache.IsNotepad := false
	_ActiveAppCache.IsMicrosoftOffice := true
}

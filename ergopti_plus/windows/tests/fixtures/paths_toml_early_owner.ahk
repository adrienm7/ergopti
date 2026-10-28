; tests/fixtures/paths_toml_early_owner.ahk

; ==============================================================================
; MODULE: Early Bootstrap TOML Owner Fixture
; DESCRIPTION:
; Runs the genuine path reader before any manifest or configuration globals
; exist. Passive diagnostics observe the real fatal handler and process exit;
; no keyboard, desktop, network or resident driver owner is initialized.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off

global _PathsEarlyLocator := A_Args[1]
global _PathsEarlyReceipt := A_Args[2]
global _DriverBootPhase := "starting"
global _DriverStartupSmokeDir := "owned-early-bootstrap-fixture"

#Include ../../infra/error_net.ahk
OnError(ErgoptiGlobalErrorHandler)
OnExit(_PathsEarlyObserveExit)
#Include ../../infra/hotpath_profiler.ahk
#Include ../../infra/toml/toml_helpers.ahk

if IsSet(Features) || IsSet(_SharedDir) || IsSet(_ConfigDir) || IsSet(ConfigurationFile)
	throw Error("The early-reader fixture unexpectedly owns late configuration state")
Parsed := ReadPathsToml(_PathsEarlyLocator)
FileAppend("parsed_key=" . Parsed["ConfigDirPath"] . "`nsemantic_parses=" . _TOML_DocumentParses
	. "`ncounter_parses=" . _PerfCountersOwner().Counts["toml.document_parse"]
	. "`nafter_read`n", _PathsEarlyReceipt, "UTF-8")
ExitApp(0)

; This observer cannot change admission, cleanup, control flow or exit status.
LoggerError(Context, Message, Arguments*) {
	global _PathsEarlyReceipt
	if Context == "ErgoptiPlus" && Message == "Fatal startup error during phase '{1}': {2}"
		FileAppend("fatal-startup=" . Arguments[1] . "`n" . Arguments[2] . "`n",
			_PathsEarlyReceipt, "UTF-8")
}

_PathsEarlyObserveExit(Reason, Code) {
	global _PathsEarlyReceipt
	FileAppend("exit=" . Reason . "/" . Code . "`n", _PathsEarlyReceipt, "UTF-8")
}

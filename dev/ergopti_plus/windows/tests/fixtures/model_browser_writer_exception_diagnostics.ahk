; tests/fixtures/model_browser_writer_exception_diagnostics.ahk

; ==============================================================================
; MODULE: Model Browser Writer Exception Diagnostics
; DESCRIPTION:
; Observes an exception already caught by the genuine private writer owner.
; This instrumented child does not replace a writer or certify cold acceptance.
; ==============================================================================

#Requires AutoHotkey v2.0

_MBWD_Caught(Err, Stage) {
	global _MBPO
	try {
		Stack := Err.Stack
		FileAppend("DIAGNOSTIC model-browser-writer-exception "
			. '{"kind":"PrivateChildCatchInstrumentation","type":' . JsonStringLiteral(Type(Err))
			. ',"stage":' . JsonStringLiteral(Stage) . ',"message":' . JsonStringLiteral(Err.Message)
			. ',"what":' . JsonStringLiteral(Err.What) . ',"file":' . JsonStringLiteral(Err.File)
			. ',"line":' . Err.Line . ',"stack":' . JsonStringLiteral(SubStr(Stack, 1, 8192))
			. ',"stack_units":' . StrLen(Stack) . "}`n", "*", "UTF-8-RAW")
	} catch Any {
		; Retain the already caught primary if its diagnostic export refuses.
		; The original Main throws this Error; an export refusal cannot pass.
		PreviousCritical := Critical("On")
		try {
			if IsSet(_MBPO) && IsObject(_MBPO) {
				if !IsObject(_MBPO.Failure)
					_MBPO.Failure := Err
			} else
				throw Err
		} finally Critical(PreviousCritical)
	}
}

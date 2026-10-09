; ui/log_openers.ahk

; ==============================================================================
; MODULE: Log Openers
; DESCRIPTION:
; Opens the logs folder, today's log and today's errors file for the Debug menu
; and for the gesture and shortcut actions (the macOS twin is
; ui/log_openers.lua).
;
; FEATURES & RATIONALE:
; 1. One resolver. Every path comes from the logger (LoggerLogsDir,
;    LoggerTodayLogPath, LoggerTodayErrorsPath) at the moment of the click,
;    so a driver up past midnight never opens yesterday's file and a moved
;    logs folder is followed without a second formula here.
; 2. A missing errors file is an answer, not a failure. It only exists once
;    something warned that day, and Notepad offered to create an empty one,
;    which read like a broken menu row; the user is now told instead.
; 3. Launch and notification seams are injectable so the behaviour is tested
;    headlessly, without starting Explorer or Notepad.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================
; =============================
; ======= 1/ Public API =======
; =============================
; =============================

; Opens the logs folder in Explorer, creating it on first use so the user never
; sees a "not found" dialog.
; @param RunFn {Func|Integer} Launch seam for tests; 0 means Run.
; @returns {Boolean} False when the folder could not be created.
LogOpeners_OpenFolder(RunFn := 0) {
	LogDir := LoggerLogsDir()
	if !DirExist(LogDir) {
		try DirCreate(LogDir)
		catch as Err {
			try LoggerError("LogOpeners", "Logs folder '{1}' could not be created: {2}.", LogDir, Err.Message)
			return false
		}
	}
	(HasMethod(RunFn, "Call") ? RunFn : Run).Call('explorer.exe "' . LogDir . '"')
	return true
}

; Opens today's log in Notepad.
; @param RunFn {Func|Integer} Launch seam for tests; 0 means Run.
; @returns {Boolean}
LogOpeners_OpenTodayLog(RunFn := 0) {
	(HasMethod(RunFn, "Call") ? RunFn : Run).Call('notepad.exe "' . LoggerTodayLogPath() . '"')
	return true
}

; Opens today's errors-only log (WARNING + ERROR lines) in Notepad, or says that
; nothing warned today.
; @param RunFn {Func|Integer} Launch seam for tests; 0 means Run.
; @param NotifyFn {Func|Integer} Notification seam for tests; 0 means NotifierSend.
; @returns {Boolean} True when the file was opened or the user was told; false
;   when the notice was not delivered, since it is the whole answer to the click.
LogOpeners_OpenTodayErrors(RunFn := 0, NotifyFn := 0) {
	Path := LoggerTodayErrorsPath()
	if FileExist(Path) {
		(HasMethod(RunFn, "Call") ? RunFn : Run).Call('notepad.exe "' . Path . '"')
		return true
	}
	try LoggerInfo("LogOpeners", "No errors file for today at '{1}'; the user is told instead.", Path)
	Delivered := (HasMethod(NotifyFn, "Call") ? NotifyFn : NotifierSend).Call(
		t("menu.debug.no_errors_today"), Map("level", "info"))
	if !Delivered {
		try LoggerError("LogOpeners", "The no-errors-today notification was not delivered.")
		return false
	}
	return true
}

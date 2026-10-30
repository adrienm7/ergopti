; infra/quit_admission.ahk

; ==============================================================================
; MODULE: Quit Admission (Windows)
; DESCRIPTION:
; The decision of what the tray's Quit does, port of
; _shared/lua/quit_admission.lua. The user asked to quit, so Quit wins: it is
; refused only when it cannot mean anything, and otherwise it waits for a
; configuration write that is already running and then proceeds.
;
; FEATURES & RATIONALE:
; 1. Pure Decision: the driver reads the same five facts as macOS and Linux from
;    its own owners (infra/lifecycle.ahk) and this module answers admitted,
;    deferred or refused. The contract's cases are replayed by
;    tests/unit/infra/lifecycle/test_quit_admission.ahk.
; 2. A Reload Is Abandoned: OnExit already supersedes a pending reload, so the
;    decision only records it; no click is held for the reload's end.
; 3. One More Refusal Than The Lua Drivers: OnExit's gates can still veto the
;    admitted exit, which returns from ExitApp. A veto followed by no retry owner
;    is told with the same notice, because Quit otherwise did nothing visible.
; 4. Bounded Vetoes Untouched: a deferral burns no veto of the shutdown budget,
;    because ExitApp is not called until the writer has finished.
; ==============================================================================

#Requires AutoHotkey v2.0

; The causes that refuse or defer Quit, in the order they are tested
global QUIT_CAUSE_OWNER_UNAVAILABLE := "owner_unavailable"
global QUIT_CAUSE_EXIT_PENDING := "exit_pending"
global QUIT_CAUSE_WRITER_ACTIVE := "writer_active"
global QUIT_CAUSE_PUBLICATION_PENDING := "publication_pending"

; The fact names a driver supplies
global QUIT_ADMISSION_FACTS := ["owner_available", "exit_pending", "reload_pending", "writer_active", "publication_pending"]

global QUIT_ADMISSION_MESSAGES := Map(
	QUIT_CAUSE_OWNER_UNAVAILABLE, "Quit refused: the global action owner is unavailable.",
	QUIT_CAUSE_EXIT_PENDING, "Quit refused: an exit already owns the process.",
	QUIT_CAUSE_WRITER_ACTIVE, "Quit waits: a global configuration writer is still active.",
	QUIT_CAUSE_PUBLICATION_PENDING, "Quit waits: a hotstring publication is still pending.")

; A wait for a writer is running; a second click finds an exit already owned
global _QuitRequestWaiting := false
; The user's Quit reached ExitApp and no veto has answered it yet
global _QuitRequestExitOwed := false





; ==================================
; ==================================
; ======= 1/ The Decision ==========
; ==================================
; ==================================

; Decides what Quit does now.
; @param Facts {Map} Booleans named by QUIT_ADMISSION_FACTS.
; @returns {Map} { admitted, abandon_reload, deferred, cause, message }
; @throws {Error} On a missing or non-boolean fact.
QuitAdmission_Decide(Facts) {
	global QUIT_ADMISSION_FACTS, QUIT_ADMISSION_MESSAGES, QUIT_CAUSE_OWNER_UNAVAILABLE, QUIT_CAUSE_EXIT_PENDING
	global QUIT_CAUSE_WRITER_ACTIVE, QUIT_CAUSE_PUBLICATION_PENDING
	if !(Facts is Map)
		throw TypeError("Quit admission needs its facts.")
	for Name in QUIT_ADMISSION_FACTS {
		Value := Facts.Get(Name, "")
		if !(Value is Integer) || (Value != 0 && Value != 1)
			throw ValueError("Quit admission fact '" . Name . "' must be a boolean.")
	}
	Refused(Cause, Deferred) => Map("admitted", false, "abandon_reload", false, "deferred", Deferred,
		"cause", Cause, "message", QUIT_ADMISSION_MESSAGES[Cause])
	if !Facts["owner_available"]
		return Refused(QUIT_CAUSE_OWNER_UNAVAILABLE, false)
	if Facts["exit_pending"]
		return Refused(QUIT_CAUSE_EXIT_PENDING, false)
	if Facts["writer_active"]
		return Refused(QUIT_CAUSE_WRITER_ACTIVE, true)
	if Facts["publication_pending"]
		return Refused(QUIT_CAUSE_PUBLICATION_PENDING, true)
	return Map("admitted", true, "abandon_reload", Facts["reload_pending"] ? true : false,
		"deferred", false, "cause", "", "message", "")
}

; Runs Quit once admitted, waiting out a deferral within a bound.
; @param Ports {Map} facts (), schedule (Ms, Callback) -> Boolean, now () -> Ms,
;   timeout (Ms), poll (Ms), on_admitted (Decision), on_refused (Decision), warn (Text).
; @returns {String} "admitted", "refused" or "waiting"
QuitAdmission_Await(Ports) {
	if !(Ports is Map)
		throw TypeError("Quit admission needs its ports.")
	for Name in ["facts", "schedule", "now", "on_admitted", "on_refused", "warn"] {
		if !HasMethod(Ports.Get(Name, 0), "Call")
			throw ValueError("Quit admission needs the " . Name . " port.")
	}
	for Name in ["timeout", "poll"] {
		if !(Ports.Get(Name, 0) is Integer) || Ports[Name] <= 0
			throw ValueError("Quit admission needs a positive " . Name . ".")
	}
	return _QuitAdmission_Step(Ports, Ports["now"].Call(), true)
}

_QuitAdmission_Step(Ports, Started, First, *) {
	Decision := QuitAdmission_Decide(Ports["facts"].Call())
	if Decision["admitted"] {
		Ports["on_admitted"].Call(Decision)
		return "admitted"
	}
	if !Decision["deferred"] {
		Ports["on_refused"].Call(Decision)
		return "refused"
	}
	if First
		Ports["warn"].Call(Decision["message"])
	if (Ports["now"].Call() - Started >= Ports["timeout"]) {
		Decision["timed_out"] := true
		Ports["warn"].Call(Format("Quit gave up waiting after {1} ms: {2}", Ports["timeout"], Decision["message"]))
		Ports["on_refused"].Call(Decision)
		return "refused"
	}
	if (Ports["schedule"].Call(Ports["poll"], _QuitAdmission_Step.Bind(Ports, Started, false)) != true) {
		Decision["timed_out"] := true
		Ports["warn"].Call("Quit cannot wait: its poll timer was not armed.")
		Ports["on_refused"].Call(Decision)
		return "refused"
	}
	return "waiting"
}





; ======================================
; ======================================
; ======= 2/ The Tray's Request ========
; ======================================
; ======================================

; Handles one Quit request.
; @param Ports {Map} The QuitAdmission_Await ports, without on_admitted and
;   on_refused, plus exit () (ExitApp, which returns only when OnExit vetoed it),
;   retry_owned () -> Boolean (something retries this exit by itself) and
;   notify (), which tells the user of a refusal.
; @returns {Boolean} Whether the quit started or is waiting.
QuitRequest_Run(Ports) {
	global _QuitRequestWaiting
	if _QuitRequestWaiting {
		; A second click during the wait: the first one still owns the exit.
		_QuitRequest_Refuse(Ports, QuitAdmission_Decide(Map("owner_available", 1, "exit_pending", 1,
			"reload_pending", 0, "writer_active", 0, "publication_pending", 0)))
		return true
	}
	Started := false
	AwaitPorts := Ports.Clone()
	AwaitPorts["on_admitted"] := (Decision) => (Started := _QuitRequest_Start(Ports, Decision))
	AwaitPorts["on_refused"] := (Decision) => _QuitRequest_Refuse(Ports, Decision)
	State := QuitAdmission_Await(AwaitPorts)
	_QuitRequestWaiting := (State == "waiting")
	return State == "waiting" || Started
}

; Starts the exit of an admitted Quit. An OnExit veto returns here.
_QuitRequest_Start(Ports, Decision) {
	global _QuitRequestWaiting, _QuitRequestExitOwed
	_QuitRequestWaiting := false
	_QuitRequestExitOwed := true
	if Decision["abandon_reload"]
		Ports["warn"].Call("Quit supersedes the reload in flight.")
	Ports["exit"].Call()
	return QuitRequest_ExitReturned(Ports["retry_owned"], Ports["notify"])
}

; Logs a refusal, then tells the user. A deferral that expired was already logged
; with its bound.
_QuitRequest_Refuse(Ports, Decision) {
	global _QuitRequestWaiting
	_QuitRequestWaiting := false
	if !Decision.Get("timed_out", false)
		Ports["warn"].Call(Decision["message"])
	Ports["notify"].Call()
}

; An ExitApp of the user's Quit returned: OnExit vetoed it. Something that retries
; the same exit keeps the owed answer; otherwise the user is told.
; @param RetryOwnedFn {Func} Whether a retry of this exit is armed.
; @param NotifyFn {Func} Tells the user of the refusal.
; @returns {Boolean} Whether the exit is still on its way.
QuitRequest_ExitReturned(RetryOwnedFn, NotifyFn) {
	global _QuitRequestExitOwed
	if !_QuitRequestExitOwed
		return false
	if RetryOwnedFn.Call()
		return true
	_QuitRequestExitOwed := false
	NotifyFn.Call()
	return false
}

; A retry of the user's Quit gave up: the owed refusal is told once.
; @param NotifyFn {Func}
QuitRequest_RetryAbandoned(NotifyFn) {
	global _QuitRequestExitOwed
	if !_QuitRequestExitOwed
		return
	_QuitRequestExitOwed := false
	NotifyFn.Call()
}

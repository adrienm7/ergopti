; tests/fixtures/keylogger_shutdown_close_fixture.ahk

; ==============================================================================
; MODULE: Frozen Session Close Native Fixture
; DESCRIPTION: Drive actual append and focus-stop functions through controlled native ports.
; ==============================================================================

#Requires AutoHotkey v2.0

class Keylogger {
	static initialized := true
	static _shutting_down := false
	static lifecycle_generation := 1
	static _pending_entries := []
	static health_events_session := 0
	static health_privacy_hits := 0
	static next_event_id := 1
}

class KLHook {
	static registered := false
	static capture_generation := 1
	static capture_stopping := false
}

; No physical hook is installed by the fixture. Any unexpected removal or
; watermark port use must fail instead of silently impersonating native work.
class HookDispatcher {
	static Unregister(*) {
		throw Error("Unexpected native input-hook removal in the controlled fixture.")
	}
}

class HookDispatcherConst {
	static EVT_KB_CHAR := "fixture-character"
	static EVT_KB_DOWN := "fixture-keydown"
}

KL_Hook_AdvanceContextWatermarks(*) {
	throw Error("Unexpected native context advancement in the controlled fixture.")
}

class _KLSCF_ForgedPublication extends KLSessionClosePublication {
	__New() {
		this.CommitFn := (*) => 0
	}

	IsCurrent(*) {
		return true
	}
}

class MetricsFilters {
	static secure_field := true
	static disabled_apps := Map()
	static system_auth := true
	static private_browsing := true
}

global MF_SYSTEM_AUTH_PROCESSES := Map("consent.exe", true)
global MF_SYSTEM_AUTH_CLASSES := Map("ConsentUI", true)
global MF_PRIVATE_TITLE_PATTERNS := ["i)Incognito"]
global KLPW_CACHE_TTL_MS := 2000
global _KLSCF_NativeCalls := Map("cheap", 0, "schedule", 0, "flush", 0)
global _KLSCF_TimestampPort := 0

; Native focus/classification ports are controlled. Production cache, stop,
; privacy admission, close ownership and central queue mutation remain real.
KL_FocusedHostHwnd() {
	return 71
}

KL_DetectPasswordCheap(Hwnd, &Conclusive) {
	global _KLSCF_NativeCalls
	_KLSCF_NativeCalls["cheap"] += 1
	Conclusive := false
	return false
}

KL_SchedulePasswordDetect(*) {
	global _KLSCF_NativeCalls
	_KLSCF_NativeCalls["schedule"] += 1
}

KL_FlushBuffer(*) {
	global _KLSCF_NativeCalls
	_KLSCF_NativeCalls["flush"] += 1
	return true
}

MF_GetFocusSnapshot() {
	return {valid: true, process_name: "ordinary.exe", title: "ordinary", class: "BrowserHost"}
}

KL_NowTimestamp() {
	global _KLSCF_TimestampPort
	if HasMethod(_KLSCF_TimestampPort, "Call")
		_KLSCF_TimestampPort.Call()
	return "2026-10-04 12:00:00.000"
}

LoggerWarn(*) {
}

LoggerError(*) {
}

_KLSCF_Check(Condition, Message) {
	if !Condition
		throw Error(Message)
}

; Getter bindings must preserve scalar preimages, including the implicit
; class receiver of a static method and the instance supplied by DefineProp.
_KLSCF_AuthorityPreimages() {
	Owner := Map("idle_end", 150, "session_end", 100)
	Authority := KLSessionCloseAuthority(Owner)
	_KLSCF_Check(Authority.OwnerIdentity is Integer && Authority.OwnerIdentity = ObjPtr(Owner),
		"the authority getter must preserve its scalar owner identity")
	_KLSCF_Check(Authority.IdleDuration is Integer && Authority.IdleDuration = 150
		&& Authority.SessionDuration is Integer && Authority.SessionDuration = 100,
		"the authority getters must preserve independently frozen scalar durations")
	_KLSCF_Check(Authority.SessionGeneration is Integer && Authority.SessionGeneration = KLWatch.session_generation
		&& Authority.IdleGeneration is Integer && Authority.IdleGeneration = KLWatch.idle_generation,
		"the authority getters must preserve accepted generation scalars")
	_KLSCF_Check(Authority.SessionStartedAt is Integer && Authority.SessionStartedAt = KLWatch.session_started_at
		&& Authority.IdleStartedAt is Integer && Authority.IdleStartedAt = KLWatch.idle_started_at,
		"the authority getters must preserve accepted origin scalars")
}

_KLSCF_Seed() {
	KLWatch.session_close := false
	KLWatch.session_close_draining := false
	KLWatch.idle_close := false
	KLWatch.is_idle := false
	KLWatch.is_session_active := false
	KLWatch.privacy_interrupted := false
	KLWatch.privacy_started_at := 0
	KLWatch.last_authorized_tick := 0
	Keylogger.initialized := true
	Keylogger._shutting_down := false
	Keylogger._pending_entries := []
	Keylogger.health_events_session := 0
	KLPasswordCache.focus_tracking_active := true
	KLPasswordCache.focus_hook := 0
	KLPasswordCache.focus_callback := 0
	KL_CommitPwCache(71, A_TickCount, false, KLPasswordCache.focus_generation, "element:71")
	_KLSCF_Check(!MF_ShouldFilter(), "the actual foreground filter must first accept the exact safe cache")
	_KLSCF_Check(KL_Watchers_OnKeystroke(0, 100), "the real append must accept session_start")
	_KLSCF_Check(KL_LogSession("idle_start", unset, _KL_Watchers_CommitIdleStart.Bind(150)),
		"the real append must accept idle_start")
	_KLSCF_Check(Keylogger._pending_entries.Length = 2, "both starts must reach the actual queue")
	_KLSCF_Check(KL_BeginShutdown(), "the actual shutdown lease must open before producer teardown")
	Generation := KLPasswordCache.focus_generation
	KL_Hook_Stop()
	_KLSCF_Check(!KLPasswordCache.focus_tracking_active && KLPasswordCache.focus_generation = Generation + 1,
		"actual producer teardown must invalidate its safe password cache")
	_KLSCF_Check(MF_ShouldFilter(), "the actual privacy predicate must fail closed after focus teardown")
}

_KLSCF_Chain() {
	global _KLSCF_NativeCalls
	_KLSCF_Seed()
	Rejected := false
	LegacyClose := Map("type", "idle_end", "duration_ms", 150)
	_KLSCF_Check(!KL_AppendLog(LegacyClose, &Rejected, , (*) => 0),
		"the unqualified original publication path must refuse after actual focus teardown")
	_KLSCF_Check(!Rejected && Keylogger._pending_entries.Length = 2 && KLWatch.is_idle,
		"the original privacy refusal must leave accepted interval ownership intact")
	_KLSCF_Check(!KL_AppendLog(Map("type", "typing", "text", "private-marker")),
		"producer teardown must keep new telemetry fail-closed")
	_KLSCF_Check(_KL_Watchers_CloseSession(200, 300), "owned frozen closes must survive actual focus teardown")
	_KLSCF_Check(Keylogger._pending_entries.Length = 4, "only the two exact closes may join accepted starts")
	Idle := Keylogger._pending_entries[3]
	Session := Keylogger._pending_entries[4]
	_KLSCF_Check(Idle["type"] == "idle_end" && Idle["duration_ms"] = 150,
		"idle close must retain its independent frozen boundary")
	_KLSCF_Check(Session["type"] == "session_end" && Session["duration_ms"] = 100,
		"session close must retain its independent frozen boundary")
	_KLSCF_Check(Idle.Count = 4 && Session.Count = 4 && !KLWatch.is_idle && !KLWatch.is_session_active,
		"content-free queue mutation must pair with ownership commits")
	_KLSCF_Check(_KL_Watchers_CloseSession(9000, 9000) && Keylogger._pending_entries.Length = 4,
		"a repeated close must never duplicate accepted records")
	_KLSCF_Check(MF_ShouldFilter() && _KLSCF_NativeCalls["cheap"] > 0
		&& _KLSCF_NativeCalls["schedule"] > 0 && _KLSCF_NativeCalls["flush"] > 0,
		"the candidate must preserve the actual invalidation and fail-closed native-port chain")
}

_KLSCF_Retain(Kind, Duration, Commit) {
	return false
}

_KLSCF_PreparePublication() {
	_KLSCF_Seed()
	_KLSCF_Check(!_KL_Watchers_CloseSession(200, 300, _KLSCF_Retain),
		"technical refusal must detach a frozen close owner")
	KLWatch.session_close_draining := true
	Publication := KLSessionClosePublication(KLWatch.session_close.CloseAuthority, "idle_end")
	_KLSCF_Check(Publication.Authority == KLWatch.session_close.CloseAuthority
		&& Publication.Kind is String && Publication.Kind == "idle_end"
		&& Publication.Duration is Integer && Publication.Duration = 150,
		"publication getters must preserve exact authority, kind and scalar duration")
	_KLSCF_Check(Publication.Timestamp is String && Publication.Timestamp == "2026-10-04 12:00:00.000"
		&& Publication.LifecycleGeneration is Integer
		&& Publication.LifecycleGeneration = Keylogger.lifecycle_generation,
		"publication getters must preserve exact timestamp and lifecycle scalars")
	_KLSCF_Check(Publication.Entry is Map && HasMethod(Publication.CommitFn, "Call"),
		"publication getters must preserve the exact entry and trusted callback objects")
	_KLSCF_Check(Publication.Entry["duration_ms"] is Integer && Publication.Entry["duration_ms"] = 150,
		"direct indexed reads must reach the frozen scalar instead of the entry Map")
	return Publication
}

_KLSCF_Mutate(Mode, Publication) {
	if Mode == "duration"
		Publication.Entry["duration_ms"] += 1
	else if Mode == "timestamp"
		Publication.Entry["timestamp"] := "different"
	else if Mode == "type"
		Publication.Entry["type"] := "session_end"
	else if Mode == "payload"
		Publication.Entry["text"] := "private-marker"
	else if Mode == "owner"
		KLWatch.session_close := Map("idle_end", 150, "session_end", 100)
	else if Mode == "retired"
		_KL_Watchers_CommitSessionEnd()
	else if Mode == "idle-retired"
		_KL_Watchers_CommitIdleEnd()
	else if Mode == "owner-duration"
		KLWatch.session_close["idle_end"] := "150"
	else if Mode == "authority-owner"
		KLWatch.session_close.CloseAuthority := {}
	else if Mode == "same-origin"
		_KL_Watchers_CommitSessionStart(100)
	else if Mode == "lifecycle"
		KL_CancelShutdown()
	else if Mode == "uninitialized"
		Keylogger.initialized := false
	else if Mode == "instance-method" {
		Publication.DefineProp("IsCurrent", {Call: (*) => true})
		Publication.Entry["text"] := "private-marker"
	} else if Mode == "authority-method" {
		Publication.Authority.DefineProp("IsCurrent", {Call: (*) => true})
		_KL_Watchers_CommitSessionStart(100)
	} else if Mode == "coordinated-preimages" {
		Publication.DefineProp("Duration", {Get: (*) => 950})
		Publication.Authority.DefineProp("IdleDuration", {Get: (*) => 950})
		KLWatch.session_close["idle_end"] := 950
		Publication.Entry["duration_ms"] := 950
	} else if Mode == "reentry"
		_KLSCF_Check(!_KL_Watchers_CloseSession(9000, 9000), "reentry must not acquire the outer close")
	return Mode != "refuse"
}

_KLSCF_ForeignCommit(*) {
	return 0
}

_KLSCF_Refusals() {
	global _KLSCF_TimestampPort
	for Mode in ["duration", "timestamp", "type", "payload", "owner", "retired", "same-origin",
		"lifecycle", "uninitialized", "refuse", "foreign-entry", "foreign-commit", "foreign-certificate",
		"idle-retired", "owner-duration", "authority-owner", "subclass", "instance-method", "authority-method", "coordinated-preimages", "reentry"] {
		Publication := _KLSCF_PreparePublication()
		Entry := Mode == "foreign-entry" ? Publication.Entry.Clone() : Publication.Entry
		Commit := Publication.CommitFn
		if Mode == "foreign-commit"
			Commit := _KLSCF_ForeignCommit
		Certificate := Mode == "foreign-certificate" ? {}
			: Mode == "subclass" ? _KLSCF_ForgedPublication() : Publication
		if Mode == "subclass" {
			Entry := Map("type", "typing", "text", "private-marker")
			Commit := Certificate.CommitFn
		}
		Rejected := false
		try Accepted := KL_AppendLog(Entry, &Rejected, _KLSCF_Mutate.Bind(Mode, Publication), Commit, Certificate)
		finally KLWatch.session_close_draining := false
		_KLSCF_Check(Accepted = (Mode == "reentry"), "unexpected central admission for " . Mode)
		_KLSCF_Check(Keylogger._pending_entries.Length = (Mode == "reentry" ? 3 : 2),
			"refusal must precede queue mutation for " . Mode)
		_KLSCF_Check(Keylogger.health_events_session = Keylogger._pending_entries.Length,
			"rejected rows cannot advance accepted counters")
		if Mode == "refuse" {
			_KLSCF_Check(_KL_Watchers_CloseSession(9000, 9000), "refused immutable debt must remain retryable")
			_KLSCF_Check(Keylogger._pending_entries[3]["duration_ms"] = 150
				&& Keylogger._pending_entries[4]["duration_ms"] = 100, "retry must preserve both first boundaries")
		}
	}
	Publication := _KLSCF_PreparePublication()
	KLWatch.session_close_draining := false
	_KLSCF_Check(!Publication.IsCurrent(Publication.Entry), "an inactive drain cannot lend publication authority")
	KLWatch.session_close_draining := true
	_KLSCF_TimestampPort := _KLSCF_Mutate.Bind("same-origin", Publication)
	try Changed := KLSessionClosePublication(Publication.Authority, "idle_end")
	finally _KLSCF_TimestampPort := 0
	_KLSCF_Check(!Changed.IsCurrent(Changed.Entry), "yielding timestamp preparation must revalidate accepted authority")
	KLWatch.session_close_draining := false
	for Generation in ["session_generation", "idle_generation"] {
		_KLSCF_Seed()
		KLWatch.%Generation% := 0
		_KLSCF_Check(!_KL_Watchers_CloseSession(200, 300), "missing accepted generation must refuse " . Generation)
		_KLSCF_Check(Keylogger._pending_entries.Length = 2, "flags alone cannot certify accepted starts")
	}
	KLWatch.is_session_active := false
	KLWatch.is_idle := false
	KLWatch.session_close := false
	KLWatch.privacy_interrupted := false
	KLWatch.session_generation := 0
	KLWatch.idle_generation := 0
	Keylogger._pending_entries := []
	KL_Watchers_OnPrivateKeystroke(100)
	_KLSCF_Check(_KL_Watchers_CloseSession(200, 300) && Keylogger._pending_entries.Length = 0,
		"private-first physical input must not manufacture a closing authority")
}

_KLSCF_ThrowGuard(*) {
	throw Error("synthetic queue preparation failure")
}

_KLSCF_ReceiptRetirement(Mode) {
	_KLSCF_Check(_KL_SessionCloseAuthorityReceipt() = 0 && _KL_SessionClosePublicationReceipt() = 0,
		"a completed fixture must leave no issued receipts")
	Publication := _KLSCF_PreparePublication()
	_KLSCF_Check(_KL_SessionCloseAuthorityReceipt() = 1 && _KL_SessionClosePublicationReceipt() = 1,
		"one detached owner and one publication must own exact receipts")
	if Mode == "exception" {
		Thrown := false
		Rejected := false
		try KL_AppendLog(Publication.Entry, &Rejected, _KLSCF_ThrowGuard, Publication.CommitFn, Publication)
		catch Error as Failure {
			_KLSCF_Check(Failure.Message == "synthetic queue preparation failure", "the actual guard exception must execute")
			Thrown := true
		}
		_KLSCF_Check(Thrown && Keylogger._pending_entries.Length = 2 && KLWatch.is_idle,
			"an exception cannot publish or retire the retained interval")
	} else if Mode == "refused" {
		Rejected := false
		_KLSCF_Check(!KL_AppendLog(Publication.Entry, &Rejected, (*) => false, Publication.CommitFn, Publication),
			"a refusing guard must retain exact unpublished debt")
	} else if Mode == "superseded"
		KLWatch.session_close := false
	KLWatch.session_close_draining := false
	if Mode == "success" {
		_KLSCF_Check(_KL_Watchers_CloseSession(9000, 9000), "a successful drain must retire its authority")
		_KLSCF_Check(_KL_SessionCloseAuthorityReceipt() = 0 && _KL_SessionClosePublicationReceipt() = 1,
			"success must explicitly retire authority while a caller still holds its stale publication")
	}
	Publication := unset
	_KLSCF_Check(_KL_SessionClosePublicationReceipt() = 0, "released publications must retire their private receipts")
	if Mode == "refused" || Mode == "exception" {
		_KLSCF_Check(_KL_SessionCloseAuthorityReceipt() = 1, "retained technical debt must keep one accepted authority")
		_KLSCF_Check(_KL_Watchers_CloseSession(9000, 9000), "the exact retained debt must complete later")
	}
	_KLSCF_Check(_KL_SessionCloseAuthorityReceipt() = 0 && _KL_SessionClosePublicationReceipt() = 0,
		"success, supersession and retried failure must leave no receipt growth")
}

; Keep runner-loop and failure variables local. Top-level assignments would
; collide with the same names in the subjects under #Warn All.
_KLSCF_Main() {
	try {
		_KLSCF_AuthorityPreimages()
		_KLSCF_Chain()
		_KLSCF_Refusals()
		for Mode in ["success", "refused", "exception", "superseded"]
			_KLSCF_ReceiptRetirement(Mode)
		FileAppend("frozen-close-chain: passed`n", "*", "UTF-8-RAW")
		ExitApp(0)
	} catch as Failure {
		FileAppend("frozen-close-chain: failed: " . Failure.Message . "`n" . Failure.Stack . "`n", "**", "UTF-8-RAW")
		ExitApp(1)
	}
}

_KLSCF_Main()

; infra/lifecycle_transition.ahk

; Canonical owners whose suspend-bypassing work must acknowledge each
; transition. Optional features enter the transaction only when configured,
; but once an owner is present its exception or explicit false result is debt.
global LIFECYCLE_REQUIRED_OWNERS := Map(
	"suspend", [
		"navigation-event", "llm-aux-context", "tap-hold-synthetic-keys",
		"tray-root", "gesture-screenshot", "hotstring-prefix-watcher",
		"selection-capture", "space-hold-input-hook",
		"suppressive-input-hooks", "magic-key-editor-input-hook",
		"suspend-tooltip", "llm-tooltip", "llm-generation-timer",
		"llm-generation", "ollama-warmup", "llm-pointer-watch",
		"metrics-focus-refresh", "updater-checks", "updater-self-update",
		"keylogger-prefetch-typing", "keylogger-prefetch-apps",
		"keylogger-prefetch-range", "uia-selection-worker",
		"keylogger-text-migration", "keep-awake", "gesture-left-hold",
		"gesture-right-hold", "caps-word", "hotstring-engine",
		"llm-dependency-poll"
	],
	"resume", [
		"navigation-event", "hotstring-prefix-watcher", "prefix-buffer",
		"prefix-index", "llm-dependency-poll", "llm-pointer-watch",
		"metrics-focus-refresh", "keylogger-webview",
		"keylogger-text-migration", "llm-menu", "updater",
		"uia-selection-worker"
	]
)
global _LifecycleLatestTransition := 0
global _LifecycleTransitionsByPhase := Map()

LifecycleTransitionBegin(Phase) {
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	if !LIFECYCLE_REQUIRED_OWNERS.Has(Phase)
		throw Error("unknown lifecycle transition phase: " . Phase)
	Transaction := {
		phase: Phase,
		debt: [],
		started: false,
		finished: false
	}
	_LifecycleLatestTransition := Transaction
	_LifecycleTransitionsByPhase[Phase] := Transaction
	return Transaction
}

LifecycleTransitionMarkStarted(Transaction) {
	_LifecycleValidateTransaction(Transaction)
	if Transaction.finished
		throw Error("cannot start a finished lifecycle transition")
	Transaction.started := true
	return true
}

_LifecycleRunRequiredStep(Transaction, Owner, Action, RequireTrue := false) {
	_LifecycleValidateTransaction(Transaction)
	if Transaction.finished
		throw Error("cannot run an owner in a finished lifecycle transition")
	if !_LifecycleOwnerIsRequired(Transaction.phase, Owner)
		throw Error("unregistered " . Transaction.phase . " lifecycle owner: " . Owner)
	if !HasMethod(Action, "Call") {
		_LifecycleRecordDebt(Transaction, Owner, "owner action is not callable")
		return false
	}
	try Result := Action.Call()
	catch as Err {
		_LifecycleRecordDebt(Transaction, Owner, Err.Message)
		return false
	}
	; Some idempotent stop APIs return false to mean "already absent". Only ports
	; whose contract explicitly acknowledges success opt into boolean checking.
	if RequireTrue and !((Result is Integer) and Result == 1) {
		_LifecycleRecordDebt(Transaction, Owner, "returned false")
		return false
	}
	return true
}

LifecycleTransitionFinish(Transaction) {
	_LifecycleValidateTransaction(Transaction)
	Transaction.finished := true
	return Transaction.debt.Length == 0
}

LifecycleTransitionNeedsCompensation(Phase) {
	global _LifecycleTransitionsByPhase
	if !_LifecycleTransitionsByPhase.Has(Phase)
		return false
	Transaction := _LifecycleTransitionsByPhase[Phase]
	return Transaction.finished and Transaction.started
		and Transaction.debt.Length > 0
}

LifecycleTransitionDebtSnapshot(Phase := "") {
	global _LifecycleLatestTransition, _LifecycleTransitionsByPhase
	Snapshot := []
	if Phase != "" {
		if !_LifecycleTransitionsByPhase.Has(Phase)
			return Snapshot
		Transaction := _LifecycleTransitionsByPhase[Phase]
	} else if _LifecycleLatestTransition is Object {
		Transaction := _LifecycleLatestTransition
	} else {
		return Snapshot
	}
	for Debt in Transaction.debt
		Snapshot.Push({ owner: Debt.owner, message: Debt.message })
	return Snapshot
}

_LifecycleOwnerIsRequired(Phase, Owner) {
	for RequiredOwner in LIFECYCLE_REQUIRED_OWNERS[Phase] {
		if RequiredOwner == Owner
			return true
	}
	return false
}

_LifecycleRecordDebt(Transaction, Owner, Message) {
	Transaction.debt.Push({ owner: Owner, message: Message })
}

_LifecycleValidateTransaction(Transaction) {
	global _LifecycleTransitionsByPhase
	if !(Transaction is Object)
		throw TypeError("lifecycle transaction must be an object")
	if !HasProp(Transaction, "phase") or !HasProp(Transaction, "debt")
			or !HasProp(Transaction, "started") or !HasProp(Transaction, "finished")
		throw Error("invalid lifecycle transaction")
	if !_LifecycleTransitionsByPhase.Has(Transaction.phase)
			or ObjPtr(_LifecycleTransitionsByPhase[Transaction.phase])
				!= ObjPtr(Transaction)
		throw Error("stale lifecycle transaction")
}

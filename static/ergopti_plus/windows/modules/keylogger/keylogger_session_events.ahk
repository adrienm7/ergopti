; modules/keylogger/keylogger_session_events.ahk

; ==============================================================================
; MODULE: Session Event Publication
; DESCRIPTION: Pair accepted session records with their ownership commits.
; ==============================================================================

#Requires AutoHotkey v2.0

KL_LogSession(kind, duration_ms := unset, PublishCommit := 0, FrozenClose := unset) {
	if IsSet(FrozenClose) {
		if !(Type(FrozenClose) == "KLSessionClosePublication") || !IsSet(duration_ms)
				|| !(kind == FrozenClose.Kind) || duration_ms != FrozenClose.Duration
				|| PublishCommit != FrozenClose.CommitFn
			return false
		RejectedBySuspend := false
		return KL_AppendLog(FrozenClose.Entry, &RejectedBySuspend, , PublishCommit, FrozenClose)
	}
	e := Map("type", kind)
	if IsSet(duration_ms)
		e["duration_ms"] := duration_ms
	if HasMethod(PublishCommit, "Call") {
		RejectedBySuspend := false
		return KL_AppendLog(e, &RejectedBySuspend, , PublishCommit)
	}
	return KL_AppendLog(e)
}


; A closing record describes an already accepted interval, not the window that
; happens to have focus after its input producer has stopped. Keep its accepted
; preimage on the detached owner, independently of mutable retry durations.
class KLSessionCloseAuthority {
	__New(Owner) {
		Values := Map("OwnerIdentity", ObjPtr(Owner),
			"SessionGeneration", KLWatch.session_generation,
			"SessionStartedAt", KLWatch.session_started_at,
			"IdleGeneration", KLWatch.idle_generation,
			"IdleStartedAt", KLWatch.idle_started_at,
			"SessionDuration", Owner.Get("session_end", -1),
			"IdleDuration", Owner.Get("idle_end", -1))
		Getters := Map()
		for Name, Value in Values {
			Getter := KLSessionCloseAuthority.ReadOnly.Bind(KLSessionCloseAuthority, Value)
			this.DefineProp(Name, {Get: Getter})
			Getters[Name] := Getter
		}
		_KL_SessionCloseAuthorityReceipt(this, , , Getters)
	}

	__Delete() {
		_KL_SessionCloseAuthorityReceipt(this, , , , true)
	}

	; Static methods still receive implicit this. Bind the class before the
	; frozen value, then ignore the instance passed by the property getter.
	static ReadOnly(Value, *) {
		return Value
	}

	IsCurrent(Kind, Duration) {
		Owner := KLWatch.session_close
		if !(Owner is Map) || ObjPtr(Owner) != this.OwnerIdentity || !KLWatch.session_close_draining
				|| !Owner.HasOwnProp("CloseAuthority") || Owner.CloseAuthority != this
				|| !Owner.Has(Kind) || !(Owner[Kind] is Integer) || Owner[Kind] != Duration
				|| !KLWatch.is_session_active || this.SessionGeneration <= 0
				|| KLWatch.session_generation != this.SessionGeneration
				|| KLWatch.session_started_at != this.SessionStartedAt
			return false
		if Kind == "session_end"
			return Duration = this.SessionDuration
		return Kind == "idle_end" && Duration = this.IdleDuration
			&& KLWatch.is_idle && this.IdleGeneration > 0
			&& KLWatch.idle_generation = this.IdleGeneration
			&& KLWatch.idle_started_at = this.IdleStartedAt
	}
}

; Only this owner constructs the trusted closing callback and the content-free
; row. Read-only scalar properties preserve the preimage across yielding ports;
; the mutable entry itself is checked again at central queue mutation.
class KLSessionClosePublication {
	__New(Authority, Kind) {
		if !(Type(Authority) == "KLSessionCloseAuthority")
			throw TypeError("A frozen session close requires its accepted interval authority.")
		Duration := Kind == "idle_end" ? Authority.IdleDuration
			: Kind == "session_end" ? Authority.SessionDuration : -1
		if !(Duration is Integer) || Duration < 0
			throw ValueError("A frozen session close requires an owned nonnegative duration.")
		Owner := KLWatch.session_close
		if !(Owner is Map) || ObjPtr(Owner) != Authority.OwnerIdentity
			throw Error("A frozen session close requires its current detached owner.")
		LifecycleGeneration := Keylogger.lifecycle_generation
		Timestamp := KL_NowTimestamp()
		if !(Timestamp is String) || Timestamp = ""
			throw ValueError("A frozen session close requires a timestamp.")
		Values := Map("Authority", Authority, "Kind", Kind, "Duration", Duration,
			"Timestamp", Timestamp, "LifecycleGeneration", LifecycleGeneration,
			"Entry", Map("type", Kind, "duration_ms", Duration, "timestamp", Timestamp),
			"CommitFn", _KL_Watchers_CommitClose.Bind(Owner, Kind))
		Getters := Map()
		for Name, Value in Values {
			Getter := KLSessionCloseAuthority.ReadOnly.Bind(KLSessionCloseAuthority, Value)
			this.DefineProp(Name, {Get: Getter})
			Getters[Name] := Getter
		}
		_KL_SessionClosePublicationReceipt(this, , , , Getters)
	}

	__Delete() {
		_KL_SessionClosePublicationReceipt(this, , , , , true)
	}

	IsCurrent(Entry, WithId := false) {
		if !Keylogger.initialized || !Keylogger._shutting_down
				|| Keylogger.lifecycle_generation != this.LifecycleGeneration
				|| !(Entry is Map) || Entry != this.Entry
				|| Entry.Count != (WithId ? 4 : 3)
				|| !(Entry.Get("type", 0) is String) || !(Entry["type"] == this.Kind)
				|| !(Entry.Get("duration_ms", "") is Integer)
				|| Entry["duration_ms"] != this.Duration
				|| !(Entry.Get("timestamp", 0) is String) || !(Entry["timestamp"] == this.Timestamp)
			return false
		if WithId && (!(Entry.Get("_event_id", "") is Integer) || Entry["_event_id"] <= 0)
			return false
		return _KL_SessionCloseAuthorityReceipt(this.Authority, this.Kind, this.Duration)
	}
}

_KL_IsFrozenSessionClose(Entry, Publication, PublishCommit := unset, WithId := false) {
	; A subclass or an instance method replacement is not publication authority.
	; Invoke the known validators directly rather than trusting virtual dispatch.
	return _KL_SessionClosePublicationReceipt(Publication, Entry, PublishCommit?, WithId)
}


; Setter-free properties remain redefinable in AHK. Keep the originally issued
; getter identities inside lexical stores, never on caller-visible certificate
; properties. Replacing even a coordinated set of preimages invalidates admission.
_KL_SessionCloseReceiptDescriptorsMatch(Owner, Getters) {
	for Name, Getter in Getters {
		if !Owner.HasOwnProp(Name)
			return false
		Descriptor := Owner.GetOwnPropDesc(Name)
		if !Descriptor.HasOwnProp("Get") || Descriptor.Get != Getter
			return false
	}
	return true
}

_KL_SessionCloseAuthorityReceipt(Authority := unset, Kind := "", Duration := -1,
	Issue := unset, Retire := false) {
	static Receipts := Map()
	if !IsSet(Authority)
		return Receipts.Count
	if !(Type(Authority) == "KLSessionCloseAuthority")
		return false
	Identity := ObjPtr(Authority)
	if Retire {
		if Receipts.Has(Identity)
			Receipts.Delete(Identity)
		return true
	}
	if IsSet(Issue) {
		if Receipts.Has(Identity)
			throw Error("A session close authority cannot be issued twice.")
		Receipts[Identity] := Issue
		return true
	}
	return Receipts.Has(Identity)
		&& _KL_SessionCloseReceiptDescriptorsMatch(Authority, Receipts[Identity])
		&& KLSessionCloseAuthority.Prototype.IsCurrent.Call(Authority, Kind, Duration)
}

_KL_SessionClosePublicationReceipt(Publication := unset, Entry := unset, PublishCommit := unset,
	WithId := false, Issue := unset, Retire := false) {
	static Receipts := Map()
	if !IsSet(Publication)
		return Receipts.Count
	if !(Type(Publication) == "KLSessionClosePublication")
		return false
	Identity := ObjPtr(Publication)
	if Retire {
		if Receipts.Has(Identity)
			Receipts.Delete(Identity)
		return true
	}
	if IsSet(Issue) {
		if Receipts.Has(Identity)
			throw Error("A session close publication cannot be issued twice.")
		Receipts[Identity] := Issue
		return true
	}
	return Receipts.Has(Identity) && IsSet(Entry) && IsSet(PublishCommit)
		&& _KL_SessionCloseReceiptDescriptorsMatch(Publication, Receipts[Identity])
		&& PublishCommit == Publication.CommitFn
		&& KLSessionClosePublication.Prototype.IsCurrent.Call(Publication, Entry, WithId)
}

; modules/keystats/keystats_roi_privacy.ahk

; ==============================================================================
; MODULE: ROI Text Publication Privacy
; DESCRIPTION:
; Revokes unpublished word telemetry when encryption is requested. An append
; already claimed keeps its exact existing journal owner until flush or rollback
; acknowledges it; numeric savings and durable historical events are unchanged.
; ==============================================================================

class KLRoiPrivacy {
	static epoch := 0
	static blocked := false
	static started := Map()
	static request_owner := 0
	static canonical_known := false
}

KL_Roi_IsTextEntry(Entry) {
	return Entry is Map && (Entry.Get("type", "") == "new_trigger_candidate"
		|| Entry.Get("type", "") == "trigger_halflife")
}

; The requested preference and effective cipher must both be known off. A missing
; provider or malformed setting cannot turn encryption failure into plaintext.
KL_Roi_TextPostureOff() {
	if !KLRoiPrivacy.canonical_known || !IsSet(MetricsFilters) || !MetricsFilters.HasOwnProp("encrypt")
		return false
	Requested := MetricsFilters.encrypt
	if !(Requested is Integer) || Requested != 0
		return false
	try Cipher := KL_Enc_IsEnabled()
	catch
		return false
	return (Cipher is Integer) && Cipher == 0
}

; Only memory is changed here. Native persistence keeps its existing owner.
KL_Roi_BlockText() {
	PreviousCritical := Critical("On")
	try {
		if !KLRoiPrivacy.blocked
			KLRoiPrivacy.epoch += 1
		KLRoiPrivacy.blocked := true
		if IsSet(KLRoi) {
			KLRoi.current_word := ""
			KLRoi.word_overflowed := false
			KLRoi.word_context := false
			KLRoi.word_counts := Map()
			KLRoi.word_counts_generation += 1
			KLRoi.trigger_last_use := Map()
		}
		if IsSet(Keystats) && Keystats.HasOwnProp("_pending_entries") {
			Retained := []
			for Entry in Keystats._pending_entries
				if !KL_Roi_IsTextEntry(Entry) || KLRoiPrivacy.started.Has(Entry)
					Retained.Push(Entry)
			Keystats._pending_entries := Retained
		}
	} finally Critical(PreviousCritical)
}

KL_Roi_TextAllowed() {
	if !KL_Roi_TextPostureOff() {
		KL_Roi_BlockText()
		return false
	}
	if KLRoiPrivacy.blocked && !IsObject(KLRoiPrivacy.request_owner) && KL_Roi_EncryptionReady()
		KLRoiPrivacy.blocked := false
	return !KLRoiPrivacy.blocked
}

; A refused ON request still retires old words. A clean refusal may reopen new
; OFF captures only after the request owner and all native debts have settled.
KL_Roi_RequestEncryption(Requested) {
	if !(Requested is Integer) || (Requested != 0 && Requested != 1) {
		KL_Roi_BlockText()
		return false
	}
	if Requested
		KL_Roi_BlockText()
	return true
}

KL_Roi_BeginEncryptionRequest(Requested) {
	PreviousCritical := Critical("On")
	try {
		if IsObject(KLRoiPrivacy.request_owner) || !KL_Roi_RequestEncryption(Requested)
			return 0
		Owner := {}
		KLRoiPrivacy.request_owner := Owner
		return Owner
	} finally Critical(PreviousCritical)
}

KL_Roi_EndEncryptionRequest(Owner) {
	PreviousCritical := Critical("On")
	try {
		if !IsObject(Owner) || Owner != KLRoiPrivacy.request_owner
			throw Error("ROI encryption request requires its current owner.")
		KLRoiPrivacy.request_owner := 0
		if KL_Roi_TextPostureOff() && KL_Roi_EncryptionReady()
			KLRoiPrivacy.blocked := false
	} finally Critical(PreviousCritical)
}

; The metrics reader may substitute defaults for an outdated raw TOML value.
; That compatibility behavior must not grant ROI permission to record words.
KL_Roi_SetCanonicalPolicyKnown(Known) {
	PreviousCritical := Critical("On")
	try {
		KLRoiPrivacy.canonical_known := (Known is Integer) && Known == 1
		if !KLRoiPrivacy.canonical_known
			KL_Roi_BlockText()
	} finally Critical(PreviousCritical)
}

KL_Roi_CommitEncryptionPolicy(Requested, CanonicalKnown := true) {
	KL_Roi_SetCanonicalPolicyKnown(CanonicalKnown)
	if !KL_Roi_RequestEncryption(Requested)
		return false
	if Requested
		return true
	PreviousCritical := Critical("On")
	try {
		if !KL_Roi_TextPostureOff()
			KL_Roi_BlockText()
		else if KLRoiPrivacy.blocked && !IsObject(KLRoiPrivacy.request_owner) && KL_Roi_EncryptionReady()
			KLRoiPrivacy.blocked := false
		return true
	} finally Critical(PreviousCritical)
}

; This does not repair or truncate anything. Only the original persistence
; owner may settle an append that had begun before the preference was requested.
KL_Roi_EncryptionReady(Port := 0) {
	global _KL_SQL_ACTIVE_APPENDS, _KL_SQL_APPEND_DEBTS
	PreviousCritical := Critical("On")
	try {
		Owner := _KL_JournalOwnerFor(Port)
		return !IsObject(Owner._Token) && !Owner.HasDebt()
			&& KLRoiPrivacy.started.Count == 0
			&& IsSet(_KL_SQL_ACTIVE_APPENDS) && _KL_SQL_ACTIVE_APPENDS == 0
			&& IsSet(_KL_SQL_APPEND_DEBTS) && _KL_SQL_APPEND_DEBTS.Count == 0
	} finally Critical(PreviousCritical)
}

; Own properties of a Map are not its JSON/SQL items. Keep the capture epoch
; internal so restoring a detached batch cannot revive a revoked word after OFF.
KL_Roi_AdmitTextEntry(Entry) {
	if !KL_Roi_IsTextEntry(Entry)
		return true
	if !KL_Roi_TextAllowed()
		return false
	if Entry.HasOwnProp("_KL_RoiCaptureEpoch") && Entry._KL_RoiCaptureEpoch != KLRoiPrivacy.epoch
		return false
	Entry._KL_RoiCaptureEpoch := KLRoiPrivacy.epoch
	return true
}

KL_Roi_KeepPendingEntry(Entry) {
	if !KL_Roi_IsTextEntry(Entry) || KLRoiPrivacy.started.Has(Entry)
		return true
	return Entry.HasOwnProp("_KL_RoiCaptureEpoch")
		&& Entry._KL_RoiCaptureEpoch == KLRoiPrivacy.epoch && KL_Roi_TextAllowed()
}

; Normalize before detaching, including rows inserted by a direct producer.
; Later removals mutate this retained array so logged_count still names a prefix.
KL_Roi_PreparePending(Snapshot) {
	Retained := []
	for Entry in Snapshot {
		if KL_Roi_IsTextEntry(Entry) && !Entry.HasOwnProp("_KL_RoiCaptureEpoch")
			if !KL_Roi_AdmitTextEntry(Entry)
				continue
		if KL_Roi_KeepPendingEntry(Entry)
			Retained.Push(Entry)
	}
	return Retained
}

; Claim once after encoding, immediately before the native append outside
; Critical. Revocation can remove every later row but cannot abandon this write.
KL_Roi_ClaimTextAppend(Entry) {
	PreviousCritical := Critical("On")
	try {
		if !KL_Roi_KeepPendingEntry(Entry)
			return false
		if KL_Roi_IsTextEntry(Entry)
			KLRoiPrivacy.started[Entry] := true
		return true
	} finally Critical(PreviousCritical)
}

; A true native flush or an acknowledged existing rollback ends the ownership.
; A refused compensation retains it and keeps activation closed until repair.
KL_Roi_SettleTextAppends(Snapshot, Acknowledged) {
	if !(Acknowledged is Integer) || Acknowledged != 1
		return false
	PreviousCritical := Critical("On")
	try {
		for Entry in Snapshot
			if KLRoiPrivacy.started.Has(Entry)
				KLRoiPrivacy.started.Delete(Entry)
		Keystats._pending_entries := KL_Roi_PreparePending(Keystats._pending_entries)
		return true
	} finally Critical(PreviousCritical)
}

; The existing owner retains this exact repair callback across a refused native
; rollback. Successful later repair retires its rows before any retry is opened.
KL_Roi_RepairTextAppends(Snapshot, RollbackFn, Fh, Boundary) {
	Acknowledged := RollbackFn.Call(Fh, Boundary)
	KL_Roi_SettleTextAppends(Snapshot, Acknowledged)
	return Acknowledged
}

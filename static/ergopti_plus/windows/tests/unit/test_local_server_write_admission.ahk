; tests/unit/test_local_server_write_admission.ahk

; ==============================================================================
; MODULE: Retained Local Server Write Admission Tests
; DESCRIPTION:
; Composes the real controller/models/curl fixture and distinct private token
; classes. Controlled durable phase proves admission separation, not WAL I/O.
; Load after private API source classes and test_local_servers.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Retained Write Fixture =======
; =========================================
; =========================================

class _LSWA_Fixture extends _LSO_Fixture {
	__New() {
		super.__New()
		this.Durable := false
		this.SourceAfter := 0
		this.EntryAfter := 0
		this.AdmitAfter := 0
		this.Control := ""
		this.FinalControl := ""
		this.Observed := Map()
		this.Callback := 0
		this.Capability := 0
		this.Private := LLM_Menu_ApiPrivateSourceOwner()
	}

	SourceCurrent(Source) {
		if this.Durable {
			this.SourceAfter += 1
			return false
		}
		return super.SourceCurrent(Source)
	}

	Entry(Id) {
		if this.Durable {
			this.EntryAfter += 1
			throw Error("ordinary entry access is forbidden after controlled durability")
		}
		return super.Entry(Id)
	}

	Admission() {
		if this.Durable
			this.AdmitAfter += 1
		return super.Admission()
	}

	Alter(Control) {
		switch Control {
			case "view": this.Native.BeginView()
			case "cache": this.Native.Cache := this.Native.Cache.Clone()
			case "ordered_models": this.Native.Cache["results"]["lmstudio"]["models"][1] := "replaced"
			case "model_generation": this.Native.ModelGeneration += 1
			case "configuration": this.Native.ConfigurationGeneration += 1
			case "controller": this.Native.Controller.Invalidate()
			case "rescan": this.Native.RescanGeneration += 1
			case "pending_owner": this.Native.Pending["lmstudio"] := Map("token", "late")
			case "pending_values": this.Native.Pending["lmstudio"]["token"] := "late"
			case "target": this.Native.Views[ObjPtr(this.Receipt)]["target"]["entry_id"] := "replacement-entry"
			case "pause": Suspend(true)
			case "shutdown": this.Native.Cancel(true)
			case "returned_result": this.OutwardVerdict["models"][1] := "external-result"
			case "publication_snapshot": this.OutwardPublished["lmstudio"]["models"][1] := "external-publication"
			case "shared_result": this.Native.Controller.Result("lmstudio")["models"][1] := "external-shared"
		}
	}

	Persist(Id, Fields, Source, Admission, SelectModel) {
		this.Callback := Admission
		this.Observed["pre"] := Admission.Call()
		this.Durable := true
		Capability := LLM_Menu_ApiPrivateCandidateReceipt()
		this.Capability := Capability
		this.Observed["forged_private_authority"] := this.Private.CandidateCurrent(Capability)
		this.Observed["source_as_candidate"] := Admission.Call("committed", LLM_Menu_ApiPrivateSourceReceipt())
		this.Observed["wrong_phase"] := Admission.Call("Committed", Capability)
		Suspended := A_IsSuspended
		try {
			this.Alter(this.Control)
			this.Observed["post"] := Admission.Call("committed", Capability)
			this.Observed["post_source_calls"] := this.SourceAfter
			this.Observed["post_entry_calls"] := this.EntryAfter
			this.Observed["post_admit_calls"] := this.AdmitAfter
			this.Observed["ordinary_after"] := Admission.Call()
			this.Observed["claim_outside"] := Admission.Call("claim", Capability)
			this.Alter(this.FinalControl)
			PreviousCritical := Critical("On")
			try {
				this.Observed["critical_before"] := A_IsCritical
				this.Observed["claim"] := Admission.Call("claim", Capability)
				this.Observed["critical_after"] := A_IsCritical
			} finally Critical(PreviousCritical)
		} finally Suspend(Suspended)
		; A constructed nominal token has no private registry authority. This
		; controlled port acknowledges no save and performs no RAM publication.
		return false
	}

	Prepare() {
		if this.Control == "pending_values"
			this.Native.Pending["lmstudio"] := Map("token", "original")
		AssertTrue(this.Native.Rescan())
		this.Complete(1, 200, '{"data":[{"id":"chosen"},{"id":"other"}]}')
		this.Native.BeginView()
		this.Receipt := this.Native.Capture("lmstudio")
		AssertTrue(this.Native.IsCurrent(this.Receipt, "chosen"))
		this.OutwardVerdict := this.Native.Result("lmstudio")
		this.OutwardPublished := this.Published[1]
	}

	Dispose() {
		this.Durable := false
		this.Callback := 0
		this.Capability := 0
		super.Dispose()
	}
}





; =============================================
; =============================================
; ======= 2/ Independent Write Controls =======
; =============================================
; =============================================

_LSWA_SeparatePostDurableAdmission(Control := "", FinalControl := "") {
	Fixture := _LSWA_Fixture()
	try {
		Fixture.Control := Control, Fixture.FinalControl := FinalControl
		Fixture.Prepare()
		AssertFalse(Fixture.Native.Apply(Fixture.Receipt, Map("model", "chosen")), "controlled port acknowledges no real persistence")
		Observed := Fixture.Observed
		AssertTrue(Observed["pre"], "ordinary admission validates the original source before durability")
		AssertFalse(Observed["forged_private_authority"], "a nominal candidate instance has no private writer authority")
		AssertFalse(Observed["source_as_candidate"], "ordinary source tokens never inherit committed authority")
		AssertFalse(Observed["wrong_phase"], "phase identity is exact")
		AssertEqual(Control == "", Observed["post"], "committed admission checks the retained native view")
		AssertEqual(0, Observed["post_source_calls"], "committed branch must not consult ordinary old source authority")
		AssertEqual(0, Observed["post_entry_calls"], "committed branch must not read old native entries through general ports")
		AssertEqual(0, Observed["post_admit_calls"], "private candidate validation owns native lease admission")
		AssertFalse(Observed["ordinary_after"], "ordinary old-source authority stays revoked after durability")
		AssertFalse(Observed["claim_outside"], "final claim requires the publisher's inherited Critical region")
		AssertEqual(Control == "" && FinalControl == "", Observed["claim"], "final generation change refuses RAM publication")
		AssertTrue(Observed["critical_before"] > 0)
		AssertEqual(Observed["critical_before"], Observed["critical_after"], "final claim preserves the publisher's atomic boundary")
		AssertFalse(Fixture.Native.WriteClaim is Map)
		AssertFalse(Fixture.Native.Writing)
		AssertFalse(Fixture.Callback.Call("committed", Fixture.Capability), "completed writer cannot lend its old claim to a retained callback")
		AssertEqual("saved", Fixture.Entries["lmstudio"]["Model"], "admission predicates never publish native RAM")
	} finally Fixture.Dispose()
}
Test("local write admission: committed provenance does not broaden old source authority", _LSWA_SeparatePostDurableAdmission)
Test("local write admission: retained view replacement refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("view"))
Test("local write admission: accepted cache replacement refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("cache"))
Test("local write admission: ordered model mutation refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("ordered_models"))
Test("local write admission: model generation change refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("model_generation"))
Test("local write admission: configuration generation change refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("configuration"))
Test("local write admission: logical controller change refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("controller"))
Test("local write admission: rescan intent change refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("rescan"))
Test("local write admission: pending owner replacement refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("pending_owner"))
Test("local write admission: pending scalar change refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("pending_values"))
Test("local write admission: retained target replacement refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("target"))
Test("local write admission: pause refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("pause"))
Test("local write admission: shutdown refuses committed admission", _LSWA_SeparatePostDurableAdmission.Bind("shutdown"))
Test("local write admission: late view change refuses the final atomic claim", _LSWA_SeparatePostDurableAdmission.Bind("", "view"))
Test("local write admission: late controller change refuses the final atomic claim", _LSWA_SeparatePostDurableAdmission.Bind("", "controller"))
Test("local write admission: late pending replacement refuses the final atomic claim", _LSWA_SeparatePostDurableAdmission.Bind("", "pending_owner"))





; =============================================
; =============================================
; ======= 3/ Outward Snapshot Isolation =======
; =============================================
; =============================================

_LSWA_OutwardSnapshotCannotRevokeClaim(Control) {
	Fixture := _LSWA_Fixture()
	try {
		Fixture.FinalControl := Control
		Fixture.Prepare()
		AssertFalse(Fixture.Native.Apply(Fixture.Receipt, Map("model", "chosen")))
		AssertTrue(Fixture.Observed["pre"])
		AssertTrue(Fixture.Observed["post"], "full retained proof precedes external snapshot mutation")
		AssertTrue(Fixture.Observed["claim"], "external copies cannot remove the internally retained model")
		switch Control {
			case "returned_result": AssertEqual("external-result", Fixture.OutwardVerdict["models"][1])
			case "publication_snapshot": AssertEqual("external-publication", Fixture.OutwardPublished["lmstudio"]["models"][1])
			case "shared_result": AssertEqual("external-shared", Fixture.Native.Controller.Result("lmstudio")["models"][1])
		}
		AssertEqual("chosen", Fixture.Native.Cache["results"]["lmstudio"]["models"][1])
		AssertFalse(Fixture.Native.Writing)
		AssertFalse(Fixture.Native.WriteClaim is Map)
		AssertEqual(0, Fixture.Observed["post_source_calls"])
		AssertEqual(0, Fixture.Observed["post_entry_calls"])
		AssertEqual(0, Fixture.Observed["post_admit_calls"])
		AssertEqual(Fixture.Observed["critical_before"], Fixture.Observed["critical_after"])
		AssertEqual("saved", Fixture.Entries["lmstudio"]["Model"], "predicate isolation does not publish RAM")
	} finally Fixture.Dispose()
}
Test("local write admission: returned verdict mutation cannot change private retained models", _LSWA_OutwardSnapshotCannotRevokeClaim.Bind("returned_result"))
Test("local write admission: publication snapshot mutation cannot change private retained models", _LSWA_OutwardSnapshotCannotRevokeClaim.Bind("publication_snapshot"))
Test("local write admission: shared result mutation cannot change private retained models", _LSWA_OutwardSnapshotCannotRevokeClaim.Bind("shared_result"))

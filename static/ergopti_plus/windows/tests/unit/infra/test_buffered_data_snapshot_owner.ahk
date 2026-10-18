; static/ergopti_plus/windows/tests/unit/infra/test_buffered_data_snapshot_owner.ahk
#Requires AutoHotkey v2.0

/** Detached image facts never install a native container prototype on an Object. */
_B91S_ImageBaseIsData() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("keys", ["Escape"])
	Token := Owner.Capture(Source)
	Image := Owner._images[Token]
	AssertEqual(Object.Prototype, ObjGetBase(Image), "The image keeps ordinary Object inheritance.")
	AssertTrue(Image.HasOwnProp("OriginalBase"), "The source prototype is an explicit data fact.")
	AssertEqual(Map.Prototype, Image.OriginalBase)
	Nested := Image.Entries[1].Value
	AssertEqual(Object.Prototype, ObjGetBase(Nested))
	AssertTrue(Nested.HasOwnProp("OriginalBase"))
	AssertEqual(Array.Prototype, Nested.OriginalBase)
	AssertTrue(Owner.Matches(Source, Token))
	Source["keys"][1] := "Enter"
	AssertFalse(Owner.Matches(Source, Token), "Detached source facts still fence a real mutation.")
	Owner.Release(Token)
}
Test("windows91 snapshots: source prototype stays image data (snapshot-base-data)", _B91S_ImageBaseIsData)

; Handwritten data/source oracles. These never call action callbacks or output.
; The ordinary runner must include the actual owner, writer and TOML helpers.
_B91S_UnchangedComposite() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("keys", [Map("id", "left_alt"), Map("id", "right_ctrl")])
	OldImage := _TH_CloneData(Source)
	AssertFalse(_TH_SameValue(Source, OldImage), "the original scalar helper really refuses its fresh Map clone")
	AssertFalse(_TH_SameValue(Source["keys"], OldImage["keys"]), "the same actual prerequisite mismatch affects Arrays")
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token), "unchanged original containers match their private data image")
	Source["keys"][2]["id"] := "left_ctrl"
	AssertFalse(Owner.Matches(Source, Token), "a real nested source mutation must refuse")
	Source["keys"][2]["id"] := "right_ctrl"
	AssertTrue(Owner.Matches(Source, Token))
}

_B91S_MapMode() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map()
	Source.CaseSense := "On"
	Source["Alpha"] := "Value"
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token))
	Source.Clear()
	Source.CaseSense := "Off"
	Source["Alpha"] := "Value"
	AssertFalse(Owner.Matches(Source, Token), "Map matching mode is an original source fact")
	Source.Clear()
	Source.CaseSense := "On"
	Source["Alpha"] := "value"
	AssertFalse(Owner.Matches(Source, Token), "string value case must not coerce")
	Source["Alpha"] := "Value"
	AssertTrue(Owner.Matches(Source, Token))
}

_B91S_TypedKeys() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map(1, "integer slot", "1", "string slot")
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token))
	Source.Delete(1)
	Source[2] := "integer slot"
	AssertFalse(Owner.Matches(Source, Token), "equal counts cannot borrow a different typed key")
}

_B91S_ArrayPositions() {
	Owner := BufferedDataSnapshotOwner()
	Source := []
	Source.Length := 3
	Source[1] := "first"
	Source[3] := "third"
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token), "a genuine unset slot is retained as absent")
	Source[2] := ""
	AssertFalse(Owner.Matches(Source, Token), "an empty string cannot impersonate absence")
	Source.Delete(2)
	AssertTrue(Owner.Matches(Source, Token))
	Source[1] := "third"
	Source[3] := "first"
	AssertFalse(Owner.Matches(Source, Token), "Array order remains exact")
}

_B91S_TypedBooleans() {
	Owner := BufferedDataSnapshotOwner()
	Flag := TOML_Bool(false)
	Source := Map("symmetric", Flag)
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token))
	Flag.Value := true
	AssertFalse(Owner.Matches(Source, Token), "typed Boolean data is captured independently from the wrapper reference")
	Flag.Value := false
	AssertTrue(Owner.Matches(Source, Token))
	Source["symmetric"] := 0
	AssertFalse(Owner.Matches(Source, Token), "raw integer false cannot borrow the original typed Boolean")
}

_B91S_ActionFields() {
	Owner := BufferedDataSnapshotOwner()
	Generated := GestureEmitActionsData()["escape"]
	Entry := { Fn: _GestureMakeKeyEmitter(Generated.Key, Generated.Mods), Key: Generated.Key, Mods: Generated.Mods }
	Source := Map("escape", Entry)
	OldImage := _TH_CloneData(Source)
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token), "the genuine generated action fields and original Func identity match")
	AssertTrue(OldImage["escape"] = Entry, "the old clone actually aliases the mutable plain action entry")
	OriginalFn := Entry.Fn
	Entry.Fn := _GestureMakeKeyEmitter("Escape", [])
	AssertFalse(Owner.Matches(Source, Token), "another genuine emitter with equal key semantics is a different source function")
	Entry.Fn := OriginalFn
	Entry.Key := "Backspace"
	AssertFalse(Owner.Matches(Source, Token), "the aliased original action object's Key field is independently retained")
	Entry.Key := "Escape"
	Entry.Mods.Push("Ctrl")
	AssertFalse(Owner.Matches(Source, Token), "mutating the genuine action Mods Array refuses without invoking its Fn")
	Entry.Mods.Pop()
	AssertTrue(Owner.Matches(Source, Token))
}

_B91S_SourceIdentity() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("key", ["Escape"])
	Token := Owner.Capture(Source)
	AssertFalse(Owner.Matches(Map("key", ["Escape"]), Token), "equivalent caller data is not the original source")
	Source["key"] := ["Escape"]
	AssertFalse(Owner.Matches(Source, Token), "a copied nested source cannot borrow the old container identity")
	AssertFalse(Owner.Matches(Source, {}), "a caller token has no private image")
}

_B91S_CycleRefused() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map()
	Source["self"] := Source
	Refused := false
	try Owner.Capture(Source)
	catch Any {
		Refused := true
	}
	AssertTrue(Refused, "cyclic data is not a closed original source frame")
	AssertEqual(0, Owner._images.Count, "failed capture publishes no partial image")
	Source.Delete("self")
	AssertTrue(Owner.Matches(Source, Owner.Capture(Source)))
}

_B91S_AccessorRefused() {
	Owner := BufferedDataSnapshotOwner()
	Context := { Calls: 0 }
	Source := { Key: "Escape" }
	Token := Owner.Capture(Source)
	Source.DefineProp("Key", { Get: (*) => (Context.Calls += 1, "Escape") })
	AssertFalse(Owner.Matches(Source, Token), "a data property replaced by a getter must refuse")
	AssertEqual(0, Context.Calls, "original descriptor access cannot execute the replacement getter")
}

_B91S_EnumeratorRefused() {
	Owner := BufferedDataSnapshotOwner()
	Context := { Calls: 0 }
	Source := Map("key", "Escape")
	Token := Owner.Capture(Source)
	Source.DefineProp("__Enum", { Value: (*) => (Context.Calls += 1) })
	AssertFalse(Owner.Matches(Source, Token), "a named container override is not plain original data")
	AssertEqual(0, Context.Calls, "the intrinsic cannot call a substituted Map enumerator")
}

_B91S_RevokedHelper() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("key", "Escape")
	Token := Owner.Capture(Source)
	OriginalMatch := Owner.Matches.Bind(Owner)
	OriginalRelease := Owner.Release.Bind(Owner)
	Saved := BufferedDataSnapshotOwner.Prototype._Read
	Context := { Calls: 0 }
	try {
		BufferedDataSnapshotOwner.Prototype.DefineProp("_Read", { Call: (*) => (Context.Calls += 1, {}) })
		AssertFalse(OriginalMatch.Call(Source, Token), "the captured method refuses changed original helper exports")
		AssertEqual(0, Context.Calls, "no substituted recursive helper executes")
		AssertTrue(OriginalRelease.Call(Token), "captured image-only cleanup remains available after source revocation")
		AssertEqual(0, Owner._images.Count)
	} finally {
		BufferedDataSnapshotOwner.Prototype.DefineProp("_Read", { Call: Saved })
	}
}

_B91S_InstanceOverride() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("key", "Escape")
	Token := Owner.Capture(Source)
	OriginalMatch := Owner.Matches.Bind(Owner)
	Context := { Calls: 0 }
	try {
		Owner.DefineProp("_Read", { Get: (*) => (Context.Calls += 1, (*) => {}) })
		AssertFalse(OriginalMatch.Call(Source, Token), "an instance helper override cannot replace the retained implementation")
		AssertEqual(0, Context.Calls, "even helper lookup does not execute its substituted getter")
	} finally {
		Owner.DeleteProp("_Read")
	}
}

_B91S_ExplicitImageCleanup() {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("key", "Escape")
	Token := Owner.Capture(Source)
	AssertTrue(Owner.Matches(Source, Token))
	AssertTrue(Owner.Release(Token))
	AssertFalse(Owner.Matches(Source, Token), "release removes only the private data image")
	Owner.Capture(Source)
	AssertTrue(Owner.Clear())
	AssertEqual(0, Owner._images.Count, "closing data images claims no native or output retirement")
}

Test("windows91 snapshots: original scalar comparison refuses clones while unchanged composite source remains current", _B91S_UnchangedComposite)
Test("windows91 snapshots: Map mode and string case remain exact", _B91S_MapMode)
Test("windows91 snapshots: integer and string key slots remain distinct", _B91S_TypedKeys)
Test("windows91 snapshots: Array holes and order remain exact", _B91S_ArrayPositions)
Test("windows91 snapshots: real TOML Boolean mutation and integer substitution refuse", _B91S_TypedBooleans)
Test("windows91 snapshots: genuine generated action Fn Key and Mods fields are detached observations", _B91S_ActionFields)
Test("windows91 snapshots: equivalent caller and nested replacement cannot borrow original source identity", _B91S_SourceIdentity)
Test("windows91 snapshots: cyclic source publishes no image", _B91S_CycleRefused)
Test("windows91 snapshots: substituted data getter refuses without execution", _B91S_AccessorRefused)
Test("windows91 snapshots: substituted container enumerator refuses without execution", _B91S_EnumeratorRefused)
Test("windows91 snapshots: original recursive helper revocation refuses and retains exact image cleanup", _B91S_RevokedHelper)
Test("windows91 snapshots: own helper getter cannot execute at terminal currentness", _B91S_InstanceOverride)
Test("windows91 snapshots: explicit image release carries no native lifecycle claim", _B91S_ExplicitImageCleanup)

; Use genuine AHK method Call descriptors, as the original config/native
; owner regression does; the original function object identity stays equal.
_B91S_OwnHelperCall(Name) {
	Owner := BufferedDataSnapshotOwner()
	Source := Map("key", ["Escape"])
	Token := Owner.Capture(Source)
	OriginalMatch := Owner.Matches.Bind(Owner)
	Method := Object.Prototype.GetOwnPropDesc.Call(BufferedDataSnapshotOwner.Prototype, Name).Call
	Context := { Calls: 0 }
	try {
		Method.DefineProp("Call", { Call: (*) => (Context.Calls += 1, true) })
		AssertFalse(OriginalMatch.Call(Source, Token), "same-function own Call cannot enter the captured source helper")
		AssertEqual(0, Context.Calls, "original Current and recursive method overrides refuse before invocation")
	} finally {
		Method.DeleteProp("Call")
	}
	AssertTrue(OriginalMatch.Call(Source, Token))
}

_B91S_OwnCallableLeaf() {
	Owner := BufferedDataSnapshotOwner()
	Fn := _GestureMakeKeyEmitter("Escape", [])
	Source := { Fn: Fn, Key: "Escape", Mods: [] }
	Token := Owner.Capture(Source)
	Context := { Calls: 0 }
	try {
		Fn.DefineProp("Call", { Call: (*) => (Context.Calls += 1, true) })
		AssertFalse(Owner.Matches(Source, Token), "the original generated Func identity cannot hide an own Call replacement")
		AssertEqual(0, Context.Calls, "function leaf data is never invoked")
	} finally {
		Fn.DeleteProp("Call")
	}
	AssertTrue(Owner.Matches(Source, Token))
}

Test("windows91 snapshots: original Current own Call replacement refuses without invocation", _B91S_OwnHelperCall.Bind("Current"))
Test("windows91 snapshots: original recursive helper own Call replacement refuses without invocation", _B91S_OwnHelperCall.Bind("_Read"))
Test("windows91 snapshots: original generated function own Call replacement refuses without invocation", _B91S_OwnCallableLeaf)

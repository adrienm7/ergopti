; platform/remap/tap_hold_migration.ahk

; ==============================================================================
; MODULE: Tap-Hold File Migration (Windows)
; DESCRIPTION:
; Versions a user's tap_hold.toml. It reads ``[_meta] schema_version``, replays
; the steps of _shared/tap_hold/migrations.toml on the typed document and stamps
; the result. The Windows counterpart of _shared/lua/tap_hold/migrate.lua and of
; linux/platform/remap/tap_hold_writer.lua's migrate_file; the corpus
; _shared/tests/corpus/tap_hold_migrations pins the semantics of all of them.
;
; FEATURES & RATIONALE:
; 1. Replaces the permanent ``[tap_hold] explicit_delays = true`` marker. The
;    cleanup of the per-key delays earlier builds shipped was decided again on
;    every read and write by looking for that marker; it is now one step, run
;    once, and the version says it ran.
; 2. One view for every owner. The boot migrates the file on disk, the loader
;    reads a file the boot has not touched (a folder the wizard inspects) as the
;    migration leaves it, and every writer migrates before it applies its own
;    change, so no path reads an old file differently.
; 3. The edit keeps the file. The semantic document owner removes the retired
;    lines and adds the stamp; comments, order and formatting survive, and a
;    dotted or inline spelling is edited where it is, not refused.
; 4. Fail fast. A registry defect throws. A newer file or an unusable stamp is
;    never rewritten: the boot refuses every later write to it for the session.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================
; ===========================
; ======= 1/ Registry =======
; ===========================
; ===========================

; Validates a parsed migrations.toml and returns its detached, ordered form.
; @param Document {Map} The typed registry document.
; @returns {Map} "current", "unstamped" and "steps" (each Map "from", "to", "ops").
; Throws on the first defect: a build that guesses a version rewrites a user's file wrongly.
TapHoldMigrationParseRegistry(Document) {
	Head := Document.Get("registry", 0)
	if !(Head is Map) || !_TapHoldMigrationIsVersion(Head.Get("current_version", ""))
			|| !_TapHoldMigrationIsVersion(Head.Get("unstamped_version", ""))
			|| Head["current_version"] <= Head["unstamped_version"]
		throw Error("tap-hold migration registry: [registry] needs current_version above unstamped_version")
	Current := Integer(Head["current_version"])
	Unstamped := Integer(Head["unstamped_version"])
	Named := Map()
	Declared := Document.Get("steps", Map())
	if !(Declared is Map)
		throw Error("tap-hold migration registry: [steps] is not a table")
	for Name, Step in Declared {
		Where := "tap-hold migration registry: [steps." . Name . "]"
		if !(Step is Map) || !_TapHoldMigrationIsVersion(Step.Get("from", ""))
				|| Step.Get("to", "") != Step["from"] + 1
				|| !(Name == "v" . Integer(Step["from"]) . "_to_v" . Integer(Step["to"]))
			throw Error(Where . " must be named v<from>_to_v<to> with to = from + 1")
		Ops := Step.Get("ops", "")
		if !(Ops is Array)
			throw Error(Where . " needs an ops array")
		for Index, Op in Ops
			_TapHoldMigrationValidateOp(Op, Where . " op " . Index)
		Named[Integer(Step["from"])] := Map("from", Integer(Step["from"]), "to", Integer(Step["to"]), "ops", Ops)
	}
	Steps := []
	Expected := Unstamped
	while Named.Has(Expected) {
		Steps.Push(Named[Expected])
		Expected += 1
	}
	if Expected != Current || Steps.Length != Named.Count
		throw Error("tap-hold migration registry: the steps do not chain v" . Unstamped . " to v" . Current)
	return Map("current", Current, "unstamped", Unstamped, "steps", Steps)
}

; A non-negative integral number; a TOML 1.0 counts as 1, as on Linux.
_TapHoldMigrationIsVersion(Value) {
	return ((Value is Integer) || (Value is Float)) && Value >= 0 && Value == Floor(Value)
}

; Throws unless Op is a member of the closed set, well formed.
_TapHoldMigrationValidateOp(Op, Where) {
	if !(Op is Map) || !(Op.Get("op", "") == "drop_retired_values" || Op.Get("op", "") == "delete")
		throw Error(Where . " names no known op")
	if !_ConfigMigrateIsSectionPath(Op.Get("section", "")) || !_ConfigMigrateIsBareKey(Op.Get("key", ""))
		throw Error(Where . " needs a section path and a key")
	if Op["op"] == "delete"
		return
	if !_ConfigMigrateIsSectionPath(Op.Get("retired", ""))
		throw Error(Where . " needs the name of its retired table")
	if Op.Has("unless") {
		Unless := Op["unless"]
		if !(Unless is Map) || !_ConfigMigrateIsSectionPath(Unless.Get("section", ""))
				|| !_ConfigMigrateIsBareKey(Unless.Get("key", "")) || !Unless.Has("value")
			throw Error(Where . " has an invalid unless condition")
	}
}

; The shipped registry, read and validated once per process. Throws when broken.
; @returns {Map} See TapHoldMigrationParseRegistry.
TapHoldMigrationRegistry() {
	global _SharedDir
	static Registry := 0
	if !(Registry is Map) {
		Path := _SharedDir . "\tap_hold\migrations.toml"
		Source := FSReadUtf8Exact(Path)
		if !(Source is String)
			throw Error("Cannot read the tap-hold migration registry '" . Path . "'.")
		Registry := TapHoldMigrationParseRegistry(TOML_ParseDocument(Source))
	}
	return Registry
}





; ===============================
; ===============================
; ======= 2/ The document =======
; ===============================
; ===============================

; The table at a dotted path; 0 when a segment is absent or is not a table.
_TapHoldMigrationTableAt(Document, Path) {
	Node := Document
	for Segment in StrSplit(Path, ".") {
		if !(Node is Map) || !Node.Has(Segment)
			return 0
		Node := Node[Segment]
	}
	return (Node is Map) ? Node : 0
}

; Removes the table at a dotted path when it is empty, walking up.
_TapHoldMigrationPrune(Document, Path) {
	Segments := StrSplit(Path, ".")
	while Segments.Length {
		Name := Segments.Pop()
		Parent := Document
		for Segment in Segments
			Parent := Parent[Segment]
		Node := Parent.Get(Name, 0)
		if !(Node is Map) || Node.Count
			return
		Parent.Delete(Name)
	}
}

; The version a document carries, the registry's unstamped one when it has none.
; @param Detail {VarRef} Receives why the stamp is unusable.
; @returns {Integer|String} The version, or "" when the stamp is unusable.
_TapHoldMigrationVersion(Document, Registry, &Detail) {
	Detail := ""
	if !Document.Has("_meta")
		return Registry["unstamped"]
	if !(Document["_meta"] is Map) {
		Detail := "[_meta] is not a table"
		return ""
	}
	if !Document["_meta"].Has("schema_version")
		return Registry["unstamped"]
	Stamp := Document["_meta"]["schema_version"]
	if !_TapHoldMigrationIsVersion(Stamp) {
		Detail := "[_meta] schema_version is not a non-negative integer"
		return ""
	}
	return Integer(Stamp)
}

; Applies one op to the document, recording each removed leaf.
_TapHoldMigrationApplyOp(Document, Op, Retired, Removed) {
	if Op["op"] == "delete" {
		Section := _TapHoldMigrationTableAt(Document, Op["section"])
		if (Section is Map) && Section.Has(Op["key"]) {
			Section.Delete(Op["key"])
			Removed.Push({ Section: Op["section"], Key: Op["key"] })
			_TapHoldMigrationPrune(Document, Op["section"])
		}
		return
	}
	if Op.Has("unless") {
		Guard := _TapHoldMigrationTableAt(Document, Op["unless"]["section"])
		if (Guard is Map) && Guard.Has(Op["unless"]["key"])
				&& TOML_SameValue(Guard[Op["unless"]["key"]], Op["unless"]["value"])
			return
	}
	Section := _TapHoldMigrationTableAt(Document, Op["section"])
	if !(Section is Map)
		return
	for KeyId, Seconds in Retired {
		Entry := Section.Get(KeyId, 0)
		if !(Entry is Map) || !Entry.Has(Op["key"])
			continue
		if (_TOML_ValueKind(Entry[Op["key"]]) != "number") || !(_ConfigTomlNativeValue(Entry[Op["key"]]) == Seconds)
			continue
		Entry.Delete(Op["key"])
		Removed.Push({ Section: Op["section"] . "." . KeyId, Key: Op["key"] })
		if !Entry.Count
			Section.Delete(KeyId)
	}
	_TapHoldMigrationPrune(Document, Op["section"])
}

; Migrates a typed document in place, then stamps it. A current, newer or
; invalid document is not edited.
; @param Document {Map} The typed user document, edited in place.
; @param Registry {Map} See TapHoldMigrationParseRegistry.
; @param Defaults {String} The shared defaults.toml holding the retired delays,
;        read only when the document does migrate.
; @returns {Map} "outcome" ("migrated", "current", "newer" or "invalid"), "version"
;          (the version the file carried, "" when unusable), "detail" (why it is
;          unusable), and for "migrated": "rows" and "drops", the same edit for
;          TOML_BuildConfigDocumentCandidate.
TapHoldMigrationApply(Document, Registry, Defaults) {
	Version := _TapHoldMigrationVersion(Document, Registry, &Detail)
	Plan := Map("version", Version, "detail", Detail)
	if (Version == "") {
		Plan["outcome"] := "invalid"
		return Plan
	}
	if (Version > Registry["current"] || Version == Registry["current"]) {
		Plan["outcome"] := (Version > Registry["current"]) ? "newer" : "current"
		return Plan
	}
	Retired := TapHoldRetiredDelays(Defaults)
	Removed := []
	for Step in Registry["steps"] {
		if (Step["from"] < Version)
			continue
		for Op in Step["ops"]
			_TapHoldMigrationApplyOp(Document, Op, Retired, Removed)
	}
	; A leaf whose table went with it is named by the table, so its header goes too.
	Rows := []
	Drops := Map()
	Drops.CaseSense := "On"
	for Leaf in Removed {
		Topmost := _TapHoldMigrationTopmostGone(Document, Leaf.Section)
		if (Topmost != "")
			Drops[Topmost] := true
		else
			Rows.Push({ Section: Leaf.Section, Key: Leaf.Key, Delete: 1 })
	}
	if !Document.Has("_meta")
		Document["_meta"] := Map()
	Document["_meta"]["schema_version"] := Registry["current"]
	Rows.Push({ Section: "_meta", Key: "schema_version", Value: Registry["current"] })
	DropList := []
	for Name in Drops
		DropList.Push(Name)
	Plan["outcome"] := "migrated"
	Plan["rows"] := Rows
	Plan["drops"] := DropList
	return Plan
}

; The shortest prefix of a dotted path that no longer exists, "" when all do.
_TapHoldMigrationTopmostGone(Document, Path) {
	Node := Document
	Walked := ""
	for Segment in StrSplit(Path, ".") {
		Walked := (Walked == "") ? Segment : Walked . "." . Segment
		if !Node.Has(Segment)
			return Walked
		Node := Node[Segment]
	}
	return ""
}





; =======================================
; =======================================
; ======= 3/ Readers and writers ========
; =======================================
; =======================================

; Reads a typed document as the migration leaves it, without touching the disk,
; so a file the boot has not migrated is never read differently from one it has.
; A newer file or an unusable stamp is read as it is: nothing is guessed about it.
; @param Document {Map} The typed document, edited in place.
; @param Defaults {String} The shared defaults.toml holding the retired delays.
TapHoldMigrationReadAsCurrent(Document, Defaults) {
	try TapHoldMigrationApply(Document, TapHoldMigrationRegistry(), Defaults)
	catch as Err
		try LoggerError("TapHoldMigration", "Cannot read the tap-hold file as its current version: {1}.", Err.Message)
}

; Renders the bytes that migrate Source, leaving every other byte in place.
; @param Source {String} The file's exact content.
; @param Registry {Map} See TapHoldMigrationParseRegistry.
; @param Defaults {String} The shared defaults.toml holding the retired delays.
; @returns {Map} The TapHoldMigrationApply plan, with "candidate" for "migrated".
; Throws when Source is malformed or the candidate does not read back as the model.
TapHoldMigrationPlanSource(Source, Registry, Defaults) {
	Document := TOML_ParseDocument(Source)
	Plan := TapHoldMigrationApply(Document, Registry, Defaults)
	if (Plan["outcome"] != "migrated")
		return Plan
	Built := TOML_BuildConfigDocumentCandidate(Source, Plan["rows"], Plan["drops"])
	if !TOML_SameValue(TOML_ParseDocument(Built["content"]), Document)
		throw Error("the migrated tap-hold file would not read back as the migrated document")
	Plan["candidate"] := Built["content"]
	return Plan
}

; What a writer starts from: Source at the current version. A writer never
; rewrites what it cannot version.
; @param Source {String} The file's exact content.
; @param Defaults {String} The shared defaults.toml holding the retired delays.
; @returns {String} The migrated content, or Source itself when already current.
; Throws for a newer file or an unusable stamp.
TapHoldMigrateSource(Source, Defaults) {
	Plan := TapHoldMigrationPlanSource(Source, TapHoldMigrationRegistry(), Defaults)
	switch Plan["outcome"] {
		case "migrated":
			return Plan["candidate"]
		case "current":
			return Source
		case "newer":
			throw Error("the file was saved by a newer build (schema v" . Plan["version"] . "); update before changing it")
	}
	throw Error(Plan["detail"])
}

; Why a whole-file rewrite of Path must not run, "" when it may. Everything such
; a rewrite serializes comes from memory, so a file that cannot be read back or
; versioned at this moment would lose what this build did not understand.
; @param Path {String} The tap_hold.toml.
; @returns {String}
TapHoldMigrationWriteRefusal(Path) {
	Refusal := TOML_WriteRefusal(Path)
	if (Refusal != "")
		return Refusal
	if !FileExist(Path)
		return ""
	Source := FSReadUtf8Exact(Path)
	if !(Source is String)
		return "the file is not exact UTF-8"
	try Document := TOML_ParseDocument(Source)
	catch as Err
		return "the file is not valid TOML: " . Err.Message
	Registry := TapHoldMigrationRegistry()
	Version := _TapHoldMigrationVersion(Document, Registry, &Detail)
	if (Version == "")
		return Detail
	if (Version > Registry["current"])
		return "the file was saved by a newer build (schema v" . Version . ")"
	return ""
}





; =======================
; =======================
; ======= 4/ Boot =======
; =======================
; =======================

; Migrates the user's file on disk to the current version, once: a verified
; byte-exact backup first, then one atomic publication. A current or absent file
; is not written. A file this build cannot version (newer, unusable stamp,
; malformed, or whose edit cannot be verified) is left untouched, ERROR logged,
; and refuses every later write for the session.
; @param Path {String} The user's tap_hold.toml.
; @param Defaults {String} The shared defaults.toml holding the retired delays.
; @param Stamp {String} Test seam: the backup's time stamp.
; @param BackupFn {Func} Test seam: BackupFn(Path, Content) -> 1.
; @param PublishFn {Func} Test seam: PublishFn(Path, Candidate, Source) -> "".
; @returns {Map} "status" ("absent", "current", "migrated", "newer", "invalid" or
;          "failed"), "from", "to", "backup" and "detail".
TapHoldMigrateFile(Path, Defaults, Stamp := "", BackupFn := 0, PublishFn := 0) {
	Result := Map("status", "failed", "from", "", "to", "", "backup", "", "detail", "")
	try LoggerStart("TapHoldMigration", "Checking the tap-hold file version of '{1}'…", Path)

	Refuse(Status, Detail) {
		Result["status"] := Status
		Result["detail"] := Detail
		TOML_RefuseWrites(Path, Detail)
		try LoggerError("TapHoldMigration", "'{1}' cannot be migrated ({2}): {3}. It is left untouched and this session will not write it.",
			Path, Status, Detail)
		return Result
	}

	try Registry := TapHoldMigrationRegistry()
	catch as Err
		return Refuse("failed", Err.Message)
	Result["to"] := Registry["current"]
	if !FileExist(Path) {
		Result["status"] := "absent"
		try LoggerSuccess("TapHoldMigration", "No tap-hold file at '{1}' yet; nothing to migrate.", Path)
		return Result
	}
	Owner := _ConfigWriteLeaseTryAcquire(Path, "tap-hold-migration")
	if !(Owner is Object)
		return Refuse("failed", "another configuration transaction owns the file")
	try {
		Source := FSReadUtf8Exact(Path)
		if !(Source is String)
			return Refuse("failed", "the file is not exact UTF-8, so it cannot be backed up byte for byte")
		try Plan := TapHoldMigrationPlanSource(Source, Registry, Defaults)
		catch as Err
			return Refuse("failed", Err.Message)
		Result["from"] := Plan["version"]
		switch Plan["outcome"] {
			case "current":
				Result["status"] := "current"
				try LoggerSuccess("TapHoldMigration", "'{1}' is at schema v{2}; nothing to migrate.", Path, Registry["current"])
				return Result
			case "newer":
				return Refuse("newer", "the file declares schema v" . Plan["version"]
					. ", newer than this build's v" . Registry["current"])
			case "invalid":
				return Refuse("invalid", Plan["detail"])
		}
		BackupPath := ConfigMigrateBackupPath(Path, Registry["current"],
			Stamp != "" ? Stamp : FormatTime(A_Now, "yyyyMMdd-HHmmss"))
		Result["backup"] := BackupPath
		Written := HasMethod(BackupFn, "Call") ? BackupFn.Call(BackupPath, Source)
			: FSWriteCreateDurable(BackupPath, Source)
		if !((Written is Integer) && Written == 1) || !FSUtf8ExactMatches(BackupPath, Source)
			return Refuse("failed", "the backup '" . BackupPath . "' could not be written and verified")
		Admission := () => _ConfigWriteLeaseOwns(Owner, Path)
		Published := HasMethod(PublishFn, "Call") ? PublishFn.Call(Path, Plan["candidate"], Source)
			: _ConfigMigratePublish(Path, Plan["candidate"], Source, Admission)
		if (Published != "")
			return Refuse("failed", "publication failed: " . Published)
	} finally {
		_ConfigWriteLeaseRelease(Owner)
	}
	Result["status"] := "migrated"
	try LoggerSuccess("TapHoldMigration", "Migrated '{1}' from schema v{2} to v{3}; backup at '{4}'.",
		Path, Result["from"], Registry["current"], Result["backup"])
	return Result
}

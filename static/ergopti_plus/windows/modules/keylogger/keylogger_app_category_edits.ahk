; modules/keylogger/keylogger_app_category_edits.ahk

; ==============================================================================
; MODULE: App Category Edit Transactions
; DESCRIPTION:
; Captures the native store before dialogs and publishes only witnessed sources.
; Full window checks may perform COM outside Critical; final admission is RAM-only.
; ==============================================================================

_KL_AppCat_ReadImage(Path) {
	Present := FSStrictExists(Path)
	Content := Present ? FSReadUtf8Exact(Path) : ""
	if !(Content is String)
		throw Error("The app category source is not readable as exact UTF-8.")
	Model := _KL_AppCat_DecodeStore(Present ? Content : "{}", Path)
	Model["present"] := Present
	Model["source"] := Content
	return Model
}

_KL_AppCat_ImageCurrent(Model) {
	if FSStrictExists(Model["path"]) != Model["present"]
		return false
	if !Model["present"]
		return true
	Observed := FSReadUtf8Exact(Model["path"])
	return Observed is String && Observed == Model["source"]
}

_KL_AppCat_WriterCurrent(Owner) {
	return KLAppCat.write_owner == Owner && KLAppCat.file_path == Owner["path"]
		&& KLAppCat.categories == Owner["categories"] && KLAppCat.store_model == Owner["model"]
}

_KL_AppCat_CallGuard(Guard) {
	if Guard is Integer && Guard == 0
		return true
	Accepted := Guard.Call()
	return Accepted is Integer && Accepted == 1
}

_KL_AppCat_WriteAdmission(Owner, AdmissionFn) {
	return _KL_AppCat_WriterCurrent(Owner) && _KL_AppCat_CallGuard(AdmissionFn)
		&& _KL_AppCat_WriterCurrent(Owner)
}

; Source reads and callback checks are witnesses, not an OS compare-and-swap
; against arbitrary foreign writers. Only the final RAM check and rename share
; the adapter's minimal native publication span.
_KL_AppCat_WriteOwned(Owner, Content, Source := unset, FullCurrentFn := 0, AdmissionFn := 0) {
	if !IsSet(Source) {
		Source := _KL_AppCat_ReadImage(Owner["path"])
		Model := Owner["model"]
		if Model is Map && Model["path"] == Owner["path"] {
			if !Source["present"] || !(_KL_AppCat_JsonSource(Source["source"]) == _KL_AppCat_JsonSource(Model["source"]))
				return false
		} else if Source["versioned"] {
			throw Error("Versioned app categories require their admitted store metadata.")
		}
	}
	if !_KL_AppCat_WriterCurrent(Owner) || !_KL_AppCat_CallGuard(FullCurrentFn)
		|| !_KL_AppCat_WriterCurrent(Owner) || !_KL_AppCat_ImageCurrent(Source)
		|| !_KL_AppCat_WriteAdmission(Owner, AdmissionFn)
		return false
	Stage := Owner["path"] . "." . A_ScriptHwnd . "-" . ObjPtr(Owner) . ".tmp"
	Created := false, Published := false
	try {
		Created := FSWriteCreateDurable(Stage, Content)
		if !(Created is Integer) || Created != 1
			return false
		if !FSUtf8ExactMatches(Stage, Content)
			throw Error("The app category stage bytes did not verify.")
		if !_KL_AppCat_CallGuard(FullCurrentFn) || !_KL_AppCat_WriterCurrent(Owner)
			|| !_KL_AppCat_ImageCurrent(Source)
			return false
		Admission := _KL_AppCat_WriteAdmission.Bind(Owner, AdmissionFn)
		Accepted := Source["present"]
			? FSConfigAtomicMoveReplace(Stage, Owner["path"], , Admission)
			: FSConfigAtomicMoveCreate(Stage, Owner["path"], Admission)
		Published := Accepted is Integer && Accepted == 1
		return Published
	} finally {
		if Created && !Published
			FSDeleteStrict(Stage)
	}
}

_KL_AppCat_NativeRoot(ExpectedMetricsRoot) {
	if !(ExpectedMetricsRoot is String) || ExpectedMetricsRoot == "" || KLAppCat.file_path == ""
		throw Error("Category editing requires its initialized native metrics store.")
	SplitPath(KLAppCat.file_path, &Name, &Directory)
	Root := FSResolveDirectoryPath(ExpectedMetricsRoot)
	if !(Name == KLAppCatConst.FILE_NAME) || !(Root = FSResolveDirectoryPath(Directory))
		throw Error("The category editor does not own this metrics root.")
	return Root
}

_KL_AppCat_SnapshotCurrent(Snapshot, Owner := 0) {
	return KLAppCat.file_path == Snapshot["path"]
		&& KLAppCat.categories == Snapshot["resident_categories"]
		&& KLAppCat.write_owner == Owner
}

/**
 * Captures store authority before a picker without initializing another store.
 * @param ExpectedMetricsRoot {String} Root retained by the native dashboard entry.
 * @return {Map|false} Opaque store snapshot, or false on refusal.
 */
KL_AppCat_EditorStoreSnapshot(ExpectedMetricsRoot) {
	try {
		Path := KLAppCat.file_path, Categories := KLAppCat.categories
		if IsObject(KLAppCat.write_owner)
			return false
		Root := _KL_AppCat_NativeRoot(ExpectedMetricsRoot)
		Model := _KL_AppCat_ReadImage(Path)
		Snapshot := Map("path", Path, "root", Root, "store", Model,
			"resident_categories", Categories)
		if !_KL_AppCat_SnapshotCurrent(Snapshot)
			return false
		return Snapshot
	} catch as Err {
		try LoggerError("KLAppCat", "Category editor snapshot refused: {1}.", Err.Message)
		return false
	}
}

/**
 * Reads current edit defaults from the canonical store without discovering an app.
 * @param App {String} Process name retained by the native request.
 * @param ExpectedMetricsRoot {String} Root retained by the native dashboard entry.
 * @return {Map|false} Snapshot exposing app/current_type/current_score.
 */
KL_AppCat_EditorSnapshot(App, ExpectedMetricsRoot) {
	if !(App is String) || App == ""
		return false
	Snapshot := KL_AppCat_EditorStoreSnapshot(ExpectedMetricsRoot)
	if !(Snapshot is Map)
		return false
	Key := StrLower(App)
	Value := Snapshot["store"]["categories"].Get(Key, KLAppCatConst.DEFAULTS.Get(Key, "unknown"))
	Snapshot["app"] := App
	Snapshot["key"] := Key
	Snapshot["current_type"] := _KL_AppCat_RecordLabel(Value)
	Snapshot["current_score"] := Value is Map ? Value["score"] : 0
	return Snapshot
}

/**
 * Commits one explicit UI override in the existing versioned category store.
 * @param Snapshot {Map} Retained snapshot from EditorSnapshot.
 * @param Category {String} Nonblank category text.
 * @param Score {Number} Finite score in the shared UI interval [-2,2].
 * @param FullCurrentFn {Func|0} Reentrant full page check; paired with AdmissionFn.
 * @param AdmissionFn {Func|0} Pure RAM admission at the final native publication.
 * @return {Boolean} True only after durable publication; 0/0 is explicit headless use.
 */
KL_AppCat_CommitEdit(Snapshot, Category, Score, FullCurrentFn := 0, AdmissionFn := 0) {
	Owner := 0
	try {
		Headless := FullCurrentFn is Integer && FullCurrentFn == 0
			&& AdmissionFn is Integer && AdmissionFn == 0
		if !Headless && (!HasMethod(FullCurrentFn, "Call") || !HasMethod(AdmissionFn, "Call"))
			return false
		if !(Snapshot is Map) || !Snapshot.Has("app") || Snapshot["app"] == ""
			|| !_KL_AppCat_LabelValid(Category) || !_KL_AppCat_ScoreValid(Score)
			|| !_KL_AppCat_SnapshotCurrent(Snapshot)
			return false
		if !(_KL_AppCat_NativeRoot(Snapshot["root"]) = Snapshot["root"])
			return false
		if !_KL_AppCat_CallGuard(FullCurrentFn) || !_KL_AppCat_SnapshotCurrent(Snapshot)
			return false
		Owner := _KL_AppCat_AcquireWrite()
		if !IsObject(Owner) || !_KL_AppCat_SnapshotCurrent(Snapshot, Owner)
			return false
		Model := Snapshot["store"]
		Candidate := Map()
		for Key, Value in Model["categories"]
			Candidate[Key] := Value
		; An entry deleted from the fresh file is not a new discovery. Preserve
		; only Get-owned entries absent from the previously admitted file too.
		for Key, Value in Owner["snapshot"]
			if !Candidate.Has(Key) && _KL_AppCat_IsDiscovery(Key, Value, Owner["model"])
				Candidate[Key] := Value
		Key := Snapshot["key"]
		Existing := Candidate.Get(Key, "")
		Record := Existing is Map ? _KL_AppCat_RecordWithLabel(Existing, Category) : Map("type", Category)
		Record["score"] := Score
		Candidate[Key] := Record
		Content := _KL_AppCat_RenderStore(Candidate, Model, true)
		NextModel := _KL_AppCat_DecodeStore(Content, Owner["path"])
		Canonical := Map()
		for StoredKey, Value in KLAppCatConst.DEFAULTS
			Canonical[StoredKey] := Value
		for StoredKey, Value in NextModel["categories"]
			Canonical[StoredKey] := Value
		if !_KL_AppCat_WriteOwned(Owner, Content, Model, FullCurrentFn, AdmissionFn)
			return false
		PreviousCritical := Critical("On")
		try {
			if !_KL_AppCat_WriterCurrent(Owner)
				return false
			LateDiscoveries := Map()
			for StoredKey, Value in KLAppCat.categories
				if !Owner["snapshot"].Has(StoredKey) && _KL_AppCat_IsDiscovery(StoredKey, Value, NextModel)
					LateDiscoveries[StoredKey] := Value
			; Rebuild the same admitted Map from fresh canonical values. Old
			; records and legacy strings removed externally cannot return later.
			KLAppCat.categories.Clear()
			for StoredKey, Value in Canonical
				KLAppCat.categories[StoredKey] := Value
			for StoredKey, Value in LateDiscoveries
				KLAppCat.categories[StoredKey] := Value
			KLAppCat.store_model := NextModel
			KLAppCat.dirty := LateDiscoveries.Count > 0
		} finally Critical(PreviousCritical)
		if KLAppCat.dirty
			_KL_AppCat_ScheduleDeferredSave()
		return true
	} catch as Err {
		try LoggerError("KLAppCat", "Category edit did not commit: {1}.", Err.Message)
		return false
	} finally {
		if IsObject(Owner)
			_KL_AppCat_ReleaseWrite(Owner)
	}
}

/**
 * Reads explicit overrides for actual manifest keys in a detached worker.
 * @param MetricsRoot {String} Actual native projection root; no resident Init needed.
 * @param Apps {Array} Exact application keys emitted by this manifest.
 * @return {Map} Explicit type/score overrides; legacy classifications are omitted.
 * @throws {Error} An unreadable or invalid existing store never becomes an empty map.
 */
KL_AppCat_ProjectAt(MetricsRoot, Apps) {
	Root := FSResolveDirectoryPath(MetricsRoot)
	Model := _KL_AppCat_ReadImage(RTrim(Root, "\") . "\" . KLAppCatConst.FILE_NAME)
	return _KL_AppCat_ProjectStore(Model, Apps)
}

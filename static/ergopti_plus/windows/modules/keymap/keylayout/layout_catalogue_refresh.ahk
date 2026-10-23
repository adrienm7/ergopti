; modules/keymap/keylayout/layout_catalogue_refresh.ahk

; ==============================================================================
; MODULE: Layout Catalogue Refresh Ownership
; DESCRIPTION:
; Coalesces refreshes of one canonical Windows directory until its response,
; index and ETag have finished publishing. Callback delivery follows retirement
; so a reentrant refresh owns a new transfer without touching the old partial.
; ==============================================================================

#Requires AutoHotkey v2.0

global _LayoutCatalogueRefreshes := Map()
global _LayoutCatalogueRefreshSequence := 0

; Only RAM admission is atomic; path resolution, transport and publication stay
; outside Critical. Existing-directory resolution also unifies long/short names.
_LayoutCatalogueAcquireRefresh(LocalDir, OnDone) {
	global _LayoutCatalogueRefreshes, _LayoutCatalogueRefreshSequence
	Key := StrLower(LocalDir)
	PreviousCritical := Critical("On")
	try {
		if _LayoutCatalogueRefreshes.Has(Key) {
			_LayoutCatalogueRefreshes[Key].Callbacks.Push(OnDone)
			return 0
		}
		Owner := {Key: Key, Callbacks: [OnDone], Sequence: ++_LayoutCatalogueRefreshSequence}
		_LayoutCatalogueRefreshes[Key] := Owner
		return Owner
	} finally Critical(PreviousCritical)
}

_LayoutCatalogueRefreshCurrent(Owner) {
	global _LayoutCatalogueRefreshes
	return _LayoutCatalogueRefreshes.Has(Owner.Key) && _LayoutCatalogueRefreshes[Owner.Key] == Owner
}

; Detach the exact owner before logging or notifying anybody. A callback may
; start another refresh, and one failed subscriber must not strand the others.
_LayoutCatalogueCompleteRefresh(Owner, Outcome) {
	global _LayoutCatalogueRefreshes
	PreviousCritical := Critical("On")
	try {
		if !_LayoutCatalogueRefreshCurrent(Owner)
			return false
		_LayoutCatalogueRefreshes.Delete(Owner.Key)
		Callbacks := Owner.Callbacks
		Owner.Callbacks := []
	} finally Critical(PreviousCritical)
	_LayoutCatalogueFinishRefresh(Outcome, _LayoutCatalogueNotifyRefresh.Bind(Callbacks))
	return true
}

_LayoutCatalogueNotifyRefresh(Callbacks, Outcome) {
	Primary := 0
	for Callback in Callbacks {
		try Callback.Call(Outcome)
		catch as Err {
			if !IsObject(Primary)
				Primary := Err
		}
	}
	Callbacks.Length := 0
	if IsObject(Primary)
		throw Primary
}

/**
 * Refreshes the catalogue with a conditional request for the registry index.
 * Concurrent requests for the same canonical directory share its in-flight outcome.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @param {Func} OnDone - OnDone(Outcome), called exactly once (LayoutCatalogue_ResolveIndex).
 * @param {Map} Transport - See LayoutRegistry_Request; injectable for tests.
 * @param Bundled - Index shipped with the driver (0 for none); read from the
 *   shipped registry folder when omitted.
 * @param {Boolean} LocalSource - Use the checkout registry; defaults to the updater's source mode.
 */
LayoutCatalogue_Refresh(LocalDir, OnDone, Transport := 0, Bundled := unset, LocalSource := unset) {
	global LAYOUT_REGISTRY_PARTIAL_SUFFIX, LAYOUT_REGISTRY_USER_AGENT
	global LAYOUT_CATALOGUE_SOURCE_BUNDLED, LAYOUT_CATALOGUE_SOURCE_NONE, LAYOUT_CATALOGUE_ERROR_INVALID_INDEX
	Settings := LayoutRegistry_Settings()
	if !IsSet(Bundled)
		Bundled := LayoutCatalogue_BundledIndex()
	if !IsSet(LocalSource)
		LocalSource := Updater_IsLocalSource()
	if LocalSource {
		LoggerStart("LayoutCatalogue", "Refreshing the layout catalogue…")
		Problem := LayoutCatalogue_IndexProblem(Bundled)
		_LayoutCatalogueFinishRefresh(Map("index", Problem == "" ? Bundled : 0,
			"source", Problem == "" ? LAYOUT_CATALOGUE_SOURCE_BUNDLED : LAYOUT_CATALOGUE_SOURCE_NONE,
			"store", false, "etag", "", "error", Problem == "" ? 0
				: Map("code", LAYOUT_CATALOGUE_ERROR_INVALID_INDEX, "detail", Problem)), OnDone)
		return
	}
	try {
		if !DirExist(LocalDir)
			DirCreate(LocalDir)
		LocalDir := RTrim(FSResolveDirectoryPath(LocalDir), "\") . "\"
	} catch as Err {
		_LayoutCatalogueFinishRefresh(LayoutCatalogue_ResolveIndex(0, "", "",
			"cannot prepare " . LocalDir . ": " . Err.Message, 0, Bundled, Settings["max_file_bytes"]), OnDone)
		return
	}
	Owner := _LayoutCatalogueAcquireRefresh(LocalDir, OnDone)
	if !IsObject(Owner)
		return
	Cached := 0
	try {
		LoggerStart("LayoutCatalogue", "Refreshing the layout catalogue…")
		Cached := _LayoutCatalogueReadCache(LocalDir)
		Headers := Map("User-Agent", LAYOUT_REGISTRY_USER_AGENT)
		if (Cached is Map) && (Cached["etag"] != "")
			Headers["If-None-Match"] := Cached["etag"]
		; An unexpected dispatch exception may precede a late terminal callback.
		; Its private partial must never alias a successor's live response file.
		Partial := LocalDir . Settings["index_file"] . LAYOUT_REGISTRY_PARTIAL_SUFFIX
			. "." . A_ScriptHwnd . "_" . Owner.Sequence
		LayoutRegistry_Request(LayoutRegistry_RawUrl(Settings["index_file"]), Partial, Headers,
			Settings["download_timeout_sec"] * 1000, Transport,
			_LayoutCatalogueOnIndex.Bind(Owner, LocalDir, Partial, Cached, Bundled))
	} catch as Err {
		; A synchronous terminal callback can throw after retiring this owner.
		; Never consume that error by completing a later refresh a second time.
		if !_LayoutCatalogueRefreshCurrent(Owner)
			throw Err
		_LayoutCatalogueCompleteRefresh(Owner, LayoutCatalogue_ResolveIndex(0, "", "",
			"cannot refresh " . LocalDir . ": " . Err.Message, Cached, Bundled, Settings["max_file_bytes"]))
	}
}

_LayoutCatalogueOnIndex(Owner, LocalDir, Partial, Cached, Bundled, Status, Etag, Err) {
	global LAYOUT_CATALOGUE_ERROR_TOO_LARGE
	if !_LayoutCatalogueRefreshCurrent(Owner) {
		; Only this response owns this partial; a later directory owner has a
		; different path and must not be published or retired by this callback.
		if !FSDelete(Partial)
			LoggerWarn("LayoutCatalogue", "Cannot remove the partial download {1}.", Partial)
		return
	}
	Settings := LayoutRegistry_Settings()
	Body := ""
	if (Status == 200)
		Body := FSReadBounded(Partial, Settings["max_file_bytes"])
	if (Body is String)
		Outcome := LayoutCatalogue_ResolveIndex(Status, Body, Etag, Err, Cached, Bundled, Settings["max_file_bytes"])
	else
		Outcome := LayoutCatalogue_Fallback(Map("code", LAYOUT_CATALOGUE_ERROR_TOO_LARGE,
			"detail", "the registry index exceeds the download bound or cannot be read"), Cached, Bundled)
	if Outcome["store"] {
		try {
			if !FSAtomicMoveReplace(Partial, LocalDir . Settings["index_file"])
				throw Error("cannot publish the downloaded index in " . LocalDir)
			EtagPath := LocalDir . Settings["etag_file"]
			if (Outcome["etag"] != "")
				_LayoutCatalogueWriteText(EtagPath, Outcome["etag"])
			else if !FSDelete(EtagPath)
				throw Error("cannot remove " . EtagPath)
		} catch as Err {
			LoggerError("LayoutCatalogue", "The refreshed layout index could not be cached: {1}", Err.Message)
		}
	}
	if !FSDelete(Partial)
		LoggerWarn("LayoutCatalogue", "Cannot remove the partial download {1}.", Partial)
	_LayoutCatalogueCompleteRefresh(Owner, Outcome)
}

_LayoutCatalogueFinishRefresh(Outcome, OnDone) {
	global _LayoutCatalogueLast
	_LayoutCatalogueLast := Outcome
	try {
		if (Outcome["error"] is Map)
			LoggerWarn("LayoutCatalogue", "The layout catalogue shows the {1} index: {2} ({3}).", Outcome["source"],
				Outcome["error"]["code"], Outcome["error"]["detail"])
		LoggerSuccess("LayoutCatalogue", "Layout catalogue refreshed from the {1} index.", Outcome["source"])
	} finally OnDone.Call(Outcome)
}

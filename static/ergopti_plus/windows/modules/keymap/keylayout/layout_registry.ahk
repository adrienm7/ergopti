; modules/keymap/keylayout/layout_registry.ahk

; ==============================================================================
; MODULE: Layout Registry (Windows client)
; DESCRIPTION:
; Where the Windows driver finds registry layouts: the shared registry
; settings (_shared/layouts/data/defaults.json), the shared keycode table
; (_shared/layouts/data/mac_keycodes.json), the verification of a layout
; against its index entry, the local folder that keeps each installed
; <id>.keylayout (verified against the entry its installation recorded,
; layout_catalogue.ahk), the copy of the registry folder shipped with the
; driver, which the Ergopti emulation reads its layout from, and the one
; request every registry download goes through.
;
; FEATURES & RATIONALE:
; 1. One source for the registry location: the folder, branch, URL template,
;    bounds and local folder come from the shared defaults file, and owner/repo
;    from the updater defaults, like every other driver and the index builder.
; 2. A layout is only ever read after its size and checksum match the index
;    entry it was downloaded with: a truncated or edited file fails loudly
;    instead of emulating something else.
; 3. A download lands under a temporary name; the catalogue publishes it only
;    once the layout matches its index entry.
; 4. The transfer runs in a native WinHTTP child (CurlAsyncRequest) polled from a timer,
;    so the keyboard thread never waits on the network. Every collaborator is
;    injectable so tests replay a download without a network.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include layout_registry_download.ahk





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; A registry id is also a file name: a lowercase letter, then lowercase letters,
; digits and underscores, the rule tools/build/build-layouts-index.cjs enforces
; on the registry folder (tools/test/test-layouts-defaults-single-source.cjs
; pins this copy to it).
global LAYOUT_REGISTRY_ID_PATTERN := "^[a-z][a-z0-9_]*$"

; Suffix of a file being downloaded; it is renamed only once verified.
global LAYOUT_REGISTRY_PARTIAL_SUFFIX := ".download"

; User agent of every registry request: the one of the shared Lua client
; (_shared/layouts/engine/registry/registry_core.lua), pinned by test-layouts-defaults-single-source.cjs.
global LAYOUT_REGISTRY_USER_AGENT := "ErgoptiPlus-Layouts/1.0"

; How often a running download is polled. Short enough that a layout is ready a
; tenth of a second after the child exits, long enough to cost nothing while it runs.
global LAYOUT_REGISTRY_POLL_MS := 100

; Extra polls allowed past the transfer budget before a download that the child
; never reported finished is abandoned (the worker enforces the budget itself).
global LAYOUT_REGISTRY_POLL_GRACE := 20





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

; Parsed shared files, loaded on first use (they never change while running).
global _LayoutRegistryDefaults := 0
global _LayoutRegistryComposer := 0
global _LayoutRegistryKeycodes := 0
global _LayoutRegistryGithub := 0





; ===========================
; ===========================
; ======= 3/ Settings =======
; ===========================
; ===========================

_LayoutRegistryReadJson(RelativePath) {
	global _SharedDir
	Path := _SharedDir . "\" . RelativePath
	if !FileExist(Path)
		throw Error("Required shared file is missing: " . Path)
	return JsonParse(FSReadStrict(Path))
}

/**
 * The [registry] table of _shared/layouts/data/defaults.json.
 * @returns {Map}
 */
LayoutRegistry_Settings() {
	global _LayoutRegistryDefaults
	if !IsObject(_LayoutRegistryDefaults)
		_LayoutRegistryDefaults := _LayoutRegistryReadJson("layouts\data\defaults.json")["registry"]
	return _LayoutRegistryDefaults
}

/**
 * The [composer] table of _shared/layouts/data/defaults.json: the reserved
 * id the per-layer composer's layout is installed under, the folder that keeps
 * the user's composition and its bounds (docs/design/layout-composer.md).
 * @returns {Map}
 */
LayoutRegistry_Composer() {
	global _LayoutRegistryComposer
	if !IsObject(_LayoutRegistryComposer)
		_LayoutRegistryComposer := _LayoutRegistryReadJson("layouts\data\defaults.json")["composer"]
	return _LayoutRegistryComposer
}

/** Reads a fresh canonical keycode table without adopting the public cache. */
_LayoutRegistryReadKeycodes(SharedRoot := unset) {
	global _SharedDir
	if !IsSet(SharedRoot)
		SharedRoot := _SharedDir
	if !(SharedRoot is String) || SharedRoot == ""
		throw ValueError("The original shared keycode root is unavailable.")
	Path := SharedRoot . "\layouts\data\mac_keycodes.json"
	if !FileExist(Path)
		throw Error("Required shared file is missing: " . Path)
	return JsonParse(FSReadStrict(Path))
}

/**
 * The shared physical-key table every consumer converts a .keylayout with.
 * @returns {Map} Parsed mac_keycodes.json.
 */
LayoutRegistry_Keycodes() {
	global _LayoutRegistryKeycodes
	if !IsObject(_LayoutRegistryKeycodes)
		_LayoutRegistryKeycodes := _LayoutRegistryReadKeycodes()
	return _LayoutRegistryKeycodes
}

/**
 * Whether ``Id`` can name a registry layout (and therefore a local file).
 * @param {string} Id - Candidate id.
 * @returns {boolean}
 */
LayoutRegistry_IsValidId(Id) {
	global LAYOUT_REGISTRY_ID_PATTERN
	return (Id is String) && RegExMatch(Id, LAYOUT_REGISTRY_ID_PATTERN) > 0
}

/**
 * Download URL of a file of the registry folder.
 * @param {string} RelativePath - Path inside the registry ("index.json", "ergol/ergol.keylayout").
 * @returns {string}
 */
LayoutRegistry_RawUrl(RelativePath) {
	global _LayoutRegistryGithub
	if !IsObject(_LayoutRegistryGithub)
		_LayoutRegistryGithub := _LayoutRegistryReadJson("updater\data\defaults.json")["github"]
	Settings := LayoutRegistry_Settings()
	Url := Settings["raw_url_template"]
	for Name, Value in Map("owner", _LayoutRegistryGithub["owner"], "repo", _LayoutRegistryGithub["repo"],
		"branch", _Updater_InstalledChannel(), "folder", Settings["folder"], "path", RelativePath)
		Url := StrReplace(Url, "{" . Name . "}", Value)
	return Url
}

/**
 * Folder holding the downloaded layouts, inside the configuration folder.
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {string} Folder path with a trailing backslash.
 */
LayoutRegistry_LocalDir(ConfigDir) {
	return ConfigDir . LayoutRegistry_Settings()["local_folder"] . "\"
}

/**
 * Folder keeping the user's composition (declaration and compiled layout).
 * @param {string} ConfigDir - Configuration folder, with its trailing backslash.
 * @returns {string} Folder path with a trailing backslash.
 */
LayoutRegistry_ComposerDir(ConfigDir) {
	return ConfigDir . LayoutRegistry_Composer()["folder"] . "\"
}

/**
 * Registry folder shipped with the driver: the repository folder in a source
 * checkout, and its copy under the same path in the extracted bundle of the
 * compiled driver (tools/build/build_static_bundle.py). _StaticDir is the
 * "static" folder of either tree, so the folder resolves from its parent.
 * @returns {string} Folder path with a trailing backslash.
 */
LayoutRegistry_BundledDir() {
	global _StaticDir
	return _StaticDir . "\..\" . StrReplace(LayoutRegistry_Settings()["folder"], "/", "\") . "\"
}





; ================================
; ================================
; ======= 4/ Local layouts =======
; ================================
; ================================

/**
 * Entry of ``Id`` in a parsed registry index.
 * @param {Map} Index - Parsed index.json.
 * @param {string} Id - Registry id.
 * @returns {Map}
 * @throws {Error} When the index does not list the layout.
 */
LayoutRegistry_FindEntry(Index, Id) {
	if !(Index is Map) || !Index.Has("layouts") || !(Index["layouts"] is Array)
		throw Error("The registry index has no layouts list.")
	for Entry in Index["layouts"] {
		if (Entry is Map) && Entry.Has("id") && (Entry["id"] == Id)
			return Entry
	}
	throw Error("The layout '" . Id . "' is not in the registry index.")
}

/**
 * Throws unless ``Text`` is exactly the file the index entry describes.
 * @param {Map} Entry - Registry index entry.
 * @param {string} Text - .keylayout content, read as UTF-8 without conversion.
 */
LayoutRegistry_Verify(Entry, Text) {
	; A recorded row may hold no size (the shared rule asks id, sha256 and version):
	; the checksum below then vouches for the copy alone.
	Size := StrPut(Text, "UTF-8") - 1
	if Entry.Has("size") && (Size != Entry["size"])
		throw Error(Format("The layout '{1}' has {2} bytes instead of {3}.", Entry["id"], Size, Entry["size"]))
	Digest := CryptoSha256(Text)
	if (Digest != Entry["sha256"])
		throw Error(Format("The layout '{1}' does not match its registry checksum.", Entry["id"]))
}

_LayoutRegistryReadText(Path) {
	Text := FSReadBounded(Path, LayoutRegistry_Settings()["max_file_bytes"])
	if !(Text is String)
		throw Error("Cannot read " . Path . " (missing, unreadable or larger than the download bound).")
	return Text
}

/**
 * Reads an installed layout and verifies it against the entry its installation
 * recorded (installed.json, layout_catalogue.ahk), so a catalogue refreshed
 * since never invalidates it.
 * @param {string} Id - Registry id.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @returns {Map} Text (the .keylayout) and Entry (its recorded entry).
 * @throws {Error} When the layout is not installed or fails verification.
 */
LayoutRegistry_ReadLocal(Id, LocalDir) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	Installed := LayoutCatalogue_ReadInstalled(LocalDir)
	if !Installed.Has(Id)
		throw Error("The layout '" . Id . "' is not installed in " . LocalDir)
	LayoutPath := LocalDir . Id . ".keylayout"
	if !FileExist(LayoutPath)
		throw Error("The installed '" . Id . "' layout is missing from " . LocalDir)
	Entry := Installed[Id]
	Text := _LayoutRegistryReadText(LayoutPath)
	LayoutRegistry_Verify(Entry, Text)
	return Map("Text", Text, "Entry", Entry)
}

/**
 * Decodes the index shipped with the driver. A caller reading several shipped
 * layouts decodes it once and hands it to each LayoutRegistry_ReadBundled:
 * the decode is most of the cost of reading one layout.
 * @param {string} RegistryDir - Folder from LayoutRegistry_BundledDir.
 * @returns {Map} Parsed index.json.
 */
LayoutRegistry_ReadBundledIndex(RegistryDir) {
	PerfCount("layout_registry.bundled_index_decode")
	return JsonParse(_LayoutRegistryReadText(RegistryDir . LayoutRegistry_Settings()["index_file"]))
}

/**
 * Reads a layout shipped with the driver and verifies it against the shipped
 * index, like a downloaded one: a damaged installation fails here instead of
 * emulating something else.
 * @param {string} Id - Registry id.
 * @param {string} RegistryDir - Folder from LayoutRegistry_BundledDir.
 * @param {Map} Index - LayoutRegistry_ReadBundledIndex(RegistryDir), decoded
 *   here when omitted.
 * @returns {Map} Text (the .keylayout) and Entry (its index entry).
 * @throws {Error} When the layout is missing, misplaced or fails verification.
 */
LayoutRegistry_ReadBundled(Id, RegistryDir, Index := unset) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	if !IsSet(Index)
		Index := LayoutRegistry_ReadBundledIndex(RegistryDir)
	Entry := LayoutRegistry_FindEntry(Index, Id)
	; The index builder always files a layout as <id>/<id>.keylayout; anything
	; else would read outside the layout's own folder.
	if (Entry["file"] !== Id . "/" . Id . ".keylayout")
		throw Error("The registry index files the layout '" . Id . "' at an unexpected path: " . Entry["file"])
	Text := _LayoutRegistryReadText(RegistryDir . StrReplace(Entry["file"], "/", "\"))
	LayoutRegistry_Verify(Entry, Text)
	return Map("Text", Text, "Entry", Entry)
}





; ===========================
; ===========================
; ======= 5/ Download =======
; ===========================
; ===========================

_LayoutRegistryDefaultTransport() {
	return Map(
		"request", () => CurlAsyncRequest(),
		"managed", true,
		"schedule", (Fn, DelayMs) => SetTimer(Fn, -DelayMs)
	)
}

/**
 * Downloads one URL of the registry into ``Partial`` in a native WinHTTP child polled
 * from a timer, never on the keyboard thread, and calls
 * OnSettled(Status, Etag, Error, OutputOwner) exactly once: Status 0 when no HTTP response
 * arrived, Error then saying why; Etag is the response's, "" when none.
 * @param {string} Url
 * @param {string} Partial - Stage path acquired exclusively; an occupied path is refused.
 * @param {Map} Headers - Request headers.
 * @param {Integer} TimeoutMs - Budget of the whole transfer, connection included.
 * @param {Map} Transport - "request" (a CurlAsyncRequest-like object),
 *   "resolve_proxy" (SystemProxy_ResolveAsync) and "schedule" (Fn, DelayMs);
 *   the managed transport when 0.
 * @param {Func} OnSettled - Receives the retired download owner, or 0 if acquisition failed.
 */
LayoutRegistry_Request(Url, Partial, Headers, TimeoutMs, Transport, OnSettled) {
	Started := A_TickCount
	if !(Transport is Map)
		Transport := _LayoutRegistryDefaultTransport()
	Job := { Url: Url, Partial: Partial, Headers: Headers, TimeoutMs: TimeoutMs, Transport: Transport,
		OnSettled: OnSettled, Settled: false, Started: Started, Request: 0,
		Retiring: false, RetirementError: "", OutputOwner: 0 }
	LoggerDebug("LayoutRegistry", "Fetching {1}", Url)
	try {
		if !LayoutRegistry_RetireDownloads()
			throw Error("A previous registry download still owns native cleanup.")
		Job.OutputOwner := _LayoutRegistryDownload(Partial)
		if Transport.Get("managed", false)
			_LayoutRegistrySend(Job)
		else
			Transport["resolve_proxy"].Call([Url], (Resolved) => _LayoutRegistrySend(Job, Resolved[Url]))
	} catch as Err {
		; A synchronous subscriber may throw after settlement, or the exact
		; retirement owner may already retain a refused scheduling boundary.
		; Neither failure authorizes another dispatch-layer retirement attempt.
		if Job.Settled || Job.Retiring
			throw Err
		if IsObject(Job.Request)
			_LayoutRegistryRetire(Job, Job.Request, "cannot download " . Url . ": " . Err.Message)
		else
			_LayoutRegistrySettle(Job, 0, "", "cannot download " . Url . ": " . Err.Message)
	}
	return Job
}

_LayoutRegistrySettle(Job, Status, Etag, Err) {
	if Job.Settled
		return
	Job.Settled := true
	Job.Request := 0
	OutputOwner := Job.OutputOwner
	if IsObject(OutputOwner) {
		; Publish delivery admission before retirement: a reentrant request must
		; never mistake this callback's response for abandoned cleanup debt.
		OutputOwner.Delivering := true
		OutputOwner.Retired := true
	}
	try Job.OnSettled.Call(Status, Etag, Err, OutputOwner)
	finally {
		if IsObject(OutputOwner) {
			OutputOwner.Delivering := false
			if !OutputOwner.Remove()
				LoggerError("LayoutRegistry", "The retired download still owns native cleanup: {1}.", OutputOwner.Path)
		}
	}
}

_LayoutRegistrySend(Job, Proxy := unset) {
	if Job.Settled
		return
	try {
		Req := Job.Transport["request"].Call()
		Job.Request := Req
		if Job.Transport.Get("managed", false) {
			Req.SetManagedRouting(0, () => !Job.Settled && Job.Request == Req)
			Req.SetDeadline(Job.Started, Job.TimeoutMs)
		}
		Req.Open("GET", Job.Url, true)
		for Name, Value in Job.Headers
			Req.SetRequestHeader(Name, Value)
		if IsSet(Proxy)
			Req.SetProxy(Proxy)
		; One budget for the whole transfer, connection included.
		Req.SetTimeouts(0, Job.TimeoutMs, 0, 0)
		Req.SetOutputFile(Job.OutputOwner.Path)
		if !Req.Send()
			throw Error("The managed registry request refused dispatch.")
	} catch as Err {
		Failure := "cannot download " . Job.Url . ": " . Err.Message
		if IsObject(Job.Request)
			_LayoutRegistryRetire(Job, Job.Request, Failure)
		else
			_LayoutRegistrySettle(Job, 0, "", Failure)
		return
	}
	_LayoutRegistryPoll(Job, Req, 0)
}

; Consumers own the response file. They may remove or replace it only after
; the exact request confirms retirement, including a previously refused Abort.
_LayoutRegistryRetire(Job, Req, Failure) {
	global LAYOUT_REGISTRY_POLL_MS
	PreviousCritical := Critical("On")
	try {
		if Job.Settled
			return
		if !Job.Retiring {
			Job.RetirementError := Failure
			Job.Retiring := true
			Job.OutputOwner.RequestRetirement := _LayoutRegistryRetire.Bind(Job, Req, Failure)
		}
	} finally Critical(PreviousCritical)
	Retired := false
	try Retired := Req.Abort()
	if Job.Settled
		return
	if Retired is Integer && Retired == 1 {
		_LayoutRegistrySettle(Job, 0, "", Job.RetirementError)
		return
	}
	; Keep the request, partial and single terminal callback owned while native
	; completion or the facade's abort debt still has not proved quiescence.
	; Scheduling failure remains visible to the caller; it never proves an ACK.
	Job.Transport["schedule"].Call(_LayoutRegistryPoll.Bind(Job, Req, 0), LAYOUT_REGISTRY_POLL_MS)
}

_LayoutRegistryPoll(Job, Req, Polls) {
	if Job.Settled {
		Req.Abort()
		return
	}
	global LAYOUT_REGISTRY_POLL_MS, LAYOUT_REGISTRY_POLL_GRACE
	if Job.Retiring {
		_LayoutRegistryRetire(Job, Req, Job.RetirementError)
		return
	}
	try {
		Ready := Req.WaitForResponse(0)
	} catch as Err {
		_LayoutRegistryRetire(Job, Req, "download of " . Job.Url . " failed: " . Err.Message)
		return
	}
	if !Ready {
		if (Polls > Ceil(Job.TimeoutMs / LAYOUT_REGISTRY_POLL_MS) + LAYOUT_REGISTRY_POLL_GRACE) {
			_LayoutRegistryRetire(Job, Req, "download of " . Job.Url . " did not finish in time")
			return
		}
		try Job.Transport["schedule"].Call(_LayoutRegistryPoll.Bind(Job, Req, Polls + 1), LAYOUT_REGISTRY_POLL_MS)
		catch as Err {
			; Inline delivery may have completed the business callback. Its
			; failure is not permission to retire or silence an already settled job.
			if Job.Settled
				throw Err
			_LayoutRegistryRetire(Job, Req, "cannot schedule a poll for " . Job.Url . ": " . Err.Message)
		}
		return
	}
	Status := Req.Status
	_LayoutRegistrySettle(Job, Status, (Status == 0) ? "" : Req.GetResponseHeader("ETag"),
		(Status == 0) ? "no HTTP response for " . Job.Url . " (network, proxy or timeout)" : "")
}

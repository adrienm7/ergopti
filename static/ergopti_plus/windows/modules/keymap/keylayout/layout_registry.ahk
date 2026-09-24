; modules/keymap/keylayout/layout_registry.ahk

; ==============================================================================
; MODULE: Layout Registry (Windows client)
; DESCRIPTION:
; Where the Windows driver finds registry layouts: the shared registry
; settings (_shared/modules/layouts/defaults.json), the shared keycode table
; (_shared/modules/layouts/mac_keycodes.json), the download of index.json and
; of one .keylayout from the repository folder, and the local folder that keeps
; each downloaded <id>.keylayout next to the index.json it was verified against,
; and the copy of the registry folder shipped with the driver, which the Ergopti
; emulation reads its layout from.
;
; FEATURES & RATIONALE:
; 1. One source for the registry location: the folder, branch, URL template,
;    bounds and local folder come from the shared defaults file, and owner/repo
;    from the updater defaults, like every other driver and the index builder.
; 2. A layout is only ever read after its size and checksum match the index
;    entry it was downloaded with: a truncated or edited file fails loudly
;    instead of emulating something else.
; 3. A download never replaces a verified local copy with an unverified one:
;    both files land under a temporary name and are published only once the
;    layout matches the downloaded index.
; 4. The transfer runs in a curl child (CurlAsyncRequest) polled from a timer,
;    so the keyboard thread never waits on the network. Every collaborator is
;    injectable so tests replay a download without a network.
; ==============================================================================

#Requires AutoHotkey v2.0





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

; How often a running download is polled. Short enough that a layout is ready a
; tenth of a second after curl exits, long enough to cost nothing while it runs.
global LAYOUT_REGISTRY_POLL_MS := 100

; Extra polls allowed past the transfer budget before a download that curl
; never reported finished is abandoned (curl enforces the budget itself).
global LAYOUT_REGISTRY_POLL_GRACE := 20





; ========================
; ========================
; ======= 2/ State =======
; ========================
; ========================

; Parsed shared files, loaded on first use (they never change while running).
global _LayoutRegistryDefaults := 0
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
	return JsonParse(FileRead(Path, "UTF-8"))
}

/**
 * The [registry] table of _shared/modules/layouts/defaults.json.
 * @returns {Map}
 */
LayoutRegistry_Settings() {
	global _LayoutRegistryDefaults
	if !IsObject(_LayoutRegistryDefaults)
		_LayoutRegistryDefaults := _LayoutRegistryReadJson("modules\layouts\defaults.json")["registry"]
	return _LayoutRegistryDefaults
}

/**
 * The shared physical-key table every consumer converts a .keylayout with.
 * @returns {Map} Parsed mac_keycodes.json.
 */
LayoutRegistry_Keycodes() {
	global _LayoutRegistryKeycodes
	if !IsObject(_LayoutRegistryKeycodes)
		_LayoutRegistryKeycodes := _LayoutRegistryReadJson("modules\layouts\mac_keycodes.json")
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
		_LayoutRegistryGithub := _LayoutRegistryReadJson("modules\updater\defaults.json")["github"]
	Settings := LayoutRegistry_Settings()
	Url := Settings["raw_url_template"]
	for Name, Value in Map("owner", _LayoutRegistryGithub["owner"], "repo", _LayoutRegistryGithub["repo"],
		"branch", Settings["branch"], "folder", Settings["folder"], "path", RelativePath)
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
	Size := StrPut(Text, "UTF-8") - 1
	if (Size != Entry["size"])
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
 * Reads a downloaded layout and verifies it against its local index.
 * @param {string} Id - Registry id.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @returns {Map} Text (the .keylayout) and Entry (its index entry).
 * @throws {Error} When the layout is not downloaded or fails verification.
 */
LayoutRegistry_ReadLocal(Id, LocalDir) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	IndexPath := LocalDir . LayoutRegistry_Settings()["index_file"]
	LayoutPath := LocalDir . Id . ".keylayout"
	if !FileExist(IndexPath) || !FileExist(LayoutPath)
		throw Error("The layout '" . Id . "' is not downloaded in " . LocalDir)
	Entry := LayoutRegistry_FindEntry(JsonParse(_LayoutRegistryReadText(IndexPath)), Id)
	Text := _LayoutRegistryReadText(LayoutPath)
	LayoutRegistry_Verify(Entry, Text)
	return Map("Text", Text, "Entry", Entry)
}

/**
 * Reads a layout shipped with the driver and verifies it against the shipped
 * index, like a downloaded one: a damaged installation fails here instead of
 * emulating something else.
 * @param {string} Id - Registry id.
 * @param {string} RegistryDir - Folder from LayoutRegistry_BundledDir.
 * @returns {Map} Text (the .keylayout) and Entry (its index entry).
 * @throws {Error} When the layout is missing, misplaced or fails verification.
 */
LayoutRegistry_ReadBundled(Id, RegistryDir) {
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	Index := JsonParse(_LayoutRegistryReadText(RegistryDir . LayoutRegistry_Settings()["index_file"]))
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
		"resolve_proxy", SystemProxy_ResolveAsync,
		"schedule", (Fn, DelayMs) => SetTimer(Fn, -DelayMs)
	)
}

/**
 * Downloads the registry index and one layout into ``LocalDir``, verifies the
 * layout against that index and only then publishes both files.
 * @param {string} Id - Registry id.
 * @param {string} LocalDir - Folder from LayoutRegistry_LocalDir.
 * @param {Func} OnDone - OnDone(Ok, Detail): Detail is the index entry on
 *   success, the failure reason otherwise. Called exactly once.
 * @param {Map} Transport - "request" (returns a CurlAsyncRequest-like object),
 *   "resolve_proxy" (SystemProxy_ResolveAsync) and "schedule" (Fn, DelayMs);
 *   injectable for tests.
 */
LayoutRegistry_Fetch(Id, LocalDir, OnDone, Transport := 0) {
	global LAYOUT_REGISTRY_PARTIAL_SUFFIX
	if !LayoutRegistry_IsValidId(Id)
		throw ValueError("Invalid registry layout id.", -1, Id)
	Settings := LayoutRegistry_Settings()
	Job := {
		Id: Id,
		LocalDir: LocalDir,
		OnDone: OnDone,
		Transport: (Transport is Map) ? Transport : _LayoutRegistryDefaultTransport(),
		TimeoutMs: Settings["download_timeout_sec"] * 1000,
		IndexPartial: LocalDir . Settings["index_file"] . LAYOUT_REGISTRY_PARTIAL_SUFFIX,
		LayoutPartial: LocalDir . Id . ".keylayout" . LAYOUT_REGISTRY_PARTIAL_SUFFIX,
		Entry: 0,
		Finished: false
	}
	LoggerStart("LayoutRegistry", "Downloading the '{1}' layout from the registry…", Id)
	try {
		if !DirExist(LocalDir)
			DirCreate(LocalDir)
		_LayoutRegistryDownload(Job, Settings["index_file"], Job.IndexPartial, _LayoutRegistryOnIndex)
	} catch as Err {
		_LayoutRegistryFinish(Job, false, Err.Message)
	}
}

; Starts one file transfer once the system proxy for its URL is known.
_LayoutRegistryDownload(Job, RelativePath, Partial, OnFile) {
	Url := LayoutRegistry_RawUrl(RelativePath)
	LoggerDebug("LayoutRegistry", "Fetching {1}", Url)
	Job.Transport["resolve_proxy"].Call([Url],
		(Resolved) => _LayoutRegistrySend(Job, Url, Resolved[Url], Partial, OnFile))
}

_LayoutRegistrySend(Job, Url, Proxy, Partial, OnFile) {
	try {
		if !FSDelete(Partial)
			throw Error("Cannot remove the stale partial download " . Partial)
		Req := Job.Transport["request"].Call()
		Req.Open("GET", Url, true)
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Layouts/1.0")
		Req.SetProxy(Proxy)
		; One budget for the whole transfer, connection included.
		Req.SetTimeouts(0, Job.TimeoutMs, 0, 0)
		Req.SetOutputFile(Partial)
		Req.Send()
	} catch as Err {
		_LayoutRegistryFinish(Job, false, "cannot download " . Url . ": " . Err.Message)
		return
	}
	_LayoutRegistryPoll(Job, Req, Url, OnFile, 0)
}

_LayoutRegistryPoll(Job, Req, Url, OnFile, Polls) {
	global LAYOUT_REGISTRY_POLL_MS, LAYOUT_REGISTRY_POLL_GRACE
	try {
		Ready := Req.WaitForResponse(0)
	} catch as Err {
		try Req.Abort()
		_LayoutRegistryFinish(Job, false, "download of " . Url . " failed: " . Err.Message)
		return
	}
	if !Ready {
		if (Polls > Ceil(Job.TimeoutMs / LAYOUT_REGISTRY_POLL_MS) + LAYOUT_REGISTRY_POLL_GRACE) {
			try Req.Abort()
			_LayoutRegistryFinish(Job, false, "download of " . Url . " did not finish in time")
			return
		}
		Job.Transport["schedule"].Call(_LayoutRegistryPoll.Bind(Job, Req, Url, OnFile, Polls + 1),
			LAYOUT_REGISTRY_POLL_MS)
		return
	}
	if (Req.Status != 200) {
		_LayoutRegistryFinish(Job, false, Req.Status == 0
			? "no HTTP response for " . Url . " (network, proxy or timeout)"
			: "HTTP " . Req.Status . " for " . Url)
		return
	}
	try OnFile.Call(Job)
	catch as Err
		_LayoutRegistryFinish(Job, false, Err.Message)
}

_LayoutRegistryOnIndex(Job) {
	Entry := LayoutRegistry_FindEntry(JsonParse(_LayoutRegistryReadText(Job.IndexPartial)), Job.Id)
	if (Entry["size"] > LayoutRegistry_Settings()["max_file_bytes"])
		throw Error(Format("The layout '{1}' ({2} bytes) exceeds the download bound.", Job.Id, Entry["size"]))
	Job.Entry := Entry
	_LayoutRegistryDownload(Job, Entry["file"], Job.LayoutPartial, _LayoutRegistryOnLayout)
}

_LayoutRegistryOnLayout(Job) {
	Settings := LayoutRegistry_Settings()
	LayoutRegistry_Verify(Job.Entry, _LayoutRegistryReadText(Job.LayoutPartial))
	; The layout first: a crash between the two renames leaves a new layout
	; beside the old index, which fails verification and is downloaded again.
	if !FSAtomicMoveReplace(Job.LayoutPartial, Job.LocalDir . Job.Id . ".keylayout")
		throw Error("Cannot publish the downloaded '" . Job.Id . "' layout in " . Job.LocalDir)
	if !FSAtomicMoveReplace(Job.IndexPartial, Job.LocalDir . Settings["index_file"])
		throw Error("Cannot publish the downloaded registry index in " . Job.LocalDir)
	_LayoutRegistryFinish(Job, true, Job.Entry)
}

_LayoutRegistryFinish(Job, Ok, Detail) {
	if Job.Finished
		return
	Job.Finished := true
	if Ok {
		LoggerSuccess("LayoutRegistry", "Downloaded the '{1}' layout (version {2}).", Job.Id, Detail["version"])
	} else {
		for Partial in [Job.IndexPartial, Job.LayoutPartial]
			if !FSDelete(Partial)
				LoggerWarn("LayoutRegistry", "Cannot remove the partial download {1}.", Partial)
		LoggerError("LayoutRegistry", "The '{1}' layout could not be downloaded: {2}", Job.Id, Detail)
	}
	Job.OnDone.Call(Ok, Detail)
}

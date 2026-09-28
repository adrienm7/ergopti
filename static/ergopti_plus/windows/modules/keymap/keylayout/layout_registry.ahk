; modules/keymap/keylayout/layout_registry.ahk

; ==============================================================================
; MODULE: Layout Registry (Windows client)
; DESCRIPTION:
; Where the Windows driver finds registry layouts: the shared registry
; settings (_shared/modules/layouts/defaults.json), the shared keycode table
; (_shared/modules/layouts/mac_keycodes.json), the verification of a layout
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

; User agent of every registry request: the one of the shared Lua client
; (_shared/lua/layouts/registry.lua), pinned by test-layouts-defaults-single-source.cjs.
global LAYOUT_REGISTRY_USER_AGENT := "ErgoptiPlus-Layouts/1.0"

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
	return JsonParse(FSReadStrict(Path))
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
 * Downloads one URL of the registry into ``Partial`` in a curl child polled
 * from a timer, never on the keyboard thread, and calls
 * OnSettled(Status, Etag, Error) exactly once: Status 0 when no HTTP response
 * arrived, Error then saying why; Etag is the response's, "" when none.
 * @param {string} Url
 * @param {string} Partial - Output file; a stale one is removed first.
 * @param {Map} Headers - Request headers.
 * @param {Integer} TimeoutMs - Budget of the whole transfer, connection included.
 * @param {Map} Transport - "request" (a CurlAsyncRequest-like object),
 *   "resolve_proxy" (SystemProxy_ResolveAsync) and "schedule" (Fn, DelayMs);
 *   the curl transport when 0.
 * @param {Func} OnSettled
 */
LayoutRegistry_Request(Url, Partial, Headers, TimeoutMs, Transport, OnSettled) {
	if !(Transport is Map)
		Transport := _LayoutRegistryDefaultTransport()
	Job := { Url: Url, Partial: Partial, Headers: Headers, TimeoutMs: TimeoutMs, Transport: Transport,
		OnSettled: OnSettled, Settled: false }
	LoggerDebug("LayoutRegistry", "Fetching {1}", Url)
	Transport["resolve_proxy"].Call([Url], (Resolved) => _LayoutRegistrySend(Job, Resolved[Url]))
}

_LayoutRegistrySettle(Job, Status, Etag, Err) {
	if Job.Settled
		return
	Job.Settled := true
	Job.OnSettled.Call(Status, Etag, Err)
}

_LayoutRegistrySend(Job, Proxy) {
	try {
		if !FSDelete(Job.Partial)
			throw Error("Cannot remove the stale partial download " . Job.Partial)
		Req := Job.Transport["request"].Call()
		Req.Open("GET", Job.Url, true)
		for Name, Value in Job.Headers
			Req.SetRequestHeader(Name, Value)
		Req.SetProxy(Proxy)
		; One budget for the whole transfer, connection included.
		Req.SetTimeouts(0, Job.TimeoutMs, 0, 0)
		Req.SetOutputFile(Job.Partial)
		Req.Send()
	} catch as Err {
		_LayoutRegistrySettle(Job, 0, "", "cannot download " . Job.Url . ": " . Err.Message)
		return
	}
	_LayoutRegistryPoll(Job, Req, 0)
}

_LayoutRegistryPoll(Job, Req, Polls) {
	global LAYOUT_REGISTRY_POLL_MS, LAYOUT_REGISTRY_POLL_GRACE
	try {
		Ready := Req.WaitForResponse(0)
	} catch as Err {
		try Req.Abort()
		_LayoutRegistrySettle(Job, 0, "", "download of " . Job.Url . " failed: " . Err.Message)
		return
	}
	if !Ready {
		if (Polls > Ceil(Job.TimeoutMs / LAYOUT_REGISTRY_POLL_MS) + LAYOUT_REGISTRY_POLL_GRACE) {
			try Req.Abort()
			_LayoutRegistrySettle(Job, 0, "", "download of " . Job.Url . " did not finish in time")
			return
		}
		Job.Transport["schedule"].Call(_LayoutRegistryPoll.Bind(Job, Req, Polls + 1), LAYOUT_REGISTRY_POLL_MS)
		return
	}
	Status := Req.Status
	_LayoutRegistrySettle(Job, Status, (Status == 0) ? "" : Req.GetResponseHeader("ETag"),
		(Status == 0) ? "no HTTP response for " . Job.Url . " (network, proxy or timeout)" : "")
}

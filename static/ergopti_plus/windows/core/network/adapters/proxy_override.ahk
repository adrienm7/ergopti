; core/network/adapters/proxy_override.ahk

; ==============================================================================
; MODULE: Proxy Override Setting (Windows)
; DESCRIPTION:
; The user's proxy override (Issue #101 point 2): automatic (the system settings,
; a company PAC included), direct, or one relay every download uses. The twin of
; _shared/core/network/engine/proxy_override.lua over the canonical declaration
; _shared/core/network/data/proxy_override.json, stored under the same key in
; config.toml, the Windows settings store.
;
; FEATURES & RATIONALE:
; 1. One variable carries the choice to every channel, and only to them. It is set
;    on the private environment of each network worker at spawn (ProxyOverride_
;    SpawnWorker: the managed HTTP worker, the updater staging worker, the Ollama
;    bridges and the runtime launcher) and vendor/ergopti_network_routes.ps1 applies
;    it in one place. It never enters this process's own environment: run_command,
;    Run and any program the user opens would inherit it, password included.
; 2. Fail fast: a stored value that is not valid is published as a token the route
;    owner refuses, never read as automatic, and the user is told in words.
; 3. Every relay of the shared grammar is usable. WinHTTP and HttpWebRequest reach a
;    plain http relay only, so vendor/ergopti_network_routes.ps1 runs a loopback hop
;    for an https relay, a socks5 relay or credentials in the address; the Ollama
;    daemon reads them from its environment itself. The value holds a password then,
;    and logs name the mode.
; 4. A relay with credentials is stored whole as a DPAPI envelope, the store of the
;    API keys, so config.toml holds no password; the address goes with it because one
;    string has no torn state between two keys. A clear value edited by hand is sealed
;    once, after boot. No plaintext fallback: a seal that fails refuses the save.
;    macOS and Linux keep this value in their settings store for now: every route
;    decision there reads it synchronously, while the Keychain answers asynchronously
;    through the signed launcher and secret-tool hands the keyboard to the desktop.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\modules\llm\api_token_crypto.ahk

; The variable the route owner reads, as on macOS (network_env.lua)
global PROXY_OVERRIDE_ENVIRONMENT := "ERGOPTI_PROXY_OVERRIDE"
; Published for a stored value that cannot be used; no route owner accepts it
global PROXY_OVERRIDE_REFUSED_TOKEN := "invalid"
; The relay schemes of core/network/engine/route_plan.lua
global PROXY_OVERRIDE_RELAY_SCHEMES := Map("http", true, "https", true, "socks5", true, "socks5h", true)

global _ProxyOverrideDeclaration := 0
global _ProxyOverrideInitialized := false
; The stored text, shown back in the menu row even when it is refused
global _ProxyOverrideStored := ""
; What the next worker receives: the canonical choice, or the refused token
global _ProxyOverridePublished := ""
; Whether the value published last came from a DPAPI envelope
global _ProxyOverrideSealed := false
; Exact admitted source behind this boot's optional plaintext credential sealing.
global _ProxyOverrideBootSealSource := 0





; ====================================
; ====================================
; ======= 1/ The value grammar =======
; ====================================
; ====================================

/**
 * Reads the canonical declaration once.
 * @returns {Map} storage_key, section, key, default, direct.
 */
ProxyOverride_Declaration() {
	global _ProxyOverrideDeclaration, _SharedDir
	if _ProxyOverrideDeclaration is Map
		return _ProxyOverrideDeclaration
	Data := JsonParse(FileRead(_SharedDir . "\core\network\data\proxy_override.json", "UTF-8"))
	if !(Data is Map) || Data.Get("schema_version", 0) != 1 || Data.Get("default", 0) !== ""
			|| !(Data.Get("storage_key", 0) is String) || !(Data.Get("direct", 0) is String)
			|| !RegExMatch(Data["storage_key"], "^([a-z][a-z_]*)\.([a-z][a-z_]*)$", &Parts)
			|| !RegExMatch(Data["direct"], "^[a-z]+$")
		throw ValueError("The proxy override declaration is invalid.")
	_ProxyOverrideDeclaration := Map("storage_key", Data["storage_key"], "section", Parts[1], "key", Parts[2],
		"default", Data["default"], "direct", Data["direct"])
	return _ProxyOverrideDeclaration
}

/**
 * Whether a value is one relay an environment-driven client can export: the twin
 * of route_plan.lua valid_route and of Test-ErgoptiRoutePlanRoute.
 * @param {String} Value The candidate.
 * @returns {Boolean}
 */
ProxyOverride_IsValidRelay(Value) {
	global PROXY_OVERRIDE_RELAY_SCHEMES
	if !(Value is String) || !RegExMatch(Value, "^([a-z][a-z0-9]*)://(.+)$", &Url)
		return false
	if !PROXY_OVERRIDE_RELAY_SCHEMES.Has(Url[1])
		return false
	Address := Url[2]
	if RegExMatch(Address, "^([^@]*)@(.*)$", &Parts) {
		; A userinfo keeps only RFC 3986 characters.
		if Parts[1] == "" || RegExMatch(Parts[1], "[^A-Za-z0-9._~%!$&()*+,;=:\-]")
			return false
		Address := Parts[2]
	}
	if !RegExMatch(Address, "^([^/\s@]+):([0-9]+)$", &HostPort) || StrLen(HostPort[2]) > 5
		return false
	Port := Integer(HostPort[2])
	if Port < 1 || Port > 65535
		return false
	if SubStr(HostPort[1], 1, 1) == "["
		return RegExMatch(HostPort[1], "^\[[0-9A-Fa-f:]+\]$") != 0
	return !RegExMatch(HostPort[1], "[^A-Za-z0-9._\-]")
}

/**
 * Classifies a stored or typed value.
 * @param {Any} Value Anything but a string is refused.
 * @returns {Map|Integer} mode "automatic", "direct" or "relay" with its relay; 0 when refused.
 */
ProxyOverride_Parse(Value) {
	Direct := ProxyOverride_Declaration()["direct"]
	if !(Value is String)
		return 0
	Value := Trim(Value, " `t`r`n")
	if Value == ""
		return Map("mode", "automatic")
	if StrLower(Value) == Direct
		return Map("mode", "direct")
	if !ProxyOverride_IsValidRelay(Value)
		return 0
	return Map("mode", "relay", "relay", Value)
}

/**
 * The form a valid value is stored under.
 * @param {Map} Choice From ProxyOverride_Parse.
 * @returns {String}
 */
ProxyOverride_Canonical(Choice) {
	Declaration := ProxyOverride_Declaration()
	switch Choice["mode"] {
		case "automatic":
			return Declaration["default"]
		case "direct":
			return Declaration["direct"]
	}
	return Choice["relay"]
}

/**
 * Whether a relay address holds a credential, so it must stay out of any file.
 * @param {String} Relay The relay.
 * @returns {Boolean}
 */
ProxyOverride_CarriesCredentials(Relay) {
	return InStr(Relay, "@") > 0
}

/**
 * Whether a stored value is a DPAPI envelope.
 * @param {Any} Stored The stored value.
 * @returns {Boolean}
 */
ProxyOverride_IsSealed(Stored) {
	global LLM_API_TOKEN_DPAPI_PREFIX
	return Stored is String && SubStr(Stored, 1, StrLen(LLM_API_TOKEN_DPAPI_PREFIX)) == LLM_API_TOKEN_DPAPI_PREFIX
}

/**
 * The form a canonical value takes in config.toml.
 * @param {String} Canonical From ProxyOverride_Canonical.
 * @returns {String|Boolean} The value, its envelope when it holds credentials, or
 *   false when it cannot be sealed: the caller refuses the save, never writes it clear.
 */
ProxyOverride_Seal(Canonical) {
	if !ProxyOverride_CarriesCredentials(Canonical)
		return Canonical
	Envelope := LLM_ApiToken_Encrypt(Canonical)
	return Envelope is String && Envelope != "" ? Envelope : false
}

/**
 * The value a stored form stands for.
 * @param {Any} Stored The stored value.
 * @returns {Any} Anything but an envelope unchanged; false for an envelope this
 *   Windows account cannot open, which the grammar then refuses.
 */
ProxyOverride_Unseal(Stored) {
	if !ProxyOverride_IsSealed(Stored)
		return Stored
	Clear := LLM_ApiToken_Decrypt(Stored)
	return Clear is String && !ProxyOverride_IsSealed(Clear) ? Clear : false
}





; =======================================
; =======================================
; ======= 2/ The published choice =======
; =======================================
; =======================================

/**
 * Publishes a stored value to the route owners of this process and to every network
 * worker started next. It stays in this process's memory.
 * @param {Any} Stored The stored value, an envelope included.
 * @returns {Boolean} False when the value is refused.
 */
ProxyOverride_Publish(Stored) {
	return _ProxyOverride_ApplyPublication(_ProxyOverride_PreparePublication(Stored))
}

; Resolve DPAPI and normalize the route before entering a durable publisher.
_ProxyOverride_PreparePublication(Stored) {
	global PROXY_OVERRIDE_REFUSED_TOKEN
	Sealed := ProxyOverride_IsSealed(Stored)
	Value := ProxyOverride_Unseal(Stored)
	RuntimeStored := Value is String ? Value : Stored is String ? Stored : String(Stored)
	Choice := ProxyOverride_Parse(Value)
	Usable := Choice is Map
	Published := Usable ? ProxyOverride_Canonical(Choice) : PROXY_OVERRIDE_REFUSED_TOKEN
	return {config: Stored, stored: RuntimeStored, published: Published, sealed: Sealed, usable: Usable}
}

; Primitive swaps only: durable publishers call this under the gateway Critical.
_ProxyOverride_ApplyPublication(Publication) {
	global _ProxyOverrideStored, _ProxyOverridePublished, _ProxyOverrideSealed, _ProxyOverrideBootSealSource
	_ProxyOverrideBootSealSource := 0
	_ProxyOverrideSealed := Publication.sealed
	_ProxyOverrideStored := Publication.stored
	_ProxyOverridePublished := Publication.published
	return Publication.usable
}

/**
 * The choice in force now.
 * @returns {Map|Integer} As ProxyOverride_Parse; 0 when the stored value is refused.
 */
ProxyOverride_Current() {
	global _ProxyOverridePublished
	if _ProxyOverridePublished == ""
		return Map("mode", "automatic")
	return ProxyOverride_Parse(_ProxyOverridePublished)
}

/**
 * The private environment of one network worker: this process's, with the choice in
 * force and the native module path. An empty override still overwrites a value
 * something exported for the driver, which is not the user's choice in this driver.
 * @returns {Buffer} A Unicode environment block.
 */
ProxyOverride_WorkerEnvironment() {
	global PROXY_OVERRIDE_ENVIRONMENT, _ProxyOverridePublished
	return ShellRunner_BuildEnvironment(Map(PROXY_OVERRIDE_ENVIRONMENT, _ProxyOverridePublished,
		"PSModulePath", ShellRunner_WinPsModulePath()))
}

/**
 * ShellRunner_SpawnTreeOwned for a worker that downloads: the only way the override
 * leaves this process. Same arguments, same task.
 */
ProxyOverride_SpawnWorker(Executable, Args, OnDone?, OnChunk?, BeforeNativeAdoptFn?,
		MaxOutputBytes := 0, CaptureOutput := true, PrivateDiagnostics := false) {
	return ShellRunner_SpawnTreeOwnedPrivate(ProxyOverride_WorkerEnvironment(), Executable, Args, OnDone?,
		OnChunk?, BeforeNativeAdoptFn?, MaxOutputBytes, CaptureOutput, PrivateDiagnostics)
}

/**
 * Root boot owner: publishes the stored value before anything can download. Logs
 * name the mode only: a relay address may be private.
 * @param {Map} Cache The boot configuration cache.
 * @returns {Boolean} False when the stored value is refused.
 */
ProxyOverride_Init(Cache) {
	global _ProxyOverrideInitialized, PROXY_OVERRIDE_ENVIRONMENT, ConfigurationFile
	global _ProxyOverrideBootSealSource, _ProxyOverrideStored, _ProxyOverrideSealed
	if _ProxyOverrideInitialized
		throw Error("The proxy override was initialized twice.")
	_ProxyOverrideInitialized := true
	; A value something exported for this driver must not reach what it starts.
	EnvSet(PROXY_OVERRIDE_ENVIRONMENT)
	Declaration := ProxyOverride_Declaration()
	; Capture A from the authenticated bootstrap snapshot before publishing its
	; RAM value. A later automatic seal cannot borrow a freshly edited file B.
	Path := IsSet(ConfigurationFile) ? ConfigurationFile : ""
	Snapshot := ConfigTomlBootSnapshot(Cache)
	BootSource := 0
	if IsObject(Snapshot) {
		ConfigTomlBootSnapshotValue(Snapshot, Declaration["section"], Declaration["key"], &Stored)
		if StrCompare(Path, ConfigurationFile, true) != 0
			throw Error("The proxy bootstrap source changed its configuration path.")
		; The ordinary bootstrap reader consumes one UTF-8 BOM. Retain an exact
		; native image only if that reader's projection is still the original A.
		ExactContent := false
		try ExactContent := Snapshot.Present ? FSConfigReadUtf8Exact(Path) : ""
		if ExactContent is String {
			ProjectedContent := SubStr(ExactContent, 1, 1) == Chr(0xFEFF) ? SubStr(ExactContent, 2) : ExactContent
			if StrCompare(ProjectedContent, Snapshot.Source, true) == 0
				BootSource := {Path: Path, Content: ExactContent, Present: Snapshot.Present, Stored: Stored}
		}
	} else
		Stored := IniCacheGet(Cache, Declaration["section"], Declaration["key"])
	if Stored == "_"
		Stored := Declaration["default"]
	if ProxyOverride_Publish(Stored) {
		PreviousCritical := Critical("On")
		try {
			if IsObject(BootSource) && Stored is String && !_ProxyOverrideSealed
					&& StrCompare(Stored, _ProxyOverrideStored, true) == 0
				_ProxyOverrideBootSealSource := BootSource
		} finally Critical(PreviousCritical)
		LoggerInfo("ProxyOverride", "Proxy override in force: {1}.", ProxyOverride_Current()["mode"])
		return true
	}
	LoggerError("ProxyOverride", "The stored proxy override is refused: every download refuses until it is corrected.")
	; Told at start, not at the first failed download; off this thread, as the UI needs the pump.
	SetTimer(ProxyOverride_SayStoredRefused, -1)
	return false
}

; infra/config_transition.ahk

; ==============================================================================
; MODULE: Bounded Configuration Transition Journal
; DESCRIPTION:
; Coordinates crash-safe changes spanning paths.toml and one or more physical
; configuration targets. A strictly bounded write-ahead journal records hashes
; and intent while immutable same-directory stages and backups retain the bytes
; needed to deterministically restore one complete side of the transition.
;
; FEATURES & RATIONALE:
; 1. Strict framing rejects unknown versions, fields, paths, phases, and hashes.
; 2. Eight-target and 64 KiB limits bound every early-boot journal operation.
; 3. Create-only artifact publication refuses namespace collisions fail-closed.
; 4. Phase-directed recovery chooses all-old or all-new without disk heuristics.
; 5. Injectable ports and pause seams expose every durable boundary to tests.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Format and Port Contract =======
; ===========================================
; ===========================================

global CONFIG_TRANSITION_WAL_HEADER := "ERGOPTI_CONFIG_TRANSITION_WAL"
global CONFIG_TRANSITION_WAL_VERSION := 1
global CONFIG_TRANSITION_PHASE_PREPARED := "prepared"
global CONFIG_TRANSITION_PHASE_APPLYING := "applying"
global CONFIG_TRANSITION_PHASE_COMMITTED_NEW := "committed_new"
global CONFIG_TRANSITION_PHASE_COMMITTED_OLD := "committed_old"
global CONFIG_TRANSITION_MAX_TARGETS := 8
global CONFIG_TRANSITION_MAX_WAL_BYTES := 64 * 1024
global CONFIG_TRANSITION_MAX_TX_ID_CHARS := 64
global CONFIG_TRANSITION_MAX_PATH_CHARS := 32767
global CONFIG_TRANSITION_MAX_COMPONENT_CHARS := 255
global CONFIG_TRANSITION_WAL_SUFFIX := ".config-transition.wal"
global CONFIG_TRANSITION_ARTIFACT_TAG := ".ergopti-transition-"
global CONFIG_TRANSITION_HASH_ABSENT := "-"

; Builds a typed result shared by every public operation.
; @param Status {String} High-level outcome such as ok, retry, quarantine, or fatal.
; @param Kind {String} Stable machine-readable reason.
; @param Detail {String} Developer-facing diagnostic detail.
; @param Record {Map|false} Validated journal record when one is available.
; @return {Map} Typed operation result.
_ConfigTransitionResult(Status, Kind, Detail := "", Record := false) {
	return Map("status", Status, "kind", Kind, "detail", Detail,
		"record", Record)
}

; Validates the injected filesystem and hash contract.
; @param Port {Map} Adapter map supplied by the integration boundary.
; @return {Map|false} The validated port, or false when incomplete.
_ConfigTransitionResolvePort(Port) {
	if !(Port is Map)
		return false
	for Method in ["exists", "read", "read_bounded", "write_create_durable",
			"move_create", "move_replace", "delete", "hash"] {
		if !Port.Has(Method) || !HasMethod(Port[Method], "Call")
			return false
	}
	return Port
}

; Calls the strict existence adapter without conflating string "0" with false.
; @param Port {Map} Validated adapter map.
; @param Path {String} Physical path to probe.
; @param Exists {VarRef} Receives integer 0 or 1.
; @param Detail {VarRef} Receives a refusal diagnostic.
; @return {Boolean} True only for a well-typed adapter response.
_ConfigTransitionPortExists(Port, Path, &Exists, &Detail) {
	try Result := Port["exists"].Call(Path)
	catch as Err {
		Detail := "Existence probe threw for '" . Path . "': " . Err.Message
		return false
	}
	if !(Result is Integer) || (Result !== 0 && Result !== 1) {
		Detail := "Existence probe returned a malformed status for '" . Path . "'."
		return false
	}
	Exists := Result
	return true
}

; Reads one target or immutable artifact through the injected adapter.
; @param Port {Map} Validated adapter map.
; @param Path {String} Physical path to read.
; @param Content {VarRef} Receives exact text bytes decoded by the adapter.
; @param Detail {VarRef} Receives a refusal diagnostic.
; @return {Boolean} True only when the adapter returns a string.
_ConfigTransitionPortRead(Port, Path, &Content, &Detail) {
	try Result := Port["read"].Call(Path)
	catch as Err {
		Detail := "Read threw for '" . Path . "': " . Err.Message
		return false
	}
	if !(Result is String) {
		Detail := "Read was refused for '" . Path . "'."
		return false
	}
	Content := Result
	return true
}

; Reads the live journal under its hard allocation budget.
; @param Port {Map} Validated adapter map.
; @param Path {String} Journal path to read.
; @param Content {VarRef} Receives the bounded text.
; @param Detail {VarRef} Receives a refusal diagnostic.
; @return {Boolean} True only when bounded reading succeeds.
_ConfigTransitionPortReadBounded(Port, Path, &Content, &Detail) {
	global CONFIG_TRANSITION_MAX_WAL_BYTES
	try Result := Port["read_bounded"].Call(Path,
		CONFIG_TRANSITION_MAX_WAL_BYTES)
	catch as Err {
		Detail := "Bounded journal read threw for '" . Path . "': " . Err.Message
		return false
	}
	if !(Result is String) {
		Detail := "Bounded journal read was refused for '" . Path . "'."
		return false
	}
	Content := Result
	return true
}

; Calls a mutating adapter and requires an exact integer success result.
; @param Port {Map} Validated adapter map.
; @param Method {String} Port method name.
; @param Detail {VarRef} Receives a refusal diagnostic.
; @param Args {Array} Arguments forwarded to the port.
; @return {Boolean} True only for integer 1.
_ConfigTransitionPortStatus(Port, Method, &Detail, Args*) {
	try Result := Port[Method].Call(Args*)
	catch as Err {
		Detail := "Filesystem operation '" . Method . "' threw: " . Err.Message
		return false
	}
	if !(Result is Integer) || Result !== 1 {
		Detail := "Filesystem operation '" . Method
			. "' returned a malformed or refused status."
		return false
	}
	return true
}

; Computes and validates a canonical lowercase SHA-256 digest.
; @param Port {Map} Validated adapter map.
; @param Content {String} Text to hash as UTF-8.
; @param Digest {VarRef} Receives the 64-character digest.
; @param Detail {VarRef} Receives a refusal diagnostic.
; @return {Boolean} True only for a canonical digest.
_ConfigTransitionPortHash(Port, Content, &Digest, &Detail) {
	try Result := Port["hash"].Call(Content)
	catch as Err {
		Detail := "Hash adapter threw: " . Err.Message
		return false
	}
	if !(Result is String) || !RegExMatch(Result, "^[0-9a-f]{64}$") {
		Detail := "Hash adapter did not return canonical SHA-256."
		return false
	}
	Digest := Result
	return true
}

; Invokes an optional crash-test seam after a durable commit point.
; @param PauseFn {Callable|0} Optional callback receiving the stable point name.
; @param Point {String} Durable boundary identifier.
_ConfigTransitionPause(PauseFn, Point) {
	if (PauseFn is Integer) && PauseFn == 0
		return
	if !HasMethod(PauseFn, "Call")
		throw TypeError("Config transition pause seam must be callable.")
	PauseFn.Call(Point)
}





; ==============================================
; ==============================================
; ======= 2/ Strict Paths, Codec, Schema =======
; ==============================================
; ==============================================

; Normalizes a strict absolute Windows file path or refuses it.
; @param Path {String} Candidate drive or UNC path.
; @return {String|false} Canonical backslash path, or false.
_ConfigTransitionNormalizePath(Path) {
	global CONFIG_TRANSITION_MAX_PATH_CHARS
	global CONFIG_TRANSITION_MAX_COMPONENT_CHARS
	if !(Path is String) || Path == ""
		return false
	Normalized := StrReplace(Path, "/", "\")
	if StrLen(Normalized) > CONFIG_TRANSITION_MAX_PATH_CHARS
		return false
	if Trim(Normalized) !== Normalized || SubStr(Normalized, -1) == "\"
		return false
	Loop Parse, Normalized {
		if Ord(A_LoopField) < 32
			return false
	}
	for Forbidden in [Chr(34), "<", ">", "|", "*", "?"] {
		if InStr(Normalized, Forbidden, true)
			return false
	}
	if RegExMatch(Normalized, "^[A-Za-z]:\\") {
		if InStr(SubStr(Normalized, 4), ":", true)
			return false
		Segments := StrSplit(SubStr(Normalized, 4), "\")
	} else if SubStr(Normalized, 1, 2) == "\\" {
		if InStr(Normalized, ":", true)
			return false
		Segments := StrSplit(SubStr(Normalized, 3), "\")
		if Segments.Length < 3
			return false
	} else {
		return false
	}
	if Segments.Length == 0
		return false
	for Segment in Segments {
		if Segment == "" || Segment == "." || Segment == ".."
			|| StrLen(Segment) > CONFIG_TRANSITION_MAX_COMPONENT_CHARS
			|| RegExMatch(Segment, "[ .]$")
			return false
		BaseName := StrSplit(Segment, ".")[1]
		if RegExMatch(BaseName, "i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$")
			return false
	}
	return Normalized
}

; Returns the case-insensitive lexical identity used for collision checks.
; @param Path {String} Already-normalized Windows path.
; @return {String} Case-folded path key.
_ConfigTransitionPathKey(Path) {
	return StrLower(StrReplace(Path, "/", "\"))
}

; Derives the journal beside the stable paths.toml locator.
; @param PathsFile {String} Absolute stable locator path.
; @return {String|false} Journal path, or false for an invalid locator.
ConfigTransitionWalPath(PathsFile) {
	global CONFIG_TRANSITION_WAL_SUFFIX
	Normalized := _ConfigTransitionNormalizePath(PathsFile)
	if !(Normalized is String)
		return false
	return _ConfigTransitionNormalizePath(Normalized
		. CONFIG_TRANSITION_WAL_SUFFIX)
}

; Validates a transaction identifier safe for deterministic sibling names.
; @param TxId {String} Candidate transaction identifier.
; @return {Boolean} True when the identifier is canonical.
_ConfigTransitionTxIdIsValid(TxId) {
	global CONFIG_TRANSITION_MAX_TX_ID_CHARS
	return (TxId is String)
		&& RegExMatch(TxId, "^[A-Za-z0-9_-]{1,"
			. CONFIG_TRANSITION_MAX_TX_ID_CHARS . "}$")
}

; Generates a process-local collision-resistant transaction identifier.
; @return {String} Filesystem-safe identifier.
_ConfigTransitionNewId() {
	static Sequence := 0
	Sequence += 1
	return Format("{}_{:x}_{:x}_{:x}", A_NowUTC, A_ScriptHwnd,
		A_TickCount, Sequence)
}

; Encodes a string as uppercase UTF-8 hexadecimal without a terminator.
; @param Text {String} String to encode.
; @return {String|false} Canonical hexadecimal, or false for a non-string.
_ConfigTransitionEncodeHex(Text) {
	if !(Text is String)
		return false
	ByteCapacity := StrPut(Text, "UTF-8")
	Bytes := Buffer(ByteCapacity, 0)
	Written := StrPut(Text, Bytes, "UTF-8")
	Hex := ""
	Loop Written - 1
		Hex .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Hex
}

; Decodes canonical uppercase UTF-8 hexadecimal with a round-trip check.
; @param Hex {String} Encoded field.
; @return {Map} Result with ok and value fields.
_ConfigTransitionDecodeHex(Hex) {
	if !(Hex is String) || Mod(StrLen(Hex), 2) != 0
		return Map("ok", 0, "value", "")
	if Hex != "" && !RegExMatch(Hex, "^[0-9A-F]+$")
		return Map("ok", 0, "value", "")
	ByteCount := StrLen(Hex) // 2
	if ByteCount == 0
		return Map("ok", 1, "value", "")
	Bytes := Buffer(ByteCount + 1, 0)
	Loop ByteCount {
		NumPut("UChar", Integer("0x" . SubStr(Hex,
			(A_Index - 1) * 2 + 1, 2)), Bytes, A_Index - 1)
	}
	try Value := StrGet(Bytes.Ptr, ByteCount, "UTF-8")
	catch
		return Map("ok", 0, "value", "")
	RoundTrip := _ConfigTransitionEncodeHex(Value)
	if !(RoundTrip is String) || RoundTrip !== Hex
		return Map("ok", 0, "value", "")
	return Map("ok", 1, "value", Value)
}

; Tests whether a presence/hash pair is internally canonical.
; @param Present {Integer} Exact 0 or 1 presence bit.
; @param Hash {String} SHA-256 or the absent sentinel.
; @return {Boolean} True when the pair is valid.
_ConfigTransitionPresenceHashIsValid(Present, Hash) {
	global CONFIG_TRANSITION_HASH_ABSENT
	if !(Present is Integer) || (Present !== 0 && Present !== 1)
		return false
	if !(Hash is String)
		return false
	return Present
		? RegExMatch(Hash, "^[0-9a-f]{64}$")
		: Hash == CONFIG_TRANSITION_HASH_ABSENT
}

; Returns true only for one of the four durable recovery phases.
; @param Phase {String} Candidate phase.
; @return {Boolean} True when recognized.
_ConfigTransitionPhaseIsValid(Phase) {
	if !(Phase is String)
		return false
	for ValidPhase in _ConfigTransitionPhases() {
		if Phase == ValidPhase
			return true
	}
	return false
}

; Returns the canonical durable phase order for validation and cleanup.
; @return {Array} Four immutable phase identifiers.
_ConfigTransitionPhases() {
	global CONFIG_TRANSITION_PHASE_PREPARED
	global CONFIG_TRANSITION_PHASE_APPLYING
	global CONFIG_TRANSITION_PHASE_COMMITTED_NEW
	global CONFIG_TRANSITION_PHASE_COMMITTED_OLD
	return [CONFIG_TRANSITION_PHASE_PREPARED,
		CONFIG_TRANSITION_PHASE_APPLYING,
		CONFIG_TRANSITION_PHASE_COMMITTED_NEW,
		CONFIG_TRANSITION_PHASE_COMMITTED_OLD]
}

; Derives immutable and transient artifact paths for one target.
; @param TargetPath {String} Normalized target path.
; @param TxId {String} Validated transaction identifier.
; @return {Map} Complete same-directory artifact namespace.
_ConfigTransitionArtifactPaths(TargetPath, TxId) {
	global CONFIG_TRANSITION_ARTIFACT_TAG
	Base := TargetPath . CONFIG_TRANSITION_ARTIFACT_TAG . TxId
	return Map(
		"old", Base . ".old",
		"new", Base . ".new",
		"publish_old", Base . ".publish-old",
		"publish_new", Base . ".publish-new")
}

; Derives the private stage used to publish a new journal frame.
; @param WalPath {String} Live journal path.
; @param TxId {String} Validated transaction identifier.
; @param Phase {String} Durable phase carried by this private frame.
; @return {String} Same-directory journal stage.
_ConfigTransitionWalStagePath(WalPath, TxId, Phase) {
	return WalPath . "." . TxId . "." . Phase . ".stage"
}

; Validates record shape, target uniqueness, and every derived path collision.
; @param Record {Map} Candidate in-memory journal record.
; @param PathsFile {String} Stable locator used to derive the live journal.
; @return {Boolean} True only for the exact supported schema.
_ConfigTransitionRecordIsValid(Record, PathsFile) {
	global CONFIG_TRANSITION_WAL_VERSION, CONFIG_TRANSITION_MAX_TARGETS
	if !(Record is Map) || Record.Count != 5
		return false
	for Key in ["version", "phase", "tx_id", "locator", "targets"] {
		if !Record.Has(Key)
			return false
	}
	if !(Record["version"] is Integer)
		|| Record["version"] !== CONFIG_TRANSITION_WAL_VERSION
		|| !_ConfigTransitionPhaseIsValid(Record["phase"])
		|| !_ConfigTransitionTxIdIsValid(Record["tx_id"])
		|| !(Record["targets"] is Array)
		|| Record["targets"].Length < 1
		|| Record["targets"].Length > CONFIG_TRANSITION_MAX_TARGETS
		return false
	WalPath := ConfigTransitionWalPath(PathsFile)
	NormalizedPathsFile := _ConfigTransitionNormalizePath(PathsFile)
	if !(WalPath is String) || !(NormalizedPathsFile is String)
		return false
	RecordLocator := _ConfigTransitionNormalizePath(Record["locator"])
	if !(RecordLocator is String) || RecordLocator !== Record["locator"]
		|| _ConfigTransitionPathKey(RecordLocator)
			!= _ConfigTransitionPathKey(NormalizedPathsFile)
		return false
	LocatorKey := _ConfigTransitionPathKey(NormalizedPathsFile)
	Occupied := Map(
		_ConfigTransitionPathKey(WalPath), "wal",
		LocatorKey, "locator")
	for Phase in _ConfigTransitionPhases() {
		WalStage := _ConfigTransitionWalStagePath(WalPath, Record["tx_id"], Phase)
		for Candidate in [WalStage, WalStage . ".tmp"] {
			if !(_ConfigTransitionNormalizePath(Candidate) is String)
				|| Occupied.Has(_ConfigTransitionPathKey(Candidate))
				return false
			Occupied[_ConfigTransitionPathKey(Candidate)] := "wal_stage"
		}
	}
	for Index, Target in Record["targets"] {
		if !(Target is Map) || Target.Count != 5
			return false
		for Key in ["path", "old_present", "old_hash", "new_present",
				"new_hash"] {
			if !Target.Has(Key)
				return false
		}
		Path := _ConfigTransitionNormalizePath(Target["path"])
		if !(Path is String) || Path !== Target["path"]
			|| !_ConfigTransitionPresenceHashIsValid(Target["old_present"],
				Target["old_hash"])
			|| !_ConfigTransitionPresenceHashIsValid(Target["new_present"],
				Target["new_hash"])
			return false
		TargetKey := _ConfigTransitionPathKey(Path)
		; The locator is reserved against derived artifacts. Only its explicit
		; final target is allowed to claim that name during a relocation
		if TargetKey == LocatorKey {
			if Index != Record["targets"].Length
				return false
			Occupied.Delete(TargetKey)
		}
		if Occupied.Has(TargetKey)
			return false
		Occupied[TargetKey] := "target"
		Artifacts := _ConfigTransitionArtifactPaths(Path, Record["tx_id"])
		for _, ArtifactPath in Artifacts {
			for Candidate in [ArtifactPath, ArtifactPath . ".tmp"] {
				if !(_ConfigTransitionNormalizePath(Candidate) is String)
					|| Occupied.Has(_ConfigTransitionPathKey(Candidate))
					return false
				Occupied[_ConfigTransitionPathKey(Candidate)] := "artifact"
			}
		}
	}
	return true
}

; Serializes one exact record into a bounded line-oriented frame.
; @param Record {Map} Validated record.
; @param PathsFile {String} Stable locator used for contextual validation.
; @return {String|false} Canonical frame, or false.
_ConfigTransitionSerialize(Record, PathsFile) {
	global CONFIG_TRANSITION_WAL_HEADER, CONFIG_TRANSITION_MAX_WAL_BYTES
	if !_ConfigTransitionRecordIsValid(Record, PathsFile)
		return false
	Lines := [CONFIG_TRANSITION_WAL_HEADER,
		"version=" . Record["version"],
		"phase=" . Record["phase"],
		"tx_id=" . Record["tx_id"],
		"locator=" . _ConfigTransitionEncodeHex(Record["locator"]),
		"target_count=" . Record["targets"].Length]
	for Index, Target in Record["targets"] {
		Prefix := "target." . Index . "."
		Lines.Push(Prefix . "path=" . _ConfigTransitionEncodeHex(Target["path"]))
		Lines.Push(Prefix . "old_present=" . Target["old_present"])
		Lines.Push(Prefix . "old_hash=" . Target["old_hash"])
		Lines.Push(Prefix . "new_present=" . Target["new_present"])
		Lines.Push(Prefix . "new_hash=" . Target["new_hash"])
	}
	Content := ""
	for Index, Line in Lines
		Content .= (Index > 1 ? "`n" : "") . Line
	return (StrPut(Content, "UTF-8") - 1 <= CONFIG_TRANSITION_MAX_WAL_BYTES)
		? Content : false
}

; Parses only the exact supported frame and rejects trailing or unknown fields.
; @param Content {String} Raw bounded journal content.
; @param PathsFile {String} Stable locator used for contextual path validation.
; @return {Map|false} Validated record, or false.
_ConfigTransitionParse(Content, PathsFile) {
	global CONFIG_TRANSITION_WAL_HEADER, CONFIG_TRANSITION_MAX_WAL_BYTES
	global CONFIG_TRANSITION_WAL_VERSION, CONFIG_TRANSITION_MAX_TARGETS
	if !(Content is String) || Content == "" || InStr(Content, "`r", true)
		|| StrPut(Content, "UTF-8") - 1 > CONFIG_TRANSITION_MAX_WAL_BYTES
		return false
	Lines := StrSplit(Content, "`n")
	if Lines.Length < 11 || Lines[1] !== CONFIG_TRANSITION_WAL_HEADER
		|| Lines[2] !== "version=" . CONFIG_TRANSITION_WAL_VERSION
		return false
	if !RegExMatch(Lines[3], "^phase=(.+)$", &PhaseMatch)
		|| !_ConfigTransitionPhaseIsValid(PhaseMatch[1])
		|| !RegExMatch(Lines[4], "^tx_id=([A-Za-z0-9_-]+)$", &TxMatch)
		|| !_ConfigTransitionTxIdIsValid(TxMatch[1])
		|| !RegExMatch(Lines[5], "^locator=([0-9A-F]+)$", &LocatorMatch)
		|| !RegExMatch(Lines[6], "^target_count=([0-9])$", &CountMatch)
		return false
	DecodedLocator := _ConfigTransitionDecodeHex(LocatorMatch[1])
	if !DecodedLocator["ok"]
		return false
	TargetCount := Integer(CountMatch[1])
	if TargetCount < 1 || TargetCount > CONFIG_TRANSITION_MAX_TARGETS
		|| Lines.Length != 6 + (TargetCount * 5)
		return false
	Targets := []
	Loop TargetCount {
		Index := A_Index
		Offset := 7 + ((Index - 1) * 5)
		Prefix := "target\." . Index . "\."
		if !RegExMatch(Lines[Offset], "^" . Prefix . "path=([0-9A-F]+)$",
				&PathMatch)
			|| !RegExMatch(Lines[Offset + 1], "^" . Prefix
				. "old_present=([01])$", &OldPresentMatch)
			|| !RegExMatch(Lines[Offset + 2], "^" . Prefix
				. "old_hash=(-|[0-9a-f]{64})$", &OldHashMatch)
			|| !RegExMatch(Lines[Offset + 3], "^" . Prefix
				. "new_present=([01])$", &NewPresentMatch)
			|| !RegExMatch(Lines[Offset + 4], "^" . Prefix
				. "new_hash=(-|[0-9a-f]{64})$", &NewHashMatch)
			return false
		DecodedPath := _ConfigTransitionDecodeHex(PathMatch[1])
		if !DecodedPath["ok"]
			return false
		Targets.Push(Map(
			"path", DecodedPath["value"],
			"old_present", Integer(OldPresentMatch[1]),
			"old_hash", OldHashMatch[1],
			"new_present", Integer(NewPresentMatch[1]),
			"new_hash", NewHashMatch[1]))
	}
	Record := Map(
		"version", CONFIG_TRANSITION_WAL_VERSION,
		"phase", PhaseMatch[1],
		"tx_id", TxMatch[1],
		"locator", DecodedLocator["value"],
		"targets", Targets)
	return _ConfigTransitionRecordIsValid(Record, PathsFile) ? Record : false
}





; =================================================
; =================================================
; ======= 3/ Immutable Artifact Publication =======
; =================================================
; =================================================

; Reads a path snapshot and computes its hash when present.
; @param Port {Map} Validated adapter map.
; @param Path {String} Target or artifact path.
; @param Bounded {Boolean} Whether the path carries a bounded WAL frame.
; @return {Map} Typed result containing snapshot on success.
_ConfigTransitionReadSnapshot(Port, Path, Bounded := false) {
	if !_ConfigTransitionPortExists(Port, Path, &Exists, &Detail)
		return _ConfigTransitionResult("retry", "existence_unreadable", Detail)
	if !Exists {
		return Map("status", "ok", "kind", "snapshot", "detail", "",
			"record", false, "snapshot", Map("present", 0,
				"hash", CONFIG_TRANSITION_HASH_ABSENT, "content", ""))
	}
	ReadSucceeded := Bounded
		? _ConfigTransitionPortReadBounded(Port, Path, &Content, &Detail)
		: _ConfigTransitionPortRead(Port, Path, &Content, &Detail)
	if !ReadSucceeded
		return _ConfigTransitionResult("retry", "content_unreadable", Detail)
	if !_ConfigTransitionPortHash(Port, Content, &Digest, &Detail)
		return _ConfigTransitionResult("retry", "hash_refused", Detail)
	return Map("status", "ok", "kind", "snapshot", "detail", "",
		"record", false, "snapshot", Map("present", 1,
			"hash", Digest, "content", Content))
}

; Tests one snapshot against a known presence/hash state.
; @param Snapshot {Map} Snapshot from _ConfigTransitionReadSnapshot.
; @param Present {Integer} Expected presence bit.
; @param Hash {String} Expected hash or absent sentinel.
; @return {Boolean} True when the state is exactly known.
_ConfigTransitionSnapshotMatches(Snapshot, Present, Hash) {
	return Snapshot["present"] == Present
		&& Snapshot["hash"] == Hash
}

; Publishes immutable content through a verified private temp and no-replace move.
; @param Port {Map} Validated adapter map.
; @param Destination {String} Authoritative artifact path.
; @param Content {String} Exact artifact content.
; @param ExpectedHash {String} Canonical content digest.
; @param Bounded {Boolean} Whether destination and temp carry WAL frames.
; @return {Map} Typed publication result.
_ConfigTransitionPublishCreate(Port, Destination, Content, ExpectedHash,
		Bounded := false) {
	TempPath := Destination . ".tmp"
	DestinationResult := _ConfigTransitionReadSnapshot(Port, Destination, Bounded)
	if DestinationResult["status"] !== "ok"
		return DestinationResult
	if DestinationResult["snapshot"]["present"] {
		if _ConfigTransitionSnapshotMatches(DestinationResult["snapshot"], 1,
				ExpectedHash)
			return _ConfigTransitionResult("ok", "artifact_already_published")
		return _ConfigTransitionResult("fatal", "artifact_conflict",
			"Create-only artifact has an unknown hash: '" . Destination . "'.")
	}
	TempSnapshotResult := _ConfigTransitionReadSnapshot(Port, TempPath, Bounded)
	if TempSnapshotResult["status"] !== "ok"
		return TempSnapshotResult
	if !TempSnapshotResult["snapshot"]["present"] {
		; The second namespace boundary must remain atomic with the write, not
		; just preflighted here; replacement is forbidden even for private temps
		WriteSucceeded := _ConfigTransitionPortStatus(Port,
			"write_create_durable",
			&Detail, TempPath, Content)
		if !WriteSucceeded {
			RacedResult := _ConfigTransitionReadSnapshot(Port, TempPath, Bounded)
			if RacedResult["status"] !== "ok"
				return RacedResult
			if RacedResult["snapshot"]["present"] {
				if _ConfigTransitionSnapshotMatches(RacedResult["snapshot"], 1,
						ExpectedHash) {
					TempSnapshotResult := RacedResult
				} else {
					return _ConfigTransitionResult("fatal",
						"artifact_hash_conflict",
						"Create-only private write collided at '"
						. TempPath . "'.")
				}
			} else {
				return _ConfigTransitionResult("retry", "artifact_write_failed",
					Detail)
			}
		} else {
			TempSnapshotResult := _ConfigTransitionReadSnapshot(Port, TempPath,
				Bounded)
			if TempSnapshotResult["status"] !== "ok"
				return TempSnapshotResult
		}
	}
	TempSnapshot := TempSnapshotResult["snapshot"]
	if !_ConfigTransitionSnapshotMatches(TempSnapshot, 1, ExpectedHash)
		return _ConfigTransitionResult("fatal", "artifact_hash_conflict",
			"Private artifact stage failed hash verification: '" . TempPath . "'.")
	if !_ConfigTransitionPortStatus(Port, "move_create", &Detail,
			TempPath, Destination) {
		PublishedResult := _ConfigTransitionReadSnapshot(Port, Destination,
			Bounded)
		if PublishedResult["status"] !== "ok"
			return PublishedResult
		if PublishedResult["snapshot"]["present"] {
			if _ConfigTransitionSnapshotMatches(PublishedResult["snapshot"], 1,
					ExpectedHash) {
				return _ConfigTransitionResult("ok", "artifact_already_published")
			}
			return _ConfigTransitionResult("fatal", "artifact_conflict",
				"Create-only publication collided at '" . Destination . "'.")
		}
		return _ConfigTransitionResult("retry", "artifact_publish_failed", Detail)
	}
	PublishedResult := _ConfigTransitionReadSnapshot(Port, Destination, Bounded)
	if PublishedResult["status"] !== "ok"
		return PublishedResult
	if !_ConfigTransitionSnapshotMatches(PublishedResult["snapshot"], 1,
			ExpectedHash) {
		return _ConfigTransitionResult("fatal", "artifact_hash_conflict",
			"Published artifact failed hash verification: '" . Destination . "'.")
	}
	return _ConfigTransitionResult("ok", "artifact_published")
}

; Reads and verifies one immutable artifact required for recovery.
; @param Port {Map} Validated adapter map.
; @param Path {String} Artifact path.
; @param ExpectedHash {String} Hash recorded by the journal.
; @param Bounded {Boolean} Whether the artifact carries a bounded WAL frame.
; @return {Map} Typed result containing content on success.
_ConfigTransitionReadArtifact(Port, Path, ExpectedHash, Bounded := false) {
	SnapshotResult := _ConfigTransitionReadSnapshot(Port, Path, Bounded)
	if SnapshotResult["status"] !== "ok"
		return SnapshotResult
	Snapshot := SnapshotResult["snapshot"]
	if !_ConfigTransitionSnapshotMatches(Snapshot, 1, ExpectedHash) {
		return _ConfigTransitionResult("fatal", "artifact_hash_conflict",
			"Required artifact is absent or has an unknown hash: '" . Path . "'.")
	}
	return Map("status", "ok", "kind", "artifact", "detail", "",
		"record", false, "content", Snapshot["content"])
}

; Publishes a desired target image from an immutable source artifact.
; @param Port {Map} Validated adapter map.
; @param Target {Map} Validated target record.
; @param Record {Map} Owning transaction record.
; @param Side {String} old or new.
; @param Content {String} Verified desired bytes.
; @return {Map} Typed replacement result.
_ConfigTransitionReplaceTarget(Port, Target, Record, Side, Content) {
	Artifacts := _ConfigTransitionArtifactPaths(Target["path"], Record["tx_id"])
	PublishPath := Artifacts["publish_" . Side]
	DesiredHash := Target[Side . "_hash"]
	if !_ConfigTransitionPortExists(Port, PublishPath, &Exists, &Detail)
		return _ConfigTransitionResult("retry", "publish_probe_failed", Detail)
	if Exists {
		PublishResult := _ConfigTransitionReadArtifact(Port, PublishPath,
			DesiredHash)
		if PublishResult["status"] !== "ok"
			return PublishResult
	} else {
		PublishResult := _ConfigTransitionPublishCreate(Port, PublishPath,
			Content, DesiredHash)
		if PublishResult["status"] !== "ok"
			return PublishResult
	}
	if !_ConfigTransitionPortStatus(Port, "move_replace", &Detail,
			PublishPath, Target["path"])
		return _ConfigTransitionResult("retry", "target_replace_failed", Detail)
	SnapshotResult := _ConfigTransitionReadSnapshot(Port, Target["path"])
	if SnapshotResult["status"] !== "ok"
		return SnapshotResult
	if !_ConfigTransitionSnapshotMatches(SnapshotResult["snapshot"], 1,
			DesiredHash) {
		return _ConfigTransitionResult("fatal", "target_hash_conflict",
			"Published target failed hash verification: '" . Target["path"] . "'.")
	}
	return _ConfigTransitionResult("ok", "target_replaced")
}

; Creates a record clone carrying a new durable phase.
; @param Record {Map} Existing validated record.
; @param Phase {String} New valid phase.
; @return {Map} Detached record clone.
_ConfigTransitionWithPhase(Record, Phase) {
	return Map(
		"version", Record["version"],
		"phase", Phase,
		"tx_id", Record["tx_id"],
		"locator", Record["locator"],
		"targets", Record["targets"])
}

; Publishes the first live journal frame with create-only semantics.
; @param Port {Map} Validated adapter map.
; @param PathsFile {String} Stable locator path.
; @param Record {Map} Prepared journal record.
; @return {Map} Typed publication result.
_ConfigTransitionPublishWalCreate(Port, PathsFile, Record) {
	WalPath := ConfigTransitionWalPath(PathsFile)
	Content := _ConfigTransitionSerialize(Record, PathsFile)
	if !(Content is String)
		return _ConfigTransitionResult("fatal", "wal_schema_invalid",
			"Prepared journal could not be serialized.")
	if !_ConfigTransitionPortHash(Port, Content, &Digest, &Detail)
		return _ConfigTransitionResult("retry", "hash_refused", Detail)
	WalStage := _ConfigTransitionWalStagePath(WalPath, Record["tx_id"],
		Record["phase"])
	StageResult := _ConfigTransitionPublishCreate(Port, WalStage, Content, Digest,
		true)
	if StageResult["status"] !== "ok"
		return StageResult
	if !_ConfigTransitionPortStatus(Port, "move_create", &Detail,
			WalStage, WalPath) {
		CollisionResult := ConfigTransitionInspect(PathsFile, Port)
		if CollisionResult["status"] !== "ok"
			return CollisionResult
		if CollisionResult["kind"] == "absent"
			return _ConfigTransitionResult("retry", "wal_publish_failed", Detail)
		CollisionContent := _ConfigTransitionSerialize(CollisionResult["record"],
			PathsFile)
		if !(CollisionContent is String) || CollisionContent !== Content {
			return _ConfigTransitionResult("fatal", "active_transition",
				"Create-only live journal publication collided with an active WAL.")
		}
	}
	if !_ConfigTransitionPortReadBounded(Port, WalPath, &Published, &Detail)
		return _ConfigTransitionResult("retry", "wal_unreadable_after_publish", Detail)
	if Published !== Content {
		return _ConfigTransitionResult("fatal", "wal_publish_conflict",
			"Live journal differs from its verified create-only frame.")
	}
	return _ConfigTransitionResult("ok", "wal_published", "", Record)
}

; Atomically replaces the live journal with a verified later phase frame.
; @param Port {Map} Validated adapter map.
; @param PathsFile {String} Stable locator path.
; @param Record {Map} New-phase journal record.
; @return {Map} Typed phase publication result.
_ConfigTransitionPublishWalReplace(Port, PathsFile, Record) {
	WalPath := ConfigTransitionWalPath(PathsFile)
	Content := _ConfigTransitionSerialize(Record, PathsFile)
	if !(Content is String)
		return _ConfigTransitionResult("fatal", "wal_schema_invalid",
			"Replacement journal frame could not be serialized.")
	if !_ConfigTransitionPortHash(Port, Content, &Digest, &Detail)
		return _ConfigTransitionResult("retry", "hash_refused", Detail)
	WalStage := _ConfigTransitionWalStagePath(WalPath, Record["tx_id"],
		Record["phase"])
	if !_ConfigTransitionPortExists(Port, WalStage, &Exists, &Detail)
		return _ConfigTransitionResult("retry", "wal_stage_probe_failed", Detail)
	if Exists {
		StageResult := _ConfigTransitionReadArtifact(Port, WalStage, Digest, true)
		if StageResult["status"] !== "ok"
			return StageResult
	} else {
		StageResult := _ConfigTransitionPublishCreate(Port, WalStage,
			Content, Digest, true)
		if StageResult["status"] !== "ok"
			return StageResult
	}
	if !_ConfigTransitionPortStatus(Port, "move_replace", &Detail,
			WalStage, WalPath)
		return _ConfigTransitionResult("retry", "wal_phase_publish_failed", Detail)
	if !_ConfigTransitionPortReadBounded(Port, WalPath, &Published, &Detail)
		return _ConfigTransitionResult("retry", "wal_phase_unreadable", Detail)
	if Published !== Content {
		return _ConfigTransitionResult("fatal", "wal_phase_conflict",
			"Published journal phase differs from its verified frame.")
	}
	return _ConfigTransitionResult("ok", "wal_phase_published", "", Record)
}





; ============================================
; ============================================
; ======= 4/ Prepare and Ordered Apply =======
; ============================================
; ============================================

; Inspects the bounded live journal without modifying any path.
; @param PathsFile {String} Absolute stable paths.toml locator.
; @param Port {Map} Injected filesystem and hash adapters.
; @return {Map} absent, ready, quarantine, retry, or fatal result.
ConfigTransitionInspect(PathsFile, Port) {
	Port := _ConfigTransitionResolvePort(Port)
	WalPath := ConfigTransitionWalPath(PathsFile)
	if !(Port is Map) || !(WalPath is String)
		return _ConfigTransitionResult("fatal", "invalid_arguments",
			"Config transition locator or port is invalid.")
	if !_ConfigTransitionPortExists(Port, WalPath, &Exists, &Detail)
		return _ConfigTransitionResult("retry", "wal_probe_failed", Detail)
	if !Exists
		return _ConfigTransitionResult("ok", "absent")
	if !_ConfigTransitionPortReadBounded(Port, WalPath, &Content, &Detail) {
		return _ConfigTransitionResult("quarantine", "wal_unreadable", Detail)
	}
	try Record := _ConfigTransitionParse(Content, PathsFile)
	catch as Err {
		return _ConfigTransitionResult("quarantine", "wal_malformed",
			"Live config transition journal raised during strict validation: "
			. Err.Message)
	}
	if !(Record is Map) {
		return _ConfigTransitionResult("quarantine", "wal_malformed",
			"Live config transition journal failed strict validation.")
	}
	return _ConfigTransitionResult("ok", "ready", "", Record)
}

; Reads old target snapshots and builds a detached prepared record.
; @param PathsFile {String} Stable locator path.
; @param TargetSpecs {Array} Exact path/new_present/new_content maps.
; @param Port {Map} Validated adapter map.
; @param TxId {String} Validated transaction identifier.
; @return {Map} Typed result containing the record on success.
_ConfigTransitionBuildPreparedRecord(PathsFile, TargetSpecs, Port, TxId) {
	global CONFIG_TRANSITION_WAL_VERSION, CONFIG_TRANSITION_PHASE_PREPARED
	global CONFIG_TRANSITION_MAX_TARGETS, CONFIG_TRANSITION_HASH_ABSENT
	if !(TargetSpecs is Array) || TargetSpecs.Length < 1
		|| TargetSpecs.Length > CONFIG_TRANSITION_MAX_TARGETS
		return _ConfigTransitionResult("fatal", "target_count_invalid")
	Targets := []
	for Spec in TargetSpecs {
		if !(Spec is Map) || (Spec.Count != 3 && Spec.Count != 4)
			return _ConfigTransitionResult("fatal", "target_schema_invalid")
		for Key in ["path", "new_present", "new_content"] {
			if !Spec.Has(Key)
				return _ConfigTransitionResult("fatal", "target_schema_invalid")
		}
		if Spec.Count == 4 && !Spec.Has("expected_old")
			return _ConfigTransitionResult("fatal", "target_schema_invalid")
		Path := _ConfigTransitionNormalizePath(Spec["path"])
		NewPresent := Spec["new_present"]
		NewContent := Spec["new_content"]
		if !(Path is String) || !(NewPresent is Integer)
			|| (NewPresent !== 0 && NewPresent !== 1)
			|| !(NewContent is String) || (!NewPresent && NewContent !== "")
			return _ConfigTransitionResult("fatal", "target_schema_invalid")
		OldResult := _ConfigTransitionReadSnapshot(Port, Path)
		if OldResult["status"] !== "ok"
			return OldResult
		OldSnapshot := OldResult["snapshot"]
		if Spec.Has("expected_old") {
			Expected := Spec["expected_old"]
			if !(Expected is Map) || Expected.Count != 2
					|| !Expected.Has("present") || !Expected.Has("hash")
					|| !(Expected["present"] is Integer)
					|| (Expected["present"] !== 0 && Expected["present"] !== 1)
					|| !(Expected["hash"] is String)
					|| (Expected["present"] == 0
						&& Expected["hash"] !== CONFIG_TRANSITION_HASH_ABSENT)
					|| (Expected["present"] == 1
						&& !_ConfigTransitionPresenceHashIsValid(1,
							Expected["hash"]))
				return _ConfigTransitionResult("fatal",
					"expected_old_schema_invalid")
			if OldSnapshot["present"] !== Expected["present"]
					|| OldSnapshot["hash"] !== Expected["hash"] {
				return _ConfigTransitionResult("retry",
					"expected_old_conflict",
					"The target changed after its detached candidate was built.")
			}
		}
		if NewPresent {
			if !_ConfigTransitionPortHash(Port, NewContent, &NewHash, &Detail)
				return _ConfigTransitionResult("retry", "hash_refused", Detail)
		} else {
			NewHash := CONFIG_TRANSITION_HASH_ABSENT
		}
		Targets.Push(Map(
			"path", Path,
			"old_present", OldSnapshot["present"],
			"old_hash", OldSnapshot["hash"],
			"new_present", NewPresent,
			"new_hash", NewHash,
			"old_content", OldSnapshot["content"],
			"new_content", NewContent))
	}
	SchemaTargets := []
	for Target in Targets {
		SchemaTargets.Push(Map(
			"path", Target["path"],
			"old_present", Target["old_present"],
			"old_hash", Target["old_hash"],
			"new_present", Target["new_present"],
			"new_hash", Target["new_hash"]))
	}
	Record := Map(
		"version", CONFIG_TRANSITION_WAL_VERSION,
		"phase", CONFIG_TRANSITION_PHASE_PREPARED,
		"tx_id", TxId,
		"locator", PathsFile,
		"targets", SchemaTargets)
	if !_ConfigTransitionRecordIsValid(Record, PathsFile)
		return _ConfigTransitionResult("fatal", "target_collision")
	return Map("status", "ok", "kind", "record_built", "detail", "",
		"record", Record, "material", Targets)
}

; Verifies that no transition-owned artifact name exists before preparation.
; @param PathsFile {String} Stable locator path.
; @param Record {Map} Validated prepared record.
; @param Port {Map} Validated adapter map.
; @return {Map} Typed namespace result.
_ConfigTransitionNamespaceIsFree(PathsFile, Record, Port) {
	WalPath := ConfigTransitionWalPath(PathsFile)
	Candidates := []
	for Phase in _ConfigTransitionPhases() {
		WalStage := _ConfigTransitionWalStagePath(WalPath, Record["tx_id"], Phase)
		Candidates.Push(WalStage)
		Candidates.Push(WalStage . ".tmp")
	}
	for Target in Record["targets"] {
		Artifacts := _ConfigTransitionArtifactPaths(Target["path"], Record["tx_id"])
		for _, ArtifactPath in Artifacts {
			Candidates.Push(ArtifactPath)
			Candidates.Push(ArtifactPath . ".tmp")
		}
	}
	for Candidate in Candidates {
		if !_ConfigTransitionPortExists(Port, Candidate, &Exists, &Detail)
			return _ConfigTransitionResult("retry", "namespace_probe_failed", Detail)
		if Exists {
			return _ConfigTransitionResult("fatal", "artifact_conflict",
				"Transition artifact namespace is already occupied: '"
				. Candidate . "'.")
		}
	}
	return _ConfigTransitionResult("ok", "namespace_free")
}

; Publishes write-ahead authority before preparing immutable backups and stages.
; @param PathsFile {String} Absolute stable paths.toml locator.
; @param TargetSpecs {Array} Ordered target intentions.
; @param Port {Map} Injected filesystem and hash adapters.
; @param TxId {String} Optional deterministic identifier for tests.
; @param PauseFn {Callable|0} Optional crash seam.
; @return {Map} Typed prepared result.
ConfigTransitionPrepare(PathsFile, TargetSpecs, Port, TxId := "",
		PauseFn := 0) {
	Port := _ConfigTransitionResolvePort(Port)
	NormalizedPathsFile := _ConfigTransitionNormalizePath(PathsFile)
	if !(Port is Map) || !(NormalizedPathsFile is String)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	if TxId == ""
		TxId := _ConfigTransitionNewId()
	if !_ConfigTransitionTxIdIsValid(TxId)
		return _ConfigTransitionResult("fatal", "tx_id_invalid")
	Existing := ConfigTransitionInspect(NormalizedPathsFile, Port)
	if Existing["status"] !== "ok" || Existing["kind"] !== "absent" {
		if Existing["status"] == "ok"
			return _ConfigTransitionResult("fatal", "active_transition",
				"A valid config transition is already active.", Existing["record"])
		return Existing
	}
	Built := _ConfigTransitionBuildPreparedRecord(NormalizedPathsFile,
		TargetSpecs, Port, TxId)
	if Built["status"] !== "ok"
		return Built
	Record := Built["record"]
	if !(_ConfigTransitionSerialize(Record, NormalizedPathsFile) is String) {
		return _ConfigTransitionResult("fatal", "wal_size_invalid",
			"Prepared intent cannot fit the bounded journal.")
	}
	FreeResult := _ConfigTransitionNamespaceIsFree(NormalizedPathsFile,
		Record, Port)
	if FreeResult["status"] !== "ok"
		return FreeResult
	; The live frame must precede every transition-owned content artifact. A
	; crash during their publication then leaves a discoverable prepared WAL,
	; whose phase deterministically cleans the still-untouched old target image
	PublishResult := _ConfigTransitionPublishWalCreate(Port,
		NormalizedPathsFile, Record)
	if PublishResult["status"] !== "ok"
		return PublishResult
	_ConfigTransitionPause(PauseFn, "phase:prepared")
	for Index, Target in Record["targets"] {
		Material := Built["material"][Index]
		Artifacts := _ConfigTransitionArtifactPaths(Target["path"], TxId)
		if Target["old_present"] {
			Result := _ConfigTransitionPublishCreate(Port, Artifacts["old"],
				Material["old_content"], Target["old_hash"])
			if Result["status"] !== "ok"
				return Result
		}
		if Target["new_present"] {
			Result := _ConfigTransitionPublishCreate(Port, Artifacts["new"],
				Material["new_content"], Target["new_hash"])
			if Result["status"] !== "ok"
				return Result
		}
	}
	return _ConfigTransitionResult("ok", "prepared", "", Record)
}

; Validates both rollback authority and forward stages before entering applying.
; @param Record {Map} Prepared record.
; @param Port {Map} Validated adapter map.
; @return {Map} Typed preflight result.
_ConfigTransitionApplyPreflight(Record, Port) {
	for Target in Record["targets"] {
		SnapshotResult := _ConfigTransitionReadSnapshot(Port, Target["path"])
		if SnapshotResult["status"] !== "ok"
			return SnapshotResult
		if !_ConfigTransitionSnapshotMatches(SnapshotResult["snapshot"],
				Target["old_present"], Target["old_hash"]) {
			return _ConfigTransitionResult("fatal", "target_conflict",
				"Prepared target no longer matches its old snapshot: '"
				. Target["path"] . "'.", Record)
		}
		Artifacts := _ConfigTransitionArtifactPaths(Target["path"], Record["tx_id"])
		for Side in ["old", "new"] {
			Present := Target[Side . "_present"]
			ArtifactResult := _ConfigTransitionReadSnapshot(Port, Artifacts[Side])
			if ArtifactResult["status"] !== "ok"
				return ArtifactResult
			if Present {
				if !_ConfigTransitionSnapshotMatches(ArtifactResult["snapshot"], 1,
						Target[Side . "_hash"])
					return _ConfigTransitionResult("fatal", "artifact_hash_conflict",
						"Transition artifact failed apply preflight: '"
						. Artifacts[Side] . "'.", Record)
			} else if ArtifactResult["snapshot"]["present"] {
				return _ConfigTransitionResult("fatal", "artifact_conflict",
					"Unexpected artifact exists for an absent state: '"
					. Artifacts[Side] . "'.", Record)
			}
		}
	}
	return _ConfigTransitionResult("ok", "apply_preflight", "", Record)
}

; Preflights a deterministic all-old or all-new realization plan.
; @param Record {Map} Validated journal record.
; @param Port {Map} Validated adapter map.
; @param Side {String} old or new.
; @return {Map} Typed result containing an ordered plan.
_ConfigTransitionBuildRealizePlan(Record, Port, Side) {
	Plan := []
	for Index, Target in Record["targets"] {
		SnapshotResult := _ConfigTransitionReadSnapshot(Port, Target["path"])
		if SnapshotResult["status"] !== "ok"
			return SnapshotResult
		Snapshot := SnapshotResult["snapshot"]
		OldMatch := _ConfigTransitionSnapshotMatches(Snapshot,
			Target["old_present"], Target["old_hash"])
		NewMatch := _ConfigTransitionSnapshotMatches(Snapshot,
			Target["new_present"], Target["new_hash"])
		if !OldMatch && !NewMatch {
			return _ConfigTransitionResult("fatal", "target_conflict",
				"Target matches neither journal side: '" . Target["path"] . "'.",
				Record)
		}
		DesiredMatch := (Side == "old") ? OldMatch : NewMatch
		if DesiredMatch
			continue
		DesiredPresent := Target[Side . "_present"]
		Content := ""
		if DesiredPresent {
			Artifacts := _ConfigTransitionArtifactPaths(Target["path"],
				Record["tx_id"])
			ArtifactResult := _ConfigTransitionReadArtifact(Port, Artifacts[Side],
				Target[Side . "_hash"])
			if ArtifactResult["status"] !== "ok"
				return ArtifactResult
			Content := ArtifactResult["content"]
		}
		Plan.Push(Map("index", Index, "content", Content))
	}
	return Map("status", "ok", "kind", "realize_plan", "detail", "",
		"record", Record, "plan", Plan)
}

; Executes a fully preflighted ordered realization plan.
; @param Record {Map} Validated journal record.
; @param Port {Map} Validated adapter map.
; @param Side {String} old or new.
; @param Plan {Array} Ordered plan from _ConfigTransitionBuildRealizePlan.
; @param PauseFn {Callable|0} Optional crash seam.
; @return {Map} Typed realization result.
_ConfigTransitionExecuteRealizePlan(Record, Port, Side, Plan, PauseFn) {
	for Entry in Plan {
		Index := Entry["index"]
		Target := Record["targets"][Index]
		SnapshotResult := _ConfigTransitionReadSnapshot(Port, Target["path"])
		if SnapshotResult["status"] !== "ok"
			return SnapshotResult
		Snapshot := SnapshotResult["snapshot"]
		OldMatch := _ConfigTransitionSnapshotMatches(Snapshot,
			Target["old_present"], Target["old_hash"])
		NewMatch := _ConfigTransitionSnapshotMatches(Snapshot,
			Target["new_present"], Target["new_hash"])
		if !OldMatch && !NewMatch {
			return _ConfigTransitionResult("fatal", "target_conflict",
				"Target changed after transition preflight: '"
				. Target["path"] . "'.", Record)
		}
		DesiredMatch := (Side == "old") ? OldMatch : NewMatch
		if DesiredMatch
			continue
		if Target[Side . "_present"] {
			Result := _ConfigTransitionReplaceTarget(Port, Target, Record,
				Side, Entry["content"])
		} else if !_ConfigTransitionPortStatus(Port, "delete", &Detail,
				Target["path"]) {
			Result := _ConfigTransitionResult("retry", "target_delete_failed", Detail)
		} else {
			Result := _ConfigTransitionResult("ok", "target_deleted")
		}
		if Result["status"] !== "ok"
			return Result
		SettledResult := _ConfigTransitionReadSnapshot(Port, Target["path"])
		if SettledResult["status"] !== "ok"
			return SettledResult
		if !_ConfigTransitionSnapshotMatches(SettledResult["snapshot"],
				Target[Side . "_present"], Target[Side . "_hash"]) {
			return _ConfigTransitionResult("fatal", "target_hash_conflict",
				"Target did not commit before its pause seam: '"
				. Target["path"] . "'.", Record)
		}
		_ConfigTransitionPause(PauseFn, "target:" . Side . ":" . Index)
	}
	return _ConfigTransitionResult("ok", "realized_" . Side, "", Record)
}

; Re-reads every target after an ordered plan so no stale preflight or lying
; adapter can authorize a committed phase for a mixed configuration image.
; @param Record {Map} Validated journal record.
; @param Port {Map} Validated adapter map.
; @param Side {String} old or new.
; @return {Map} Typed side-verification result.
_ConfigTransitionVerifySide(Record, Port, Side) {
	for Target in Record["targets"] {
		SnapshotResult := _ConfigTransitionReadSnapshot(Port, Target["path"])
		if SnapshotResult["status"] !== "ok"
			return SnapshotResult
		if !_ConfigTransitionSnapshotMatches(SnapshotResult["snapshot"],
				Target[Side . "_present"], Target[Side . "_hash"]) {
			return _ConfigTransitionResult("fatal", "target_hash_conflict",
				"Target did not settle to the journal's " . Side . " hash: '"
				. Target["path"] . "'.", Record)
		}
	}
	return _ConfigTransitionResult("ok", "verified_" . Side, "", Record)
}

; Applies a prepared transition in declared target order and commits new intent.
; @param PathsFile {String} Absolute stable paths.toml locator.
; @param Port {Map} Injected filesystem and hash adapters.
; @param PauseFn {Callable|0} Optional crash seam.
; @return {Map} Typed committed-new result.
ConfigTransitionApply(PathsFile, Port, PauseFn := 0) {
	Port := _ConfigTransitionResolvePort(Port)
	if !(Port is Map)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	Inspected := ConfigTransitionInspect(PathsFile, Port)
	if Inspected["status"] !== "ok" || Inspected["kind"] !== "ready"
		return Inspected
	Record := Inspected["record"]
	if Record["phase"] !== CONFIG_TRANSITION_PHASE_PREPARED {
		return _ConfigTransitionResult("fatal", "phase_conflict",
			"Apply requires the prepared phase.", Record)
	}
	NamespaceResult := _ConfigTransitionPreflightOwnedNamespace(PathsFile,
		Record, Port)
	if NamespaceResult["status"] !== "ok"
		return NamespaceResult
	Preflight := _ConfigTransitionApplyPreflight(Record, Port)
	if Preflight["status"] !== "ok"
		return Preflight
	DiscardResult := _ConfigTransitionDiscardInterruptedTemps(
		NamespaceResult, Port, Record)
	if DiscardResult["status"] !== "ok"
		return DiscardResult
	ApplyingRecord := _ConfigTransitionWithPhase(Record,
		CONFIG_TRANSITION_PHASE_APPLYING)
	PhaseResult := _ConfigTransitionPublishWalReplace(Port, PathsFile,
		ApplyingRecord)
	if PhaseResult["status"] !== "ok"
		return PhaseResult
	_ConfigTransitionPause(PauseFn, "phase:applying")
	PlanResult := _ConfigTransitionBuildRealizePlan(ApplyingRecord, Port, "new")
	if PlanResult["status"] !== "ok"
		return PlanResult
	RealizeResult := _ConfigTransitionExecuteRealizePlan(ApplyingRecord, Port,
		"new", PlanResult["plan"], PauseFn)
	if RealizeResult["status"] !== "ok"
		return RealizeResult
	VerifyResult := _ConfigTransitionVerifySide(ApplyingRecord, Port, "new")
	if VerifyResult["status"] !== "ok"
		return VerifyResult
	CommittedRecord := _ConfigTransitionWithPhase(ApplyingRecord,
		CONFIG_TRANSITION_PHASE_COMMITTED_NEW)
	PhaseResult := _ConfigTransitionPublishWalReplace(Port, PathsFile,
		CommittedRecord)
	if PhaseResult["status"] !== "ok"
		return PhaseResult
	_ConfigTransitionPause(PauseFn, "phase:committed_new")
	return _ConfigTransitionResult("ok", "committed_new", "", CommittedRecord)
}





; ==============================================
; ==============================================
; ======= 5/ Deterministic Boot Recovery =======
; ==============================================
; ==============================================

; Builds the complete cleanup namespace with the hash each owned file may carry.
; Missing entries are safe after a partial cleanup; present entries must match.
; @param PathsFile {String} Stable locator path.
; @param Record {Map} Validated journal record.
; @param Port {Map} Validated adapter map.
; @return {Map} Typed result containing ordered cleanup entries.
_ConfigTransitionBuildOwnedEntries(PathsFile, Record, Port) {
	WalPath := ConfigTransitionWalPath(PathsFile)
	Entries := []
	for Phase in _ConfigTransitionPhases() {
		PhaseRecord := _ConfigTransitionWithPhase(Record, Phase)
		Content := _ConfigTransitionSerialize(PhaseRecord, PathsFile)
		if !(Content is String) {
			return _ConfigTransitionResult("fatal", "wal_schema_invalid",
				"A cleanup phase frame could not be serialized.", Record)
		}
		if !_ConfigTransitionPortHash(Port, Content, &Digest, &Detail)
			return _ConfigTransitionResult("retry", "hash_refused", Detail, Record)
		WalStage := _ConfigTransitionWalStagePath(WalPath, Record["tx_id"], Phase)
		Entries.Push(Map("path", WalStage . ".tmp", "allowed", 1,
			"hash", Digest, "bounded", 1, "disposable", 1))
		Entries.Push(Map("path", WalStage, "allowed", 1, "hash", Digest,
			"bounded", 1, "disposable", 0))
	}
	for Target in Record["targets"] {
		Artifacts := _ConfigTransitionArtifactPaths(Target["path"], Record["tx_id"])
		for Side in ["old", "new"] {
			Allowed := Target[Side . "_present"]
			ExpectedHash := Target[Side . "_hash"]
			for ArtifactName in [Side, "publish_" . Side] {
				ArtifactPath := Artifacts[ArtifactName]
				Entries.Push(Map("path", ArtifactPath . ".tmp",
					"allowed", Allowed, "hash", ExpectedHash, "bounded", 0,
					"disposable", Allowed ? 1 : 0))
				Entries.Push(Map("path", ArtifactPath,
					"allowed", Allowed, "hash", ExpectedHash, "bounded", 0,
					"disposable", 0))
			}
		}
	}
	return Map("status", "ok", "kind", "cleanup_entries", "detail", "",
		"record", Record, "entries", Entries)
}

; Proves every present cleanup candidate belongs to this exact transaction.
; This entire validation completes before the first delete, so a late namespace
; collision is fatal and byte-preserving rather than mistaken for stale debris.
; @param PathsFile {String} Stable locator path.
; @param Record {Map} Validated journal record.
; @param Port {Map} Validated adapter map.
; @return {Map} Typed ownership-preflight result.
_ConfigTransitionPreflightOwnedNamespace(PathsFile, Record, Port) {
	EntryResult := _ConfigTransitionBuildOwnedEntries(PathsFile, Record, Port)
	if EntryResult["status"] !== "ok"
		return EntryResult
	Discard := []
	for Entry in EntryResult["entries"] {
		SnapshotResult := _ConfigTransitionReadSnapshot(Port, Entry["path"],
			Entry["bounded"])
		if SnapshotResult["status"] !== "ok" {
			if Entry["bounded"] && SnapshotResult["kind"] == "content_unreadable" {
				return _ConfigTransitionResult("fatal", "cleanup_hash_conflict",
					"Bounded WAL-stage bytes cannot be validated: '"
					. Entry["path"] . "'.", Record)
			}
			return SnapshotResult
		}
		Snapshot := SnapshotResult["snapshot"]
		if !Snapshot["present"]
			continue
		if !Entry["allowed"] {
			return _ConfigTransitionResult("fatal", "cleanup_namespace_conflict",
				"Unexpected file occupies an absent-state cleanup name: '"
				. Entry["path"] . "'.", Record)
		}
		if !_ConfigTransitionSnapshotMatches(Snapshot, 1, Entry["hash"]) {
			; A process loss can interrupt WriteFile before its finally block can
			; delete the create-only private temp. The live WAL proves the exact
			; transaction namespace; temps for present sides are disposable only
			; after every authoritative artifact and target has preflighted.
			if Entry["disposable"] {
				Discard.Push(Entry)
				continue
			}
			return _ConfigTransitionResult("fatal", "cleanup_hash_conflict",
				"Cleanup candidate has an unknown hash: '"
				. Entry["path"] . "'.", Record)
		}
	}
	WalPath := ConfigTransitionWalPath(PathsFile)
	ExpectedWal := _ConfigTransitionSerialize(Record, PathsFile)
	if !(ExpectedWal is String)
		return _ConfigTransitionResult("fatal", "wal_schema_invalid", "", Record)
	if !_ConfigTransitionPortReadBounded(Port, WalPath, &ActualWal, &Detail)
		return _ConfigTransitionResult("retry", "wal_cleanup_unreadable", Detail,
			Record)
	if ActualWal !== ExpectedWal {
		return _ConfigTransitionResult("fatal", "wal_cleanup_conflict",
			"The live WAL changed before cleanup could begin.", Record)
	}
	return Map("status", "ok", "kind", "cleanup_preflight", "detail", "",
		"record", Record, "entries", EntryResult["entries"],
		"discard", Discard)
}

; Removes only private temps whose path is owned by the validated live WAL.
; Callers invoke this after target/artifact preflight, never before it.
; @param Preflight {Map} Result from _ConfigTransitionPreflightOwnedNamespace.
; @param Port {Map} Validated adapter map.
; @param Record {Map} Validated live journal record.
; @return {Map} Typed discard result.
_ConfigTransitionDiscardInterruptedTemps(Preflight, Port, Record) {
	if !(Preflight is Map) || !Preflight.Has("discard")
			|| !(Preflight["discard"] is Array)
		return _ConfigTransitionResult("fatal", "discard_schema_invalid", "",
			Record)
	for Entry in Preflight["discard"] {
		if !_ConfigTransitionPortStatus(Port, "delete", &Detail, Entry["path"])
			return _ConfigTransitionResult("retry", "temp_discard_failed", Detail,
				Record)
		SnapshotResult := _ConfigTransitionReadSnapshot(Port, Entry["path"],
			Entry["bounded"])
		if SnapshotResult["status"] !== "ok"
			return SnapshotResult
		if SnapshotResult["snapshot"]["present"] {
			return _ConfigTransitionResult("retry", "temp_discard_failed",
				"Interrupted private temp remained after deletion: '"
				. Entry["path"] . "'.", Record)
		}
	}
	return _ConfigTransitionResult("ok", "temps_discarded", "", Record)
}

; Removes verified artifacts first and the authoritative live journal last.
; @param PathsFile {String} Stable locator path.
; @param Record {Map} Committed journal record.
; @param Port {Map} Validated adapter map.
; @return {Map} Typed cleanup result.
_ConfigTransitionCleanup(PathsFile, Record, Port) {
	Preflight := _ConfigTransitionPreflightOwnedNamespace(PathsFile, Record, Port)
	if Preflight["status"] !== "ok"
		return Preflight
	for Entry in Preflight["entries"] {
		if !_ConfigTransitionPortStatus(Port, "delete", &Detail, Entry["path"])
			return _ConfigTransitionResult("retry", "artifact_cleanup_failed",
				Detail, Record)
	}
	WalPath := ConfigTransitionWalPath(PathsFile)
	if !_ConfigTransitionPortStatus(Port, "delete", &Detail, WalPath)
		return _ConfigTransitionResult("retry", "wal_cleanup_failed", Detail,
			Record)
	return _ConfigTransitionResult("ok", "cleaned", "", Record)
}

; Recovers a valid transition to the side dictated exclusively by its phase.
; @param PathsFile {String} Absolute stable paths.toml locator.
; @param Port {Map} Injected filesystem and hash adapters.
; @param PauseFn {Callable|0} Optional crash seam.
; @return {Map} Typed absent, recovered, quarantine, retry, or fatal result.
ConfigTransitionRecover(PathsFile, Port, PauseFn := 0) {
	Port := _ConfigTransitionResolvePort(Port)
	if !(Port is Map)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	Inspected := ConfigTransitionInspect(PathsFile, Port)
	if Inspected["status"] !== "ok" || Inspected["kind"] !== "ready"
		return Inspected
	Record := Inspected["record"]
	Phase := Record["phase"]
	Side := (Phase == CONFIG_TRANSITION_PHASE_COMMITTED_NEW) ? "new" : "old"
	NamespaceResult := _ConfigTransitionPreflightOwnedNamespace(PathsFile,
		Record, Port)
	if NamespaceResult["status"] !== "ok"
		return NamespaceResult
	PlanResult := _ConfigTransitionBuildRealizePlan(Record, Port, Side)
	if PlanResult["status"] !== "ok"
		return PlanResult
	DiscardResult := _ConfigTransitionDiscardInterruptedTemps(
		NamespaceResult, Port, Record)
	if DiscardResult["status"] !== "ok"
		return DiscardResult
	RealizeResult := _ConfigTransitionExecuteRealizePlan(Record, Port, Side,
		PlanResult["plan"], PauseFn)
	if RealizeResult["status"] !== "ok"
		return RealizeResult
	VerifyResult := _ConfigTransitionVerifySide(Record, Port, Side)
	if VerifyResult["status"] !== "ok"
		return VerifyResult
	if Side == "old" && Phase !== CONFIG_TRANSITION_PHASE_COMMITTED_OLD {
		Record := _ConfigTransitionWithPhase(Record,
			CONFIG_TRANSITION_PHASE_COMMITTED_OLD)
		PhaseResult := _ConfigTransitionPublishWalReplace(Port, PathsFile, Record)
		if PhaseResult["status"] !== "ok"
			return PhaseResult
		_ConfigTransitionPause(PauseFn, "phase:committed_old")
	}
	CleanupResult := _ConfigTransitionCleanup(PathsFile, Record, Port)
	if CleanupResult["status"] !== "ok"
		return CleanupResult
	return _ConfigTransitionResult("ok", "recovered_" . Side, "", Record)
}

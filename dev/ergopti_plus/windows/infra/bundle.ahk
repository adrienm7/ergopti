; infra/bundle.ahk





; ===============================================
; ===============================================
; ======= 1/ Compiled Bundle Bootstrapper =======
; ===============================================
; ===============================================
;
; MODULE: Compiled Bundle Bootstrapper
; DESCRIPTION:
; In compiled mode (A_IsCompiled), the .exe ships an embedded zip that holds
; every runtime asset the driver reads from disk: hotstring TOMLs, locales,
; the menu manifest, tray icons, language flags, gestures shared TOML, the
; ``_shared`` driver tree (WebView HTML/CSS/JS, LLM defaults, DB schema) and
; the native DLLs that DllCall expects. The bootstrapper extracts this zip
; into %LOCALAPPDATA%\Ergopti\bundle-<version>\ on first launch, then exposes
; the resolved path via the global ``_BundleDir`` so the rest of the driver
; can read assets without caring whether it runs from source or from a
; compiled binary.
;
; FEATURES & RATIONALE:
; 1. Out-of-band install dir: extracting to LocalAppData (not next to the
;    .exe) means a downloaded ErgoptiPlus.exe sitting in ~/Downloads or any
;    other folder does not pollute its host directory with ``static/`` and
;    ``vendor/`` siblings. Users keep their download folder clean.
; 2. Single ``bundle/`` directory: one extraction location regardless of
;    version. On version change the directory is wiped before re-extraction
;    so orphan files from the previous version cannot accumulate, and disk
;    usage stays bounded at ~one bundle worth (~10-20 MB) instead of growing
;    linearly with every release.
; 3. Build-aware skip: a marker under the bundle dir holds the version and
;    source commit; if both match the compiled build the extraction is skipped,
;    so the .exe boots without paying the ~250ms unzip cost on every launch.
; 4. No-op in dev mode: when A_IsCompiled is false, the module is a passive
;    no-op and ``_BundleDir`` is left empty — the dev workflow stays identical.
; ==============================================================================



; ===================================
; ===== 1.1) Constants & Globals ====
; ===================================

; Stamped at build time by tools/build_static_bundle.py (see CI workflow):
; the literal string "__BUNDLE_VERSION__" below is rewritten before Ahk2Exe
; runs so the compiled exe ships with a stable identifier. In dev mode the
; placeholder stays as-is and we treat it as ``dev`` to disable any skip.
global BUNDLE_VERSION := "__BUNDLE_VERSION__"

; Commit the release was built from, stamped by the same CI step. The boot
; diagnostic snapshot reports it; a source checkout reads .git/HEAD instead.
global BUNDLE_COMMIT := "__BUNDLE_COMMIT__"

; GitHub release URL frozen at build time so the tray menu's first item can
; deep-link to *this exact release* without an extra API call. The release
; workflow rewrites the placeholder right after stamping BUNDLE_VERSION,
; mirroring the pattern above. Empty in dev — callers fall back to the
; channel's "latest" page resolved at runtime.
global BUNDLE_RELEASE_URL := "__BUNDLE_RELEASE_URL__"

; Asset name pattern for the self-updater download. Frozen at build time to
; keep the runtime decoupled from the release-workflow naming convention —
; if a future rename happens, only this placeholder needs to track it.
global BUNDLE_RELEASE_ASSET := "ErgoptiPlus.exe"

; Update channel this exe was BUILT from: the release workflow rewrites the
; placeholder to the registry id of the channel it publishes
; (_shared/modules/updater/channels.json). The updater follows it while
; config.toml [updater] channel names none, so a user who downloaded a
; pre-release build keeps receiving that channel; the About menu's channel
; rows switch it afterwards. A source run keeps the placeholder, which is no
; registry id, and follows the registry's unreleased-build channel instead.
global BUNDLE_CHANNEL := "__BUNDLE_CHANNEL__"

; Resolved at runtime by Bundle_Init() — empty string in dev mode (callers
; must fall back to A_ScriptDir-derived paths), versioned LocalAppData path
; in compiled mode. Exposed as a global so every module can read it.
global _BundleDir := ""

; CNG constants must be initialized before the first compiled asset check.
; Bootstrap errors use OutputDebug because the central logger is not ready yet.
#Include ../adapters/crypto.ahk
#Include ../adapters/file_system.ahk
#Include ../adapters/process_lifecycle.ahk
#Include *i ../build/bundle_inventory.ahk



; ==========================================
; ===== 1.2) Internal helper functions =====
; ==========================================

; Resolves the current user's Local AppData directory. AutoHotkey v2 has no
; built-in variable for it (unlike the Roaming ``A_AppData``) — ``EnvGet``
; is the only OS-native accessor. A prior version of this file referenced a
; nonexistent ``A_LocalAppData`` built-in directly; AHK auto-declared it as an
; unassigned local and threw on every compiled launch, before Logger even
; existed to record why. Falls back to deriving the path from
; ``%USERPROFILE%`` for the rare case ``LOCALAPPDATA`` itself is stripped from
; the environment. Shared by every module that needs this path (bundle, updater
; staging, personal-shortcuts stub) so the fallback chain has one owner.
; @return {String} The Local AppData path, or "" if both lookups fail.
ResolveLocalAppDataDir() {
	Resolved := EnvGet("LOCALAPPDATA")
	if (Resolved != "")
		return Resolved
	UserProfile := EnvGet("USERPROFILE")
	if (UserProfile != "")
		return UserProfile . "\AppData\Local"
	return ""
}

; Returns the single extraction root inside the user's Local AppData directory.
; We use one fixed folder (no version suffix) so disk usage stays bounded — on
; version change the folder is wiped by Bundle_Init() before the new bundle is
; extracted.
; @return {String} The bundle root path, or "" if Local AppData cannot be resolved.
_Bundle_ResolveDir() {
	LocalAppData := ResolveLocalAppDataDir()
	if (LocalAppData == "")
		return ""
	return LocalAppData . "\Ergopti\bundle"
}

; Reads the complete build marker; returns "" if the file is missing or
; empty. Failure is silent because a missing marker simply means "extract".
_Bundle_ReadMarker(BundleDir) {
	MarkerPath := BundleDir . "\.bundle-version"
	if !FileExist(MarkerPath)
		return ""
	Content := ""
	try Content := FileRead(MarkerPath, "UTF-8")
	return Trim(Content, " `t`r`n")
}

; Serialize the version and commit together: development builds commonly share
; one version while carrying different runtime assets.
; @return {String} Identity persisted only after extraction has verified.
_Bundle_BuildMarker() {
	return BUNDLE_VERSION . "`n" . BUNDLE_COMMIT
}

; Writes the marker file with the current build identity. Failure is logged
; via OutputDebug because the logger has not been initialised yet at the
; point Bundle_Init() runs.
_Bundle_WriteMarker(BundleDir) {
	MarkerPath := BundleDir . "\.bundle-version"
	try {
		FileDelete(MarkerPath)
	}
	try {
		FileAppend(_Bundle_BuildMarker(), MarkerPath, "UTF-8")
	} catch as Err {
		OutputDebug("[bundle] WriteMarker failed: " . Err.Message)
		return false
	}
	return FileExist(MarkerPath)
}

; The compiled inventory comes from the same selected bytes as the embedded ZIP.
; Additional runtime caches are allowed; every shipped asset remains immutable.
_Bundle_VerifyStaging(StagingDir, Inventory := unset) {
	if !DirExist(StagingDir)
		return false
	try {
		if !IsSet(Inventory) {
			if !IsSet(_Bundle_CompiledAssetInventory)
				return false
			Inventory := _Bundle_CompiledAssetInventory()
		}
		if !(Inventory is Array) or Inventory.Length == 0
			return false
		Seen := Map()
		for Row in Inventory {
			if !(Row is Array) or Row.Length != 3
				return false
			if !(Row[1] is String) or Row[1] == ""
					or RegExMatch(Row[1], "[\\:`r`n]|^/|(^|/)\.{1,2}(/|$)|//")
					or !(Row[2] is Integer) or Row[2] < 0
					or !(Row[3] is String) or !RegExMatch(Row[3], "^[0-9a-f]{64}$")
				return false
			Key := StrLower(Row[1])
			if Seen.Has(Key)
				return false
			Seen[Key] := true
			Bytes := FSReadBytesStrict(StagingDir . "\" . StrReplace(Row[1], "/", "\"))
			if Bytes.Size != Row[2] or _CryptoSha256Cng(Bytes) != Row[3]
				return false
		}
		return true
	} catch as Err {
		OutputDebug("[bundle] Asset verification failed: " . Err.Message)
		return false
	}
}

_Bundle_LiveTreeCanSkip(BundleDir, ExistingMarker, Inventory := unset) {
	; A placeholder cannot distinguish two local compiles. Extraction still
	; works, but only a stamped identity can justify reusing existing assets.
	if (BUNDLE_VERSION == "__BUNDLE_VERSION__" or BUNDLE_COMMIT == "__BUNDLE_COMMIT__"
		or BUNDLE_VERSION == "" or BUNDLE_COMMIT == ""
		or ExistingMarker != _Bundle_BuildMarker())
		return false
	return _Bundle_VerifyStaging(BundleDir, Inventory?)
}

; Atomically reserve a sibling on the bundle volume. Naming identifies an
; attempt; only successful native creation grants its cleanup authority.
_Bundle_AcquireWorkspace(BundleDir, Tick := unset, Pid := unset) {
	Tick := IsSet(Tick) ? Tick : A_TickCount
	Pid := IsSet(Pid) ? Pid : PLC_CurrentProcessIdStrict()
	Root := BundleDir . ".workspace-" . Pid . "-" . Tick
	FSCreateDirectoryExclusiveStrict(Root)
	Workspace := Map("root", Root, "owned", true, "staging", Root . "\staging",
		"rollback", Root . "\rollback", "zip", Root . "\archive.zip")
	try DirCreate(Workspace["staging"])
	catch as Err {
		try _Bundle_CleanupWorkspace(Workspace)
		catch as CleanupErr {
			throw Error("Bundle workspace setup failed: " . Err.Message
				. "; cleanup failed with ownership retained: " . CleanupErr.Message)
		}
		throw Err
	}
	return Workspace
}

; A failed commit retains the known-good tree until its native restoration has
; succeeded. A cleanup failure keeps authority live instead of reporting success.
_Bundle_CleanupWorkspace(Workspace, Committed := false) {
	if !(Workspace is Map) or !Workspace.Get("owned", false)
		throw Error("Bundle cleanup requires an acquired workspace.")
	if !Committed && DirExist(Workspace["rollback"])
		throw Error("Bundle recovery bytes must be restored before cleanup: " . Workspace["rollback"])
	DirDelete(Workspace["root"], true)
	Workspace["owned"] := false
}

; Restoration failures preserve the exact recovery tree and expose its path.
; The caller must not retire its workspace after this owner refuses restoration.
_Bundle_RestoreRollback(Workspace, BundleDir) {
	if !(Workspace is Map) or !Workspace.Get("owned", false)
		throw Error("Bundle restoration requires an acquired workspace.")
	if !DirExist(Workspace["rollback"])
		return
	try DirMove(Workspace["rollback"], BundleDir, 0)
	catch as Err {
		throw Error("Bundle restoration failed; recovery bytes retained at "
			. Workspace["rollback"], , Err.Message)
	}
}

; Runs PowerShell's Expand-Archive synchronously to unzip ``ZipPath`` into
; ``DestDir``. Returns true on success, false otherwise. We rely on PowerShell
; because AHK v2 has no built-in unzip and adding a COM-based extractor would
; bloat the bundle module for no real gain.
_Bundle_BuildUnzipCommand(ZipPath, DestDir) {
	; PowerShell single-quoted literals escape an embedded apostrophe by
	; doubling it. LocalAppData is user-controlled and a legal Windows profile
	; name may contain one, so neither path can be interpolated raw.
	QuotedZipPath := StrReplace(ZipPath, "'", "''")
	QuotedDestDir := StrReplace(DestDir, "'", "''")
	return "powershell -NoProfile -ExecutionPolicy Bypass -Command "
		. '"' . "Expand-Archive -LiteralPath '" . QuotedZipPath
		. "' -DestinationPath '" . QuotedDestDir . "' -Force" . '"'
}

_Bundle_Unzip(ZipPath, DestDir) {
	; -NoProfile keeps cold-start fast; -Command is a single string we build
	; via FormatTime-free concatenation to avoid quoting surprises.
	Cmd := _Bundle_BuildUnzipCommand(ZipPath, DestDir)
	ExitCode := 1
	try {
		ExitCode := RunWait(Cmd, , "Hide")
	} catch as Err {
		OutputDebug("[bundle] Unzip RunWait threw: " . Err.Message)
		return false
	}
	return ExitCode == 0
}



; ===================================
; ===== 1.3) Public entry point =====
; ===================================

; Ensures the runtime assets are present and resolves ``_BundleDir``. Must be
; called before any code reads from ``_StaticDir`` or ``_VendorDir``. In dev
; mode it is a no-op and ``_BundleDir`` stays empty (callers must fall back
; to A_ScriptDir-derived paths).
;
; The extraction strategy is "skip if marker matches, otherwise wipe + rewrite".
; Wiping before re-extracting prevents stale files from a previous version
; lingering (Expand-Archive merges into the destination, it does not prune
; orphan entries). Disk usage therefore stays bounded at ~one bundle worth.
Bundle_Init() {
	; Dev mode: nothing to extract — the source tree is already laid out.
	if !A_IsCompiled
		return

	BundleDir := _Bundle_ResolveDir()
	if (BundleDir == "") {
		; Neither %LOCALAPPDATA% nor %USERPROFILE% resolved — the exe has no
		; usable extraction root, so it cannot serve any runtime asset.
		Ui_MsgBox("Bundle extraction failed: could not resolve the Local AppData directory.",
			"", "Icon!")
		ExitApp(1)
	}
	global _BundleDir := BundleDir

	; Ensure the parent dir exists. The bundle dir itself is (re)created
	; below by either the skip branch or the wipe-and-extract branch.
	ParentDir := SubStr(BundleDir, 1, InStr(BundleDir, "\", , -1) - 1)
	if !DirExist(ParentDir) {
		try DirCreate(ParentDir)
	}
	; A matching marker is metadata, not proof that the prior extraction is
	; complete. Verify the live tree before accepting the fast path so a partial
	; or externally damaged bundle repairs itself on the next compiled boot.
	Existing := _Bundle_ReadMarker(BundleDir)
	if _Bundle_LiveTreeCanSkip(BundleDir, Existing) {
		OutputDebug("[bundle] Marker matches '" . BUNDLE_VERSION . "' — skipping extraction.")
		return
	}
	if (Existing != "" and Existing == _Bundle_BuildMarker())
		OutputDebug("[bundle] Marker matches but the live tree failed verification — rebuilding.")

	; Extract into a sibling staging directory. The live bundle remains intact
	; until the archive and marker have both been verified.
	try Workspace := _Bundle_AcquireWorkspace(BundleDir)
	catch as Err {
		; Fatal pre-boot errors precede i18n: its locale assets require this bundle.
		Ui_MsgBox("Bundle extraction failed (workspace acquisition): " . Err.Message, "", "Icon!")
		ExitApp(1)
	}
	StagingDir := Workspace["staging"]
	RollbackDir := Workspace["rollback"]
	TmpZip := Workspace["zip"]
	try {
		; Literal source path — Ahk2Exe scans this token at compile time to
		; decide what to embed. Do not factor into a variable.
		FileInstall("build\static_bundle.zip", TmpZip, 0)
	} catch as Err {
		; The archive is private; a refused write must not adopt existing bytes.
		_Bundle_CleanupWorkspace(Workspace)
		Ui_MsgBox("Bundle extraction failed (FileInstall): " . Err.Message,
			"", "Icon!")
		ExitApp(1)
	}

	if !_Bundle_Unzip(TmpZip, StagingDir) {
		_Bundle_CleanupWorkspace(Workspace)
		Ui_MsgBox("Bundle extraction failed (Expand-Archive returned non-zero).",
			"", "Icon!")
		ExitApp(1)
	}

	FileDelete(TmpZip)
	if !_Bundle_VerifyStaging(StagingDir) or !_Bundle_WriteMarker(StagingDir) {
		_Bundle_CleanupWorkspace(Workspace)
		Ui_MsgBox("Bundle extraction failed (staging verification).", "", "Icon!")
		ExitApp(1)
	}
	; Preserve the known-good runtime until the new tree has been fully staged.
	if DirExist(BundleDir) {
		try DirMove(BundleDir, RollbackDir, 0)
		catch as Err {
			_Bundle_CleanupWorkspace(Workspace)
			Ui_MsgBox("Bundle extraction failed (could not preserve current bundle): " . Err.Message,
				"", "Icon!")
			ExitApp(1)
		}
	}
	try DirMove(StagingDir, BundleDir, 0)
	catch as Err {
		_Bundle_RestoreRollback(Workspace, BundleDir)
		_Bundle_CleanupWorkspace(Workspace)
		Ui_MsgBox("Bundle extraction failed (commit): " . Err.Message, "", "Icon!")
		ExitApp(1)
	}
	_Bundle_CleanupWorkspace(Workspace, true)
	OutputDebug("[bundle] Extracted bundle version '" . BUNDLE_VERSION . "' to " . BundleDir)
}

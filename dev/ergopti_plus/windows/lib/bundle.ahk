; lib/bundle.ahk





; =============================================
; ===============================================
; ======= 1/ Compiled Bundle Bootstrapper =======
; ===============================================
; =============================================
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
; 3. Version-aware skip: a marker file under the bundle dir holds the build
;    version string; if it matches BUNDLE_VERSION the extraction is skipped,
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

; Update channel this exe was BUILT from. The release workflow rewrites the
; placeholder to "dev" for pre-release builds and "main" for stable releases.
; ``Updater_LoadChannel`` honours this as the default when no explicit
; ``[Updater] UpdateChannel`` override exists in config.toml — so a user who
; downloaded a dev exe stays on dev (and gets dev-channel update prompts)
; without having to flip the channel manually. The menu's channel submenu
; lets them switch afterwards. In source / dev mode the placeholder stays
; unresolved and we default to "main" for backward compatibility.
global BUNDLE_CHANNEL := "__BUNDLE_CHANNEL__"

; Resolved at runtime by Bundle_Init() — empty string in dev mode (callers
; must fall back to A_ScriptDir-derived paths), versioned LocalAppData path
; in compiled mode. Exposed as a global so every module can read it.
global _BundleDir := ""



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

; Reads the marker file's first line; returns "" if the file is missing or
; empty. Failure is silent because a missing marker simply means "extract".
_Bundle_ReadMarker(BundleDir) {
	MarkerPath := BundleDir . "\.bundle-version"
	if !FileExist(MarkerPath)
		return ""
	Content := ""
	try Content := FileRead(MarkerPath, "UTF-8")
	return Trim(Content, " `t`r`n")
}

; Writes the marker file with the current BUNDLE_VERSION. Failure is logged
; via OutputDebug because the logger has not been initialised yet at the
; point Bundle_Init() runs.
_Bundle_WriteMarker(BundleDir) {
	MarkerPath := BundleDir . "\.bundle-version"
	try {
		FileDelete(MarkerPath)
	}
	try {
		FileAppend(BUNDLE_VERSION, MarkerPath, "UTF-8")
	} catch as Err {
		OutputDebug("[bundle] WriteMarker failed: " . Err.Message)
		return false
	}
	return FileExist(MarkerPath)
}

_Bundle_VerifyStaging(StagingDir) {
	return DirExist(StagingDir) and DirExist(StagingDir . "\static")
}

; Runs PowerShell's Expand-Archive synchronously to unzip ``ZipPath`` into
; ``DestDir``. Returns true on success, false otherwise. We rely on PowerShell
; because AHK v2 has no built-in unzip and adding a COM-based extractor would
; bloat the bundle module for no real gain.
_Bundle_Unzip(ZipPath, DestDir) {
	; -NoProfile keeps cold-start fast; -Command is a single string we build
	; via FormatTime-free concatenation to avoid quoting surprises.
	Cmd := "powershell -NoProfile -ExecutionPolicy Bypass -Command "
		. '"' . "Expand-Archive -LiteralPath '" . ZipPath . "' -DestinationPath '" . DestDir . "' -Force" . '"'
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
		MsgBox("Bundle extraction failed: could not resolve the Local AppData directory.",
			"ErgoptiPlus", "Icon!")
		ExitApp(1)
	}
	global _BundleDir := BundleDir

	; Ensure the parent dir exists. The bundle dir itself is (re)created
	; below by either the skip branch or the wipe-and-extract branch.
	ParentDir := SubStr(BundleDir, 1, InStr(BundleDir, "\", , -1) - 1)
	if !DirExist(ParentDir) {
		try DirCreate(ParentDir)
	}
	; Skip if the marker matches the embedded version.
	Existing := _Bundle_ReadMarker(BundleDir)
	if (Existing != "" and Existing == BUNDLE_VERSION) {
		OutputDebug("[bundle] Marker matches '" . BUNDLE_VERSION . "' — skipping extraction.")
		return
	}

	; Extract into a sibling staging directory. The live bundle remains intact
	; until the archive and marker have both been verified.
	StagingDir := BundleDir . ".staging-" . A_TickCount
	RollbackDir := BundleDir . ".rollback-" . A_TickCount
	if DirExist(StagingDir)
		try DirDelete(StagingDir, true)
	try DirCreate(StagingDir)

	; Write the zip out of the .exe into a temp location, then unzip it
	; into BundleDir so static/ and vendor/ end up under it.
	TmpZip := A_Temp . "\ergopti_bundle_" . A_TickCount . ".zip"
	try {
		; Literal source path — Ahk2Exe scans this token at compile time to
		; decide what to embed. Do not factor into a variable.
		FileInstall("build\static_bundle.zip", TmpZip, 1)
	} catch as Err {
		; If FileInstall fails the exe is unusable — surface a hard error.
		MsgBox("Bundle extraction failed (FileInstall): " . Err.Message,
			"ErgoptiPlus", "Icon!")
		ExitApp(1)
	}

	if !_Bundle_Unzip(TmpZip, StagingDir) {
		try FileDelete(TmpZip)
		try DirDelete(StagingDir, true)
		MsgBox("Bundle extraction failed (Expand-Archive returned non-zero).",
			"ErgoptiPlus", "Icon!")
		ExitApp(1)
	}

	try FileDelete(TmpZip)
	if !_Bundle_VerifyStaging(StagingDir) or !_Bundle_WriteMarker(StagingDir) {
		try DirDelete(StagingDir, true)
		MsgBox("Bundle extraction failed (staging verification).", "ErgoptiPlus", "Icon!")
		ExitApp(1)
	}
	; Preserve the known-good runtime until the new tree has been fully staged.
	if DirExist(BundleDir) {
		try DirMove(BundleDir, RollbackDir, 0)
		catch as Err {
			try DirDelete(StagingDir, true)
			MsgBox("Bundle extraction failed (could not preserve current bundle): " . Err.Message,
				"ErgoptiPlus", "Icon!")
			ExitApp(1)
		}
	}
	try DirMove(StagingDir, BundleDir, 0)
	catch as Err {
		try DirMove(RollbackDir, BundleDir, 0)
		MsgBox("Bundle extraction failed (commit): " . Err.Message, "ErgoptiPlus", "Icon!")
		ExitApp(1)
	}
	if DirExist(RollbackDir)
		try DirDelete(RollbackDir, true)
	OutputDebug("[bundle] Extracted bundle version '" . BUNDLE_VERSION . "' to " . BundleDir)
}

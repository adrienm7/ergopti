; lib/bundle.ahk

; =============================================
; =============================================
; ======= 1/ Compiled Bundle Bootstrapper =====
; =============================================
; =============================================
;
; MODULE: Compiled Bundle Bootstrapper
; DESCRIPTION:
; In compiled mode (A_IsCompiled), the .exe ships an embedded zip that holds
; every runtime asset the driver reads from disk: hotstring TOMLs, locales,
; the menu manifest, tray icons, language flags, gestures shared TOML, the
; ``_shared`` driver tree (WebView HTML/CSS/JS, LLM defaults, DB schema) and
; the native DLLs that DllCall expects. The bootstrapper extracts this zip
; into A_LocalAppData\Ergopti\bundle-<version>\ on first launch, then exposes
; the resolved path via the global ``_BundleDir`` so the rest of the driver
; can read assets without caring whether it runs from source or from a
; compiled binary.
;
; FEATURES & RATIONALE:
; 1. Out-of-band install dir: extracting to LocalAppData (not next to the
;    .exe) means a downloaded ErgoptiPlus.exe sitting in ~/Downloads or any
;    other folder does not pollute its host directory with ``static/`` and
;    ``vendor/`` siblings. Users keep their download folder clean.
; 2. Per-version directories: each ``BUNDLE_VERSION`` lives in its own
;    folder (``bundle-1.2.3``), so a future updater can ship a new version
;    without touching the old one and roll back trivially if needed.
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
; the literal string ``"__BUNDLE_VERSION__"`` below is rewritten before Ahk2Exe
; runs so the compiled exe ships with a stable identifier. In dev mode the
; placeholder stays as-is and we treat it as ``dev`` to disable any skip.
global BUNDLE_VERSION := "__BUNDLE_VERSION__"

; Resolved at runtime by Bundle_Init() — empty string in dev mode (callers
; must fall back to A_ScriptDir-derived paths), versioned LocalAppData path
; in compiled mode. Exposed as a global so every module can read it.
global _BundleDir := ""




; ==========================================
; ===== 1.2) Internal helper functions =====
; ==========================================

; Returns the per-version extraction root inside A_LocalAppData. We version
; the folder so a future updater (Velopack) can ship new versions side-by-side
; with old ones; the marker check then guarantees a single extraction per
; install rather than per launch.
_Bundle_ResolveDir() {
	return A_AppData . "\..\Local\Ergopti\bundle-" . BUNDLE_VERSION
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
	}
}

; Runs PowerShell's Expand-Archive synchronously to unzip ``ZipPath`` into
; ``DestDir``. Returns true on success, false otherwise. We rely on PowerShell
; because AHK v2 has no built-in unzip and adding a COM-based extractor would
; bloat the bundle module for no real gain.
_Bundle_Unzip(ZipPath, DestDir) {
	; -NoProfile keeps cold-start fast; -Command is a single string we build
	; via FormatTime-free concatenation to avoid quoting surprises.
	Cmd := "powershell -NoProfile -ExecutionPolicy Bypass -Command "
		. "`"Expand-Archive -LiteralPath '" . ZipPath . "' -DestinationPath '" . DestDir . "' -Force`""
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
; The extraction strategy is "wipe + rewrite" only when the version marker
; mismatches — within a given version we trust the on-disk copy and skip the
; ~250 ms unzip cost. Per-version folders mean cross-version orphan files
; cannot accumulate.
Bundle_Init() {
	; Dev mode: nothing to extract — the source tree is already laid out.
	if !A_IsCompiled
		return

	BundleDir := _Bundle_ResolveDir()
	global _BundleDir := BundleDir

	; Ensure the bundle dir exists before any FS operation.
	if !DirExist(BundleDir) {
		try DirCreate(BundleDir)
	}

	; Skip if the marker matches the embedded version.
	Existing := _Bundle_ReadMarker(BundleDir)
	if (Existing != "" and Existing == BUNDLE_VERSION) {
		OutputDebug("[bundle] Marker matches '" . BUNDLE_VERSION . "' — skipping extraction.")
		return
	}

	; Write the zip out of the .exe into a temp location, then unzip it
	; into BundleDir so static/ and vendor/ end up under the per-version dir.
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

	if !_Bundle_Unzip(TmpZip, BundleDir) {
		try FileDelete(TmpZip)
		MsgBox("Bundle extraction failed (Expand-Archive returned non-zero).",
			"ErgoptiPlus", "Icon!")
		ExitApp(1)
	}

	try FileDelete(TmpZip)
	_Bundle_WriteMarker(BundleDir)
	OutputDebug("[bundle] Extracted bundle version '" . BUNDLE_VERSION . "' to " . BundleDir)
}

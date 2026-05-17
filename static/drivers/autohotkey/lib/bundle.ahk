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
; the native DLLs that DllCall expects next to the exe. The bootstrapper
; extracts this zip into A_ScriptDir on first launch and short-circuits on
; subsequent launches via a version marker.
;
; FEATURES & RATIONALE:
; 1. Mirror the dev layout: the bundle is extracted so that A_ScriptDir/static
;    and A_ScriptDir/vendor have the exact same shape as <repo>/static and
;    <repo>/static/drivers/autohotkey/vendor. That keeps every _StaticDir-based
;    read site working in both dev (uncompiled) and release (compiled) modes.
; 2. Version-aware skip: a marker file under static/ holds the build version
;    string; if it matches BUNDLE_VERSION the extraction is skipped, so the
;    .exe boots without paying the ~250ms unzip cost on every launch.
; 3. No-op in dev mode: when A_IsCompiled is false, the module is a passive
;    no-op. The dev workflow stays identical to today.
; ==============================================================================



; ===================================
; ===== 1.1) Constants & Globals ====
; ===================================

; Stamped at build time by tools/build_static_bundle.py (see CI workflow):
; the literal string ``"__BUNDLE_VERSION__"`` below is rewritten before Ahk2Exe
; runs so the compiled exe ships with a stable identifier. In dev mode the
; placeholder stays as-is and we treat it as ``dev`` to disable any skip.
global BUNDLE_VERSION := "__BUNDLE_VERSION__"

; Marker file written after a successful extraction. Stored INSIDE the
; extracted ``static\`` dir so wiping the dir invalidates the marker too.
; The FileInstall path itself MUST stay as a literal at the call site —
; Ahk2Exe scans for the exact source string ``"build\static_bundle.zip"``
; at compile time, so it cannot be parameterised here.
global _BUNDLE_MARKER_REL := "static\.bundle-version"



; ==========================================
; ===== 1.2) Internal helper functions =====
; ==========================================

; Reads the marker file's first line; returns "" if the file is missing or
; empty. Failure is silent because a missing marker simply means "extract".
_Bundle_ReadMarker() {
	MarkerPath := A_ScriptDir . "\" . _BUNDLE_MARKER_REL
	if !FileExist(MarkerPath)
		return ""
	Content := ""
	try Content := FileRead(MarkerPath, "UTF-8")
	return Trim(Content, " `t`r`n")
}

; Writes the marker file with the current BUNDLE_VERSION. Failure is logged
; via OutputDebug because the logger has not been initialised yet at the
; point Bundle_Init() runs.
_Bundle_WriteMarker() {
	MarkerPath := A_ScriptDir . "\" . _BUNDLE_MARKER_REL
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

; Ensures the runtime assets are present next to the .exe. Must be called
; before any code reads from _StaticDir or A_ScriptDir\\vendor. No-op in dev.
;
; The extraction strategy is "wipe + rewrite" only when the version marker
; mismatches — within a given version we trust the on-disk copy and skip the
; ~250 ms unzip cost. Velopack ships each version in its own folder, so
; cross-version orphan files cannot accumulate.
Bundle_Init() {
	; Dev mode: nothing to extract — the source tree is already laid out.
	if !A_IsCompiled
		return

	; Skip if the marker matches the embedded version.
	Existing := _Bundle_ReadMarker()
	if (Existing != "" and Existing == BUNDLE_VERSION) {
		OutputDebug("[bundle] Marker matches '" . BUNDLE_VERSION . "' — skipping extraction.")
		return
	}

	; Write the zip out of the .exe into a temp location, then unzip it
	; into A_ScriptDir so static/ and vendor/ end up siblings of the .exe.
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

	if !_Bundle_Unzip(TmpZip, A_ScriptDir) {
		try FileDelete(TmpZip)
		MsgBox("Bundle extraction failed (Expand-Archive returned non-zero).",
			"ErgoptiPlus", "Icon!")
		ExitApp(1)
	}

	try FileDelete(TmpZip)
	_Bundle_WriteMarker()
	OutputDebug("[bundle] Extracted bundle version '" . BUNDLE_VERSION . "' to " . A_ScriptDir)
}

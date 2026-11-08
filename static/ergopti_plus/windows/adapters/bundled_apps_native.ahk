; adapters/bundled_apps_native.ahk

; ==============================================================================
; MODULE: Bundled Apps Native Adapter
; DESCRIPTION:
; The operating-system calls of the bundled App Cloner and Encryptor
; (windows/apps/): random salt bytes, memory copies of whole files, the atomic
; replacement of a converted file, shortcuts, directory junctions, Explorer and
; the start of an app process. The apps' cores hold no DllCall, as the OS-purity
; rule asks of every module outside adapters/.
;
; FEATURES & RATIONALE:
; 1. MoveFileExW with MOVEFILE_REPLACE_EXISTING replaces a destination the user
;    approved only once its successor is complete, as macOS's mv -f does.
; 2. Shortcuts go through the Windows Script Host's IShellLink wrapper, the one
;    a .lnk with arguments, a working folder and an icon needs.
; 3. A command line is quoted by CommandLineToArgvW's rules, so a program
;    receives each argument whole whatever spaces, quotes or trailing
;    backslashes it carries.
; ==============================================================================

#Requires AutoHotkey v2.0+

; MoveFileExW flags: replace an existing target, return only once flushed.
global BUNDLED_APPS_MOVEFILE_REPLACE_EXISTING := 0x1
global BUNDLED_APPS_MOVEFILE_WRITE_THROUGH := 0x8





; ==================================
; ==================================
; ======= 1/ Bytes and files =======
; ==================================
; ==================================

/**
 * Returns bytes from the system random generator.
 * @param {Integer} Count
 * @returns {Buffer}
 */
BundledAppsNative_RandomBytes(Count) {
	Bytes := Buffer(Count)
	; BCRYPT_USE_SYSTEM_PREFERRED_RNG
	if DllCall("bcrypt\BCryptGenRandom", "Ptr", 0, "Ptr", Bytes, "UInt", Count, "UInt", 2, "UInt") != 0
		throw OSError(A_LastError, -1, "Random bytes could not be generated.")
	return Bytes
}

/**
 * Copies bytes between two buffers.
 * @param {Integer} Destination Address to write.
 * @param {Integer} Source Address to read.
 * @param {Integer} Count Byte count.
 */
BundledAppsNative_Copy(Destination, Source, Count) {
	if Count > 0
		DllCall("Kernel32\RtlMoveMemory", "Ptr", Destination, "Ptr", Source, "UPtr", Count)
}

/**
 * Replaces Target with the complete file Stage.
 * @param {String} Stage
 * @param {String} Target
 * @returns {Boolean}
 */
BundledAppsNative_ReplaceFile(Stage, Target) {
	return DllCall("Kernel32\MoveFileExW", "Str", Stage, "Str", Target,
		"UInt", BUNDLED_APPS_MOVEFILE_REPLACE_EXISTING | BUNDLED_APPS_MOVEFILE_WRITE_THROUGH, "Int") != 0
}




; ==================================
; ==================================
; ======= 2/ Shell =================
; ==================================
; ==================================

/**
 * Quotes one argument as CommandLineToArgvW reads it back.
 * @param {String} Arg
 * @returns {String}
 */
BundledAppsNative_QuoteArg(Arg) {
	if Arg != "" && !RegExMatch(Arg, '[\s"]')
		return Arg
	Out := '"'
	Slashes := 0
	loop parse Arg {
		Char := A_LoopField
		if (Char == "\") {
			Slashes += 1
			continue
		}
		if (Char == '"') {
			loop Slashes * 2 + 1
				Out .= "\"
			Out .= '"'
		} else {
			loop Slashes
				Out .= "\"
			Out .= Char
		}
		Slashes := 0
	}
	loop Slashes * 2
		Out .= "\"
	return Out . '"'
}

/**
 * Joins arguments into one command line.
 * @param {Array} Args
 * @returns {String}
 */
BundledAppsNative_CommandLine(Args) {
	Line := ""
	for Arg in Args
		Line .= (Line == "" ? "" : " ") . BundledAppsNative_QuoteArg(String(Arg))
	return Line
}

/**
 * Starts a program without waiting for it.
 * @param {String} Executable
 * @param {Array} Args
 * @returns {Integer} The process id.
 */
BundledAppsNative_Start(Executable, Args) {
	Pid := 0
	Run(BundledAppsNative_QuoteArg(Executable) . " " . BundledAppsNative_CommandLine(Args), , , &Pid)
	return Pid
}

/**
 * Shows a file selected in Explorer.
 * @param {String} Path
 */
BundledAppsNative_Reveal(Path) {
	Run('explorer.exe /select,' . BundledAppsNative_QuoteArg(Path))
}

/**
 * Writes a shortcut through the built-in FileCreateShortcut: the shell COM
 * object route counts against the exe's antivirus script-host ceiling
 * (tools/ci/windows-exe-av-surface.json).
 * @param {String} Path The .lnk to write.
 * @param {Map} Fields target, arguments, working_directory, icon (an
 *     IconLocation "file,index"), description.
 */
BundledAppsNative_WriteShortcut(Path, Fields) {
	IconFile := "", IconNumber := ""
	if Fields.Get("icon", "") != ""
		_BundledAppsNative_SplitIconLocation(Fields["icon"], &IconFile, &IconNumber)
	FileCreateShortcut(Fields["target"], Path, Fields.Get("working_directory", ""), Fields.Get("arguments", ""),
		Fields.Get("description", ""), IconFile, , IconNumber)
}

/**
 * Reads a shortcut's target, arguments and icon through the built-in
 * FileGetShortcut.
 * @param {String} Path
 * @returns {Map} target, arguments and icon as an IconLocation "file,index"
 *     ("" when the shortcut names no icon file).
 */
BundledAppsNative_ReadShortcut(Path) {
	FileGetShortcut(Path, &Target, , &Arguments, , &IconFile, &IconNumber)
	Icon := ""
	if IconFile != ""
		Icon := IconFile . "," . _BundledAppsNative_IconIndex(IconNumber)
	return Map("target", Target, "arguments", Arguments, "icon", Icon)
}

; Splits an IconLocation "file,index" into FileCreateShortcut's icon file and
; icon number: a zero-based index becomes the one-based number, a negative
; resource ID stays negative (both conventions mean a resource ID there).
_BundledAppsNative_SplitIconLocation(Location, &IconFile, &IconNumber) {
	if !RegExMatch(Location, "^(.*),(-?\d+)$", &Parts)
		throw ValueError("The shortcut icon must be an IconLocation ""file,index"": " . Location, -1)
	IconFile := Parts[1]
	Index := Integer(Parts[2])
	IconNumber := Index >= 0 ? Index + 1 : Index
}

; The zero-based IconLocation index of FileGetShortcut's icon number, which is
; blank for the first icon, one-based otherwise and negative for a resource ID.
_BundledAppsNative_IconIndex(IconNumber) {
	if IconNumber == ""
		return 0
	Ordinal := Integer(IconNumber)
	return Ordinal > 0 ? Ordinal - 1 : Ordinal
}

/**
 * Creates a directory junction (no administrator right needed, unlike a link).
 * @param {String} Link The junction to create.
 * @param {String} Target The existing folder it points at.
 * @returns {Boolean}
 */
BundledAppsNative_Junction(Link, Target) {
	ExitCode := RunWait(A_ComSpec . ' /c mklink /J ' . BundledAppsNative_QuoteArg(Link) . " "
		. BundledAppsNative_QuoteArg(Target) . " >NUL", , "Hide")
	return ExitCode == 0
}

; _shared/modules/config/outdated.ahk

; ==============================================================================
; MODULE: Shared Outdated File Entry Reports
; DESCRIPTION:
; Matches config_outdated.report_in_file: one warning per exact file, rendered
; entry path and reason during the process. Reporting never deletes user data
; or promises that config.toml cleanup owns another file. The reader supplies
; its central logger port; logger timing and consecutive deduplication do not
; decide whether a persisted obsolete entry has already been reported.
; ==============================================================================

/**
 * Reports an obsolete entry of a file outside config.toml once per process.
 * @param {String} FilePath The calling reader's exact persisted file identity.
 * @param {String} EntryPath The calling owner's rendered TOML entry path.
 * @param {String} Detail Why the published catalogue does not use the entry.
 * @param {Func} Warn The central logger's format-and-arguments warning port.
 * @returns {Boolean} True for the first report of this file, path and reason.
 */
ConfigOutdatedReportInFile(FilePath, EntryPath, Detail, Warn) {
	static Reported := Map()
	if !(FilePath is String) || FilePath == "" || !(EntryPath is String)
			|| EntryPath == "" || !(Detail is String) || !HasMethod(Warn, "Call")
		throw TypeError("An outdated file entry requires its file, rendered path, reason and warning owner.")
	; Native threads share this process-lifetime identity; protect only its
	; check/mark, then restore the caller before invoking the logger port.
	PreviousCritical := Critical("On")
	try {
		if !Reported.Has(FilePath)
			Reported[FilePath] := Map()
		Paths := Reported[FilePath]
		if !Paths.Has(EntryPath)
			Paths[EntryPath] := Map()
		Reasons := Paths[EntryPath]
		if Reasons.Has(Detail)
			return false
		Reasons[Detail] := true
	} finally Critical(PreviousCritical)
	Warn.Call("Outdated entry '{1}' in '{2}' ignored ({3}); the config cleanup only covers "
		. "config.toml, so fix or delete it in that file.", EntryPath, FilePath, Detail)
	return true
}

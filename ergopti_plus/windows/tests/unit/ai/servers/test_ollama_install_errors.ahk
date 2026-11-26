; tests/unit/ai/servers/test_ollama_install_errors.ahk

; ==============================================================================
; MODULE: Managed Ollama Install Error Tests (Windows)
; DESCRIPTION:
; OLL-04, OLL-05 and OLL-14 of the 2026-11-20 managed Ollama campaign: every failed
; install showed « Local Ollama could not be prepared », a full disk and an
; unreachable host alike, and only the PowerShell helper checked the archive's
; size against the volume. Replays the shared corpus, drives the real bootstrap
; flow with fake file actions, and runs the real PowerShell evidence writer on
; constructed exceptions. Nothing is downloaded or installed.
; ==============================================================================

#Requires AutoHotkey v2.0

_OIE_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\ollama_install_error_vectors.json", "UTF-8"))
}

_OIE_ReplaysTheCorpus() {
	Corpus := _OIE_Corpus()
	AssertTrue(Corpus["cases"].Length > 0, "the corpus names its cases")
	Seen := Map()
	for Vector in Corpus["cases"] {
		Class := LLM_OllamaInstallErrorClass(Vector["evidence"])
		AssertEqual(Vector["class"], Class, Vector["id"])
		AssertEqual("ollama.install_error." . Class, LLM_OllamaInstallErrorKey(Class), Vector["id"])
		AssertTrue(t(LLM_OllamaInstallErrorKey(Class)) != t("ollama.runtime_repair_failed"), Vector["id"] . " names its cause")
		Seen[Class] := true
	}
	for Class in ["network", "disk_full", "checksum", "permission", "cancelled", "unknown"]
		AssertTrue(Seen.Has(Class), "the corpus covers " . Class)
	for Vector in Corpus["free_space"]
		AssertEqual(Vector["fits"], LLM_OllamaInstallFits(Vector["asset_bytes"], Vector["unpacked_bytes"],
			Vector["margin_bytes"], Vector["free_bytes"]), Vector["id"])
	AssertThrows(() => LLM_OllamaInstallFits("", 0, 0, 1), "a missing asset size is refused, not guessed")
	AssertThrows(() => LLM_OllamaInstallFits(1, "", 0, 1), "a missing unpacked size is refused, not guessed")
	AssertThrows(() => LLM_OllamaInstallErrorKey("no_such_class"), "an unknown class has no message")
	; OLL-14: a model pull that filled the disk shows the full disk, as macOS and Linux do.
	AssertTrue(Corpus["pull_cases"].Length > 0, "the corpus names its pull cases")
	for Vector in Corpus["pull_cases"] {
		Class := LLM_OllamaPullInstallClass(Vector["pull_class"])
		AssertEqual(Vector.Get("class", ""), Class, Vector["id"])
		if Class != ""
			AssertEqual("ollama.pull_error." . Class, LLM_OllamaPullInstallKey(Class), Vector["id"])
	}
	AssertEqual("", LLM_OllamaPullInstallClass(""), "no pull class is no install class")
	AssertThrows(() => LLM_OllamaPullInstallKey("network"), "a class without a pull message has none")
}
Test("managed install errors: every shared vector has its class (ollama-install-error-vectors)", _OIE_ReplaysTheCorpus)

_OIE_RefusesMalformedData() {
	Path := A_Temp . "\ergopti_install_errors_" . A_TickCount . "_" . Random(1000, 999999) . ".json"
	try {
		for Text in ['{"schema_version":2,"messages":{"unknown":"ollama.install_error.unknown"},"classes":[["x","unknown"]]}',
				'{"schema_version":1,"messages":{},"classes":[["x","unknown"]]}',
				'{"schema_version":1,"messages":{"unknown":"ollama.install_error.unknown"},"classes":[["X","unknown"]]}',
				'{"schema_version":1,"messages":{"unknown":"ollama.install_error.unknown"},"classes":[["x","network"]]}',
				'{"schema_version":1,"messages":{"unknown":"ollama.install_error.unknown"},"classes":[["x","unknown"]]}',
				'{"schema_version":1,"messages":{"unknown":"ollama.install_error.unknown"},"classes":[["x","unknown"]],'
				. '"pull":{"no_space":"disk_full"},"pull_messages":{"unknown":"ollama.pull_error.unknown"}}'] {
			if FileExist(Path)
				FileDelete(Path)
			FileAppend(Text, Path, "UTF-8-RAW")
			AssertThrows(() => LLM_OllamaInstallErrors(Path), Text)
		}
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("managed install errors: a malformed data file is refused (ollama-install-error-vectors)", _OIE_RefusesMalformedData)

; The failure message the flow published, restored after the case.
_OIE_Failure(Setup) {
	global _LLM_Deps_FailureMessage
	Saved := _LLM_Deps_FailureMessage
	F := _G4B_Fixture()
	try {
		Setup.Call(F)
		F.Start()
		return {Fixture: F, Message: _LLM_Deps_FailureMessage}
	} finally {
		F.Close()
		_LLM_Deps_FailureMessage := Saved
	}
}

_OIE_NoRoomNoDownload() {
	Setup(F) {
		F.FreeBytes := 449
	}
	Result := _OIE_Failure(Setup)
	F := Result.Fixture
	AssertEqual(1, F.FreeReads, "the free space is read once, after the install consent")
	for Action in F.Calls
		AssertTrue(Action != "download", "nothing is downloaded on a volume without room")
	AssertEqual(1, F.FailedCalls)
	AssertEqual(t("ollama.install_error.disk_full"), Result.Message, "the disk words, not the generic failure")
}
Test("managed install errors: a volume without room for the archive, its runtime and its margin downloads nothing (ollama-install-free-space)",
	_OIE_NoRoomNoDownload)

_OIE_RoomDownloads() {
	Setup(F) {
		F.FreeBytes := 450
	}
	Result := _OIE_Failure(Setup)
	Downloads := 0
	for Action in Result.Fixture.Calls
		Downloads += Action == "download"
	AssertEqual(1, Downloads, "room for the archive, its runtime and its margin starts the download")
	AssertEqual(0, Result.Fixture.FailedCalls)
}
Test("managed install errors: room for the archive, its runtime and its margin downloads (ollama-install-free-space)",
	_OIE_RoomDownloads)

; OLL-14: the archive stays until its extraction ends, so room for the archive
; and the margin alone must not start a download the extraction cannot finish.
_OIE_UnpackedRuntimeCounts() {
	Setup(F) {
		F.FreeBytes := 150
	}
	Result := _OIE_Failure(Setup)
	for Action in Result.Fixture.Calls
		AssertTrue(Action != "download", "the unpacked runtime counts before the download")
	AssertEqual(t("ollama.install_error.disk_full"), Result.Message)
}
Test("managed install errors: room for the archive and its margin alone downloads nothing (ollama-install-free-space)",
	_OIE_UnpackedRuntimeCounts)

_OIE_UnreadableVolume() {
	Setup(F) {
		F.FreeBytes := OSError("unreadable volume")
	}
	Result := _OIE_Failure(Setup)
	for Action in Result.Fixture.Calls
		AssertTrue(Action != "download", "an unreadable volume downloads nothing")
	AssertEqual(t("ollama.install_error.unknown"), Result.Message)
}
Test("managed install errors: an unreadable volume refuses the install (ollama-install-free-space)", _OIE_UnreadableVolume)

_OIE_StepNamesItsClass(Action, Evidence, Key) {
	Setup(F) {
		F.Refusals[Action] := Evidence
	}
	Result := _OIE_Failure(Setup)
	AssertEqual(1, Result.Fixture.FailedCalls)
	AssertEqual(t(Key), Result.Message, Action . " refusal: " . Evidence)
}
for _OIE_Row in [
	["download", "stage=connect reason=download System.InvalidOperationException hresult=0x80131509 All artifact routes were refused.",
		"ollama.install_error.network"],
	["download", "stage=file_write reason=download System.Management.Automation.MethodInvocationException hresult=0x80131501 "
		. "System.IO.IOException hresult=0x80070070 Exception calling Write.", "ollama.install_error.disk_full"],
	["download", "stage=file_read reason=verify System.Management.Automation.RuntimeException hresult=0x80131501 "
		. "The complete acquired archive differs from its original identity or pin.", "ollama.install_error.checksum"],
	["prepare", "stage=prepare reason=install System.IO.IOException hresult=0x80070070 "
		. "The complete portable archive will not fit on the target volume.", "ollama.install_error.disk_full"],
	["publish", "stage=publish reason=install System.UnauthorizedAccessException hresult=0x80070005 Access is denied.",
		"ollama.install_error.permission"],
	["download", "", "ollama.install_error.unknown"]]
	Test("managed install errors: a refused " . _OIE_Row[1] . " names " . _OIE_Row[3] . " (ollama-install-errors)",
		_OIE_StepNamesItsClass.Bind(_OIE_Row*))

; The real evidence writer of ollama_managed_files.ps1, on exceptions built in
; place: a .NET call wraps its own exception, whose HRESULT names the cause
; whatever the Windows language.
_OIE_PowerShellEvidence() {
	global _StaticDir
	Helper := _StaticDir . "\ergopti_plus\windows\ai\engine\ollama\ollama_managed_files.ps1"
	ScriptPath := A_Temp . "\ergopti_install_evidence_" . A_TickCount . "_" . Random(1000, 999999) . ".ps1"
	OutPath := ScriptPath . ".out"
	Script := ". '" . Helper . "'`n"
		. "$full = [Management.Automation.MethodInvocationException]::new('Exception calling Write.', "
		. "[IO.IOException]::new('Espace insuffisant sur le disque.', -2147024784))`n"
		. "$lines = @((Get-OllamaFailureEvidence $full 'file_write' 'download'),`n"
		. "(Get-OllamaFailureEvidence ([ComponentModel.Win32Exception]::new(5)) 'file_create' 'download'),`n"
		. "(Get-OllamaFailureEvidence ([InvalidOperationException]::new('All artifact routes were refused.')) 'connect' 'download'),`n"
		. "(Get-OllamaFailureEvidence ([IO.IOException]::new('The pinned archive does not fit its private target volume.', -2147024784)) 'file_create' 'download'))`n"
		. "[IO.File]::WriteAllLines('" . OutPath . "', [string[]]$lines)`n"
	try {
		FileAppend(Script, ScriptPath, "UTF-8")
		Exit := RunWait('"' . A_WinDir . '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive '
			. '-ExecutionPolicy Bypass -File "' . ScriptPath . '"', , "Hide")
		AssertEqual(0, Exit, "the evidence writer runs")
		Lines := StrSplit(Trim(FileRead(OutPath, "UTF-8"), "`r`n"), "`n", "`r")
		AssertEqual(4, Lines.Length, "one line per exception: " . FileRead(OutPath, "UTF-8"))
		AssertEqual("stage=file_write reason=download System.Management.Automation.MethodInvocationException hresult=0x80131501 "
			. "System.IO.IOException hresult=0x80070070 Exception calling Write.", Lines[1])
		AssertEqual("disk_full", LLM_OllamaInstallErrorClass(Lines[1]))
		AssertEqual("permission", LLM_OllamaInstallErrorClass(Lines[2]), Lines[2])
		AssertEqual("network", LLM_OllamaInstallErrorClass(Lines[3]), Lines[3])
		AssertEqual("stage=file_create reason=download System.IO.IOException hresult=0x80070070 "
			. "The pinned archive does not fit its private target volume.", Lines[4])
		Corpus := _OIE_Corpus()
		for Vector in Corpus["cases"]
			if Vector["id"] == "windows_disk_full_precheck"
				AssertEqual(Vector["evidence"], Lines[4], "the corpus holds the helper's real precheck line")
	} finally {
		for Path in [ScriptPath, OutPath]
			if FileExist(Path)
				FileDelete(Path)
	}
}
Test("managed install errors: the PowerShell evidence names the cause by its codes (ollama-install-errors)", _OIE_PowerShellEvidence)

_OIE_FreeBytesOfAMissingFolder() {
	Free := LLM_OllamaInstallFreeBytes(A_Temp . "\ergopti-not-yet-" . A_TickCount . "\ollama")
	AssertTrue(Free is Integer && Free > 0, "the nearest existing folder's volume answers")
	AssertThrows(() => LLM_OllamaInstallFreeBytes("relative\path"), "a relative path is refused")
}
Test("managed install errors: free space of a root not created yet (ollama-install-free-space)", _OIE_FreeBytesOfAMissingFolder)

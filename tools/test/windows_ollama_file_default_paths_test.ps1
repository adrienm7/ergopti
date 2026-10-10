# tools/test/windows_ollama_file_default_paths_test.ps1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Helper,
	[string]$FixtureTest = '', [string]$ScratchRoot = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($FixtureTest -eq '') {
	$FixtureTest = [IO.Path]::GetFullPath([IO.Path]::Combine([IO.Path]::GetDirectoryName($Helper), '..\..\tests\unit\test_ollama_install_files.ps1'))
}
$tokens = $null; $errors = $null
$source = [IO.File]::ReadAllText($FixtureTest, [Text.UTF8Encoding]::new($false, $true))
$ast = [Management.Automation.Language.Parser]::ParseInput($source, $FixtureTest, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'The actual native fixture entry must parse.' }
$loader = @($ast.EndBlock.Statements | Where-Object {
	$_.Extent.Text -ceq ". ([IO.Path]::Combine(`$CandidateRoot, 'ollama_managed_files.ps1'))"
})
if ($loader.Count -ne 1) { throw 'The native fixture has one exact active helper-loading boundary.' }
$prefix = $source.Substring(0, $loader[0].Extent.StartOffset)
# Native stdout follows the console code page; ASCII transport keeps the actual
# Unicode argument observation independent of a hosted runner's OEM encoding.
$prefix += "`$record = [ordered]@{ candidate = `$CandidateRoot; fixtures = `$FixtureRoot; script_root = `$PSScriptRoot } | ConvertTo-Json -Compress`n"
$prefix += "[Convert]::ToBase64String([Text.UTF8Encoding]::new(`$false, `$true).GetBytes(`$record))`n"
[void][Management.Automation.Language.Parser]::ParseInput($prefix, $FixtureTest, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) { throw 'The actual fixture entry prefix must parse.' }
$owned = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ergopti-file-path-entry-' + [Guid]::NewGuid().ToString('N'))
$tests = [IO.Path]::Combine($owned, 'tests')
$directory = [IO.Path]::Combine($tests, 'unit')
[void][IO.Directory]::CreateDirectory($directory)
$entry = [IO.Path]::Combine($directory, 'test_ollama_install_files.ps1')
[IO.File]::WriteAllText($entry, $prefix, [Text.UTF8Encoding]::new($false))
$powershell = [IO.Path]::Combine($PSHOME, 'powershell.exe')
$expectedCandidate = [IO.Path]::GetFullPath([IO.Path]::Combine($directory, '..\..\modules\llm'))
$expectedFixture = [IO.Path]::GetFullPath([IO.Path]::Combine($directory, '..\fixtures\ollama-install-files'))
$oldLocation = (Get-Location).Path
$oldDirectory = [Environment]::CurrentDirectory
$oldOutputEncoding = [Console]::OutputEncoding
$unicodeSuffix = [string][char]0x03A9 + [char]0x6771
$foreign = @([IO.Path]::GetTempPath(), [Environment]::GetFolderPath('Windows'))
if ($ScratchRoot -ne '') { $foreign[0] = $ScratchRoot }
$passed = 0; $failed = 0
try {
	foreach ($codePage in @(437, 65001)) {
		[Console]::OutputEncoding = [Text.Encoding]::GetEncoding($codePage)
		foreach ($case in @('default-first-cwd', 'default-second-cwd', 'candidate-override', 'fixture-override')) {
			try {
				$cwd = if ($case -ceq 'default-second-cwd') { $foreign[1] } else { $foreign[0] }
				Set-Location -LiteralPath $cwd
				[Environment]::CurrentDirectory = $cwd
				if ($case -ceq 'candidate-override') {
					$override = [IO.Path]::Combine($cwd, ('synthetic candidate ' + $unicodeSuffix))
					$raw = & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -CandidateRoot $override 2>&1
					$childExit = $LASTEXITCODE
					if ($childExit -ne 0) { throw 'The actual file entry child must exit successfully.' }
					$observed = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(($raw -join "`n"))) | ConvertFrom-Json
					if ($observed.candidate -cne $override -or $observed.fixtures -cne $expectedFixture) { throw 'Explicit candidate override lost its exact owner.' }
				} elseif ($case -ceq 'fixture-override') {
					$override = [IO.Path]::Combine($cwd, ('synthetic fixtures ' + $unicodeSuffix))
					$raw = & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry -FixtureRoot $override 2>&1
					$childExit = $LASTEXITCODE
					if ($childExit -ne 0) { throw 'The actual file entry child must exit successfully.' }
					$observed = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(($raw -join "`n"))) | ConvertFrom-Json
					if ($observed.fixtures -cne $override -or $observed.candidate -cne $expectedCandidate) { throw 'Explicit fixture override lost its exact owner.' }
				} else {
					$raw = & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $entry 2>&1
					$childExit = $LASTEXITCODE
					if ($childExit -ne 0) { throw 'The actual file entry child must exit successfully.' }
					$observed = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(($raw -join "`n"))) | ConvertFrom-Json
					if ($observed.candidate -cne $expectedCandidate -or $observed.fixtures -cne $expectedFixture) { throw 'Omitted paths must resolve against the actual script, never the foreign CWD.' }
				}
				if ($observed.script_root -cne $directory) { throw 'The actual script entry identity was not retained.' }
				$passed++; Write-Output ('PASS cp' + $codePage + '/' + $case)
			} catch { $failed++; Write-Output ('FAIL cp' + $codePage + '/' + $case + ': ' + $_.Exception.Message) }
		}
	}
} finally {
	[Console]::OutputEncoding = $oldOutputEncoding
	Set-Location -LiteralPath $oldLocation
	[Environment]::CurrentDirectory = $oldDirectory
	[IO.File]::Delete($entry)
	[IO.Directory]::Delete($directory)
	[IO.Directory]::Delete($tests)
	[IO.Directory]::Delete($owned)
}
Write-Output ("RESULT passed=$passed failed=$failed native_calls=0 real_file_acquisitions=0")
if ($failed) { exit 1 }

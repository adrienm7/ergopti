# tests/unit/test_ollama_managed_bootstrap.ps1
# Native Windows managed-bootstrap file acceptance. Inert independent fixtures.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..\..\modules\llm\ollama_managed_files.ps1'))
. $module
Initialize-OllamaManagedNative
$fixture = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..\fixtures\ollama-install-files'))
$receipt = ([IO.File]::ReadAllText([IO.Path]::Combine($fixture, 'receipts.json')) | ConvertFrom-Json).portable
$ticket = [Guid]::NewGuid().ToString('N')
$runtime = [Guid]::NewGuid().ToString('N')
$rootPath = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'ergopti-bootstrap-test-' + $ticket)
$catalogue = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ergopti-bootstrap-source-' + $ticket + '.json')
Write-OllamaOwnedJson $catalogue ([ordered]@{ schema_version = 1; version = '0.24.0'; assets = [ordered]@{
	'windows-amd64' = [ordered]@{ filename = 'ollama-windows-amd64.zip'; bytes = $receipt.bytes; sha256 = $receipt.sha256 }
} })
$source = Open-OllamaReadFile $catalogue
try { $digest = Get-OllamaStreamHash $source } finally { $source.Dispose() }
$script:passed = 0; $script:failed = 0
function Assert-Bootstrap([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw ('ASSERTION: ' + $Message) }
}
function Case([string]$Name, [scriptblock]$Body) {
	try { & $Body; $script:passed++; Write-Output ('PASS ' + $Name) }
	catch { $script:failed++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Refuse([scriptblock]$Body) {
	$refused = $false
	try { & $Body | Out-Null } catch { $refused = $true }
	Assert-Bootstrap $refused 'Actual native operation must refuse.'
}
$root = $null; $archive = $null; $stage = $null
try {
	$root = Open-OllamaManagedRoot $rootPath
	$archive = Read-OllamaPinnedArchive $catalogue $digest 'windows-amd64' ([IO.Path]::Combine($fixture, 'portable.zip')) 0 0
	Case 'missing pinned version is inspection only' {
		$before = @([IO.Directory]::EnumerateFileSystemEntries($root.path) | Sort-Object)
		$result = Inspect-OllamaPublishedVersion $root $archive
		Assert-Bootstrap ($result.ok -and $result.phase -ceq 'missing') 'Missing inspection succeeds without installation.'
		$after = @([IO.Directory]::EnumerateFileSystemEntries($root.path) | Sort-Object)
		Assert-Bootstrap (($before -join "`n") -ceq ($after -join "`n")) 'Inspection creates no stage, journal or selector.'
	}
	$prepared = Prepare-OllamaManagedStage $root $archive $ticket
	$stage = Open-OllamaPreparedStage $root $ticket $prepared.stage_identity $prepared.manifest_sha256
	$published = Publish-OllamaPreparedStage $root $stage
	Close-OllamaPreparedStage $stage; $stage = $null
	Case 'pinned immutable version is reusable through fresh full inventory' {
		$result = Inspect-OllamaPublishedVersion $root $archive
		Assert-Bootstrap ($result.ok -and $result.phase -ceq 'published') 'Published inspection is admitted.'
		Assert-Bootstrap ($result.ticket -ceq $ticket -and $result.root_identity -ceq $root.identity) 'Originating tickets/root survive reuse.'
		Assert-Bootstrap ($result.version_identity -ceq $published.version_identity -and $result.manifest_sha256 -ceq $prepared.manifest_sha256) 'Fresh exact source/version identities survive reuse.'
	}
	Case 'changed catalogue cannot borrow published authority' {
		$captured = $archive.catalogue_sha256
		try { $archive.catalogue_sha256 = 'f' * 64; Refuse { Inspect-OllamaPublishedVersion $root $archive } }
		finally { $archive.catalogue_sha256 = $captured }
		Assert-Bootstrap ([IO.File]::Exists($published.executable)) 'Refusal preserves installed bytes.'
	}
	Case 'publication source journal retires without deleting version' {
		$result = Remove-OllamaPartialStage $root $ticket $prepared.creation_wal_identity $prepared.creation_wal_sha256
		Assert-Bootstrap $result.ok 'The exact old stage journal retires.'
		Assert-Bootstrap ([IO.File]::Exists($published.executable)) 'The immutable version remains.'
	}
	Case 'absent runtime receipt needs no invented image' {
		$result = Remove-OllamaRuntimeReceipt $root $root.identity $ticket $runtime '' ''
		Assert-Bootstrap $result.ok 'Exact ticket absence retires safely.'
	}
	$readyPath = [IO.Path]::Combine($root.path, '.runtime-' + $runtime + '.json')
	Write-OllamaOwnedJson $readyPath ([ordered]@{ runtime_ticket = $runtime; ticket = $ticket; root_identity = $root.identity; child_created_filetime = 133700000000000000L })
	$ready = Open-OllamaReadFile $readyPath
	try { $readyIdentity = [Ergopti.Ollama.ManagedNative]::Identity($ready.SafeFileHandle.DangerousGetHandle()); $readyHash = Get-OllamaStreamHash $ready }
	finally { $ready.Dispose() }
	Case 'unobserved present runtime receipt retains physical debt' {
		Refuse { Remove-OllamaRuntimeReceipt $root $root.identity $ticket $runtime '' '' }
		Assert-Bootstrap ([IO.File]::Exists($readyPath)) 'Present unowned bytes remain.'
	}
	Case 'foreign root or wrong image cannot retire receipt' {
		Refuse { Remove-OllamaRuntimeReceipt $root '00000000:0000000000000000' $ticket $runtime $readyIdentity $readyHash }
		Refuse { Remove-OllamaRuntimeReceipt $root $root.identity $ticket $runtime $readyIdentity ('f' * 64) }
		Assert-Bootstrap ([IO.File]::Exists($readyPath)) 'Both refusals preserve the exact receipt.'
	}
	Case 'older present receipt cannot invent child creation identity' {
		$oldRuntime = [Guid]::NewGuid().ToString('N')
		$oldPath = [IO.Path]::Combine($root.path, '.runtime-' + $oldRuntime + '.json')
		Write-OllamaOwnedJson $oldPath ([ordered]@{ runtime_ticket = $oldRuntime; ticket = $ticket; root_identity = $root.identity })
		$oldStream = Open-OllamaReadFile $oldPath
		try { $oldIdentity = [Ergopti.Ollama.ManagedNative]::Identity($oldStream.SafeFileHandle.DangerousGetHandle()); $oldHash = Get-OllamaStreamHash $oldStream }
		finally { $oldStream.Dispose() }
		Refuse { Remove-OllamaRuntimeReceipt $root $root.identity $ticket $oldRuntime $oldIdentity $oldHash }
		Assert-Bootstrap ([IO.File]::Exists($oldPath)) 'An older exact image remains owned debt without invented provenance.'
	}
	Case 'observed exact runtime receipt physically retires' {
		$result = Remove-OllamaRuntimeReceipt $root $root.identity $ticket $runtime $readyIdentity $readyHash
		Assert-Bootstrap ($result.ok -and [Ergopti.Ollama.ManagedNative]::PathIsAbsent($readyPath)) 'Actual file identity/image retire before ACK.'
	}
} finally {
	if ($null -ne $stage) { Close-OllamaPreparedStage $stage }
	if ($null -ne $archive) { Close-OllamaPinnedArchive $archive }
	if ($null -ne $root) { Close-OllamaManagedRoot $root }
	Write-Output ('Evidence root: ' + $rootPath)
	Write-Output ('Source receipt: ' + $catalogue)
	Write-Output ('RESULT passed=' + $script:passed + ' failed=' + $script:failed + ' skipped=0')
}
if ($script:failed -ne 0) { exit 1 }

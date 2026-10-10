# Native Windows acceptance candidate. All ZIP payloads are inert fixture text.
# Not registered or executed in the Linux cloud container.
[CmdletBinding()]
param(
	[string]$CandidateRoot,
	[string]$FixtureRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PSScriptRoot is established for the body, after default parameter binding.
# Resolve only omitted arguments; explicit fixture overrides keep their owner.
if (-not $PSBoundParameters.ContainsKey('CandidateRoot')) {
	$CandidateRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..\..\modules\llm'))
}
if (-not $PSBoundParameters.ContainsKey('FixtureRoot')) {
	$FixtureRoot = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '..\fixtures\ollama-install-files'))
}
. ([IO.Path]::Combine($CandidateRoot, 'ollama_managed_files.ps1'))
Initialize-OllamaManagedNative
$fixtures = $FixtureRoot
$receipts = [IO.File]::ReadAllText([IO.Path]::Combine($fixtures, 'receipts.json')) | ConvertFrom-Json
$payloads = [IO.File]::ReadAllText([IO.Path]::Combine($fixtures, 'payloads.json')) | ConvertFrom-Json
$token = [Guid]::NewGuid().ToString('N')
$rootPath = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'ergopti-ollama-test-' + $token)
$sourcePath = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'ergopti-ollama-source-' + $token)
[void][IO.Directory]::CreateDirectory($sourcePath)
$script:passed = 0
$script:failed = 0
$script:source_index = 0
$script:partial_receipt = $null
$script:partial_ticket = ''
function Assert-Receipt([bool]$Condition, [string]$Message) {
	if (-not $Condition) { throw ('ASSERTION: ' + $Message) }
}
function Case([string]$Name, [scriptblock]$Body) {
	try { & $Body; $script:passed++; Write-Output ('PASS ' + $Name) }
	catch { $script:failed++; Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Must-Refuse([scriptblock]$Body) {
	$refused = $false
	try { & $Body | Out-Null } catch { $refused = $true }
	Assert-Receipt $refused 'The actual native owner must refuse this operation.'
}
function Open-Fixture([string]$Name, [long]$Budget = 0, [int]$Count = 0) {
	$receipt = $receipts.PSObject.Properties[$Name].Value
	# This independent fixture catalogue admits only inert test payloads. It is
	# never copied over the authoritative production catalogue.
	$catalogue = [ordered]@{ schema_version = 1; version = '0.24.0'; assets = [ordered]@{
		'windows-amd64' = [ordered]@{ filename = 'ollama-windows-amd64.zip'; bytes = $receipt.bytes; sha256 = $receipt.sha256 }
	} }
	$path = [IO.Path]::Combine($sourcePath, $Name + '-' + (++$script:source_index) + '.json')
	Write-OllamaOwnedJson $path $catalogue
	$read = Open-OllamaReadFile $path
	try { $hash = Get-OllamaStreamHash $read } finally { $read.Dispose() }
	return Read-OllamaPinnedArchive $path $hash 'windows-amd64' ([IO.Path]::Combine($fixtures, $Name + '.zip')) $Budget $Count
}
$root = $null
$archive = $null
$prepared = $null
try {
	Case 'native protected current-user root and exclusive ownership receipt' {
		$script:root = Open-OllamaManagedRoot $rootPath
		Assert-OllamaPrivateSecurity $rootPath
		Assert-Receipt ([IO.File]::Exists([IO.Path]::Combine($rootPath, 'root-owner.json'))) 'Root ownership marker exists.'
	}
	foreach ($name in @('traversal', 'ads', 'rooted', 'device', 'collision', 'trailing-dot', 'receipt-collision', 'directory-cli', 'symlink')) {
		# Bind each fixture name through an independent function scope.
		function Refuse-Fixture([string]$FixtureName) { Case ('reject ' + $FixtureName) { Must-Refuse { Open-Fixture $FixtureName } } }
		Refuse-Fixture $name
	}
	foreach ($name in @('file-ancestor-cli', 'file-ancestor-library', 'file-ancestor-reverse', 'file-ancestor-case', 'prepared-receipt-descendant', 'owner-receipt-descendant')) {
		function Refuse-NamespaceFixture([string]$FixtureName) {
			Case ('reject namespace before stage/WAL: ' + $FixtureName) {
				$before = @([IO.Directory]::EnumerateFileSystemEntries($root.path) | Sort-Object)
				Must-Refuse { Open-Fixture $FixtureName }
				$after = @([IO.Directory]::EnumerateFileSystemEntries($root.path) | Sort-Object)
				Assert-Receipt (($before -join "`n") -ceq ($after -join "`n")) 'Namespace refusal must not acquire a stage or creation WAL.'
			}
		}
		Refuse-NamespaceFixture $name
	}
	Case 'full portable extraction retains every inert library and prerequisite payload' {
		$script:archive = Open-Fixture 'portable'
		$script:prepared = Prepare-OllamaManagedStage $root $archive $token
		Assert-Receipt ($prepared.ok -and $prepared.files -eq 4) 'All four independently declared files extracted.'
		foreach ($property in $payloads.PSObject.Properties) {
			$actual = [IO.File]::ReadAllBytes([IO.Path]::Combine($prepared.stage, $property.Name.Replace('/', '\')))
			Assert-Receipt (([BitConverter]::ToString($actual).Replace('-', '').ToLowerInvariant()) -eq $property.Value.hex) ('Exact independent payload: ' + $property.Name)
		}
	}
	Case 'archive reader lock excludes concurrent byte replacement' {
		Must-Refuse { $write = [IO.File]::Open($archive.archive_stream.Name, 'Open', 'Write', 'ReadWrite'); $write.Dispose() }
	}
	Case 'admitted expanded byte budget rejects portable extraction before stage creation' {
		Must-Refuse { Open-Fixture 'portable' 1 }
	}
	Case 'admitted entry budget rejects portable extraction before stage creation' {
		Must-Refuse { Open-Fixture 'portable' 0 1 }
	}
	Case 'foreign stage content blocks exact prepared publication' {
		$foreign = [IO.Path]::Combine($prepared.stage, 'foreign.txt')
		Write-OllamaOwnedJson $foreign @{ foreign = $true }
		Must-Refuse { Open-OllamaPreparedStage $root $token $prepared.stage_identity $prepared.manifest_sha256 }
		# This case owns the exact deliberately introduced test file only.
		$read = Open-OllamaReadFile $foreign $true
		Remove-OllamaExactFile $read
	}
	Case 'physical exact stage receipt rejects borrowed identity' {
		Must-Refuse { Open-OllamaPreparedStage $root $token '00000000:0000000000000000' $prepared.manifest_sha256 }
	}
	Case 'prepared receipt hash rejects changed source before publication' {
		Must-Refuse { Open-OllamaPreparedStage $root $token $prepared.stage_identity ('0' * 64) }
	}
	Case 'immutable no-replace native version publication' {
		$stage = Open-OllamaPreparedStage $root $token $prepared.stage_identity $prepared.manifest_sha256
		try {
			$published = Publish-OllamaPreparedStage $root $stage
			Assert-Receipt ($published.version_identity -eq $prepared.stage_identity) 'Physical directory identity survives publication.'
			Assert-Receipt ([IO.File]::Exists($published.executable)) 'Published CLI path exists.'
			$script:published = $published
		} finally { Close-OllamaPreparedStage $stage }
	}
	Case 'cleanup acknowledges exact source path absence after publication without deleting version' {
		$retired = Remove-OllamaPreparedStage $root $token $prepared.stage_identity $prepared.manifest_sha256
		Assert-Receipt $retired.ok 'Old private stage retired.'
		Assert-Receipt ([IO.File]::Exists($published.executable)) 'Immutable published version remains.'
	}
	Case 'existing version refuses replacement and exact unpublished duplicate can retire' {
		$otherTicket = [Guid]::NewGuid().ToString('N')
		$other = Prepare-OllamaManagedStage $root $archive $otherTicket
		$stage = Open-OllamaPreparedStage $root $otherTicket $other.stage_identity $other.manifest_sha256
		try { Must-Refuse { Publish-OllamaPreparedStage $root $stage } }
		finally { Close-OllamaPreparedStage $stage }
		$retired = Remove-OllamaPreparedStage $root $otherTicket $other.stage_identity $other.manifest_sha256
		Assert-Receipt $retired.ok 'Exact duplicate stage retired.'
		Assert-Receipt ([IO.File]::Exists($published.executable)) 'Original published version survived duplicate refusal and cleanup.'
	}
	Case 'causal interruption durably owns empty CLI before any extracted content write' {
		$script:partial_ticket = [Guid]::NewGuid().ToString('N')
		$failure = $null
		try {
			Prepare-OllamaManagedStage $root $archive $partial_ticket $false { param($Path, $Identity) throw 'Independent interruption after exact owned-file WAL admission.' } | Out-Null
		} catch { $failure = $_.Exception }
		Assert-Receipt ($null -ne $failure) 'The injected physical boundary actually interrupts extraction.'
		Assert-Receipt ($failure.Data.Contains('ollama_creation_receipt')) 'Partial extraction publishes an exact creation receipt, not incidental missing-manifest failure.'
		$script:partial_receipt = $failure.Data['ollama_creation_receipt']
		$wal = Read-OllamaCreationWal $root $partial_ticket $partial_receipt.creation_wal_identity $partial_receipt.creation_wal_sha256
		try {
			Assert-Receipt ($wal.objects.ContainsKey('ollama.exe') -and $wal.objects['ollama.exe'].identity -ne '') 'Exact CLI identity is durable before payload bytes.'
			$cli = [IO.Path]::Combine($root.path, '.stage-' + $partial_ticket, 'ollama.exe')
			Assert-Receipt ((Get-Item -LiteralPath $cli).Length -eq 0) 'The interruption precedes the first extracted payload byte.'
			Assert-Receipt (-not [IO.File]::Exists([IO.Path]::Combine($root.path, '.stage-' + $partial_ticket, 'prepared.json'))) 'There is no final-manifest authority to borrow.'
		} finally { $wal.stream.Dispose() }
	}
	Case 'partial cleanup rejects changed journal image and preserves exact CLI' {
		Must-Refuse { Remove-OllamaPartialStage $root $partial_ticket $partial_receipt.creation_wal_identity ('0' * 64) }
		Assert-Receipt ([IO.File]::Exists([IO.Path]::Combine($root.path, '.stage-' + $partial_ticket, 'ollama.exe'))) 'Wrong-source refusal preserves the owned CLI.'
	}
	Case 'partial cleanup rejects foreign replacement without deleting it' {
		$cli = [IO.Path]::Combine($root.path, '.stage-' + $partial_ticket, 'ollama.exe')
		$old = $cli + '.fixture-owned-original'
		[IO.File]::Move($cli, $old)
		$replacement = [Ergopti.Ollama.ManagedNative]::CreateOwnedFile($cli)
		try {
			$bytes = [Text.Encoding]::ASCII.GetBytes('Independent foreign replacement.')
			$replacement.Write($bytes, 0, $bytes.Length); $replacement.Flush($true)
		} finally { $replacement.Dispose() }
		try {
			Must-Refuse { Remove-OllamaPartialStage $root $partial_ticket $partial_receipt.creation_wal_identity $partial_receipt.creation_wal_sha256 }
			Assert-Receipt ([IO.File]::ReadAllText($cli) -eq 'Independent foreign replacement.') 'Foreign replacement survives refused partial cleanup.'
		} finally {
			# Repair only the exact independently introduced fixture object and
			# return the original physical file, preserving its journal identity.
			$replacement = Open-OllamaReadFile $cli $true
			Remove-OllamaExactFile $replacement
			[IO.File]::Move($old, $cli)
		}
	}
	Case 'exact partial cleanup retires owned zero-byte file and absent final manifest' {
		$retired = Remove-OllamaPartialStage $root $partial_ticket $partial_receipt.creation_wal_identity $partial_receipt.creation_wal_sha256
		Assert-Receipt $retired.ok 'Actual partial cleanup acknowledges native physical retirement.'
		Assert-Receipt ([Ergopti.Ollama.ManagedNative]::PathIsAbsent([IO.Path]::Combine($root.path, '.stage-' + $partial_ticket))) 'Exact partial stage is physically absent.'
		Assert-Receipt ([Ergopti.Ollama.ManagedNative]::PathIsAbsent([IO.Path]::Combine($root.path, '.creation-' + $partial_ticket + '.jsonl'))) 'Exact creation journal retires after its objects.'
	}
	Case 'creation-before-identity crash window preserves ambiguous stage debt' {
		$windowTicket = [Guid]::NewGuid().ToString('N')
		$wal = Begin-OllamaCreationWal $root $archive $windowTicket
		$handle = [IntPtr]::Zero
		try {
			Add-OllamaCreationRecord $wal 'stage-intent' '' ''
			$stagePath = [IO.Path]::Combine($root.path, '.stage-' + $windowTicket)
			[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($stagePath, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
			$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($stagePath, $true)
			$physicalIdentity = [Ergopti.Ollama.ManagedNative]::Identity($handle)
			$old = Get-OllamaCreationReceipt $wal
			$wal.stream.Dispose()
			Must-Refuse { Remove-OllamaPartialStage $root $windowTicket $old.creation_wal_identity $old.creation_wal_sha256 }
			Assert-Receipt ([IO.Directory]::Exists($stagePath)) 'Unproven present stage survives cleanup refusal.'
			Assert-Receipt ([IO.File]::Exists($wal.path)) 'Discoverable exact journal debt survives refusal.'
			# This fixture retains its original creation handle independently.
			# Repair requires that exact proof; a real crash has no such authority.
			$wal.stream = [IO.File]::Open($wal.path, 'Open', 'ReadWrite', 'Read')
			Assert-Receipt ([Ergopti.Ollama.ManagedNative]::Identity($wal.stream.SafeFileHandle.DangerousGetHandle()) -eq $old.creation_wal_identity) 'Fixture repair retains the exact original journal object.'
			Assert-Receipt ((Get-OllamaStreamHash $wal.stream) -eq $old.creation_wal_sha256) 'Fixture repair retains the exact original journal image.'
			Add-OllamaCreationRecord $wal 'stage-owned' '' $physicalIdentity
			$repaired = Get-OllamaCreationReceipt $wal
			$wal.stream.Dispose()
			Assert-Receipt ([Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) 'Fixture native handle closes.'
			$handle = [IntPtr]::Zero
			$retired = Remove-OllamaPartialStage $root $windowTicket $repaired.creation_wal_identity $repaired.creation_wal_sha256
			Assert-Receipt $retired.ok 'Independent retained creation authority retires the fixture only after repair.'
		} finally {
			$wal.stream.Dispose()
			if ($handle -ne [IntPtr]::Zero) { Assert-Receipt ([Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) 'Fixture cleanup closes retained creation handle.' }
		}
	}
} finally {
	if ($null -ne $archive) { Close-OllamaPinnedArchive $archive }
	if ($null -ne $root) { Close-OllamaManagedRoot $root }
	# Preserve native evidence and the immutable published fixture version. No
	# wildcard recursive removal or replacement of production/user directories.
	Write-Output ('Evidence root: ' + $rootPath)
	Write-Output ('Independent source receipts: ' + $sourcePath)
	Write-Output ('RESULT passed=' + $script:passed + ' failed=' + $script:failed + ' skipped=0')
}
if ($script:failed -ne 0) { exit 1 }

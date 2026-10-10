# modules/llm/ollama_managed_acquisition.ps1
# Library-only finite archive acquisition over the canonical authenticated owner.
# Load verified managed-files, updater-download and network-route owners first.
Set-StrictMode -Version Latest

function New-OllamaOwnedCurlCapture($Wal, [string]$Stage, $Directories) {
	$relative = 'curl.' + [Guid]::NewGuid().ToString('N')
	Add-OllamaCreationRecord $Wal 'directory-intent' $relative ''
	$path = [IO.Path]::Combine($Stage, $relative)
	[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($path, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
	$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($path, $false)
	$Directories.Add($relative, $handle)
	Add-OllamaCreationRecord $Wal 'directory-owned' $relative ([Ergopti.Ollama.ManagedNative]::Identity($handle))
	foreach ($name in @('artifact.bin', 'headers.bin', 'capability.json', 'transport.conf', 'payload.bin')) {
		$owned = New-OllamaExtractedFile $Wal $Stage ($relative + '/' + $name)
		try { $owned.stream.Flush($true) } finally { $owned.stream.Dispose() }
	}
	return $path
}

function Invoke-OllamaManagedArchiveDownload {
	param($Root, $Source, [string]$Ticket, [int]$ConnectTimeoutMs,
		[int]$DeadlineMs, [int64]$StartedTick, [string]$PolicyPath,
		[string]$DefaultsPath, [scriptblock]$ReadConfig = $null,
		[scriptblock]$ReadEnvironment = $null)
	if ($Ticket -cnotmatch '^[0-9a-f]{32}\z' -or $Source.stream -isnot [IO.Stream] -or
		-not $Source.stream.CanRead -or $ConnectTimeoutMs -le 0 -or
		$DeadlineMs -le 0 -or $StartedTick -le 0) { throw 'Managed archive acquisition requires its original source and clock.' }
	$state = @{ Stage = 'file_create'; Reason = 'download'; Receipt = @{};
		CleanupDebt = @(); NativeCleanupDebt = $false }
	$null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $state
	$stagePath = [IO.Path]::Combine($Root.path, '.stage-' + $Ticket)
	$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($stagePath))
	if ($drive.AvailableFreeSpace -lt $Source.pin.bytes) { throw 'The pinned archive does not fit its private target volume.' }
	$wal = Begin-OllamaCreationWal $Root $Source $Ticket
	$stageHandle = [IntPtr]::Zero
	$directories = [ordered]@{}
	$capture = @{ output_owner = $null }
	$primaryFailure = $null
	try {
		$construction = Get-OllamaCreationReceipt $wal
		$construction.phase = 'creation-owned'
		[Console]::Out.WriteLine(($construction | ConvertTo-Json -Compress))
		Add-OllamaCreationRecord $wal 'stage-intent' '' ''
		[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($stagePath, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
		$stageHandle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($stagePath, $true)
		$stageIdentity = [Ergopti.Ollama.ManagedNative]::Identity($stageHandle)
		Add-OllamaCreationRecord $wal 'stage-owned' '' $stageIdentity
		$state.OwnedCaptureDirectory = New-OllamaOwnedCurlCapture $wal $stagePath $directories
		$destination = [IO.Path]::Combine($stagePath, $Source.pin.filename)
		$factory = {
			param($Path, $Size)
			if ($Path -cne $destination -or $Size -ne $Source.pin.bytes) { throw 'The captured archive output request changed.' }
			$null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $state
			$capture.output_owner = New-OllamaExtractedFile $wal $stagePath $Source.pin.filename
			$capture.output_owner.is_current = {
				param($Owner)
				return $Source.stream.CanRead -and
					[Ergopti.Ollama.ManagedNative]::Identity($stageHandle) -ceq $stageIdentity -and
					[Ergopti.Ollama.ManagedNative]::Identity($Owner.stream.SafeFileHandle.DangerousGetHandle()) -ceq $Owner.identity
			}
			return $capture.output_owner
		}
		$resolver = {
			param($DestinationUrl, $RemainingMs)
			return Resolve-ErgoptiNativeNetworkRoutes $DestinationUrl $RemainingMs $ReadConfig $ReadEnvironment $PolicyPath $DefaultsPath
		}
		$bytes = Invoke-ErgoptiUpdaterCurlDownload ([Uri]$Source.url) $destination $ConnectTimeoutMs $state $resolver $DeadlineMs $StartedTick $Source.pin.bytes $PolicyPath $DefaultsPath $ReadEnvironment $factory
		# The native copy owner has closed its output. Reacquire the exact file,
		# reject a replaced object, and consume all bytes under the read lease.
		$read = Open-OllamaReadFile $destination
		try {
			if ($null -eq $capture.output_owner -or $bytes -ne $Source.pin.bytes -or
				[Ergopti.Ollama.ManagedNative]::Identity($read.SafeFileHandle.DangerousGetHandle()) -cne $capture.output_owner.identity -or
				$read.Length -ne $Source.pin.bytes -or (Get-OllamaStreamHash $read) -cne $Source.pin.sha256) {
				throw 'The complete acquired archive differs from its original identity or pin.'
			}
		} finally { $read.Dispose() }
		$null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $state
		$receipt = Get-OllamaCreationReceipt $wal
		return [ordered]@{ ok = $true; phase = 'downloaded'; ticket = $Ticket;
			root_identity = $Root.identity; stage_identity = $stageIdentity;
			archive_identity = $capture.output_owner.identity; archive = $destination;
			bytes = $bytes; sha256 = $Source.pin.sha256;
			creation_wal_identity = $receipt.creation_wal_identity;
			creation_wal_sha256 = $receipt.creation_wal_sha256 }
	} catch {
		$failure = $_
		$primaryFailure = $failure
		try { $failure.Exception.Data['ollama_creation_receipt'] = Get-OllamaCreationReceipt $wal }
		catch { [Console]::Error.WriteLine('Archive refusal cannot prove its final creation journal image.') }
		throw $failure.Exception
	} finally {
		# Capture files are WAL-owned; the curl owner never recursively removes them.
		# Only later exact cleanup_partial may retire these retained file debts.
		$closeFailure = $null
		$finalReceipt = $null
		try { $finalReceipt = Get-OllamaCreationReceipt $wal }
		catch { $closeFailure = $_ }
		foreach ($key in @($directories.Keys)) {
			try {
				if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($directories[$key])) { throw 'Archive capture retains exact directory close debt.' }
				$directories.Remove($key)
			} catch { if ($null -eq $closeFailure) { $closeFailure = $_ } }
		}
		try { $wal.stream.Dispose() } catch { if ($null -eq $closeFailure) { $closeFailure = $_ } }
		try {
			if ($stageHandle -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($stageHandle)) { throw 'Archive acquisition retains exact stage close debt.' }
		} catch { if ($null -eq $closeFailure) { $closeFailure = $_ } }
		# Expiry rejects forward success after hashing and physical closure. It never
		# prevents exact cleanup, nor hides an earlier native/file refusal.
		if ($null -eq $primaryFailure -and $null -eq $closeFailure) {
			try { $null = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $state }
			catch { $closeFailure = $_ }
		}
		if ($null -ne $closeFailure) {
			if ($null -ne $finalReceipt) { $closeFailure.Exception.Data['ollama_creation_receipt'] = $finalReceipt }
			if ($null -eq $primaryFailure) { throw $closeFailure.Exception }
			$primaryFailure.Exception.Data['ollama_cleanup_pending'] = $true
			[Console]::Error.WriteLine('Archive cleanup retains exact physical debt.')
		}
	}
}

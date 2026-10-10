# modules/llm/ollama_download_archive.ps1
# Finite pinned acquisition; the existing task owner retains all returned debts.
[CmdletBinding()]
param(
	[ValidateSet('download')][string]$Action,
	[Parameter(Mandatory = $true)][string]$ManagedRoot,
	[Parameter(Mandatory = $true)][string]$CataloguePath,
	[Parameter(Mandatory = $true)][string]$CatalogueSha256,
	[Parameter(Mandatory = $true)][string]$AssetId,
	[Parameter(Mandatory = $true)][string]$TicketId,
	[Parameter(Mandatory = $true)][string]$ManagedHelperPath,
	[Parameter(Mandatory = $true)][string]$ManagedHelperSha256,
	[Parameter(Mandatory = $true)][string]$AcquisitionHelperPath,
	[Parameter(Mandatory = $true)][string]$AcquisitionHelperSha256,
	[Parameter(Mandatory = $true)][string]$VendorDirectory,
	[Parameter(Mandatory = $true)][string]$VendorSha256,
	[Parameter(Mandatory = $true)][string]$ProxyPolicyPath,
	[Parameter(Mandatory = $true)][string]$ProxyPolicySha256,
	[Parameter(Mandatory = $true)][string]$UpdaterDefaultsPath,
	[Parameter(Mandatory = $true)][string]$UpdaterDefaultsSha256,
	[Parameter(Mandatory = $true)][int]$ConnectTimeoutMs,
	[Parameter(Mandatory = $true)][int]$DeadlineMs,
	[Parameter(Mandatory = $true)][int64]$StartedTick
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-OllamaCapturedSource([string]$Path, [string]$ExpectedHash = '') {
	if ($Path -cnotmatch '^[A-Za-z]:\\' -or ($ExpectedHash -ne '' -and $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z')) {
		throw 'Acquisition code requires its captured absolute source identity.'
	}
	$stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		$hash = [Security.Cryptography.SHA256]::Create()
		try { $actual = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
		finally { $hash.Dispose(); $stream.Position = 0 }
		if ($ExpectedHash -ne '' -and $actual -cne $ExpectedHash) { throw 'Captured acquisition source changed.' }
		$reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
		try { $code = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Position = 0 }
		return @{ stream = $stream; code = $code; path = $Path; sha256 = $actual }
	} catch { $stream.Dispose(); throw }
}

function Get-OllamaCapturedSourceBlock($Source) {
	$tokens = $null; $errors = $null
	# The AST receives the original filename without rereading it. Vendor functions
	# retain their real PSScriptRoot, including delayed capability worker dispatch.
	$ast = [Management.Automation.Language.Parser]::ParseInput($Source.code, $Source.path, [ref]$tokens, [ref]$errors)
	if ($errors.Count -ne 0) { throw 'Captured acquisition source cannot be parsed.' }
	return $ast.GetScriptBlock()
}

function Open-OllamaCapturedVendor([string]$Directory, [string]$ExpectedHash) {
	if ($Directory -cnotmatch '^[A-Za-z]:\\' -or $ExpectedHash -cnotmatch '^[0-9a-f]{64}\z') {
		throw 'Vendor acquisition requires its captured complete source digest.'
	}
	# These are the exact eager and delayed PS dependencies of the existing owners.
	# The native PAC executable and manifest remain checked by their existing owner.
	$names = @('ergopti_updater_download.ps1', 'ergopti_network_routes.ps1',
		'ergopti_windows_proxy_config.ps1', 'ergopti_native_proxy_ex.ps1',
		'ergopti_network_pac.ps1', 'ergopti_curl_attempt.ps1', 'ergopti_curl_capabilities_worker.ps1')
	$sources = [ordered]@{}
	try {
		$inventory = ''
		foreach ($name in $names) {
			$source = Read-OllamaCapturedSource ([IO.Path]::Combine($Directory, $name))
			$sources.Add($name, $source)
			$inventory += $name + "`n" + $source.sha256 + "`n"
		}
		$hash = [Security.Cryptography.SHA256]::Create()
		try { $actual = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($inventory)))).Replace('-', '').ToLowerInvariant() }
		finally { $hash.Dispose() }
		if ($actual -cne $ExpectedHash) { throw 'The captured vendor dependency inventory changed.' }
		return $sources
	} catch {
		foreach ($source in $sources.Values) { $source.stream.Dispose() }
		throw
	}
}

function Invoke-OllamaArchiveEntry {
	$root = $null; $release = $null; $vendor = $null
	$codeOwners = [Collections.Generic.List[object]]::new()
	$retainedReceipt = $null
	$completion = @{ exit_code = 1; receipt = $null }
	# Dot-sourcing the managed file owner binds its CLI defaults in this scope.
	# Preserve the admitted acquisition values before loading that exact header.
	$entryRequest = @{ root = $ManagedRoot; catalogue = $CataloguePath; catalogue_sha256 = $CatalogueSha256;
		asset = $AssetId; ticket = $TicketId; connect_ms = $ConnectTimeoutMs;
		deadline_ms = $DeadlineMs; started_tick = $StartedTick;
		policy = $ProxyPolicyPath; defaults = $UpdaterDefaultsPath }
	try {
		if ($Action -cne 'download') { throw 'Only explicit pinned archive acquisition is admitted.' }
		if ($TicketId -cnotmatch '^[0-9a-f]{32}\z' -or $ConnectTimeoutMs -le 0 -or $DeadlineMs -le 0 -or $StartedTick -le 0) {
			throw 'Archive acquisition requires its admitted ticket and original clock.'
		}
		foreach ($digest in @($ManagedHelperSha256, $AcquisitionHelperSha256, $ProxyPolicySha256, $UpdaterDefaultsSha256)) {
			if ($digest -cnotmatch '^[0-9a-f]{64}\z') { throw 'Archive dependencies require their exact captured digests.' }
		}
		foreach ($pair in @(@($ManagedHelperPath, $ManagedHelperSha256), @($AcquisitionHelperPath, $AcquisitionHelperSha256),
			@($ProxyPolicyPath, $ProxyPolicySha256), @($UpdaterDefaultsPath, $UpdaterDefaultsSha256))) {
			$codeOwners.Add((Read-OllamaCapturedSource $pair[0] $pair[1]))
		}
		$vendor = Open-OllamaCapturedVendor $VendorDirectory $VendorSha256
		. (Get-OllamaCapturedSourceBlock $codeOwners[0])
		. (Get-OllamaCapturedSourceBlock $codeOwners[1])
		. (Get-OllamaCapturedSourceBlock $vendor['ergopti_updater_download.ps1'])
		. (Get-OllamaCapturedSourceBlock $vendor['ergopti_network_routes.ps1'])
		$root = Open-OllamaManagedRoot $entryRequest.root $true
		$release = Open-OllamaReleaseSource $entryRequest.catalogue $entryRequest.catalogue_sha256 $entryRequest.asset
		$result = Invoke-OllamaManagedArchiveDownload $root $release $entryRequest.ticket $entryRequest.connect_ms $entryRequest.deadline_ms $entryRequest.started_tick $entryRequest.policy $entryRequest.defaults
		# Preserve exact WAL evidence if the final source/root closure refuses.
		$retainedReceipt = $result
		$release.stream.Dispose(); $release = $null
		Close-OllamaManagedRoot $root; $root = $null
		$completion.exit_code = 0; $completion.receipt = $result
		return $completion
	} catch {
		$failure = [ordered]@{ ok = $false; phase = 'refused'; cleanup_pending = $true;
			ticket = $entryRequest.ticket; error = 'native_archive_download_refused'; exception_type = $_.Exception.GetType().FullName }
		if ($_.Exception.Data.Contains('ollama_creation_receipt')) { $failure.creation_receipt = $_.Exception.Data['ollama_creation_receipt'] }
		elseif ($null -ne $retainedReceipt) { $failure.creation_receipt = $retainedReceipt }
		$completion.receipt = $failure
		return $completion
	} finally {
		$closeFailure = $null
		$deadlineRefusal = $false
		try { if ($null -ne $release) { $release.stream.Dispose() } } catch { $closeFailure = $_ }
		try { if ($null -ne $root) { Close-OllamaManagedRoot $root } } catch { if ($null -eq $closeFailure) { $closeFailure = $_ } }
		$owners = @($codeOwners)
		if ($null -ne $vendor) { $owners += @($vendor.Values) }
		foreach ($source in $owners) {
			try { $source.stream.Dispose() } catch { if ($null -eq $closeFailure) { $closeFailure = $_ } }
		}
		if ($completion.exit_code -eq 0 -and $null -eq $closeFailure) {
			try { $null = Get-ErgoptiUpdaterRemainingMilliseconds $entryRequest.started_tick $entryRequest.deadline_ms }
			catch { $closeFailure = $_; $deadlineRefusal = $true }
		}
		if ($null -ne $closeFailure) {
			$completion.exit_code = 1
			if ($completion.receipt.ok) {
				$completion.receipt = [ordered]@{ ok = $false; phase = 'refused'; cleanup_pending = $true;
					ticket = $entryRequest.ticket; error = 'native_archive_cleanup_pending'; creation_receipt = $retainedReceipt }
			}
			if ($deadlineRefusal) { [Console]::Error.WriteLine('Archive entry original deadline expired after exact closure.') }
			else { [Console]::Error.WriteLine('Archive entry retains exact final closure debt.') }
		}
	}
}

if ($MyInvocation.InvocationName -ne '.') {
	# Success is a JSON receipt, never an executable or daemon admission.
	$result = Invoke-OllamaArchiveEntry
	$result.receipt | ConvertTo-Json -Depth 12 -Compress
	exit $result.exit_code
}

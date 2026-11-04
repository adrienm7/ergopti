# vendor/ergopti_diagnostics.ps1
#Requires -Version 5.1
<#
.SYNOPSIS
Collects a bounded local diagnostic archive without developer dependencies.
.DESCRIPTION
Only closed technical host fields and synthetic owned-window evidence are
exported. No network, personal files, clipboard or ambient input are collected.
Missing native qualification remains UNRUN, including resident-owner conflicts.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)][string]$SessionDirectory,
	[switch]$UiaChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath($SessionDirectory)
$taskId = [IO.Path]::GetFileName($taskRoot)
if ($taskId -cnotmatch '^ergopti-diagnostic-[0-9a-f]{32}$') { throw 'Invalid diagnostic session identity.' }
if (!(Test-Path -LiteralPath $taskRoot -PathType Container)) { throw 'Missing owned diagnostic session.' }
if ((Get-Item -LiteralPath $taskRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {
	throw 'Reparse session refused.'
}
$taskEncoding = [Text.UTF8Encoding]::new($false, $true)

function Read-CollectionJson($Path, $Limit) {
	$taskInput = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	try {
		if ($taskInput.Length -gt $Limit) { throw 'Diagnostic input limit exceeded.' }
		$taskReader = New-Object IO.StreamReader($taskInput, $taskEncoding, $true)
		try { return $taskReader.ReadToEnd() | ConvertFrom-Json } finally { $taskReader.Dispose() }
	} finally { $taskInput.Dispose() }
}

function Get-CollectionHash($Path) {
	$taskHashStream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
	$taskSha = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($taskSha.ComputeHash($taskHashStream))).Replace('-', '').ToLowerInvariant() }
	finally { $taskSha.Dispose(); $taskHashStream.Dispose() }
}
$taskStarted = [DateTime]::UtcNow
$taskWatch = [Diagnostics.Stopwatch]::StartNew()
$taskRows = New-Object Collections.Generic.List[object]
$taskForm = $null
$taskChild = $null
$taskCleanupErrors = New-Object Collections.Generic.List[object]
$taskUnfinished = New-Object Collections.Generic.List[object]
$taskPhase = 'collecting'
$taskActiveCheck = 'redaction'
$taskFailure = $null
$taskResidentReceipt = $null
$taskEvidenceReceipts = @{}
$taskIdentity = [ordered]@{
	schema_version=1; session_id=$taskId; started_at=$taskStarted.ToString('o'); ended_at=$null
	build_kind='unverified_input'; identity_status='FAIL'; version=$null; source_sha=$null
	architecture=$null; windows=[Environment]::OSVersion.Version.ToString(); runtime=$null
	components=@(); qualified_production=$false; physical_qualified=$false
}
$taskArchive = [IO.Path]::Combine([IO.Path]::GetDirectoryName($taskRoot), $taskId + '.zip')
$taskRequest = Read-CollectionJson (Join-Path $taskRoot 'request.json') 262144
$taskContract = Read-CollectionJson $taskRequest.contract_path 262144
if ($taskContract.schema_version -ne 1 -or $taskRequest.schema_version -ne 1) { throw 'Unsupported collection contract.' }

function Receive-CollectionResidentObservations($Value, $Owner) {
	if ($Owner.observation -cne 'PASS' -or $Value.schema_version -ne $taskContract.resident_observation_schema_version -or
		@($Value.PSObject.Properties.Name).Count -ne 3 -or
		@($Value.PSObject.Properties.Name | Where-Object { @('schema_version','captured_at_filetime','rows') -cnotcontains $_ }).Count -or
		$Value.captured_at_filetime -isnot [long] -or $Value.captured_at_filetime -lt $Owner.created_filetime -or
		$Value.captured_at_filetime -gt $taskStarted.ToFileTimeUtc()) { throw 'Resident observation identity refused.' }
	$taskObservationIds = @($taskContract.resident_observation_fields.PSObject.Properties.Name)
	if (@($Value.rows).Count -ne $taskObservationIds.Count) { throw 'Resident observation census refused.' }
	$taskObserved = @{}
	$taskClosedRows = New-Object Collections.Generic.List[object]
	foreach ($taskRow in $Value.rows) {
		$taskRowKeys = @('id','status','scope','reason','duration_ms','scenario_qualified','values','evidence_class','preconditions','errors')
		if (@($taskRow.PSObject.Properties.Name).Count -ne $taskRowKeys.Count -or
			@($taskRow.PSObject.Properties.Name | Where-Object {$taskRowKeys -cnotcontains $_}).Count -or
			$taskObservationIds -cnotcontains $taskRow.id -or $taskObserved.ContainsKey($taskRow.id) -or
			@('PASS','FAIL','UNRUN') -cnotcontains $taskRow.status -or
			@('runtime_state','native_readonly','unexecuted') -cnotcontains $taskRow.scope -or
			$taskRow.evidence_class -cne 'automatic' -or $taskContract.resident_observation_reasons -cnotcontains $taskRow.reason -or
			$taskRow.scenario_qualified -isnot [int] -or $taskRow.scenario_qualified -ne 0 -or
			($taskRow.duration_ms -isnot [int] -and $taskRow.duration_ms -isnot [long]) -or
			$taskRow.duration_ms -lt 0 -or $taskRow.duration_ms -gt $taskContract.deadline_ms) { throw 'Resident observation projection refused.' }
		if ($taskRow.status -ceq 'PASS' -and ($taskRow.scope -ceq 'unexecuted' -or
			($taskRow.scope -ceq 'native_readonly' -and $taskRequest.evidence_origin -cne 'resident_driver'))) { throw 'Unexecuted resident evidence cannot pass.' }
		if (@($taskRow.preconditions).Count -ne $taskContract.resident_observation_preconditions.Count -or
			@($taskRow.preconditions | Where-Object {$taskContract.resident_observation_preconditions -cnotcontains $_}).Count -or
			@($taskRow.preconditions | Select-Object -Unique).Count -ne $taskContract.resident_observation_preconditions.Count) { throw 'Resident observation preconditions refused.' }
		$taskFields = @($taskContract.resident_observation_fields.($taskRow.id))
		if (@($taskRow.values.PSObject.Properties.Name).Count -ne $taskFields.Count -or
			@($taskRow.values.PSObject.Properties.Name | Where-Object {$taskFields -cnotcontains $_}).Count) { throw 'Private resident observation fields refused.' }
		$taskValues = [ordered]@{}
		foreach ($taskField in $taskFields) {
			$taskNumber = $taskRow.values.$taskField
			if (($taskNumber -isnot [int] -and $taskNumber -isnot [long]) -or $taskNumber -lt -1) { throw 'Nontechnical resident observation value refused.' }
			$taskValues[$taskField] = $taskNumber
		}
		if ($taskRow.id -ceq 'ai' -and (@(-1,0,1) -notcontains $taskValues.managed_owner_present -or
			@(-1,0,1) -notcontains $taskValues.live_identity)) { throw 'Invalid managed observation flag.' }
		if (@('capture_replay','fifo') -ccontains $taskRow.id -and $taskValues.native_status -ne -1 -and
			$taskContract.resident_native_abi.statuses -notcontains $taskValues.native_status) { throw 'Invalid native observation status.' }
		if ($taskRow.id -ceq 'capture_replay' -and (
			($taskValues.phase -ne -1 -and $taskContract.resident_native_abi.capture_phases -notcontains $taskValues.phase) -or
			($taskValues.release_kind -ne -1 -and $taskContract.resident_native_abi.release_kinds -notcontains $taskValues.release_kind) -or
			$taskValues.queued -gt $taskContract.resident_native_abi.capture_capacity -or
			$taskValues.replayed -gt [uint32]::MaxValue -or $taskValues.last_os_error -gt [uint32]::MaxValue)) { throw 'Invalid native capture domain.' }
		if ($taskRow.id -ceq 'fifo' -and (@(-1,0,1) -notcontains $taskValues.can_stop -or
			($taskValues.record_count -ge 0 -and ($taskValues.pending_count -gt $taskValues.record_count -or
			$taskValues.unknown_count -gt $taskValues.record_count + 1)))) { throw 'Invalid native drain census.' }
		$taskPassReasons = @{hotstrings='resident_generations_observed';ai='native_managed_listener_identity_observed'
			capture_replay='native_capture_state_observed';fifo='native_aggregate_drain_observed'}
		if ($taskRow.status -ceq 'PASS' -and ($taskRow.reason -cne $taskPassReasons[$taskRow.id] -or
			@($taskRow.errors).Count)) { throw 'Contradictory passing resident observation refused.' }
		if ($taskRow.status -ceq 'PASS' -and $taskRow.id -ceq 'hotstrings' -and
			($taskRow.scope -cne 'runtime_state' -or @($taskValues.Values | Where-Object {$_ -lt 0}).Count)) { throw 'Unobserved resident generations cannot pass.' }
		if ($taskRow.status -ceq 'PASS' -and $taskRow.id -ceq 'ai' -and
			($taskRow.scope -cne 'native_readonly' -or $taskValues.managed_owner_present -ne 1 -or $taskValues.live_identity -ne 1 -or
			$taskValues.identity_handle_debt -ne 0)) { throw 'Unobserved managed identity cannot pass.' }
		if ($taskRow.status -ceq 'PASS' -and @('capture_replay','fifo') -ccontains $taskRow.id -and
			($taskRow.scope -cne 'native_readonly' -or $Owner.native_started -ne $true -or $Owner.native_quarantined -ne $false -or $taskValues.native_status -ne 0)) { throw 'Inactive native owner cannot supply passing receipts.' }
		if ($taskRow.status -ceq 'PASS' -and $taskRow.id -ceq 'capture_replay' -and
			($taskValues.token -le 0 -or @($taskValues.Values | Where-Object {$_ -lt 0}).Count)) { throw 'Incomplete native capture cannot pass.' }
		if ($taskRow.status -ceq 'PASS' -and $taskRow.id -ceq 'fifo' -and
			(@(0,1) -notcontains $taskValues.can_stop -or @($taskValues.Values | Where-Object {$_ -lt 0}).Count)) { throw 'Incomplete native drain observation cannot pass.' }
		$taskClosedErrors = @()
		if (@($taskRow.errors).Count -gt 1) { throw 'Resident observation errors exceeded their bound.' }
		foreach ($taskError in $taskRow.errors) {
			$taskErrorKeys = @($taskError.PSObject.Properties.Name)
			if ($taskErrorKeys.Count -ne 1) { throw 'Private resident error payload refused.' }
			if ($taskErrorKeys[0] -ceq 'native_status' -and $taskError.native_status -is [int]) {
				$taskClosedErrors += [ordered]@{native_status=$taskError.native_status}
			} elseif ($taskErrorKeys[0] -ceq 'reason' -and $taskContract.resident_observation_reasons -ccontains $taskError.reason) {
				$taskClosedErrors += [ordered]@{reason=$taskError.reason}
			} else { throw 'Resident observation error refused.' }
		}
		$taskObserved[$taskRow.id] = $true
		$taskClosedRows.Add([ordered]@{id=$taskRow.id;status=$taskRow.status;scope=$taskRow.scope;reason=$taskRow.reason
			duration_ms=$taskRow.duration_ms;scenario_qualified=$false;evidence_class='automatic'
			preconditions=@($taskRow.preconditions);errors=@($taskClosedErrors);values=$taskValues})
	}
	return [ordered]@{schema_version=$taskContract.resident_observation_schema_version;session_id=$taskId
		captured_at_filetime=$Value.captured_at_filetime;producer=$taskRequest.evidence_origin
		pid=$Owner.pid;created_filetime=$Owner.created_filetime;source_sha=$taskIdentity.source_sha
		build_kind=$taskIdentity.build_kind;scenario_qualified=$false;rows=@($taskClosedRows.ToArray())}
}

if ($UiaChild) {
	$taskChildStage = 'assemblies'
	try {
		Add-Type -AssemblyName System.Windows.Forms
		$taskWpf = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'WPF'
		Add-Type -Path (Join-Path $taskWpf 'UIAutomationClient.dll'), (Join-Path $taskWpf 'UIAutomationTypes.dll')
		$taskProxy = [Reflection.Assembly]::LoadFrom((Join-Path $taskWpf 'UIAutomationClientsideProviders.dll'))
		# A real declaring type prevents .NET UIA's proxy stack scan from reaching a dynamic PowerShell frame.
		Add-Type -ReferencedAssemblies (Join-Path $taskWpf 'UIAutomationClient.dll'), (Join-Path $taskWpf 'UIAutomationTypes.dll') -TypeDefinition @"
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Windows.Automation;
public static class ErgoptiDiagnosticUiaProxy {
 [MethodImpl(MethodImplOptions.NoInlining)]
 public static void Register(AssemblyName assembly) {
  ClientSettings.RegisterClientSideProviderAssembly(assembly);
 }
}
"@
		$taskChildStage = 'proxy_registration'
		[ErgoptiDiagnosticUiaProxy]::Register($taskProxy.GetName())
		$taskChildStage = 'target_receipt'
		$taskTarget = Read-CollectionJson (Join-Path $taskRoot 'uia-target.json') $taskContract.max_output_bytes
		$taskChildStage = 'owner_binding'
		$taskParent = [Diagnostics.Process]::GetProcessById($taskTarget.owner_pid)
		if ($taskParent.HasExited -or $taskParent.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $taskTarget.created_filetime) { throw 'UIA owner changed.' }
		$taskChildStage = 'receiver_binding'
		$taskElement = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$taskTarget.hwnd)
		if ($taskElement.Current.ProcessId -ne $taskTarget.owner_pid -or $taskElement.Current.IsPassword) { throw 'Foreign UIA target refused.' }
		$taskPatterns = @($taskElement.GetSupportedPatterns() | ForEach-Object { $_.Id })
		$taskChildStage = 'text_pattern'
		$taskPatternId = 0
		if ($taskPatterns -contains [Windows.Automation.ValuePattern]::Pattern.Id) {
			$taskPatternId = [Windows.Automation.ValuePattern]::Pattern.Id
			$taskText = $taskElement.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
		} elseif ($taskPatterns -contains [Windows.Automation.TextPattern]::Pattern.Id) {
			$taskPatternId = [Windows.Automation.TextPattern]::Pattern.Id
			$taskText = $taskElement.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText($taskContract.fixture.Length + 2).TrimEnd([char]13, [char]10)
		} elseif ($taskPatterns -contains [Windows.Automation.LegacyIAccessiblePattern]::Pattern.Id) {
			$taskPatternId = [Windows.Automation.LegacyIAccessiblePattern]::Pattern.Id
			$taskText = $taskElement.GetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern).Current.Value
		} else { throw 'The owned receiver exposes no text-capable UIA pattern.' }
		$taskMatched = $taskText -ceq $taskContract.fixture -and !$taskParent.HasExited
		[ordered]@{ok=$taskMatched; owner_pid=$taskTarget.owner_pid; pattern_id=$taskPatternId; value_matches_fixture=$taskMatched} | ConvertTo-Json -Compress
		exit $(if($taskMatched){0}else{1})
	} catch {
		[ordered]@{ok=$false; reason='uia_probe_refused'; stage=$taskChildStage; error_code=$_.Exception.HResult; exception_type=$_.Exception.GetType().FullName} | ConvertTo-Json -Compress
		exit 1
	}
}

function Get-CollectionStreamHash($Stream) {
	$taskSha = [Security.Cryptography.SHA256]::Create()
	try { return ([BitConverter]::ToString($taskSha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
	finally { $taskSha.Dispose() }
}

function Initialize-CollectionFileIdentity {
	if ($null -ne ('ErgoptiDiagnosticPrivate.FileIdentityV1' -as [type])) { return }
	Add-Type -Language CSharp -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace ErgoptiDiagnosticPrivate {
    public static class FileIdentityV1 {
        // BY_HANDLE_FILE_INFORMATION consists of exactly thirteen DWORDs.
        // FILETIME pairs stay explicit DWORDs; there is no architecture-sized field.
        [StructLayout(LayoutKind.Sequential, Pack = 4, Size = 52)]
        private struct ByHandleFileInformation {
            public UInt32 FileAttributes;
            public UInt32 CreationTimeLow;
            public UInt32 CreationTimeHigh;
            public UInt32 LastAccessTimeLow;
            public UInt32 LastAccessTimeHigh;
            public UInt32 LastWriteTimeLow;
            public UInt32 LastWriteTimeHigh;
            public UInt32 VolumeSerialNumber;
            public UInt32 FileSizeHigh;
            public UInt32 FileSizeLow;
            public UInt32 NumberOfLinks;
            public UInt32 FileIndexHigh;
            public UInt32 FileIndexLow;
        }

        public sealed class Identity {
            public readonly UInt32 VolumeSerialNumber;
            public readonly UInt32 FileIndexHigh;
            public readonly UInt32 FileIndexLow;
            internal Identity(UInt32 volume, UInt32 high, UInt32 low) {
                VolumeSerialNumber = volume;
                FileIndexHigh = high;
                FileIndexLow = low;
            }
        }

        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file, out ByHandleFileInformation information);

        public static Identity Capture(FileStream stream) {
            if (stream == null) {
                throw new ArgumentNullException("stream");
            }
            // SafeHandle marshalling retains the handle during the native call.
            // Reading this property may flush FileStream's own buffer, but the
            // helper never closes the stream, seeks it or reads/writes its bytes.
            SafeFileHandle handle = stream.SafeFileHandle;
            if (handle == null || handle.IsInvalid || handle.IsClosed) {
                throw new InvalidOperationException("Invalid diagnostic evidence handle.");
            }
            if (Marshal.SizeOf(typeof(ByHandleFileInformation)) != 52) {
                throw new InvalidOperationException("Diagnostic file identity ABI refused.");
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information)) {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "Native diagnostic file identity query failed.");
            }
            if (information.NumberOfLinks != 1) {
                throw new InvalidOperationException("Multiple-link diagnostic evidence refused.");
            }
            return new Identity(information.VolumeSerialNumber,
                information.FileIndexHigh, information.FileIndexLow);
        }
    }
}
'@
}

function Get-CollectionFileIdentity {
	[CmdletBinding()]
	param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)
	Initialize-CollectionFileIdentity
	$taskFileIdentity = [ErgoptiDiagnosticPrivate.FileIdentityV1]::Capture($Stream)
	# This three-field private receipt contains neither a path nor user content.
	# Keep it out of manifests, results, progress, stdout and diagnostic archives.
	return [ordered]@{
		volume_serial = $taskFileIdentity.VolumeSerialNumber
		file_index_high = $taskFileIdentity.FileIndexHigh
		file_index_low = $taskFileIdentity.FileIndexLow
	}
}

function Write-CollectionText($Name, $Text) {
	$taskBytes = $taskEncoding.GetBytes($Text)
	if ($taskBytes.Length -gt $taskContract.max_output_bytes) { throw 'Diagnostic payload limit exceeded.' }
	$taskTarget = Join-Path $taskRoot $Name
	if ($taskEvidenceReceipts.ContainsKey($Name)) {
		$taskPrior = $taskEvidenceReceipts[$Name]
		# The acquired exclusive stream is both the receipt verifier and the writer.
		$taskOutput = [IO.File]::Open($taskTarget, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		try {
			$taskIdentity = Get-CollectionFileIdentity $taskOutput
			if (!(Test-CollectionFileIdentity $taskIdentity $taskPrior.identity) -or
				$taskOutput.Length -ne $taskPrior.bytes -or (Get-CollectionStreamHash $taskOutput) -cne $taskPrior.sha256) { throw 'Foreign diagnostic output refused.' }
			$taskOutput.Position = 0
			$taskOutput.SetLength(0)
			$taskOutput.Write($taskBytes, 0, $taskBytes.Length); $taskOutput.Flush()
		} finally { $taskOutput.Dispose() }
	} else {
		if (Test-Path -LiteralPath $taskTarget) { throw 'Foreign diagnostic output refused.' }
		$taskStaging = $taskTarget + '.tmp'
		$taskOutput = [IO.File]::Open($taskStaging, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
		try {
			$taskOutput.Write($taskBytes, 0, $taskBytes.Length); $taskOutput.Flush()
			$taskIdentity = Get-CollectionFileIdentity $taskOutput
		} finally { $taskOutput.Dispose() }
		# File.Move refuses a first destination created after the earlier census.
		[IO.File]::Move($taskStaging, $taskTarget)
	}
	$taskExpected = [IO.MemoryStream]::new($taskBytes, $false)
	try { $taskEvidenceReceipts[$Name] = [ordered]@{bytes=$taskBytes.Length; sha256=(Get-CollectionStreamHash $taskExpected); identity=$taskIdentity} }
	finally { $taskExpected.Dispose() }
}

function Test-CollectionFileIdentity($Current, $Expected) {
	return $Current.volume_serial -eq $Expected.volume_serial -and
		$Current.file_index_high -eq $Expected.file_index_high -and $Current.file_index_low -eq $Expected.file_index_low
}

function Write-CollectionJson($Name, $Value) {
	$taskJson = ($Value | ConvertTo-Json -Depth 16 -Compress).Replace("`r`n", "`n") + "`n"
	Write-CollectionText $Name $taskJson
}

function Test-CollectionCancelled {
	return (Test-Path -LiteralPath (Join-Path $taskRoot 'cancel')) -or $taskWatch.ElapsedMilliseconds -ge $taskContract.deadline_ms
}

function Close-CollectionChild {
	if ($null -eq $script:taskChild) { return }
	try {
		if (!$script:taskChild.HasExited) {
			# This exact retained process only queries the synthetic UIA receiver; it never owns input.
			$script:taskChild.Kill()
			if (!$script:taskChild.WaitForExit(2000)) { throw 'Owned UIA query retirement was not acknowledged.' }
		}
		$script:taskChild.Dispose()
		$script:taskChild = $null
	} catch {
		$taskCleanupErrors.Add([ordered]@{operation='uia_query_retirement'; error_code=$_.Exception.HResult})
		$taskUnfinished.Add([ordered]@{operation='uia_query'; pid=$script:taskChild.Id})
	}
}

function Add-CollectionResult($Id, $Status, $Evidence, $Reason, $Duration = 0, $Receipt = $null, $ErrorCode = 0) {
	if ($taskContract.checks -cnotcontains $Id -or $taskContract.statuses -cnotcontains $Status -or
		$taskContract.evidence_classes -cnotcontains $Evidence -or $Reason -cnotmatch '^[a-z0-9_]+$') {
		throw 'Invalid collection result.'
	}
	if (@($taskRows | Where-Object { $_.id -ceq $Id }).Count) { throw 'Duplicate collection result.' }
	$taskRows.Add([ordered]@{
		id=$Id; status=$Status; evidence_class=$Evidence; duration_ms=$Duration
		preconditions=@('exact_component_identity', 'owned_session'); reason=$Reason
		error_code=$ErrorCode; receipt=$Receipt
	})
	Write-CollectionJson 'progress.json' ([ordered]@{
		schema_version=1; session_id=$taskId; phase=$taskPhase; completed=$taskRows.Count
		total=$taskContract.checks.Count; results=@($taskRows.ToArray())
	})
}

try {
	if ($taskRequest.redaction_verified -ne $true -or @('0','1') -cnotcontains [string]$taskRequest.compiled) { throw 'Host redaction admission is missing.' }
	if (@('resident_driver','worker_control') -cnotcontains $taskRequest.evidence_origin -or
		($taskRequest.evidence_origin -ceq 'worker_control' -and $taskRequest.compiled -eq 1)) { throw 'Invalid collection evidence origin.' }
	$taskComponents = New-Object Collections.Generic.List[object]
	$taskComponentPaths = @{}
	# The request contains only a host-side closed projection; never copy request paths or arbitrary logs.
	$taskCandidateIdentity = [ordered]@{
		schema_version=1; session_id=$taskId; started_at=$taskStarted.ToString('o'); ended_at=$null
		build_kind=$(if($taskRequest.evidence_origin -ceq 'worker_control'){'worker_control'}elseif($taskRequest.compiled -eq 1){'installed_binary'}else{'interpreted_source'})
		version=$taskRequest.version; source_sha=$taskRequest.source_sha
		architecture=$taskRequest.architecture; windows=[Environment]::OSVersion.Version.ToString()
		runtime=$taskRequest.runtime; components=@($taskComponents.ToArray())
		qualified_production=$false; physical_qualified=$false; identity_status='PASS'
	}
	$taskIdentityPatterns = @{
		version='^(?:v?[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?|local)$'
		source_sha='^(?:[0-9a-f]{7,40}|unknown)$'; architecture='^(?:x64|x86)$'; runtime='^[0-9]+[.][0-9]+[.][0-9]+$'
	}
	foreach ($taskName in $taskIdentityPatterns.Keys) {
		$taskValue = [string]$taskCandidateIdentity[$taskName]
		if ($taskValue.Length -gt 100 -or $taskValue -cnotmatch $taskIdentityPatterns[$taskName]) { throw 'Nontechnical identity field refused.' }
	}
	$taskIdentity = $taskCandidateIdentity
	Write-CollectionJson 'manifest.json' $taskIdentity
	Add-CollectionResult 'redaction' 'PASS' 'automatic' 'closed_technical_projection' 0 ([ordered]@{raw_logs_exported=$false; personal_data_exported=$false; clipboard_exported=$false})

	$taskComponentWatch = [Diagnostics.Stopwatch]::StartNew()
	$taskActiveCheck = 'components'
	foreach ($taskComponent in $taskRequest.components) {
		if (Test-CollectionCancelled) { break }
		if ($taskContract.component_ids -cnotcontains $taskComponent.id -or $taskComponentPaths.ContainsKey($taskComponent.id)) { throw 'Invalid component identity.' }
		$taskComponentPaths[$taskComponent.id] = $taskComponent.path
		$taskHash = Get-CollectionHash $taskComponent.path
		$taskComponents.Add([ordered]@{id=$taskComponent.id; sha256=$taskHash; bytes=(Get-Item -LiteralPath $taskComponent.path).Length})
	}
	$taskComponentOk = $taskComponents.Count -eq $taskContract.component_ids.Count
	$taskNativeBinding = $null
	if ($taskComponentOk) {
		$taskNativeManifest = Read-CollectionJson $taskComponentPaths['native_manifest'] $taskContract.max_output_bytes
		$taskNativeHash = @($taskComponents | Where-Object {$_.id -ceq 'native_owner'})[0].sha256
		$taskComponentOk = $taskNativeManifest.schema_version -eq 1 -and $taskNativeManifest.dll_sha256.ToLowerInvariant() -ceq $taskNativeHash -and $taskNativeManifest.source_fingerprint_sha256 -cmatch '^[A-F0-9]{64}$'
		if ($taskComponentOk) { $taskNativeBinding = [ordered]@{dll_sha256=$taskNativeHash; source_fingerprint_sha256=$taskNativeManifest.source_fingerprint_sha256.ToLowerInvariant()} }
	}
	Add-CollectionResult 'components' $(if(Test-CollectionCancelled){'SKIP'}elseif($taskComponentOk){'PASS'}else{'FAIL'}) 'automatic' $(if($taskComponentOk){'component_hashes_and_native_binding_observed'}else{'component_provenance_incomplete'}) $taskComponentWatch.ElapsedMilliseconds $taskNativeBinding
	$taskIdentity.components=@($taskComponents.ToArray())
	Write-CollectionJson 'manifest.json' $taskIdentity
	$taskActiveCheck = ''

	if (!(Test-CollectionCancelled)) {
		$taskNativeWatch = [Diagnostics.Stopwatch]::StartNew()
		try {
			Add-Type -AssemblyName System.Windows.Forms, System.Drawing
			$taskWpf = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'WPF'
			Add-Type -Path (Join-Path $taskWpf 'UIAutomationClient.dll'), (Join-Path $taskWpf 'UIAutomationTypes.dll')
			$taskForm = New-Object Windows.Forms.Form
			$taskTitle = $taskContract.fixture
			if ($taskRequest.PSObject.Properties.Name -contains 'receiver_title') {
				$taskTitle = [string]$taskRequest.receiver_title
				if ([Text.Encoding]::UTF8.GetByteCount($taskTitle) -gt 512 -or $taskTitle -match '[\x00-\x1f]') { throw 'Invalid translated receiver title.' }
			}
			$taskForm.Text = $taskTitle
			$taskForm.Size = New-Object Drawing.Size(640, 220)
			$taskEdit = New-Object Windows.Forms.TextBox
			$taskEdit.Multiline = $true
			$taskEdit.ReadOnly = $true
			$taskEdit.Dock = [Windows.Forms.DockStyle]::Fill
			$taskEdit.Text = $taskContract.fixture
			$taskForm.Controls.Add($taskEdit)
			# The read-only synthetic window is the only UIA/render target; no input is injected.
			$taskForm.Show()
			[Windows.Forms.Application]::DoEvents()
			$taskHandle = $taskEdit.Handle
			Write-CollectionJson 'uia-target.json' ([ordered]@{hwnd=$taskHandle.ToInt64(); owner_pid=$PID; created_filetime=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc()})
			# The owning GUI thread pumps while a separate native UIA client observes its receiver.
			$taskInfo = New-Object Diagnostics.ProcessStartInfo
			$taskInfo.FileName = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
			$taskInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -SessionDirectory "' + $taskRoot + '" -UiaChild'
			$taskInfo.UseShellExecute = $false
			$taskInfo.CreateNoWindow = $true
			$taskInfo.RedirectStandardOutput = $true
			$taskInfo.RedirectStandardError = $true
			$taskChild = [Diagnostics.Process]::Start($taskInfo)
			# Cold assembly/window preparation must not spend the child query's own budget.
			$taskQueryWatch = [Diagnostics.Stopwatch]::StartNew()
			$taskChildHandle = $taskChild.Handle
			$taskOutput = $taskChild.StandardOutput.ReadToEndAsync()
			$taskErrors = $taskChild.StandardError.ReadToEndAsync()
			while (!$taskChild.HasExited -and $taskQueryWatch.ElapsedMilliseconds -lt 8000 -and !(Test-CollectionCancelled)) {
				[Windows.Forms.Application]::DoEvents()
				Start-Sleep -Milliseconds 10
			}
			if (!$taskChild.HasExited) { throw 'UIA child retirement remains pending.' }
			$taskUia = $taskOutput.Result | ConvertFrom-Json
			$taskUiaOk = $taskChild.ExitCode -eq 0 -and $taskUia.ok -eq $true -and $taskErrors.Result.Length -eq 0
			$taskChild.Dispose()
			$taskChild = $null
			Add-CollectionResult 'native_uia' $(if($taskUiaOk){'PASS'}else{'FAIL'}) 'native_synthetic' 'owned_synthetic_edit_value' $taskNativeWatch.ElapsedMilliseconds $taskUia
			$taskBitmap = New-Object Drawing.Bitmap($taskForm.Width, $taskForm.Height)
			try {
				$taskForm.DrawToBitmap($taskBitmap, (New-Object Drawing.Rectangle(0, 0, $taskForm.Width, $taskForm.Height)))
				# CreateNew prevents a failed probe from adopting or overwriting an older image.
				$taskImage = [IO.File]::Open((Join-Path $taskRoot 'synthetic-window.png'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
				try {
					$taskBitmap.Save($taskImage, [Drawing.Imaging.ImageFormat]::Png)
					$taskImage.Flush(); $taskImage.Position = 0
					$taskEvidenceReceipts['synthetic-window.png'] = [ordered]@{bytes=$taskImage.Length; sha256=(Get-CollectionStreamHash $taskImage); identity=(Get-CollectionFileIdentity $taskImage)}
				} finally { $taskImage.Dispose() }
			} finally { $taskBitmap.Dispose() }
			$taskGraphics = $taskForm.CreateGraphics()
			try { $taskDpi = $taskGraphics.DpiX } finally { $taskGraphics.Dispose() }
			Add-CollectionResult 'native_render' 'PASS' 'native_synthetic' 'synthetic_window_rendered' $taskNativeWatch.ElapsedMilliseconds ([ordered]@{width=$taskForm.Width; height=$taskForm.Height; dpi=$taskDpi; actual_tooltip_qualified=$false; physical_visual_qualified=$false})
		} catch {
			foreach ($taskNativeId in @('native_uia','native_render')) {
				if (!@($taskRows | Where-Object {$_.id -ceq $taskNativeId}).Count) {
					Add-CollectionResult $taskNativeId 'FAIL' 'native_synthetic' 'native_probe_error' $taskNativeWatch.ElapsedMilliseconds $null $_.Exception.HResult
				}
			}
		} finally {
			Close-CollectionChild
			if($null -ne $taskForm){$taskForm.Dispose(); $taskForm=$null}
		}
	}
	$taskOwnerReceipt = [ordered]@{observation='UNRUN'; reason='host_owner_observation_unavailable'; isolated_input_allowed=$false}
	if ($taskRequest.PSObject.Properties.Name -contains 'input_owner') {
		$taskOwner = $taskRequest.input_owner
		if ($taskOwner.pid -isnot [int] -or $taskOwner.pid -le 0 -or $taskOwner.created_filetime -le 0 -or
			@('acquired','exempt','unavailable') -cnotcontains $taskOwner.mutex) { throw 'Invalid input owner identity.' }
		foreach ($taskFlag in @('mutex_handle_retained','dispatcher_started','native_started','native_quarantined')) {
			if (@('0','1') -cnotcontains [string]$taskOwner.$taskFlag) { throw 'Invalid input owner custody flag.' }
		}
		$taskHost = [Diagnostics.Process]::GetProcessById($taskOwner.pid)
		try {
			if ($taskHost.HasExited -or $taskHost.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $taskOwner.created_filetime) { throw 'Diagnostic host identity changed.' }
			$taskOwnerReceipt = [ordered]@{observation='PASS'; pid=$taskOwner.pid; created_filetime=$taskOwner.created_filetime
				mutex=$taskOwner.mutex; mutex_handle_retained=($taskOwner.mutex_handle_retained -eq 1)
				dispatcher_started=($taskOwner.dispatcher_started -eq 1); native_started=($taskOwner.native_started -eq 1)
				native_quarantined=($taskOwner.native_quarantined -eq 1); isolated_input_allowed=$false
				reason=$(if($taskOwner.mutex -ceq 'acquired' -and $taskOwner.dispatcher_started -eq 1){'resident_input_owner_observed'}else{'exclusive_input_session_not_admitted'})}
		} finally { $taskHost.Dispose() }
	}
	if ($taskRequest.PSObject.Properties.Name -contains 'resident_observations') {
		$taskResidentReceipt = Receive-CollectionResidentObservations $taskRequest.resident_observations $taskOwnerReceipt
		Write-CollectionJson 'resident-observations.json' $taskResidentReceipt
	}
	foreach ($taskNativeId in @('hotstrings','ai','capture_replay','callbacks','fifo','modifiers')) {
		# No isolated input owner is launched beside the collecting resident driver.
		$taskResultReceipt = [ordered]@{}
		foreach ($taskField in $taskOwnerReceipt.Keys) { $taskResultReceipt[$taskField] = $taskOwnerReceipt[$taskField] }
		if ($taskResidentReceipt -ne $null) {
			$taskObservation = @($taskResidentReceipt.rows | Where-Object {$_.id -ceq $taskNativeId})
			if ($taskObservation.Count -eq 1) { $taskResultReceipt.state_observation = $taskObservation[0] }
		}
		Add-CollectionResult $taskNativeId 'UNRUN' 'unexecuted' $(if($taskNativeId -eq 'ai'){'dedicated_install_start_model_consent_required'}elseif($taskResultReceipt.Contains('state_observation')){'resident_state_observed_scenario_unexecuted'}else{'native_collector_not_implemented'}) 0 $taskResultReceipt
	}
	$taskPhase = 'guided'
	Write-CollectionJson 'progress.json' ([ordered]@{schema_version=1; session_id=$taskId; phase=$taskPhase; completed=$taskRows.Count; total=$taskContract.checks.Count; results=@($taskRows.ToArray())})
	while (!(Test-CollectionCancelled) -and !(Test-Path -LiteralPath (Join-Path $taskRoot 'physical.json'))) {
		Start-Sleep -Milliseconds 100
	}
	$taskPhysical = $null
	if (Test-Path -LiteralPath (Join-Path $taskRoot 'physical.json')) {
		$taskPhysical = Read-CollectionJson (Join-Path $taskRoot 'physical.json') $taskContract.max_output_bytes
		if ($taskPhysical.session_id -cne $taskId) { throw 'Foreign physical acknowledgement refused.' }
	}
	foreach ($taskPhysicalId in @('physical_text','physical_display')) {
		$taskPhysicalStatus = 'UNRUN'; $taskReason = 'physical_step_not_executed'
		if (Test-CollectionCancelled) { $taskPhysicalStatus='SKIP'; $taskReason='cancelled_or_deadline' }
		elseif ($null -ne $taskPhysical) {
			$taskPhysicalStatus = [string]$taskPhysical.$taskPhysicalId
			$taskReason = 'explicit_guided_observation'
			if (@('PASS','FAIL','SKIP') -cnotcontains $taskPhysicalStatus) { throw 'Invalid physical acknowledgement.' }
		}
		Add-CollectionResult $taskPhysicalId $taskPhysicalStatus 'physical' $taskReason
	}
} catch {
	$taskPhase = 'failed'
	$taskFailure = [ordered]@{schema_version=1; session_id=$taskId; reason='collector_error'; error_code=$_.Exception.HResult}
	if ($taskActiveCheck -ne '' -and !@($taskRows | Where-Object {$_.id -ceq $taskActiveCheck}).Count) {
		Add-CollectionResult $taskActiveCheck 'FAIL' 'automatic' 'collector_error' $taskWatch.ElapsedMilliseconds $null $_.Exception.HResult
	}
	Write-CollectionJson 'failure.json' $taskFailure
} finally {
	Close-CollectionChild
	if($null -ne $taskForm){$taskForm.Dispose(); $taskForm=$null}
	if ($taskIdentity.identity_status -ceq 'PASS' -and $taskComponents.Count -eq $taskContract.component_ids.Count) {
		$taskStabilityWatch = [Diagnostics.Stopwatch]::StartNew()
		try {
			$taskStable = $true
			foreach ($taskComponent in $taskComponents) {
				if ((Get-CollectionHash $taskComponentPaths[$taskComponent.id]) -cne $taskComponent.sha256) { $taskStable = $false }
			}
			Add-CollectionResult 'component_stability' $(if($taskStable){'PASS'}else{'FAIL'}) 'automatic' $(if($taskStable){'components_unchanged_during_collection'}else{'component_changed_during_collection'}) $taskStabilityWatch.ElapsedMilliseconds
		} catch {
			Add-CollectionResult 'component_stability' 'FAIL' 'automatic' 'component_stability_probe_failed' $taskStabilityWatch.ElapsedMilliseconds $null $_.Exception.HResult
		}
	}
	foreach ($taskPendingId in $taskContract.checks) {
		if ($taskPendingId -ceq 'cleanup') { continue }
		if (!@($taskRows | Where-Object {$_.id -ceq $taskPendingId}).Count) {
			Add-CollectionResult $taskPendingId 'UNRUN' 'unexecuted' 'collector_did_not_execute'
		}
	}
	# Session control files carry paths needed locally; they never enter the archive.
	foreach ($taskControlName in @('request.json','cancel','physical.json','uia-target.json','request.json.tmp','cancel.tmp','physical.json.tmp','uia-target.json.tmp')) {
		$taskControlPath = Join-Path $taskRoot $taskControlName
		try {
			if(Test-Path -LiteralPath $taskControlPath){Remove-Item -LiteralPath $taskControlPath}
		} catch {
			$taskCleanupErrors.Add([ordered]@{operation='control_file_retirement'; error_code=$_.Exception.HResult})
			$taskUnfinished.Add([ordered]@{operation='control_file'; name=$taskControlName})
		}
	}
	# An archive written by a live worker cannot attest to that worker's later tree retirement.
	$taskUnfinished.Add([ordered]@{operation='host_worker_retirement'; state='awaiting_host_ack'; pid=$PID; input_free=$true})
	Add-CollectionResult 'cleanup' $(if($taskCleanupErrors.Count){'FAIL'}else{'PASS'}) 'automatic' $(if($taskCleanupErrors.Count){'owned_cleanup_debt'}else{'owned_window_and_control_files_retired'}) 0 ([ordered]@{scope='owned_window_and_control_files'; window_retired=($null -eq $taskForm); operations_unfinished=@($taskUnfinished.ToArray()); errors=@($taskCleanupErrors.ToArray()); user_configuration_touched=$false; clipboard_touched=$false; external_servers_touched=$false})
	Write-CollectionJson 'results.json' ([ordered]@{schema_version=1; session_id=$taskId; results=@($taskRows.ToArray())})
	$taskIdentity.ended_at=[DateTime]::UtcNow.ToString('o')
	Write-CollectionJson 'manifest.json' $taskIdentity
	$taskSummary = "# Ergopti Windows diagnostic`n`nSession: $taskId`nEvidence origin: $($taskIdentity.build_kind)`nInstalled binary evidence: $($taskIdentity.build_kind -ceq 'installed_binary')`nNo production or physical cohort qualification is granted by collection.`n`n"
	if ($null -ne $taskFailure) { $taskSummary += "Collection failed: $($taskFailure.reason) (HRESULT $($taskFailure.error_code)). Review failure.json before using any partial evidence.`n`n" }
	foreach($taskRow in $taskRows){$taskSummary += "$($taskRow.id): $($taskRow.status) [$($taskRow.evidence_class)] $($taskRow.reason)`n"}
	if ($null -ne $taskResidentReceipt) {
		$taskSummary += "`nResident state observations ($($taskResidentReceipt.producer)); these do not qualify the UNRUN functional scenarios:`n"
		foreach ($taskObservation in $taskResidentReceipt.rows) { $taskSummary += "$($taskObservation.id): $($taskObservation.status) [$($taskObservation.scope)] $($taskObservation.reason)`n" }
	}
	$taskSummary += "`nNext action: attach this local ZIP manually. Review FAIL, SKIP and UNRUN with the maintainer. Isolated native input needs an exclusive owner; AI installation and model download require separate consent. macOS and Linux were not executed here.`n"
	Write-CollectionText 'summary.md' $taskSummary
	Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
	if(Test-Path -LiteralPath $taskArchive){throw 'Existing archive refused.'}
	$taskStagingArchive = $taskArchive + '.partial'
	try {
		# Only named, closed evidence enters the ZIP; control paths and unexpected files cannot escape.
		$taskStream = [IO.File]::Open($taskStagingArchive, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
		try {
			$taskZip = New-Object IO.Compression.ZipArchive($taskStream, [IO.Compression.ZipArchiveMode]::Create, $true)
			try {
				$taskEvidenceNames = @('manifest.json','results.json','summary.md','failure.json','synthetic-window.png')
				if ($null -ne $taskResidentReceipt) { $taskEvidenceNames += 'resident-observations.json' }
				foreach ($taskEvidence in $taskEvidenceNames) {
					# A closed name is insufficient: only this worker's acknowledged bytes may enter.
					if (!$taskEvidenceReceipts.ContainsKey($taskEvidence)) { continue }
					$taskEvidencePath = Join-Path $taskRoot $taskEvidence
					$taskFile = Get-Item -LiteralPath $taskEvidencePath
					if (($taskFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $taskFile.Length -gt $taskContract.max_evidence_file_bytes) { throw 'Unsafe evidence file refused.' }
					$taskInput = [IO.File]::Open($taskEvidencePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
					try {
						$taskProduced = $taskEvidenceReceipts[$taskEvidence]
						if (!(Test-CollectionFileIdentity (Get-CollectionFileIdentity $taskInput) $taskProduced.identity) -or $taskInput.Length -ne $taskProduced.bytes -or (Get-CollectionStreamHash $taskInput) -cne $taskProduced.sha256) { throw 'Diagnostic evidence changed after production.' }
						$taskInput.Position = 0
						$taskEntry = $taskZip.CreateEntry($taskEvidence)
						$taskEntryStream = $taskEntry.Open()
						try { $taskInput.CopyTo($taskEntryStream) } finally { $taskEntryStream.Dispose() }
					} finally { $taskInput.Dispose() }
				}
			} finally { $taskZip.Dispose() }
		} finally { $taskStream.Dispose() }
		if ((Get-Item -LiteralPath $taskStagingArchive).Length -gt $taskContract.max_archive_bytes) { throw 'Diagnostic archive exceeds its bound.' }
		Move-Item -LiteralPath $taskStagingArchive -Destination $taskArchive
	} catch {
		Write-CollectionJson 'archive-error.json' ([ordered]@{schema_version=1; session_id=$taskId; reason='archive_creation_failed'; error_code=$_.Exception.HResult; partial_retained=(Test-Path -LiteralPath $taskStagingArchive)})
		throw
	}
	[ordered]@{schema_version=1; session_id=$taskId; archive_committed=$true; bytes=(Get-Item -LiteralPath $taskArchive).Length; sha256=(Get-CollectionHash $taskArchive)} | ConvertTo-Json -Compress
	Write-CollectionJson 'progress.json' ([ordered]@{schema_version=1; session_id=$taskId; phase=$(if($null -ne $taskFailure){'failed'}else{'completed'}); completed=$taskRows.Count; total=$taskContract.checks.Count; archive_created=$true; results=@($taskRows.ToArray())})
}

# A valid failure archive is available, but it cannot turn a primary refusal into completion.
if ($null -ne $taskFailure) { exit 1 }

# tests/fixtures/worker_unicode_managed_root.ps1
# Exclusive fixture birth and exact-handle retirement; no SUT output rewriting.
param(
    [Parameter(Mandatory=$true)][string]$FixtureManagedHelper,
    [Parameter(Mandatory=$true)][ValidateSet('acquire','cleanup')][string]$FixtureAction,
    [Parameter(Mandatory=$true)][string]$FixtureRoot,
    [Parameter(Mandatory=$true)][string]$FixtureNonce,
    [string]$FixtureReceiptPath = '',
    [string]$FixtureExpectedIdentity = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($FixtureNonce -cnotmatch '^[0-9a-f]{32}\z') { throw 'Fixture birth requires an exact nonce.' }
$FixtureInitialOutputCodePage = [Console]::OutputEncoding.CodePage
. $FixtureManagedHelper
if ([Console]::OutputEncoding.CodePage -ne $FixtureInitialOutputCodePage) {
    throw 'Dot-sourcing the real managed owner must not alter host stdout encoding.'
}
Initialize-OllamaManagedNative
$FixtureRoot = Assert-OllamaLocalPath $FixtureRoot
$Base = [Environment]::GetFolderPath('LocalApplicationData')
if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($FixtureRoot), $Base) -or
    [IO.Path]::GetFileName($FixtureRoot) -notlike ('ergopti-unicode-receipt-' + $FixtureNonce + '-*')) {
    throw 'Fixture root is outside its captured nonce namespace.'
}
$MarkerName = 'fixture-birth-' + $FixtureNonce + '.json'

function Remove-ExactFixtureTree([string]$Path, [IntPtr]$DirectoryHandle, [string]$PreservedMarker = '') {
    foreach ($Child in [IO.Directory]::EnumerateFileSystemEntries($Path)) {
        if ($PreservedMarker -ne '' -and [IO.Path]::GetFileName($Child) -ceq $PreservedMarker) { continue }
        $Attributes = [IO.File]::GetAttributes($Child)
        if (($Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Fixture cleanup refuses a reparse child.'
        }
        if (($Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            $ChildHandle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($Child, $true)
            try { Remove-ExactFixtureTree $Child $ChildHandle }
            finally {
                if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($ChildHandle)) {
                    throw 'Fixture child-directory closure remains unconfirmed.'
                }
            }
        } else {
            $ChildStream = Open-OllamaReadFile $Child $true
            try { [Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($ChildStream.SafeFileHandle.DangerousGetHandle()) }
            finally { $ChildStream.Dispose() }
        }
    }
    if ($PreservedMarker -eq '') { [Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($DirectoryHandle) }
}

$Handle = [IntPtr]::Zero
try {
    if ($FixtureAction -ceq 'acquire') {
        if ($FixtureReceiptPath -eq '') { throw 'Fixture birth needs its separate receipt destination.' }
        # The actual native CreateDirectoryW is exclusive. An existing directory
        # throws here and never acquires this fixture's marker or birth receipt.
        [Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($FixtureRoot,
            (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
        $Handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($FixtureRoot, $true)
        $Identity = [Ergopti.Ollama.ManagedNative]::Identity($Handle)
        Write-OllamaOwnedJson ([IO.Path]::Combine($FixtureRoot, 'root-owner.json')) ([ordered]@{
            kind='ollama-managed-root'; owner_sid=(Get-OllamaSid); identity=$Identity
        })
        Write-OllamaOwnedJson ([IO.Path]::Combine($FixtureRoot, $MarkerName)) ([ordered]@{
            kind='ergopti-receipt-fixture'; nonce=$FixtureNonce; root_identity=$Identity
        })
        if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($Handle)) { throw 'Fixture birth handle remains owned.' }
        $Handle = [IntPtr]::Zero
        # ASCII fields only, transported in an explicit UTF8 file, never a native
        # path returned through the SUT console stream being qualified.
        Write-OllamaOwnedJson $FixtureReceiptPath ([ordered]@{
            version=1; acquired=$true; nonce=$FixtureNonce; root_identity=$Identity
        })
        [Console]::Out.WriteLine('FIXTURE_ROOT_ACQUIRED')
    } else {
        if ($FixtureExpectedIdentity -cnotmatch '^[0-9a-f]{8}:[0-9a-f]{16}\z') {
            throw 'Fixture cleanup has no exact birth identity.'
        }
        # DELETE capability with no DELETE sharing pins the exact original root
        # name throughout marker verification and recursive by-handle retirement.
        $Handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($FixtureRoot, $true)
        if ([Ergopti.Ollama.ManagedNative]::Identity($Handle) -cne $FixtureExpectedIdentity) {
            throw 'Fixture cleanup refuses a replacement root.'
        }
        $MarkerStream = Open-OllamaReadFile ([IO.Path]::Combine($FixtureRoot, $MarkerName)) $true
        try {
            $Marker = Read-OllamaJsonStream $MarkerStream
            if ($Marker.kind -cne 'ergopti-receipt-fixture' -or $Marker.nonce -cne $FixtureNonce -or
                $Marker.root_identity -cne $FixtureExpectedIdentity) { throw 'Fixture cleanup refuses a foreign birth marker.' }
            # Keep the validated marker pinned and undeleted throughout child
            # cleanup, so an earlier refusal retains the same retry authority.
            Remove-ExactFixtureTree $FixtureRoot $Handle $MarkerName
            [Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($MarkerStream.SafeFileHandle.DangerousGetHandle())
        } finally { $MarkerStream.Dispose() }
        [Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($Handle)
        if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($Handle)) { throw 'Fixture retirement handle remains owned.' }
        $Handle = [IntPtr]::Zero
        [Console]::Out.WriteLine('FIXTURE_ROOT_RETIRED')
    }
} finally {
    if ($Handle -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($Handle)) {
        throw 'Fixture retains its exact native handle.'
    }
}

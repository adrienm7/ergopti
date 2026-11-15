# static/ergopti_plus/windows/vendor/ergopti_uninstall.ps1
#
# Removes only the confirmed portable executable, after terminal authorization
# and the exact inherited parent handle have both completed. Personal data and
# the shared runtime cache are retained; no installation directory is removed.

param(
	[switch]$LibraryOnly,
	[Int64]$ParentHandle,
	[string]$ReadyName,
	[string]$CommitName,
	[string]$Executable,
	[string]$ExpectedHash,
	[string]$FailureTitle,
	[string]$FailureText
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ErgoptiExecutableHash {
	param([string]$Path)
	$stream = [IO.File]::OpenRead($Path)
	$algorithm = [Security.Cryptography.SHA256]::Create()
	try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
	finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Assert-ErgoptiRemovalTarget {
	param([string]$Path, [string]$Hash)
	if (-not [IO.Path]::IsPathRooted($Path) -or [IO.Path]::GetExtension($Path) -ne '.exe' -or $Hash -notmatch '^[0-9a-fA-F]{64}$') {
		throw 'Invalid executable removal identity.'
	}
	$item = Get-Item -LiteralPath $Path -Force
	if ($item -is [IO.DirectoryInfo]) { throw 'The removal target is not a file.' }
	$cursor = $item
	while ($null -ne $cursor) {
		if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
			throw 'The executable path crosses a reparse point.'
		}
		if (($cursor -is [IO.DirectoryInfo]) -and (Test-Path -LiteralPath (Join-Path $cursor.FullName '.git'))) {
			throw 'Refusing an executable inside a source checkout.'
		}
		if ($cursor -is [IO.DirectoryInfo]) { $cursor = $cursor.Parent } else { $cursor = $cursor.Directory }
	}
	if ((Get-ErgoptiExecutableHash $Path) -ne $Hash) {
		throw 'The executable changed after confirmation.'
	}
}

function Get-ErgoptiFileIdentity {
	param([IO.FileStream]$Stream)
	# The volume serial and file index of the open object, which no rename or
	# replacement of a name can fake. The stock Windows 5.1 shell has no public
	# reader; its own hard-link code calls GetFileInformationByHandle, and the
	# bundled scripts may not declare P/Invoke (tools/ci/windows-exe-av-surface.json).
	$owner = [Management.Automation.PSObject].Assembly.GetType(
		'Microsoft.PowerShell.Commands.InternalSymbolicLinkLinkCodeMethods', $true)
	$reader = $owner.GetMethod('GetFileInformationByHandle', [Reflection.BindingFlags]'Static,Public,NonPublic')
	if ($null -eq $reader) { throw 'The file identity reader is unavailable.' }
	$arguments = @($Stream.SafeFileHandle.DangerousGetHandle(),
		[Activator]::CreateInstance($reader.GetParameters()[1].ParameterType.GetElementType()))
	if (-not $reader.Invoke($null, $arguments)) { throw 'The file identity could not be read.' }
	$information = $arguments[1]
	return '{0:x8}:{1:x8}{2:x8}' -f $information.VolumeSerialNumber, $information.FileIndexHigh, $information.FileIndexLow
}

function Open-ErgoptiFileAnchor {
	param([string]$Path)
	# Attribute access only: Windows applies no sharing check to such a handle,
	# so it blocks no reader, writer, rename or recycle, and it keeps the object
	# (so its file index) alive while it is open.
	return New-Object IO.FileStream($Path, [IO.FileMode]::Open,
		[Security.AccessControl.FileSystemRights]'ReadAttributes, Synchronize', [IO.FileShare]'ReadWrite, Delete',
		4096, [IO.FileOptions]::None)
}

function Get-ErgoptiRecycleBinFolder {
	param([string]$Path)
	$user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
	return Join-Path ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))) ('$Recycle.Bin\' + $user)
}

# The recycled entry ($R...) whose identity is Identity, or $null.
function Find-ErgoptiRecycledIdentity {
	param([string]$Bin, [string]$Identity)
	if (-not (Test-Path -LiteralPath $Bin -PathType Container)) { return $null }
	# The shell names a recycled file $R<id><extension>, beside its $I record.
	foreach ($entry in Get-ChildItem -LiteralPath $Bin -Force -File -Filter '$R*') {
		try { $candidate = Open-ErgoptiFileAnchor $entry.FullName }
		catch [UnauthorizedAccessException], [IO.IOException] {
			Write-Warning "Recycle Bin entry $($entry.Name) could not be compared: $($_.Exception.Message)"
			continue
		}
		try { if ((Get-ErgoptiFileIdentity $candidate) -eq $Identity) { return $entry.FullName } }
		finally { $candidate.Dispose() }
	}
	return $null
}

function Invoke-ErgoptiRemoval {
	param([string]$Path, [string]$Hash, [scriptblock]$Authorize, [scriptblock]$WaitOwner, [scriptblock]$Recycle,
		[scriptblock]$Unregister = {}, [scriptblock]$Locate = { param($Item, $Identity)
			Find-ErgoptiRecycledIdentity (Get-ErgoptiRecycleBinFolder $Item) $Identity }, [scriptblock]$Released = {})
	Assert-ErgoptiRemovalTarget $Path $Hash
	if (-not (& $Authorize)) { return $false }
	if (-not (& $WaitOwner)) { throw 'The application did not finish shutting down.' }
	# The last check and the unregistration run under a handle that denies write,
	# rename and delete: a pathname hash alone left the shortcut work, which takes
	# COM calls, free to swap the image that the recycle then selected. Windows
	# cannot recycle a pinned file, so the pin must end before the recycle; the
	# identity read under it (volume serial and file index) then follows the
	# exact object through its quarantine name into the Recycle Bin.
	$anchor = $null
	try {
		$pin = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
		try {
			Assert-ErgoptiRemovalTarget $Path $Hash
			$identity = Get-ErgoptiFileIdentity $pin
			& $Unregister $Path
			# Opened under the pin, so it is the pinned object: it keeps that file
			# index from being reused by another file until the end.
			$anchor = Open-ErgoptiFileAnchor $Path
			if ((Get-ErgoptiFileIdentity $anchor) -ne $identity) { throw 'The executable changed under its pin.' }
		} finally { $pin.Dispose() }
		& $Released $Path
		# A fresh unguessable name in the same directory: the recycle selects this
		# name, never the published one another program may recreate.
		$quarantine = Join-Path ([IO.Path]::GetDirectoryName($Path)) (
			'.ergopti-uninstall-' + [guid]::NewGuid().ToString('N') + '.exe')
		[IO.File]::Move($Path, $quarantine)
		$check = Open-ErgoptiFileAnchor $quarantine
		try { $quarantined = (Get-ErgoptiFileIdentity $check) -eq $identity } finally { $check.Dispose() }
		if (-not $quarantined) {
			# The name was replaced between the pin and the rename: hand the foreign
			# file its name back and recycle nothing.
			[IO.File]::Move($quarantine, $Path)
			throw 'The executable was replaced before its quarantine; nothing was recycled.'
		}
		& $Recycle $quarantine
		if (Test-Path -LiteralPath $quarantine) { throw 'The quarantined executable was not recycled.' }
		if ($null -eq (& $Locate $quarantine $identity)) {
			throw 'The recycled file is not the confirmed executable; check the Recycle Bin.'
		}
	} finally { if ($null -ne $anchor) { $anchor.Dispose() } }
	return $true
}

function Remove-ErgoptiStartupShortcut {
	param([string]$ExecutablePath, [string]$ShortcutPath)
	if (-not (Test-Path -LiteralPath $ShortcutPath)) { return }
	$entry = Get-Item -LiteralPath $ShortcutPath -Force
	if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
		Write-Warning 'Linked startup entry retained.'
		return
	}
	$shell = New-Object -ComObject WScript.Shell
	$link = $null
	try {
		$link = $shell.CreateShortcut($ShortcutPath)
		$actualTarget = $link.TargetPath
		# Normalize both paths through the Shell, including 8.3 directory names.
		# The Shell setter keeps "." and ".." segments verbatim, so the path is
		# made canonical first. This object is never saved: the on-disk shortcut
		# remains untouched.
		$link.TargetPath = [IO.Path]::GetFullPath($ExecutablePath)
		if ($actualTarget -ne $link.TargetPath -or $link.Arguments -ne '') {
			Write-Warning 'Foreign startup entry retained.'
			return
		}
	} finally {
		if ($null -ne $link) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
		[void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
	}
	Remove-Item -LiteralPath $ShortcutPath
}

# The login owner accepts exact manual shortcut names as well as the canonical
# filename. Removal must inspect the complete folder before retiring the image.
function Remove-ErgoptiStartupShortcuts {
	param([string]$ExecutablePath, [string]$StartupFolder)
	if ([string]::IsNullOrEmpty($StartupFolder)) { return }
	try { $folder = Get-Item -LiteralPath $StartupFolder -Force -ErrorAction Stop }
	catch [System.Management.Automation.ItemNotFoundException] { return }
	if (-not $folder.PSIsContainer) { throw 'The Startup path is not a directory.' }
	foreach ($entry in Get-ChildItem -LiteralPath $StartupFolder -Force) {
		if ($entry.PSIsContainer -or $entry.Extension -ne '.lnk') { continue }
		Remove-ErgoptiStartupShortcut $ExecutablePath $entry.FullName
	}
}

if ($LibraryOnly) { return }

$ready = $null
$commit = $null
$parent = $null
try {
	if ($ParentHandle -le 0) { throw 'An exact parent process handle is required.' }
	$ready = [Threading.EventWaitHandle]::OpenExisting($ReadyName)
	$commit = [Threading.EventWaitHandle]::OpenExisting($CommitName)
	$parent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset)
	$oldHandle = $parent.SafeWaitHandle
	$parent.SafeWaitHandle = [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr]$ParentHandle, $true)
	$oldHandle.Dispose()
	Add-Type -AssemblyName Microsoft.VisualBasic
	$authorize = {
		[void]$ready.Set()
		# Parent exit, timeout or a crash without COMMIT never authorizes removal.
		return [Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($commit, $parent), 60000) -eq 0
	}
	$waitOwner = { return $parent.WaitOne(60000) }
	$recycle = {
		param($Path)
		[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path,
			[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
			[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
			[Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException)
	}
	$unregister = {
		param($Path)
		Remove-ErgoptiStartupShortcuts $Path ([Environment]::GetFolderPath('Startup'))
	}
	[void](Invoke-ErgoptiRemoval $Executable $ExpectedHash $authorize $waitOwner $recycle $unregister)
} catch {
	[Console]::Error.WriteLine($_.Exception.Message)
	Add-Type -AssemblyName System.Windows.Forms
	[void][Windows.Forms.MessageBox]::Show($FailureText, $FailureTitle)
	exit 1
} finally {
	foreach ($handle in @($parent, $commit, $ready)) { if ($null -ne $handle) { $handle.Dispose() } }
	# This worker is a unique temporary copy, never its packaged source.
	if ($PSCommandPath -and ([IO.Path]::GetFileName($PSCommandPath) -match '^ergopti-uninstall-[0-9a-f]+\.ps1$')) {
		Remove-Item -LiteralPath $PSCommandPath -Force
	}
}

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

function Invoke-ErgoptiRemoval {
	param([string]$Path, [string]$Hash, [scriptblock]$Authorize, [scriptblock]$WaitOwner, [scriptblock]$Recycle,
		[scriptblock]$Unregister = {})
	Assert-ErgoptiRemovalTarget $Path $Hash
	if (-not (& $Authorize)) { return $false }
	if (-not (& $WaitOwner)) { throw 'The application did not finish shutting down.' }
	Assert-ErgoptiRemovalTarget $Path $Hash
	& $Unregister $Path
	& $Recycle $Path
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
		# This object is never saved: the on-disk shortcut remains untouched.
		$link.TargetPath = $ExecutablePath
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
		Remove-ErgoptiStartupShortcut $Path (Join-Path ([Environment]::GetFolderPath('Startup')) 'ErgoptiPlus.lnk')
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

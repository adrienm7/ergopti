# modules/llm/ollama_managed_files.ps1
# Native Windows files only: no download, installer execution, daemon or AI toggle.
# The caller owns consent/source admission, the helper job and all returned debts.

[CmdletBinding()]
param(
	[ValidateSet('', 'prepare', 'publish', 'cleanup', 'cleanup_partial')][string]$Action = '',
	[string]$ManagedRoot = '',
	[string]$CataloguePath = '',
	[string]$CatalogueSha256 = '',
	[string]$AssetId = '',
	[string]$ArchivePath = '',
	[string]$TicketId = '',
	[string]$StageIdentity = '',
	[string]$ManifestSha256 = '',
	[string]$CreationWalIdentity = '',
	[string]$CreationWalSha256 = '',
	[long]$MaxExpandedBytes = 0,
	[int]$MaxEntries = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-OllamaManagedNative {
	if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
		throw 'Managed Ollama files require native Windows.'
	}
	if ('Ergopti.Ollama.ManagedNative' -as [type]) { return }
	Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Ergopti.Ollama {
 public static class ManagedNative {
  [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
   public int Length; public IntPtr Descriptor;
   [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
  }
  [StructLayout(LayoutKind.Sequential)] struct FileInfo {
   public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
    WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [StructLayout(LayoutKind.Sequential)] struct IoStatus { public IntPtr Status, Information; }
  [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool CreateDirectory(string path, ref SecurityAttributes security);
  [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr security,
   uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32", SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr handle, out FileInfo info);
  [DllImport("kernel32", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("ntdll")] static extern int NtSetInformationFile(IntPtr handle, out IoStatus status,
   IntPtr info, uint bytes, int informationClass);
  [DllImport("ntdll")] static extern uint RtlNtStatusToDosError(int status);
  [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFileAttributes(string path);
  public static bool PathIsAbsent(string path) {
   if(GetFileAttributes(path)!=0xffffffffu) return false;
   int error=Marshal.GetLastWin32Error();
   if(error==2 || error==3) return true;
   throw new Win32Exception(error);
  }
  public static void DeleteExactDirectory(IntPtr handle) {
   var memory=Marshal.AllocHGlobal(1);
   try {
    Marshal.WriteByte(memory,1);
    IoStatus status;
    int result=NtSetInformationFile(handle,out status,memory,1,13);
    if(result<0) throw new Win32Exception((int)RtlNtStatusToDosError(result));
   } finally { Marshal.FreeHGlobal(memory); }
  }
  public static System.IO.FileStream OpenRegularFile(string path, bool retire) {
   var handle=CreateFile(path, 0x80000000u | (retire ? 0x10000u : 0u), 1,
    IntPtr.Zero, 3, 0x00200000u, IntPtr.Zero);
   if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   FileInfo info;
   if(!GetFileInformationByHandle(handle,out info) || (info.Attributes & 0x410)!=0) {
    int error=Marshal.GetLastWin32Error(); CloseHandle(handle);
    throw new Win32Exception(error==0 ? 4390 : error,"Source is not a regular non-reparse file.");
   }
   var owned=new SafeFileHandle(handle,true);
   try { return new System.IO.FileStream(owned,System.IO.FileAccess.Read); }
   catch { owned.Dispose(); throw; }
  }
  public static System.IO.FileStream CreateOwnedFile(string path) {
   var handle=CreateFile(path,0xc0010000u,1,IntPtr.Zero,1,0x00200000u,IntPtr.Zero);
   if(handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   var owned=new SafeFileHandle(handle,true);
   try { return new System.IO.FileStream(owned,System.IO.FileAccess.ReadWrite); }
   catch { owned.Dispose(); throw; }
  }
  public static void CreateProtectedDirectory(string path, byte[] descriptor) {
   var pinned=GCHandle.Alloc(descriptor, GCHandleType.Pinned);
   try {
    var security=new SecurityAttributes { Length=Marshal.SizeOf(typeof(SecurityAttributes)),
     Descriptor=pinned.AddrOfPinnedObject(), Inherit=false };
    if (!CreateDirectory(path, ref security)) throw new Win32Exception(Marshal.GetLastWin32Error());
   } finally { pinned.Free(); }
  }
  public static IntPtr OpenDirectory(string path, bool rename) {
   uint access=0x80u | (rename ? 0x10000u : 0u);
   var handle=CreateFile(path, access, 3, IntPtr.Zero, 3, 0x02200000u, IntPtr.Zero);
   if (handle==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
   FileInfo info;
   if (!GetFileInformationByHandle(handle, out info) || (info.Attributes & 0x10)==0 || (info.Attributes & 0x400)!=0) {
    int error=Marshal.GetLastWin32Error(); CloseHandle(handle);
    throw new Win32Exception(error==0 ? 4390 : error, "Untrusted managed directory shape.");
   }
   return handle;
  }
  public static string Identity(IntPtr handle) {
   FileInfo info;
   if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return info.Volume.ToString("x8")+":"+info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8");
  }
  public static void RenameCreate(IntPtr source, string destination) {
   // Rename through the exact DELETE-capable source handle, which never shares
   // DELETE. A path-based MoveFileEx would require releasing that identity fence.
   string absolute=System.IO.Path.GetFullPath(destination);
   string native=absolute.StartsWith(@"\\?\") ? @"\??\"+absolute.Substring(4) : @"\??\"+absolute;
   byte[] name=System.Text.Encoding.Unicode.GetBytes(native);
   int rootOffset=IntPtr.Size==8 ? 8 : 4;
   int lengthOffset=rootOffset+IntPtr.Size, nameOffset=lengthOffset+4;
   var memory=Marshal.AllocHGlobal(nameOffset+name.Length);
   try {
    for(int n=0;n<nameOffset+name.Length;n++) Marshal.WriteByte(memory,n,0);
    Marshal.WriteIntPtr(memory,rootOffset,IntPtr.Zero);
    Marshal.WriteInt32(memory,lengthOffset,name.Length);
    Marshal.Copy(name,0,IntPtr.Add(memory,nameOffset),name.Length);
    IoStatus status;
    int result=NtSetInformationFile(source,out status,memory,(uint)(nameOffset+name.Length),10);
    if(result<0) throw new Win32Exception((int)RtlNtStatusToDosError(result));
   } finally { Marshal.FreeHGlobal(memory); }
  }
 }
}
'@ | Out-Null
	Add-Type -AssemblyName System.IO.Compression | Out-Null
}

function Get-OllamaSid {
	return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function New-OllamaPrivateSecurity {
	$security = New-Object Security.AccessControl.DirectorySecurity
	$sid = Get-OllamaSid
	$security.SetSecurityDescriptorSddlForm("O:${sid}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;${sid})")
	return $security
}

function Assert-OllamaPrivateSecurity([string]$Path) {
	$security = Get-Acl -LiteralPath $Path
	$sid = Get-OllamaSid
	if (-not $security.AreAccessRulesProtected -or -not $security.AreAccessRulesCanonical -or
		$security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid) {
		throw 'The managed directory has untrusted owner or inheritance.'
	}
	$rules = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
	if ($rules.Count -ne 2) { throw 'The managed directory has unexpected access grants.' }
	$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
	foreach ($rule in $rules) {
		if ($rule.IsInherited -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
			$rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
			$rule.InheritanceFlags -ne ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit) -or
			$rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or
			$rule.IdentityReference.Value -notin @($sid, 'S-1-5-18') -or -not $seen.Add($rule.IdentityReference.Value)) {
			throw 'The managed directory grants an unexpected principal or right.'
		}
	}
}

function Assert-OllamaLocalPath([string]$Path) {
	if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains("`r") -or $Path.Contains("`n")) {
		throw 'Managed paths must be absolute local Windows paths.'
	}
	foreach ($component in $Path.Substring(3).Split('\')) {
		if ($component -eq '' -or $component -in @('.', '..') -or
			$component.EndsWith('.') -or $component.EndsWith(' ') -or
			$component.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
			throw 'The managed path has an ambiguous native component.'
		}
	}
	return [IO.Path]::GetFullPath($Path)
}

function Open-OllamaReadFile([string]$Path, [bool]$Retire = $false) {
	return [Ergopti.Ollama.ManagedNative]::OpenRegularFile($Path, $Retire)
}

function Remove-OllamaExactFile([IO.FileStream]$Stream) {
	[Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($Stream.SafeFileHandle.DangerousGetHandle())
	$Stream.Dispose()
}

function Hold-OllamaStageDirectories([string]$Stage, $Directories, [bool]$Create = $false,
	[bool]$Retiring = $false, $CreationWal = $null) {
	$held = [ordered]@{}
	try {
		foreach ($relative in @($Directories | Sort-Object { $_.Length })) {
			$path = [IO.Path]::Combine($Stage, $relative.Replace('/', '\'))
			if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($path)) {
				if ($Create) {
					if ($null -eq $CreationWal) { throw 'Directory creation requires its exact durable call-scoped journal.' }
					Add-OllamaCreationRecord $CreationWal 'directory-intent' $relative ''
					[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($path, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
				} elseif ($Retiring) { continue }
				else { throw 'An expected prepared directory is absent.' }
			}
			$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($path, $true)
			$held[$relative] = $handle
			Assert-OllamaPrivateSecurity $path
			if ($Create) { Add-OllamaCreationRecord $CreationWal 'directory-owned' $relative ([Ergopti.Ollama.ManagedNative]::Identity($handle)) }
		}
		return ,$held
	} catch {
		foreach ($handle in $held.Values) {
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) {
				[Console]::Error.WriteLine('Nested directory refusal retains exact native close debt.')
			}
		}
		throw
	}
}

function Get-OllamaStreamHash([IO.Stream]$Stream) {
	$position = $Stream.Position
	$hasher = [Security.Cryptography.SHA256]::Create()
	try {
		$Stream.Position = 0
		return ([BitConverter]::ToString($hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant()
	} finally {
		$Stream.Position = $position
		$hasher.Dispose()
	}
}

function Read-OllamaJsonStream([IO.Stream]$Stream) {
	$reader = [IO.StreamReader]::new($Stream, [Text.UTF8Encoding]::new($false, $true), $true, 1024, $true)
	try { return $reader.ReadToEnd() | ConvertFrom-Json }
	finally { $reader.Dispose(); $Stream.Position = 0 }
}

function Write-OllamaOwnedJson([string]$Path, $Value) {
	$bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($Value | ConvertTo-Json -Depth 12 -Compress) + "`n")
	$stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
	try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
	finally { $stream.Dispose() }
}

function Add-OllamaCreationRecord($Wal, [string]$Kind, [string]$Relative, [string]$Identity) {
	$record = [ordered]@{ kind = $Kind; sequence = ++$Wal.sequence; path = $Relative; identity = $Identity }
	$bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($record | ConvertTo-Json -Compress) + "`n")
	$Wal.stream.Position = $Wal.stream.Length
	$Wal.stream.Write($bytes, 0, $bytes.Length)
	$Wal.stream.Flush($true)
}

function Begin-OllamaCreationWal($Root, $Archive, [string]$Ticket) {
	$path = [IO.Path]::Combine($Root.path, '.creation-' + $Ticket + '.jsonl')
	$stream = [Ergopti.Ollama.ManagedNative]::CreateOwnedFile($path)
	try {
		$identity = [Ergopti.Ollama.ManagedNative]::Identity($stream.SafeFileHandle.DangerousGetHandle())
		$header = [ordered]@{ kind = 'ollama-creation'; ticket = $Ticket; root_identity = $Root.identity;
			identity = $identity; version = $Archive.version; asset = $Archive.asset;
			archive_sha256 = $Archive.pin.sha256; catalogue_sha256 = $Archive.catalogue_sha256 }
		$bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($header | ConvertTo-Json -Compress) + "`n")
		$stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
		return @{ path = $path; stream = $stream; identity = $identity; header = $header; sequence = 0 }
	} catch { $stream.Dispose(); throw }
}

function Get-OllamaCreationReceipt($Wal) {
	return [ordered]@{ ticket = $Wal.header.ticket; root_identity = $Wal.header.root_identity;
		creation_wal_identity = $Wal.identity; creation_wal_sha256 = (Get-OllamaStreamHash $Wal.stream) }
}

function New-OllamaExtractedFile($Wal, [string]$Stage, [string]$Relative) {
	Add-OllamaCreationRecord $Wal 'file-intent' $Relative ''
	$stream = [Ergopti.Ollama.ManagedNative]::CreateOwnedFile([IO.Path]::Combine($Stage, $Relative.Replace('/', '\')))
	try {
		$identity = [Ergopti.Ollama.ManagedNative]::Identity($stream.SafeFileHandle.DangerousGetHandle())
		# The exact creation identity is durable before the first payload byte.
		Add-OllamaCreationRecord $Wal 'file-owned' $Relative $identity
		return @{ stream = $stream; identity = $identity }
	} catch { $stream.Dispose(); throw }
}

function Write-OllamaExtractedJson($Wal, [string]$Stage, [string]$Relative, $Value) {
	$owned = New-OllamaExtractedFile $Wal $Stage $Relative
	try {
		$bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(($Value | ConvertTo-Json -Depth 12 -Compress) + "`n")
		$owned.stream.Write($bytes, 0, $bytes.Length); $owned.stream.Flush($true)
		return Get-OllamaStreamHash $owned.stream
	} finally { $owned.stream.Dispose() }
}

function Open-OllamaManagedRoot([string]$Root, [bool]$AllowCreate = $true) {
	Initialize-OllamaManagedNative
	$rootPath = Assert-OllamaLocalPath $Root
	$base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
	if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($rootPath), $base)) {
		throw 'The managed root must be one explicitly selected child of the current user LocalApplicationData.'
	}
	$handles = [Collections.Generic.List[IntPtr]]::new()
	try {
		# Hold every existing ancestor without DELETE sharing before creation.
		$ancestor = [IO.DirectoryInfo]::new($base)
		while ($null -ne $ancestor) {
			$handles.Add([Ergopti.Ollama.ManagedNative]::OpenDirectory($ancestor.FullName, $false))
			$ancestor = $ancestor.Parent
		}
		$created = -not [IO.Directory]::Exists($rootPath)
		if ($created -and -not $AllowCreate) { throw 'Cleanup and publication cannot create a replacement managed root.' }
		if ($created) {
			[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($rootPath, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
		}
		$rootHandle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($rootPath, $false)
		$handles.Add($rootHandle)
		Assert-OllamaPrivateSecurity $rootPath
		$identity = [Ergopti.Ollama.ManagedNative]::Identity($rootHandle)
		$markerPath = [IO.Path]::Combine($rootPath, 'root-owner.json')
		if ($created) {
			Write-OllamaOwnedJson $markerPath ([ordered]@{ kind = 'ollama-managed-root'; owner_sid = (Get-OllamaSid); identity = $identity })
		}
		$markerStream = Open-OllamaReadFile $markerPath
		try {
			$marker = Read-OllamaJsonStream $markerStream
			if ($marker.kind -ne 'ollama-managed-root' -or $marker.owner_sid -ne (Get-OllamaSid) -or $marker.identity -ne $identity) {
				throw 'An existing managed root has no exact ownership receipt.'
			}
		} finally { $markerStream.Dispose() }
		$versions = [IO.Path]::Combine($rootPath, 'versions')
		if (-not [IO.Directory]::Exists($versions)) {
			if (-not $AllowCreate) { throw 'Cleanup and publication cannot create a replacement versions directory.' }
			[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($versions, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
		}
		$versionsHandle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($versions, $false)
		$handles.Add($versionsHandle)
		Assert-OllamaPrivateSecurity $versions
		return @{ path = $rootPath; identity = $identity; versions = $versions; handles = $handles }
	} catch {
		foreach ($handle in $handles) {
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) {
				[Console]::Error.WriteLine('Managed root failure retained a native close debt.')
			}
		}
		throw
	}
}

function Close-OllamaManagedRoot($Root) {
	$remaining = [Collections.Generic.List[IntPtr]]::new()
	foreach ($handle in $Root.handles) {
		if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) { $remaining.Add($handle) }
	}
	$Root.handles = $remaining
	if ($remaining.Count -ne 0) { throw 'The exact managed directory handles retain close debt.' }
}

function Assert-OllamaRelativePath([string]$Name) {
	$name = $Name.Replace('\', '/')
	if ($name -eq '' -or $name.StartsWith('/') -or $name.Contains(':') -or $name.Contains([char]0)) {
		throw 'The archive has a rooted, empty, control-bearing or alternate-stream path.'
	}
	if ($name.EndsWith('/')) { throw 'The normalized relative path cannot carry trailing separators.' }
	foreach ($part in $name.Split('/')) {
		if ($part -eq '' -or $part -in @('.', '..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or
			$part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
			$part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|\z)') {
			throw 'The archive contains traversal, an ambiguous path or a reserved device.'
		}
	}
	return $name
}

function Get-OllamaEntryPath([IO.Compression.ZipArchiveEntry]$Entry) {
	$raw = $Entry.FullName.Replace('\', '/')
	$directory = $raw.EndsWith('/')
	$name = Assert-OllamaRelativePath $raw.TrimEnd('/')
	if ($name.Split('/')[0] -in @('stage-owner.json', 'prepared.json')) { throw 'The archive collides with native ownership receipts.' }
	$attributes = [uint32]([long]$Entry.ExternalAttributes -band 0xffffffffL)
	$unixKind = ($attributes -shr 16) -band 0xf000
	if (($attributes -band 0x400) -ne 0 -or $unixKind -notin @(0, 0x8000, 0x4000) -or
		($unixKind -eq 0x4000 -and -not $directory) -or ($unixKind -eq 0x8000 -and $directory)) {
		throw 'The archive contains a link, reparse point or nonregular native entry.'
	}
	if ($directory -and $Entry.Length -ne 0) { throw 'An archive directory carries unexpected payload.' }
	return @{ path = $name; directory = $directory; bytes = [long]$Entry.Length }
}

# Validate the complete namespace before acquiring any stage or creation WAL.
# Explicit directory entries may share their namespace with implicit parents;
# regular files may never be ancestors of another archive entry, in either order.
function Assert-OllamaArchiveNamespace($Entries) {
	$kinds = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::OrdinalIgnoreCase)
	foreach ($item in $Entries) {
		if ($kinds.ContainsKey($item.path)) { throw 'The archive has colliding native paths.' }
		$kinds.Add($item.path, [bool]$item.directory)
	}
	foreach ($item in $Entries) {
		$parts = $item.path.Split('/')
		$parent = ''
		for ($index = 0; $index -lt ($parts.Length - 1); $index++) {
			$parent = if ($parent -eq '') { $parts[$index] } else { $parent + '/' + $parts[$index] }
			if ($kinds.ContainsKey($parent) -and -not $kinds[$parent]) {
				throw 'The archive has a regular-file ancestor collision.'
			}
		}
	}
}

function Open-OllamaReleaseSource([string]$Catalogue, [string]$ExpectedCatalogueHash, [string]$Asset) {
	if ($ExpectedCatalogueHash -notmatch '^[0-9a-f]{64}\z' -or $Asset -notin @('windows-amd64', 'windows-arm64')) {
		throw 'The captured canonical release source is invalid.'
	}
	$catalogueStream = Open-OllamaReadFile (Assert-OllamaLocalPath $Catalogue)
	try {
		if ((Get-OllamaStreamHash $catalogueStream) -ne $ExpectedCatalogueHash) { throw 'The exact canonical release source changed.' }
		$data = Read-OllamaJsonStream $catalogueStream
		$pin = $data.assets.PSObject.Properties[$Asset].Value
		if ($data.schema_version -ne 1 -or $data.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\z' -or
			$pin.sha256 -notmatch '^[0-9a-f]{64}\z' -or $pin.filename -notmatch '^ollama-windows-(amd64|arm64)\.zip\z' -or
			-not ($pin.bytes -is [int] -or $pin.bytes -is [long]) -or $pin.bytes -le 0) {
			throw 'The selected canonical release receipt is unreadable.'
		}
		if ($pin.filename -ne ('ollama-' + $Asset + '.zip')) { throw 'The selected archive basename disagrees with its canonical asset identity.' }
		return @{ stream = $catalogueStream; version = $data.version; pin = $pin; asset = $Asset;
			catalogue_sha256 = $ExpectedCatalogueHash;
			url = ('https://github.com/ollama/ollama/releases/download/v' + $data.version + '/' + $pin.filename) }
	} catch { $catalogueStream.Dispose(); throw }
}

function Read-OllamaPinnedArchive([string]$Catalogue, [string]$ExpectedCatalogueHash, [string]$Asset,
	[string]$Archive, [long]$ExpandedBudget, [int]$EntryBudget) {
	if ($ExpandedBudget -lt 0 -or $EntryBudget -lt 0) { throw 'The captured archive bounds are invalid.' }
	$source = Open-OllamaReleaseSource $Catalogue $ExpectedCatalogueHash $Asset
	$catalogueStream = $source.stream
	$pin = $source.pin
	$archiveStream = $null
	$zip = $null
	try {
		$archiveStream = Open-OllamaReadFile (Assert-OllamaLocalPath $Archive)
		if ($archiveStream.Length -ne $pin.bytes -or (Get-OllamaStreamHash $archiveStream) -ne $pin.sha256) {
			throw 'The exact pinned archive bytes or SHA-256 do not match.'
		}
		# Inspection occurs only after the complete pinned digest is admitted.
		$zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $true)
		if ($zip.Entries.Count -eq 0 -or ($EntryBudget -gt 0 -and $zip.Entries.Count -gt $EntryBudget)) {
			throw 'The archive exceeds its admitted entry budget or contains nothing.'
		}
		$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		$entries = [Collections.Generic.List[object]]::new()
		[long]$total = 0
		foreach ($entry in $zip.Entries) {
			$item = Get-OllamaEntryPath $entry
			if (-not $seen.Add($item.path)) { throw 'The archive has colliding native paths.' }
			if ($item.bytes -lt 0 -or $item.bytes -gt ([long]::MaxValue - $total)) { throw 'The archive length sum overflowed.' }
			$total += $item.bytes
			if ($ExpandedBudget -gt 0 -and $total -gt $ExpandedBudget) { throw 'The archive exceeds its admitted expanded byte budget.' }
			$item.entry = $entry
			$entries.Add($item)
		}
		Assert-OllamaArchiveNamespace $entries
		$cli = @($entries | Where-Object { $_.path -eq 'ollama.exe' -and -not $_.directory -and $_.bytes -gt 0 })
		if ($cli.Count -ne 1) { throw 'The complete portable archive lacks one regular CLI.' }
		return @{ version = $source.version; pin = $pin; asset = $Asset; entries = $entries; total = $total;
			zip = $zip; archive_stream = $archiveStream; catalogue_stream = $catalogueStream; catalogue_sha256 = $ExpectedCatalogueHash }
	} catch {
		if ($null -ne $zip) { $zip.Dispose() }
		if ($null -ne $archiveStream) { $archiveStream.Dispose() }
		$catalogueStream.Dispose()
		throw
	}
}

function Close-OllamaPinnedArchive($Archive) {
	$Archive.zip.Dispose(); $Archive.archive_stream.Dispose(); $Archive.catalogue_stream.Dispose()
}

function Prepare-OllamaManagedStage($Root, $Archive, [string]$Ticket,
	[bool]$EmitConstructionReceipt = $false, [scriptblock]$AfterOwnedEntry = $null) {
	if ($Ticket -notmatch '^[0-9a-f]{32}\z') { throw 'A stage needs its originating private ticket.' }
	$stage = [IO.Path]::Combine($Root.path, '.stage-' + $Ticket)
	$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($stage))
	if ($drive.AvailableFreeSpace -lt $Archive.total) { throw 'The complete portable archive will not fit on the target volume.' }
	$wal = Begin-OllamaCreationWal $Root $Archive $Ticket
	$handle = [IntPtr]::Zero
	$directoryHandles = [ordered]@{}
	try {
		if ($EmitConstructionReceipt) {
			$construction = Get-OllamaCreationReceipt $wal
			$construction.phase = 'creation-owned'
			[Console]::Out.WriteLine(($construction | ConvertTo-Json -Compress))
		}
		Add-OllamaCreationRecord $wal 'stage-intent' '' ''
		[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($stage, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())
		$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($stage, $true)
		$identity = [Ergopti.Ollama.ManagedNative]::Identity($handle)
		Add-OllamaCreationRecord $wal 'stage-owned' '' $identity
		$owner = [ordered]@{ kind = 'ollama-stage'; ticket = $Ticket; root_identity = $Root.identity; identity = $identity }
		[void](Write-OllamaExtractedJson $wal $stage 'stage-owner.json' $owner)
		$files = [Collections.Generic.List[object]]::new()
		$directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		foreach ($item in $Archive.entries) {
			$parts = $item.path.Split('/')
			$parentCount = $parts.Length - 1
			if ($item.directory) { $parentCount = $parts.Length }
			for ($index = 1; $index -le $parentCount; $index++) {
				[void]$directories.Add(($parts[0..($index - 1)] -join '/'))
			}
		}
		$directoryHandles = Hold-OllamaStageDirectories $stage $directories $true $false $wal
		foreach ($item in $Archive.entries) {
			$destination = [IO.Path]::Combine($stage, $item.path.Replace('/', '\'))
			if ($item.directory) { continue }
			$entryStream = $item.entry.Open()
			$owned = New-OllamaExtractedFile $wal $stage $item.path
			$output = $owned.stream
			try {
				if ($null -ne $AfterOwnedEntry) { & $AfterOwnedEntry $item.path $owned.identity }
				$buffer = New-Object byte[] 65536
				[long]$written = 0
				while (($count = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
					if ($count -gt ($item.bytes - $written)) { throw 'An extracted stream exceeded its verified declared length.' }
					$output.Write($buffer, 0, $count); $written += $count
				}
				if ($written -ne $item.bytes) { throw 'An extracted stream ended before its verified declared length.' }
				$output.Flush($true)
				$fileHash = Get-OllamaStreamHash $output
			} finally { $output.Dispose(); $entryStream.Dispose() }
			$files.Add([ordered]@{ path = $item.path; identity = $owned.identity; bytes = $item.bytes; sha256 = $fileHash })
		}
		$directoryIdentities = [ordered]@{}
		foreach ($relative in $directoryHandles.Keys) {
			$directoryIdentities[$relative] = [Ergopti.Ollama.ManagedNative]::Identity($directoryHandles[$relative])
		}
		$manifest = [ordered]@{ kind = 'ollama-prepared'; ticket = $Ticket; root_identity = $Root.identity;
			identity = $identity; version = $Archive.version; asset = $Archive.asset;
			archive_sha256 = $Archive.pin.sha256; catalogue_sha256 = $Archive.catalogue_sha256;
			directories = @($directories | Sort-Object); directory_identities = $directoryIdentities; files = @($files.ToArray()) }
		$manifestPath = [IO.Path]::Combine($stage, 'prepared.json')
		$manifestHash = Write-OllamaExtractedJson $wal $stage 'prepared.json' $manifest
		$receipt = Get-OllamaCreationReceipt $wal
		return [ordered]@{ ok = $true; phase = 'prepared'; stage = $stage; ticket = $Ticket;
			root_identity = $Root.identity; stage_identity = $identity; manifest_sha256 = $manifestHash;
			creation_wal_identity = $receipt.creation_wal_identity; creation_wal_sha256 = $receipt.creation_wal_sha256;
			version = $Archive.version; asset = $Archive.asset; expanded_bytes = $Archive.total; files = $files.Count }
	} catch {
		# A caught refusal can publish the exact final WAL hash. If the process
		# dies before this receipt, an older/unknown image retains debt.
		$failure = $_
		try { $failure.Exception.Data['ollama_creation_receipt'] = Get-OllamaCreationReceipt $wal }
		catch { [Console]::Error.WriteLine('Preparation refusal cannot prove its final creation journal image.') }
		throw $failure.Exception
	} finally {
		foreach ($nestedHandle in $directoryHandles.Values) {
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($nestedHandle)) { throw 'The exact prepared child directory retains close debt.' }
		}
		if ($handle -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) { throw 'The exact prepared directory retains handle close debt.' }
		$wal.stream.Dispose()
	}
}

function Assert-OllamaHeldInventory([string]$Stage, $Directories, $Files) {
	$paths = [Collections.Generic.List[string]]::new()
	$paths.Add($Stage)
	foreach ($relative in $Directories.Keys) { $paths.Add([IO.Path]::Combine($Stage, $relative.Replace('/', '\'))) }
	# Enumerate only directories whose exact native handles are already held.
	# Never recurse into an unknown junction before discovering its shape.
	foreach ($path in $paths) {
		foreach ($entry in Get-ChildItem -LiteralPath $path -Force) {
			$relative = $entry.FullName.Substring($Stage.Length + 1).Replace('\', '/')
			if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Owned inventory preserves unexpected reparse content.' }
			if ($entry.PSIsContainer) {
				if (-not $Directories.Contains($relative)) { throw 'A foreign directory entered the held owned inventory.' }
			} elseif (-not $Files.Contains($relative)) { throw 'A foreign file entered the held owned inventory.' }
		}
	}
}

function Open-OllamaPreparedStage($Root, [string]$Ticket, [string]$ExpectedIdentity, [string]$ExpectedManifestHash,
	[bool]$AllowRetiring = $false, [string]$PublishedPath = '',
	[IntPtr]$RetainedHandle = [IntPtr]::Zero) {
	if ($Ticket -notmatch '^[0-9a-f]{32}\z' -or $ExpectedManifestHash -notmatch '^[0-9a-f]{64}\z') {
		throw 'Prepared stage admission needs exact originating receipts.'
	}
	$stage = [IO.Path]::Combine($Root.path, '.stage-' + $Ticket)
	if ($PublishedPath -ne '') {
		if ($AllowRetiring -or $RetainedHandle -eq [IntPtr]::Zero -or
			-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($PublishedPath), $Root.versions)) {
			throw 'Published validation requires its retained stage handle and exact versions parent.'
		}
		$stage = $PublishedPath
		$handle = $RetainedHandle
	} else {
		if ($RetainedHandle -ne [IntPtr]::Zero) { throw 'A retained publication handle needs its canonical target.' }
		$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($stage, $true)
	}
	$streams = [Collections.Generic.List[object]]::new()
	$ownedFiles = [ordered]@{}
	$directoryHandles = [ordered]@{}
	$cleanupStream = $null
	try {
		Assert-OllamaPrivateSecurity $stage
		if ([Ergopti.Ollama.ManagedNative]::Identity($handle) -ne $ExpectedIdentity) { throw 'The exact prepared directory was replaced.' }
		$cleanupPath = [IO.Path]::Combine($Root.path, '.cleanup-' + $Ticket + '.json')
		$retiring = $false
		$cleanup = $null
		if (-not [Ergopti.Ollama.ManagedNative]::PathIsAbsent($cleanupPath)) {
			if (-not $AllowRetiring) { throw 'A retiring stage cannot be published.' }
			$cleanupStream = Open-OllamaReadFile $cleanupPath $true
			$cleanup = Read-OllamaJsonStream $cleanupStream
			if ($cleanup.kind -ne 'ollama-cleanup' -or $cleanup.ticket -ne $Ticket -or
				$cleanup.identity -ne $ExpectedIdentity -or $cleanup.root_identity -ne $Root.identity -or
				$cleanup.manifest_sha256 -ne $ExpectedManifestHash) { throw 'The exact root cleanup journal changed.' }
			$retiring = $true
		}
		$manifestPath = [IO.Path]::Combine($stage, 'prepared.json')
		if ($retiring -and [Ergopti.Ollama.ManagedNative]::PathIsAbsent($manifestPath)) {
			$manifestStream = [IO.MemoryStream]::new([Convert]::FromBase64String($cleanup.manifest_bytes), $false)
		} else {
			$manifestStream = Open-OllamaReadFile $manifestPath $true
			$ownedFiles['prepared.json'] = $manifestStream
		}
		$streams.Add($manifestStream)
		if ((Get-OllamaStreamHash $manifestStream) -ne $ExpectedManifestHash) { throw 'The exact prepared receipt changed.' }
		$manifest = Read-OllamaJsonStream $manifestStream
		$memory = [IO.MemoryStream]::new()
		try {
			$manifestStream.CopyTo($memory); $manifestBytes = $memory.ToArray(); $manifestStream.Position = 0
		} finally { $memory.Dispose() }
		if ($manifest.kind -ne 'ollama-prepared' -or $manifest.ticket -ne $Ticket -or
			$manifest.identity -ne $ExpectedIdentity -or $manifest.root_identity -ne $Root.identity -or
			$manifest.version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\z' -or
			$manifest.asset -notin @('windows-amd64', 'windows-arm64') -or $manifest.archive_sha256 -notmatch '^[0-9a-f]{64}\z') {
			throw 'The prepared receipt does not own this stage.'
		}
		if ($PublishedPath -ne '') {
			$leaf = $manifest.version + '-' + $manifest.asset + '-' + $manifest.archive_sha256
			if (-not [StringComparer]::OrdinalIgnoreCase.Equals($PublishedPath, [IO.Path]::Combine($Root.versions, $leaf))) {
				throw 'The published target differs from its exact prepared source.'
			}
		}
		$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		[void]$expected.Add('prepared.json'); [void]$expected.Add('stage-owner.json')
		$ownerPath = [IO.Path]::Combine($stage, 'stage-owner.json')
		if (-not ($retiring -and [Ergopti.Ollama.ManagedNative]::PathIsAbsent($ownerPath))) {
			$ownerStream = Open-OllamaReadFile $ownerPath $true
			$ownedFiles['stage-owner.json'] = $ownerStream
			$streams.Add($ownerStream)
			$owner = Read-OllamaJsonStream $ownerStream
			if ($owner.kind -ne 'ollama-stage' -or $owner.ticket -ne $Ticket -or
				$owner.identity -ne $ExpectedIdentity -or $owner.root_identity -ne $Root.identity) {
				throw 'The exact stage creation receipt changed.'
			}
		}
		$expectedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		foreach ($directory in $manifest.directories) {
			if (-not $expectedDirectories.Add($directory)) { throw 'The prepared receipt contains colliding directories.' }
		}
		$directoryHandles = Hold-OllamaStageDirectories $stage $expectedDirectories $false $retiring
		foreach ($relative in $directoryHandles.Keys) {
			$expectedDirectory = $manifest.directory_identities.PSObject.Properties[$relative]
			if ($null -eq $expectedDirectory -or $expectedDirectory.Value -notmatch '^[0-9a-f]{8}:[0-9a-f]{16}\z' -or
				[Ergopti.Ollama.ManagedNative]::Identity($directoryHandles[$relative]) -ne $expectedDirectory.Value) {
				throw 'A prepared directory identity changed before publication or cleanup.'
			}
		}
		foreach ($file in $manifest.files) {
			if (-not $expected.Add($file.path)) { throw 'The prepared receipt contains colliding files.' }
			$path = [IO.Path]::Combine($stage, $file.path.Replace('/', '\'))
			if ($retiring -and [Ergopti.Ollama.ManagedNative]::PathIsAbsent($path)) { continue }
			$stream = Open-OllamaReadFile $path $true
			$ownedFiles[$file.path] = $stream
			$streams.Add($stream)
			if ([Ergopti.Ollama.ManagedNative]::Identity($stream.SafeFileHandle.DangerousGetHandle()) -ne $file.identity -or
				$stream.Length -ne $file.bytes -or (Get-OllamaStreamHash $stream) -ne $file.sha256) {
				throw 'A prepared runtime file changed before publication.'
			}
		}
		Assert-OllamaHeldInventory $stage $directoryHandles $expected
		return @{ path = $stage; handle = $handle; streams = $streams; manifest = $manifest;
			manifest_bytes = $manifestBytes; cleanup_path = $cleanupPath;
			owned_files = $ownedFiles; directory_handles = $directoryHandles; cleanup_stream = $cleanupStream }
	} catch {
		if ($null -ne $cleanupStream) { $cleanupStream.Dispose() }
		foreach ($stream in $streams) { $stream.Dispose() }
		foreach ($nestedHandle in $directoryHandles.Values) {
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($nestedHandle)) {
				[Console]::Error.WriteLine('Prepared child directory refusal retains close debt.')
			}
		}
		# A borrowed publication handle stays with its originating Stage on refusal.
		if ($PublishedPath -eq '' -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) {
			[Console]::Error.WriteLine('Prepared stage refusal retains a directory close debt.')
		}
		throw
	}
}

function Close-OllamaPreparedChildren($Stage) {
	foreach ($stream in @($Stage.streams.ToArray())) {
		$safe = $null
		if ($stream -is [IO.FileStream]) { $safe = $stream.SafeFileHandle }
		$stream.Dispose()
		if ($null -ne $safe -and -not $safe.IsClosed) { throw 'An exact prepared file retains physical close debt.' }
		[void]$Stage.streams.Remove($stream)
	}
	foreach ($relative in @($Stage.directory_handles.Keys | Sort-Object { $_.Length } -Descending)) {
		if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($Stage.directory_handles[$relative])) { throw 'An exact prepared child directory retains close debt.' }
		$Stage.directory_handles.Remove($relative)
	}
}

function Close-OllamaPreparedStage($Stage) {
	if ($null -ne $Stage.cleanup_stream) { $Stage.cleanup_stream.Dispose(); $Stage.cleanup_stream = $null }
	Close-OllamaPreparedChildren $Stage
	if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($Stage.handle)) { throw 'The exact prepared stage handle retains close debt.' }
	$Stage.handle = [IntPtr]::Zero
}

function Publish-OllamaPreparedStage($Root, $Stage) {
	$manifest = $Stage.manifest
	$leaf = $manifest.version + '-' + $manifest.asset + '-' + $manifest.archive_sha256
	$target = [IO.Path]::Combine($Root.versions, $leaf)
	$memory = [IO.MemoryStream]::new($Stage.manifest_bytes, $false)
	try { $manifestHash = Get-OllamaStreamHash $memory } finally { $memory.Dispose() }
	$debt = [ordered]@{ ticket = $manifest.ticket; root_identity = $Root.identity;
		stage_identity = $manifest.identity; manifest_sha256 = $manifestHash;
		version_path = $target; renamed = $false; cleanup_pending = $true }
	$Stage.publication_receipt = $debt
	try {
		# Windows directory rename refuses open descendant handles. Only children
		# close; the exact stage and parent fences remain held throughout.
		Close-OllamaPreparedChildren $Stage
		[Ergopti.Ollama.ManagedNative]::RenameCreate($Stage.handle, $target)
		$debt.renamed = $true
		$Stage.path = $target
		# Descendant custody was released: all original IDs, bytes, hashes and
		# inventory must be freshly admitted before any executable is published.
		$checked = Open-OllamaPreparedStage $Root $manifest.ticket $manifest.identity $manifestHash $false $target $Stage.handle
		$Stage.streams = $checked.streams
		$Stage.owned_files = $checked.owned_files
		$Stage.directory_handles = $checked.directory_handles
		return [ordered]@{ ok = $true; phase = 'published'; version_path = $target;
			version_identity = ([Ergopti.Ollama.ManagedNative]::Identity($Stage.handle)); ticket = $manifest.ticket;
			archive_sha256 = $manifest.archive_sha256; executable = [IO.Path]::Combine($target, 'ollama.exe') }
	} catch {
		# A moved but unvalidated target is retained debt, never executable success.
		$_.Exception.Data['ollama_publication_receipt'] = $debt
		throw
	}
}

function Read-OllamaCreationWal($Root, [string]$Ticket, [string]$ExpectedIdentity, [string]$ExpectedHash) {
	if ($Ticket -notmatch '^[0-9a-f]{32}\z' -or $ExpectedIdentity -notmatch '^[0-9a-f]{8}:[0-9a-f]{16}\z' -or
		$ExpectedHash -notmatch '^[0-9a-f]{64}\z') { throw 'Partial cleanup requires its exact captured creation journal.' }
	$path = [IO.Path]::Combine($Root.path, '.creation-' + $Ticket + '.jsonl')
	$stream = Open-OllamaReadFile $path $true
	try {
		if ([Ergopti.Ollama.ManagedNative]::Identity($stream.SafeFileHandle.DangerousGetHandle()) -ne $ExpectedIdentity -or
			(Get-OllamaStreamHash $stream) -ne $ExpectedHash) { throw 'The captured creation journal identity or image changed.' }
		$reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)
		try { $text = $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Position = 0 }
		if (-not $text.EndsWith("`n") -or $text.Contains("`r")) { throw 'The creation journal has an incomplete or noncanonical frame.' }
		$lines = $text.TrimEnd("`n").Split("`n")
		$header = $lines[0] | ConvertFrom-Json
		if ($header.kind -ne 'ollama-creation' -or $header.ticket -ne $Ticket -or $header.identity -ne $ExpectedIdentity -or
			$header.root_identity -ne $Root.identity -or $header.archive_sha256 -notmatch '^[0-9a-f]{64}\z' -or
			$header.catalogue_sha256 -notmatch '^[0-9a-f]{64}\z' -or $header.asset -notin @('windows-amd64', 'windows-arm64')) {
			throw 'The creation journal does not belong to this exact native call.'
		}
		$objects = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
		for ($index = 1; $index -lt $lines.Length; $index++) {
			$record = $lines[$index] | ConvertFrom-Json
			if ($record.sequence -ne $index -or $record.kind -notin @('stage-intent', 'stage-owned', 'directory-intent', 'directory-owned', 'file-intent', 'file-owned')) {
				throw 'The creation journal sequence or operation is unknown.'
			}
			$parts = $record.kind.Split('-'); $kind = $parts[0]; $phase = $parts[1]
			$relative = $record.path
			if ($kind -eq 'stage') {
				if ($relative -ne '') { throw 'The creation journal stage path is ambiguous.' }
			} else { [void](Assert-OllamaRelativePath $relative) }
			$key = $relative
			if ($phase -eq 'intent') {
				if ($objects.ContainsKey($key) -or $record.identity -ne '') { throw 'Creation intent duplicates or borrows an existing identity.' }
				$objects.Add($key, @{ kind = $kind; path = $relative; identity = '' })
			} else {
				if (-not $objects.ContainsKey($key) -or $objects[$key].kind -ne $kind -or $objects[$key].identity -ne '' -or
					$record.identity -notmatch '^[0-9a-f]{8}:[0-9a-f]{16}\z') { throw 'Creation identity has no exact preceding intent.' }
				$objects[$key].identity = $record.identity
			}
		}
		return @{ stream = $stream; path = $path; objects = $objects; header = $header }
	} catch { $stream.Dispose(); throw }
}

function Remove-OllamaPartialStage($Root, [string]$Ticket, [string]$ExpectedWalIdentity, [string]$ExpectedWalHash) {
	$wal = Read-OllamaCreationWal $Root $Ticket $ExpectedWalIdentity $ExpectedWalHash
	$stagePath = [IO.Path]::Combine($Root.path, '.stage-' + $Ticket)
	$stageHandle = [IntPtr]::Zero
	$directories = [ordered]@{}
	$files = [Collections.Generic.List[object]]::new()
	try {
		if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($stagePath)) {
			Remove-OllamaExactFile $wal.stream
			return [ordered]@{ ok = $true; phase = 'retired'; ticket = $Ticket }
		}
		if (-not $wal.objects.ContainsKey('') -or $wal.objects[''].identity -eq '') {
			throw 'A present stage without durable creation identity retains ambiguous debt.'
		}
		$stageHandle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($stagePath, $true)
		if ([Ergopti.Ollama.ManagedNative]::Identity($stageHandle) -ne $wal.objects[''].identity) {
			throw 'Partial cleanup refuses a replacement stage directory.'
		}
		Assert-OllamaPrivateSecurity $stagePath
		$knownFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
		foreach ($item in @($wal.objects.Values | Where-Object { $_.kind -eq 'directory' } | Sort-Object { $_.path.Length })) {
			$path = [IO.Path]::Combine($stagePath, $item.path.Replace('/', '\'))
			if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($path)) { continue }
			if ($item.identity -eq '') { throw 'A present directory without durable creation identity retains ambiguous debt.' }
			$handle = [Ergopti.Ollama.ManagedNative]::OpenDirectory($path, $true)
			$directories[$item.path] = $handle
			if ([Ergopti.Ollama.ManagedNative]::Identity($handle) -ne $item.identity) { throw 'Partial cleanup refuses a replacement child directory.' }
			Assert-OllamaPrivateSecurity $path
		}
		foreach ($item in @($wal.objects.Values | Where-Object { $_.kind -eq 'file' })) {
			[void]$knownFiles.Add($item.path)
			$path = [IO.Path]::Combine($stagePath, $item.path.Replace('/', '\'))
			if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($path)) { continue }
			if ($item.identity -eq '') { throw 'A present file without durable creation identity retains ambiguous debt.' }
			$stream = Open-OllamaReadFile $path $true
			$files.Add($stream)
			if ([Ergopti.Ollama.ManagedNative]::Identity($stream.SafeFileHandle.DangerousGetHandle()) -ne $item.identity) {
				throw 'Partial cleanup refuses a replacement extracted file.'
			}
		}
		Assert-OllamaHeldInventory $stagePath $directories $knownFiles
		# The complete held inventory is admitted before deletion begins. Already
		# absent exact objects remain absent on retry; unknown replacements refuse.
		foreach ($stream in $files) { Remove-OllamaExactFile $stream }
		$files.Clear()
		foreach ($relative in @($directories.Keys | Sort-Object { $_.Length } -Descending)) {
			[Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($directories[$relative])
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($directories[$relative])) { throw 'Partial child directory retains physical close debt.' }
			$directories.Remove($relative)
		}
		[Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($stageHandle)
		if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($stageHandle)) { throw 'Partial stage retains physical close debt.' }
		$stageHandle = [IntPtr]::Zero
		if (-not [Ergopti.Ollama.ManagedNative]::PathIsAbsent($stagePath)) { throw 'Partial stage still retains physical deletion debt.' }
		Remove-OllamaExactFile $wal.stream
		return [ordered]@{ ok = $true; phase = 'retired'; ticket = $Ticket }
	} finally {
		foreach ($stream in $files) { $stream.Dispose() }
		foreach ($handle in $directories.Values) {
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($handle)) { [Console]::Error.WriteLine('Partial cleanup retains child directory close debt.') }
		}
		if ($stageHandle -ne [IntPtr]::Zero -and -not [Ergopti.Ollama.ManagedNative]::CloseHandle($stageHandle)) {
			[Console]::Error.WriteLine('Partial cleanup retains stage close debt.')
		}
		$wal.stream.Dispose()
	}
}

function Remove-OllamaPreparedStage($Root, [string]$Ticket, [string]$ExpectedIdentity, [string]$ExpectedManifestHash) {
	if ($Ticket -notmatch '^[0-9a-f]{32}\z') { throw 'Cleanup requires the exact originating private ticket.' }
	$path = [IO.Path]::Combine($Root.path, '.stage-' + $Ticket)
	if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($path)) {
		$cleanupPath = [IO.Path]::Combine($Root.path, '.cleanup-' + $Ticket + '.json')
		if (-not [Ergopti.Ollama.ManagedNative]::PathIsAbsent($cleanupPath)) {
			$read = Open-OllamaReadFile $cleanupPath $true
			try {
				$receipt = Read-OllamaJsonStream $read
				if ($receipt.kind -ne 'ollama-cleanup' -or $receipt.ticket -ne $Ticket -or
					$receipt.identity -ne $ExpectedIdentity -or $receipt.root_identity -ne $Root.identity -or
					$receipt.manifest_sha256 -ne $ExpectedManifestHash) { throw 'A foreign cleanup journal cannot be removed.' }
				Remove-OllamaExactFile $read
			} finally { $read.Dispose() }
		}
		return [ordered]@{ ok = $true; phase = 'retired'; ticket = $Ticket }
	}
	$stage = Open-OllamaPreparedStage $Root $Ticket $ExpectedIdentity $ExpectedManifestHash $true
	$journal = $stage.cleanup_stream
	$stage.cleanup_stream = $null
	try {
		# Retire through exact DELETE-capable handles. Never drop the identity
		# fence to reopen a pathname that foreign content can replace.
		$cleanupPath = $stage.cleanup_path
		if ([Ergopti.Ollama.ManagedNative]::PathIsAbsent($cleanupPath)) {
			Write-OllamaOwnedJson $cleanupPath ([ordered]@{ kind = 'ollama-cleanup'; ticket = $Ticket;
				identity = $ExpectedIdentity; root_identity = $Root.identity; manifest_sha256 = $ExpectedManifestHash;
				manifest_bytes = [Convert]::ToBase64String($stage.manifest_bytes) })
			$journal = Open-OllamaReadFile $cleanupPath $true
		}
		foreach ($stream in $stage.owned_files.Values) { Remove-OllamaExactFile $stream }
		foreach ($stream in $stage.streams) { $stream.Dispose() }
		$stage.streams.Clear()
		$directories = @($stage.manifest.directories | Sort-Object { $_.Length } -Descending)
		foreach ($directory in $directories) {
			if (-not $stage.directory_handles.Contains($directory)) { continue }
			$nestedHandle = $stage.directory_handles[$directory]
			[Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($nestedHandle)
			if (-not [Ergopti.Ollama.ManagedNative]::CloseHandle($nestedHandle)) { throw 'An exact retired child directory retains close debt.' }
			$stage.directory_handles.Remove($directory)
		}
		# Mark only the exact retained directory for deletion. Never drop the
		# identity fence to reopen a pathname that a foreign directory can replace.
		[Ergopti.Ollama.ManagedNative]::DeleteExactDirectory($stage.handle)
		Close-OllamaPreparedStage $stage
		if (-not [Ergopti.Ollama.ManagedNative]::PathIsAbsent($stage.path)) { throw 'The exact marked directory still retains physical cleanup debt.' }
		Remove-OllamaExactFile $journal
		$journal = $null
		return [ordered]@{ ok = $true; phase = 'retired'; ticket = $Ticket }
	} finally {
		if ($null -ne $journal) { $journal.Dispose() }
		if ($stage.handle -ne [IntPtr]::Zero) { Close-OllamaPreparedStage $stage }
	}
}

if ($MyInvocation.InvocationName -ne '.') {
	$root = $null; $archive = $null; $stage = $null; $publicationReceipt = $null
	try {
		if ($Action -eq '') { throw 'An explicit native file operation is required.' }
		$root = Open-OllamaManagedRoot $ManagedRoot ($Action -eq 'prepare')
		switch ($Action) {
			'prepare' {
				$archive = Read-OllamaPinnedArchive $CataloguePath $CatalogueSha256 $AssetId $ArchivePath $MaxExpandedBytes $MaxEntries
				$result = Prepare-OllamaManagedStage $root $archive $TicketId $true
			}
			'publish' {
				$stage = Open-OllamaPreparedStage $root $TicketId $StageIdentity $ManifestSha256
				$result = Publish-OllamaPreparedStage $root $stage
				# Retain scalar ownership evidence until every final native closure ACKs.
				$publicationReceipt = [ordered]@{}
				foreach ($key in $stage.publication_receipt.Keys) { $publicationReceipt[$key] = $stage.publication_receipt[$key] }
			}
			'cleanup' { $result = Remove-OllamaPreparedStage $root $TicketId $StageIdentity $ManifestSha256 }
			'cleanup_partial' { $result = Remove-OllamaPartialStage $root $TicketId $CreationWalIdentity $CreationWalSha256 }
		}
		if ($null -ne $stage) { Close-OllamaPreparedStage $stage; $stage = $null }
		if ($null -ne $archive) { Close-OllamaPinnedArchive $archive; $archive = $null }
		Close-OllamaManagedRoot $root; $root = $null
		$result | ConvertTo-Json -Depth 12 -Compress
	} catch {
		$failure = [ordered]@{ ok = $false; phase = 'refused'; cleanup_pending = $true; ticket = $TicketId;
			error = $_.Exception.Message }
		if ($_.Exception.Data.Contains('ollama_creation_receipt')) { $failure.creation_receipt = $_.Exception.Data['ollama_creation_receipt'] }
		if ($_.Exception.Data.Contains('ollama_publication_receipt')) { $failure.publication_receipt = $_.Exception.Data['ollama_publication_receipt'] }
		elseif ($null -ne $publicationReceipt) { $failure.publication_receipt = $publicationReceipt }
		elseif ($null -ne $stage -and $stage.ContainsKey('publication_receipt')) { $failure.publication_receipt = $stage.publication_receipt }
		$failure | ConvertTo-Json -Depth 12 -Compress
		exit 1
	} finally {
		if ($null -ne $stage) { Close-OllamaPreparedStage $stage }
		if ($null -ne $archive) { Close-OllamaPinnedArchive $archive }
		if ($null -ne $root) { Close-OllamaManagedRoot $root }
	}
}

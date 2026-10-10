# tools/test/windows_ollama_file_validation_test.ps1
# Exact existing helper bodies, with explicitly recording native identity ports.
# No native type initialization, C# compiler, ACL read/write or file acquisition.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Helper, [string]$Inverse = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$tree=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$tokens,[ref]$errors)
if ($errors.Count -ne 0) { throw 'Helper AST must be valid.' }
$names=@('Get-OllamaStreamHash','Read-OllamaJsonStream','Assert-OllamaRelativePath','Read-OllamaCreationWal','Open-OllamaPreparedStage')
foreach ($name in $names) {
 $found=@($tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
 if ($found.Count -ne 1) { throw 'Receiving source definition is not unique.' }
 $body=$found[0].Extent.Text
 # This is the only transformation of native calls, not of their decisions.
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::Identity(', '(Get-RecordedIdentity ')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::OpenDirectory(', '(Open-RecordedDirectory ')
 $body=$body.Replace('(Open-RecordedDirectory $stage, $true)', '(Open-RecordedDirectory -Path $stage -Retire $true)')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::PathIsAbsent(', '(Test-RecordedAbsence ')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::CloseHandle(', '(Close-RecordedHandle ')
 if ($Inverse -ceq 'directory' -and $name -ceq 'Open-OllamaPreparedStage') {
  $body=$body.Replace('(Get-RecordedIdentity $directoryHandles[$relative]) -ne $expectedDirectory.Value', '$false')
 }
 if ($Inverse -ceq 'wal-image' -and $name -ceq 'Read-OllamaCreationWal') {
  $body=$body.Replace('(Get-OllamaStreamHash $stream) -ne $ExpectedHash', '$false')
 }
 . ([scriptblock]::Create($body))
}
$script:stageIdentity='11111111:0000000000000001'
$script:directoryIdentity='11111111:0000000000000002'
$script:walIdentity='11111111:0000000000000009'
$script:ticket='1'*32
$script:root=@{path='Z:\owned';versions='Z:\owned\versions';identity='11111111:0000000000000000'}
function Get-RecordedIdentity($Handle) {
 switch ($Handle) { 1 {return $script:stageIdentity} 2 {return $script:directoryIdentity} 9 {return $script:walIdentity} default {throw 'Foreign recording handle.'} }
}
function Open-RecordedDirectory($Path,$Retire) {
 if ($Path -cne $script:ownedStagePath -or -not $Retire) {throw 'Foreign recording directory.'}
 return 1
}
function Test-RecordedAbsence($Path) {
 if ($Path -cne ('Z:\owned\.cleanup-'+$script:ticket+'.json')) {throw 'Unknown recording absence.'}
 return $true
}
function Close-RecordedHandle($Handle) {
 if ($Handle -notin @(1,2)) {throw 'Foreign recording close.'}
 return $true
}
function Assert-OllamaPrivateSecurity($Path) {
 if ($Path -cne $script:ownedStagePath) {throw 'Foreign recording security path.'}
}
function Hold-OllamaStageDirectories($Stage,$Directories,$Create,$Retiring) {
 if ($Create -or $Retiring -or $Directories.Count -ne 1 -or -not $Directories.Contains('lib')) {throw 'Recording inventory differs.'}
 return [ordered]@{lib=2}
}
function Assert-OllamaHeldInventory($Stage,$Directories,$Files) {
 if ($Directories.Count -ne 1 -or $Files.Count -ne 2) {throw 'Recording held inventory differs.'}
}
function Open-OllamaReadFile([string]$Path,[bool]$Retire) {
 if (-not $Retire) {throw 'Exact recorded read admission must be requested.'}
 if ($Path -ceq ('Z:\owned\.creation-'+$script:ticket+'.jsonl')) {
  $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($script:walText),$false)
  $cap=New-Object PSObject
  $cap | Add-Member ScriptMethod DangerousGetHandle {return 9}
  $stream | Add-Member NoteProperty SafeFileHandle $cap
  return $stream
 }
 if ($Path -ceq ($script:ownedStagePath+'\prepared.json')) {return [IO.MemoryStream]::new($script:manifestBytes,$false)}
 if ($Path -ceq ($script:ownedStagePath+'\stage-owner.json')) {
  $text=@{kind='ollama-stage';ticket=$script:ticket;identity=$script:stageIdentity;root_identity=$script:root.identity}|ConvertTo-Json -Compress
  return [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($text),$false)
 }
 throw 'Foreign recording file.'
}
function New-Manifest {
 return [ordered]@{kind='ollama-prepared';ticket=$script:ticket;identity=$script:stageIdentity;root_identity=$script:root.identity;
  version='0.24.0';asset='windows-amd64';archive_sha256=('2'*64);directories=@('lib');directory_identities=@{lib='11111111:0000000000000002'};files=@()}
}
function Read-Stage($Manifest,[string]$PublishedPath='',[IntPtr]$RetainedHandle=[IntPtr]::Zero) {
 $script:ownedStagePath=if ($PublishedPath -eq '') {'Z:\owned\.stage-'+$script:ticket} else {$PublishedPath}
 $script:manifestBytes=[Text.Encoding]::UTF8.GetBytes(($Manifest|ConvertTo-Json -Depth 8 -Compress))
 $stream=[IO.MemoryStream]::new($script:manifestBytes,$false)
 try {$hash=Get-OllamaStreamHash $stream} finally {$stream.Dispose()}
 $stage=Open-OllamaPreparedStage $script:root $script:ticket $script:stageIdentity $hash $false $PublishedPath $RetainedHandle
 foreach ($stream in $stage.streams) {$stream.Dispose()}
}
function New-Wal {
 $header=@{kind='ollama-creation';ticket=$script:ticket;identity=$script:walIdentity;root_identity=$script:root.identity;archive_sha256=('2'*64);catalogue_sha256=('3'*64);asset='windows-amd64'}
 $records=@($header,@{kind='stage-intent';sequence=1;path='';identity=''},@{kind='stage-owned';sequence=2;path='';identity=$script:stageIdentity},@{kind='file-intent';sequence=3;path='ollama.exe';identity=''},@{kind='file-owned';sequence=4;path='ollama.exe';identity='11111111:0000000000000003'})
 return $records
}
function Read-Wal($Records,[string]$Hash='') {
 $script:walText=(($Records | ForEach-Object {$_|ConvertTo-Json -Compress}) -join "`n")+"`n"
 if ($Hash -eq '') {
  $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($script:walText),$false)
  try {$Hash=Get-OllamaStreamHash $stream} finally {$stream.Dispose()}
 }
 $wal=Read-OllamaCreationWal $script:root $script:ticket $script:walIdentity $Hash
 try {
  if (-not $wal.objects.ContainsKey('ollama.exe') -or $wal.objects['ollama.exe'].identity -cne '11111111:0000000000000003') {throw 'Actual WAL parser did not retain owned CLI.'}
 } finally {$wal.stream.Dispose()}
}
$script:passed=0; $script:failed=0
function Check([string]$Name,[scriptblock]$Body,[string]$Reason='') {
 $observed=''
 try {& $Body} catch {$observed=$_.Exception.Message}
 if ($observed -ceq $Reason) {$script:passed++;Write-Output ('PASS '+$Name)} else {$script:failed++;Write-Output ('FAIL '+$Name+' expected='+$Reason+' observed='+$observed)}
}
Check 'actual prepared directory identity admitted' {Read-Stage (New-Manifest)}
Check 'replacement directory refused under same named inventory' {$script:directoryIdentity='11111111:0000000000000099';try {Read-Stage (New-Manifest)} finally {$script:directoryIdentity='11111111:0000000000000002'}} 'A prepared directory identity changed before publication or cleanup.'
Check 'missing captured directory identity refused' {$m=New-Manifest;$m.directory_identities=@{};Read-Stage $m} 'A prepared directory identity changed before publication or cleanup.'
Check 'actual WAL parser retains ordered owned CLI' {Read-Wal (New-Wal)}
Check 'changed WAL image refused' {Read-Wal (New-Wal) ('0'*64)} 'The captured creation journal identity or image changed.'
Check 'foreign WAL root refused' {$r=New-Wal;$r[0].root_identity='foreign';Read-Wal $r} 'The creation journal does not belong to this exact native call.'
Check 'sequence gap refused' {$r=New-Wal;$r[2].sequence=7;Read-Wal $r} 'The creation journal sequence or operation is unknown.'
Check 'owned identity without intent refused' {$r=New-Wal;$r[1].kind='stage-owned';$r[1].identity=$script:stageIdentity;Read-Wal $r} 'Creation identity has no exact preceding intent.'
Check 'intent cannot borrow physical identity' {$r=New-Wal;$r[3].identity='11111111:0000000000000003';Read-Wal $r} 'Creation intent duplicates or borrows an existing identity.'
$m=New-Manifest
$target=[IO.Path]::Combine($script:root.versions,$m.version+'-'+$m.asset+'-'+$m.archive_sha256)
Check 'published target validation borrows exact stage handle' {Read-Stage (New-Manifest) $target ([IntPtr]1)}
Check 'published target still rejects replacement child' {$script:directoryIdentity='11111111:0000000000000099';try {Read-Stage (New-Manifest) $target ([IntPtr]1)} finally {$script:directoryIdentity='11111111:0000000000000002'}} 'A prepared directory identity changed before publication or cleanup.'
Check 'published target cannot borrow a foreign leaf' {Read-Stage (New-Manifest) ($target+'-foreign') ([IntPtr]1)} 'The published target differs from its exact prepared source.'
Check 'published target cannot reacquire a stage by path' {Read-Stage (New-Manifest) $target ([IntPtr]::Zero)} 'Published validation requires its retained stage handle and exact versions parent.'
Write-Output ('RESULT passed='+$script:passed+' failed='+$script:failed+' native_calls=0 real_file_acquisitions=0')
if ($script:failed -ne 0) {exit 1}

# tools/test/windows_ollama_file_publication_test.ps1
# Actual publication/closure bodies with recording native and reopen boundaries.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Helper,[string]$Inverse='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$t,[ref]$e)
if ($e.Count) {throw 'Helper AST invalid.'}
foreach ($name in @('Get-OllamaStreamHash','Close-OllamaPreparedChildren','Publish-OllamaPreparedStage')) {
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
 if ($f.Count -eq 0 -and $name -ceq 'Close-OllamaPreparedChildren') {continue}
 if ($f.Count -ne 1) {throw 'Actual body missing or ambiguous.'}
 $body=$f[0].Extent.Text.Replace('[Ergopti.Ollama.ManagedNative]::CloseHandle($Stage.directory_handles[$relative])','(Close-RecordedChild $Stage.directory_handles[$relative])')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::RenameCreate($Stage.handle, $target)','Invoke-RecordedRename $Stage.handle $target')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::Identity($Stage.handle)','(Get-RecordedIdentity $Stage.handle)')
 if ($Inverse -ceq 'no-close') {$body=$body.Replace('Close-OllamaPreparedChildren $Stage','# omitted descendant closure')}
 if ($Inverse -ceq 'no-revalidate') {$body=$body.Replace('$checked = Open-OllamaPreparedStage $Root $manifest.ticket $manifest.identity $manifestHash $false $target $Stage.handle','$checked = @{streams=$Stage.streams;owned_files=$Stage.owned_files;directory_handles=$Stage.directory_handles}')}
 . ([scriptblock]::Create($body))
}
function New-Stage {
 $script:closeAck=$true;$script:throwDispose=$false;$script:rejectTarget=$false
 $script:renameCalls=0;$script:openCalls=0;$script:disposeCalls=0
 $stream=New-Object PSObject
 $stream | Add-Member ScriptMethod Dispose {
  $script:disposeCalls++
  if ($script:throwDispose) {throw 'Injected exact file close refusal.'}
 }
 $streams=[Collections.Generic.List[object]]::new();$streams.Add($stream)
 $manifest=@{version='0.24.0';asset='windows-amd64';archive_sha256=('2'*64);ticket=('1'*32);identity='11111111:0000000000000001'}
 $script:stage=@{handle=[IntPtr]1;path='Z:\owned\.stage-'+('1'*32);manifest=$manifest;
  manifest_bytes=[Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Compress));streams=$streams;owned_files=@{'ollama.exe'=$stream};directory_handles=[ordered]@{lib=[IntPtr]2}}
 $script:root=@{path='Z:\owned';versions='Z:\owned\versions';identity='11111111:0000000000000000'}
}
function Close-RecordedChild($Handle) {
 if ($Handle -ne [IntPtr]2) {throw 'Foreign close capability.'}
 return $script:closeAck
}
function Get-RecordedIdentity($Handle) {
 if ($Handle -ne [IntPtr]1) {throw 'Foreign stage capability.'}
 return $script:stage.manifest.identity
}
function Invoke-RecordedRename($Handle,$Target) {
 if ($Handle -ne [IntPtr]1) {throw 'Foreign rename capability.'}
 if ($script:stage.streams.Count -ne 0 -or $script:stage.directory_handles.Count -ne 0) {throw 'Native recorded Access denied: retained descendants.'}
 $script:renameCalls++
 $script:renamedTarget=$Target
}
function Open-OllamaPreparedStage($Root,$Ticket,$Identity,$Hash,$Retiring,$Target,$Handle) {
 $script:openCalls++
 if ($Handle -ne [IntPtr]1 -or $Retiring -or $Ticket -cne $script:stage.manifest.ticket -or $Identity -cne $script:stage.manifest.identity -or $Target -cne $script:renamedTarget) {throw 'Foreign revalidation authority.'}
 $memory=[IO.MemoryStream]::new($script:stage.manifest_bytes,$false)
 try {$expectedHash=Get-OllamaStreamHash $memory} finally {$memory.Dispose()}
 if ($Hash -cne $expectedHash) {throw 'Revalidation did not retain exact manifest bytes.'}
 if ($script:rejectTarget) {throw 'Injected target file identity/hash refusal.'}
 return @{streams=[Collections.Generic.List[object]]::new();owned_files=@{};directory_handles=[ordered]@{}}
}
function Assert-Case($Value,[string]$Message) {if (-not $Value) {throw $Message}}
$script:pass=0;$script:fail=0
function Case([string]$Name,[scriptblock]$Body) {
 try {New-Stage;&$Body;$script:pass++;Write-Output ('PASS '+$Name)} catch {$script:fail++;Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
Case 'same retained stage publishes only after child closure and target revalidation' {
 $r=Publish-OllamaPreparedStage $root $stage
 Assert-Case ($r.ok -and $openCalls -eq 1 -and $renameCalls -eq 1 -and $disposeCalls -eq 1) 'Actual closure/reopen sequence required.'
 Assert-Case ($stage.handle -eq [IntPtr]1 -and $r.version_identity -ceq $stage.manifest.identity) 'Original stage handle retained.'
}
Case 'child close false prevents rename and retains exact capability' {
 $script:closeAck=$false;$failure=$null
 try {Publish-OllamaPreparedStage $root $stage|Out-Null} catch {$failure=$_.Exception}
 Assert-Case ($null -ne $failure -and $renameCalls -eq 0 -and $stage.directory_handles['lib'] -eq [IntPtr]2) 'Refused child ACK must retain its handle before rename.'
 Assert-Case ($failure.Data.Contains('ollama_publication_receipt') -and -not $failure.Data['ollama_publication_receipt'].renamed) 'Pre-rename exact debt receipt required.'
}
Case 'file close throw prevents rename and retains remaining stream' {
 $script:throwDispose=$true;$failure=$null
 try {Publish-OllamaPreparedStage $root $stage|Out-Null} catch {$failure=$_.Exception}
 Assert-Case ($null -ne $failure -and $renameCalls -eq 0 -and $stage.streams.Count -eq 1) 'Thrown close retains exact stream capability.'
}
Case 'changed target refuses executable and carries renamed debt' {
 $script:rejectTarget=$true;$result=$null;$failure=$null
 try {$result=Publish-OllamaPreparedStage $root $stage} catch {$failure=$_.Exception}
 Assert-Case ($null -eq $result -and $null -ne $failure -and $openCalls -eq 1) 'Revalidation refusal cannot publish executable.'
 $debt=$failure.Data['ollama_publication_receipt']
 Assert-Case ($debt.renamed -and $debt.cleanup_pending -and $debt.version_path -ceq $renamedTarget -and $stage.handle -eq [IntPtr]1) 'Renamed exact target remains owned debt.'
}
Write-Output ('RESULT passed='+$script:pass+' failed='+$script:fail+' native_calls=0')
if ($script:fail) {exit 1}

[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Library,[string]$Inverse='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Library,[ref]$t,[ref]$e)
if($e.Count){throw 'Source must parse.'}
foreach($name in @('New-OllamaOwnedCurlCapture','Invoke-OllamaManagedArchiveDownload')) {
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
 if($f.Count -ne 1){throw 'Actual acquisition source missing.'}
 $body=$f[0].Extent.Text
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($path, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())','New-RecordedDirectory $path')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::CreateProtectedDirectory($stagePath, (New-OllamaPrivateSecurity).GetSecurityDescriptorBinaryForm())','New-RecordedDirectory $stagePath')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::OpenDirectory($path, $false)','(Open-RecordedDirectory $path)')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::OpenDirectory($stagePath, $true)','(Open-RecordedDirectory $stagePath)')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::Identity(', '(Get-RecordedIdentity ')
 $body=$body.Replace('[Ergopti.Ollama.ManagedNative]::CloseHandle(', '(Close-RecordedHandle ')
 $body=$body.Replace('$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($stagePath))','$drive = @{AvailableFreeSpace=100000}')
 $body=$body.Replace('[Console]::Out.WriteLine(($construction | ConvertTo-Json -Compress))','$script:construction=$construction')
 if($Inverse -eq 'scope-loss'){$body=$body.Replace('$capture.output_owner = New-OllamaExtractedFile', '$outputOwner = New-OllamaExtractedFile').Replace('$capture.output_owner.is_current', '$outputOwner.is_current').Replace('return $capture.output_owner', 'return $outputOwner')}
 if($Inverse -eq 'ignore-identity'){$body=$body.Replace('(Get-RecordedIdentity $read.SafeFileHandle.DangerousGetHandle()) -cne $capture.output_owner.identity', '$false')}
 if($Inverse -eq 'ignore-digest'){$body=$body.Replace('(Get-OllamaStreamHash $read) -cne $Source.pin.sha256', '$false')}
 if($Inverse -eq 'direct-route'){$body=$body.Replace('return Resolve-ErgoptiNativeNetworkRoutes $DestinationUrl $RemainingMs $ReadConfig $ReadEnvironment $PolicyPath $DefaultsPath', 'return @{Ok=$true}')}
 if($Inverse -eq 'lose-close-receipt'){$body=$body.Replace("if (`$null -ne `$finalReceipt) { `$closeFailure.Exception.Data['ollama_creation_receipt'] = `$finalReceipt }", '# omitted close receipt')}
 . ([scriptblock]::Create($body))
}
class OwnedMemory : IO.MemoryStream {[void]Flush([bool]$Durable){}}
function Add-OllamaCreationRecord($Wal,$Kind,$Path,$Identity) {$script:events.Add($Kind+':'+$Path)}
function New-RecordedDirectory($Path) {$script:events.Add('create-directory:'+([IO.Path]::GetFileName($Path)))}
function Open-RecordedDirectory($Path) {if([IO.Path]::GetFileName($Path) -like 'curl.*'){return [IntPtr]2};return [IntPtr]1}
function Get-RecordedIdentity($Handle) {return ('11111111:'+([int64]$Handle).ToString('x16'))}
function Close-RecordedHandle($Handle) {$script:closeCalls++;return -not ($script:mode -eq 'close-refused' -and $Handle -eq [IntPtr]2)}
function Begin-OllamaCreationWal($Root,$Source,$Ticket) {return @{stream=[IO.MemoryStream]::new();identity='11111111:0000000000000008'}}
function Get-OllamaCreationReceipt($Wal) {return @{creation_wal_identity=$Wal.identity;creation_wal_sha256=('4'*64)}}
function Get-ErgoptiUpdaterRemainingMilliseconds($Start,$Budget,$State) {if($Start -ne 11 -or $Budget -ne 1000){throw 'Original clock changed.'};if(($script:mode -eq 'late-hash' -and $script:hashCompleted) -or ($script:mode -eq 'late-close' -and $script:closeCalls -eq 2)){$script:clockRefusalAt=$script:closeCalls;throw [TimeoutException]::new('recorded_deadline_expired')};return 1000}
function New-OllamaExtractedFile($Wal,$Stage,$Relative) {
 Add-OllamaCreationRecord $Wal 'file-intent' $Relative ''
 $stream=[OwnedMemory]::new()
 $cap=New-Object PSObject;$cap|Add-Member ScriptMethod DangerousGetHandle {return 3}
 $stream|Add-Member NoteProperty SafeFileHandle $cap
 Add-OllamaCreationRecord $Wal 'file-owned' $Relative '11111111:0000000000000003'
 if($Relative -eq 'ollama-windows-amd64.zip') {$script:archiveStream=$stream}
 return @{stream=$stream;identity='11111111:0000000000000003'}
}
function Resolve-ErgoptiNativeNetworkRoutes($Url,$Budget,$ReadConfig,$ReadEnvironment,$Policy,$Defaults) {
 $script:routeCalls++
 if($Policy -cne 'policy' -or $Defaults -cne 'defaults') {throw 'Canonical policy routing changed.'}
 return @{Ok=$true}
}
function Invoke-ErgoptiUpdaterCurlDownload($Uri,$Path,$Connect,$State,$Resolver,$Budget,$Start,$Size,$Policy,$Defaults,$ReadEnvironment,$Factory) {
 if($Start -ne 11 -or $Budget -ne 1000 -or $Connect -ne 200 -or $Size -ne 3) {throw 'Transport original timing or pin changed.'}
 if($State.OwnedCaptureDirectory -notmatch 'curl\.[0-9a-f]{32}$'){throw 'Parent-owned capture not supplied.'}
 $selection=&$Resolver $Uri.AbsoluteUri 1000
 if(-not $selection.Ok){throw 'Routing refused.'}
 if($script:mode -eq 'transport-refused'){throw 'recorded_transport_refused'}
 $owned=&$Factory $Path $Size
 if($null -eq $owned -or -not (&$owned.is_current $owned)){throw 'Recorded output authority refused.'}
 if($script:events[-1] -cne 'file-owned:ollama-windows-amd64.zip'){throw 'Durable exact file ownership must precede payload bytes.'}
 $script:events.Add('payload-write')
 $bytes=[Text.Encoding]::ASCII.GetBytes('abc');$owned.stream.Write($bytes,0,$bytes.Length);$owned.stream.Flush($true);$owned.stream.Dispose()
 return 3
}
function Open-OllamaReadFile($Path) {
 $stream=[IO.MemoryStream]::new($script:archiveStream.ToArray(),$false)
 $cap=New-Object PSObject
 $cap|Add-Member ScriptMethod DangerousGetHandle {if($script:mode -eq 'replaced'){return 99};return 3}
 $stream|Add-Member NoteProperty SafeFileHandle $cap
 return $stream
}
function Get-OllamaStreamHash($Stream) {
 $hash=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($hash.ComputeHash($Stream))).Replace('-','').ToLowerInvariant()}
 finally{$hash.Dispose();$Stream.Position=0;$script:hashCompleted=$true}
}
$passed=0;$failed=0
foreach($caseMode in @('owned','replaced','digest-mismatch','transport-refused','close-refused','late-hash','late-close')) {
 $script:mode=$caseMode;$script:events=[Collections.Generic.List[string]]::new();$script:closeCalls=0;$script:routeCalls=0;$script:hashCompleted=$false;$script:clockRefusalAt=-1
 $sourceStream=[IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('catalogue'),$false)
 $source=@{stream=$sourceStream;url='https://example.invalid/official';version='0.24.0';asset='windows-amd64';catalogue_sha256=('5'*64);pin=@{filename='ollama-windows-amd64.zip';bytes=3;sha256='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'}}
 if($caseMode -eq 'digest-mismatch'){$source.pin.sha256='0'*64}
 $result=$null;$failure=$null
 try{$result=Invoke-OllamaManagedArchiveDownload @{path='D:\owned';identity='root'} $source ('1'*32) 200 1000 11 'policy' 'defaults'} catch{$failure=$_.Exception} finally{$sourceStream.Dispose()}
 $ok=if($caseMode -eq 'owned') {$null -eq $failure -and $result.ok -and $result.archive_identity -ceq '11111111:0000000000000003' -and $script:closeCalls -eq 2} else {$null -ne $failure -and $null -eq $result -and $failure.Data.Contains('ollama_creation_receipt')}
 if($caseMode -eq 'transport-refused'){$ok=$ok -and $failure.Message -ceq 'recorded_transport_refused' -and -not $script:events.Contains('payload-write')}
 if($caseMode -in @('replaced','digest-mismatch')){$ok=$ok -and $failure.Message -ceq 'The complete acquired archive differs from its original identity or pin.'}
 if($caseMode -eq 'close-refused'){$ok=$ok -and $failure.Message -ceq 'Archive capture retains exact directory close debt.'}
 if($caseMode -in @('late-hash','late-close')){$ok=$ok -and $null -ne $failure -and $failure.Message -ceq 'recorded_deadline_expired' -and $script:closeCalls -eq 2 -and $script:clockRefusalAt -eq $(if($caseMode -eq 'late-hash'){0}else{2})}
 $ok=$ok -and $script:routeCalls -eq 1
 if($ok){$passed++;Write-Output ('PASS '+$caseMode)} else {$failed++;Write-Output ('FAIL '+$caseMode+' reason='+$(if($null -ne $failure){$failure.Message}else{'unexpected success'}))}
}
Write-Output ('RESULT passed='+$passed+' failed='+$failed+' native=0 network=0 filesystem=0')
if($failed){exit 1}

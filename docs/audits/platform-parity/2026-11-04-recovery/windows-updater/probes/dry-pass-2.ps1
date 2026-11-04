param([string]$ProbeDirectory,[string]$StagingSource)
$ErrorActionPreference='Stop'
. (Join-Path $ProbeDirectory 'actual-swap-helpers.ps1')
$Root=Join-Path $ProbeDirectory 'helper-controls';[IO.Directory]::CreateDirectory($Root)|Out-Null
$DiagnosticPath=Join-Path $Root 'diagnostic.log'
$Source=Join-Path $Root 'source é.bin';$Destination=Join-Path $Root 'destination space.bin'
[IO.File]::WriteAllText($Source,'source bytes Ω',[Text.UTF8Encoding]::new($false))
foreach($Path in @($Destination,($Destination+'.tmp'))){if([IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}
$Received=PublishCopy $Source $Destination
if($Received -cne $Destination -or [IO.File]::ReadAllText($Destination) -cne 'source bytes Ω'){throw 'Actual copy did not preserve exact synthetic bytes'}
$Failure=$null;try{PublishCopy $Source $Destination|Out-Null}catch{$Failure=$_}
if($null -eq $Failure -or [IO.File]::ReadAllText($Destination) -cne 'source bytes Ω'){throw 'Collision must refuse without replacing destination'}
$Terminal=Join-Path $Root 'terminal';WriteTerminal $Terminal (('Z'*2100)+"`r`ninjected line")
if([IO.File]::ReadAllText($Terminal).Length -ne 2000 -or [IO.File]::ReadAllText($Terminal).Contains("`n")){throw 'Actual terminal must remain bounded and one-line'}
$Utf8Terminal=Join-Path $Root 'utf8-terminal';WriteTerminal $Utf8Terminal ('SWAP_ERROR:'+('漢'*900))
$Utf8Bytes=[IO.FileInfo]::new($Utf8Terminal).Length
if($Utf8Bytes -le 2048){throw 'The producer/consumer budget observation was not exercised'}
Write-Output ('OBSERVATION synthetic_unicode_terminal_bytes='+$Utf8Bytes+' consumer_budget=2048 real_windows_exception_reachability=unestablished')
$Claim=Join-Path $Root 'recovery.claim';WriteClaim $Claim $Destination $Source
if([IO.File]::ReadAllText($Claim) -cne ($Destination+[Environment]::NewLine+$Source)){throw 'Actual recovery claim must retain exact target/stage'}
$Text=[IO.File]::ReadAllText($StagingSource)
$From=$Text.IndexOf('  if ($ExpectedSha256 -cnotmatch ',[StringComparison]::Ordinal);$To=$Text.IndexOf('  $SwapSource=',[StringComparison]::Ordinal)
if($From -lt 0 -or $To -le $From){throw 'Actual complete digest source absent'}
$Digest=[ScriptBlock]::Create($Text.Substring($From,$To-$From))
$NewExe=Join-Path $Root 'digest bytes.bin';[IO.File]::WriteAllBytes($NewExe,[Text.Encoding]::ASCII.GetBytes('abc'))
$StartedTick=101;$DeadlineMs=5000;$script:BudgetCalls=0
function Get-ErgoptiUpdaterRemainingMilliseconds($Started,$Deadline,$Observed){if($Started -ne 101 -or $Deadline -ne 5000 -or $Observed.Stage -cne 'file_read'){throw 'Budget identity changed'};$script:BudgetCalls++;return 4999}
foreach($Mode in @('valid','mismatch','invalid')){
 $State=@{Stage='file_read';Reason='download'}
 $ExpectedSha256=switch($Mode){valid{'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'} mismatch{'0'*64} invalid{'not-a-sha256'}}
 $Failed=$false;try{. $Digest}catch{$Failed=$true}
 if($Failed -ne ($Mode -ne 'valid')){throw 'Actual digest outcome wrong'}
 if($Failed -and $State.Reason -cne 'verify'){throw 'Actual digest refusal lost verification provenance'}
 $Exclusive=[IO.File]::Open($NewExe,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$Exclusive.Dispose()
 if([IO.File]::ReadAllText($NewExe) -cne 'abc'){throw 'Digest control changed source bytes'}
 Write-Output ('PASS actual-digest '+$Mode+' native_requests=0')
}
if($script:BudgetCalls -ne 2){throw 'Valid/mismatch must consume exact original budget; invalid refused before hash'}
Write-Output 'PASS actual-swap-helpers controls=4 actual-digest controls=3 real-private-file-io=true native-process-events=false'

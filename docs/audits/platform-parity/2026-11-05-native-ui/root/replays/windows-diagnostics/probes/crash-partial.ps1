param([Parameter(Mandatory=$true)][string]$SourceRoot,[Parameter(Mandatory=$true)][string]$PrivateRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$timestamp='2026-11-05T12:34:56Z'
foreach($worker in @('ergopti_crash_worker.ps1','ergopti_crash_fallback_worker.ps1')){
 $source=Join-Path $SourceRoot ('static/ergopti_plus/windows/vendor/'+$worker)
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$t,[ref]$e)
 if($e.Count){throw 'Genuine worker parse failed.'}
 $fn=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Write-CrashDocument'})
 if($fn.Count -ne 1){throw 'Genuine writer not found exactly once.'}
 . ([scriptblock]::Create($fn[0].Extent.Text))
 $directory=Join-Path $PrivateRoot $worker;[void][IO.Directory]::CreateDirectory($directory)
 $healthy='{"canary":"owned-small-healthy"}'
 $first=Write-CrashDocument $directory $timestamp $healthy
 if([IO.File]::ReadAllText($first) -cne $healthy){throw 'Healthy writer mismatch.'}
 $second=Write-CrashDocument $directory $timestamp $healthy
 if($first -ceq $second -or [IO.File]::ReadAllText($first) -cne $healthy){throw 'Collision replacement or duplicate name.'}
 Write-Output ('PASS '+$worker+' healthy JSON + no-replace duplicate')
 $large='{"canary":"'+('A'*16384)+'"}'
 $refused=$false;$exceptionType=''
 try{Write-CrashDocument $directory $timestamp $large|Out-Null}catch{$refused=$true;$exceptionType=$_.Exception.GetBaseException().GetType().FullName}
 $partial=Join-Path $directory '2026-11-05T12-34-56Z-3.json'
 $exists=[IO.File]::Exists($partial)
 $length=if($exists){([IO.FileInfo]$partial).Length}else{0}
 $valid=$true;if($exists){try{[IO.File]::ReadAllText($partial)|ConvertFrom-Json|Out-Null}catch{$valid=$false}}
 [ordered]@{worker=$worker;write_refused=$refused;exception=$exceptionType;canonical_json_retained=$exists;retained_bytes=$length;intended_bytes=[Text.Encoding]::UTF8.GetByteCount($large);valid_json=$valid}|ConvertTo-Json -Compress
 if(-not $refused -or -not $exists -or $length -le 0 -or $length -ge [Text.Encoding]::UTF8.GetByteCount($large) -or $valid){throw 'Partial-write defect was not reproduced.'}
}
Write-Output 'CONFIRMED both unchanged production crash writers retain truncated canonical JSON after actual private-file write refusal'

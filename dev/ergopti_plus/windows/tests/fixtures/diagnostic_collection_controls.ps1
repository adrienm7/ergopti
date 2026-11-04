# tests/fixtures/diagnostic_collection_controls.ps1
#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Checkout, [Parameter(Mandatory=$true)][string]$Runtime)
$ErrorActionPreference='Stop'
$taskRoot=(Join-Path ([IO.Path]::GetTempPath()) 'ergopti-collector-controls-')+[Guid]::NewGuid().ToString('N')
[IO.Directory]::CreateDirectory($taskRoot)|Out-Null
$taskWorker=Join-Path $Checkout 'static/ergopti_plus/windows/vendor/ergopti_diagnostics.ps1'
$taskContract=Join-Path $Checkout 'static/ergopti_plus/_shared/modules/diagnostics/collection.json'
$taskPowerShell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$taskProofs=New-Object Collections.Generic.List[object]
$taskSentinel='sk-'+('A'*32)
$taskSourceSha=(& git -C $Checkout rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $taskSourceSha -cnotmatch '^[0-9a-f]{40}$'){throw 'The fixture requires its actual checkout commit identity.'}
$taskRuntimeVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($Runtime).ProductVersion
if($taskRuntimeVersion -cnotmatch '^[0-9]+[.][0-9]+[.][0-9]+$'){throw 'The fixture requires its actual runtime identity.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$env:PSModulePath="$env:SystemRoot/System32/WindowsPowerShell/v1.0/Modules;"+$env:PSModulePath
foreach($taskCase in @('native','slow-native-setup','cancel','deadline','foreign-physical','missing-component','redaction-refusal','false-installed-origin','existing-partial','archive-limit','owner-observed','query-timeout','resident-observed','resident-private-field','resident-native-forgery','resident-stale','resident-future','resident-phase','resident-capacity','resident-fifo-census','resident-pass-reason','approved-name-failure','approved-name-image','produced-evidence-change','foreign-evidence-output','foreign-evidence-stage','first-evidence-publication-race','repeated-evidence-successor','repeated-evidence-equal-successor','repeated-evidence-hardlink','exclusive-evidence-update')){
 $taskId='ergopti-diagnostic-'+[Guid]::NewGuid().ToString('N');$taskDirectory=Join-Path $taskRoot $taskId
 [IO.Directory]::CreateDirectory($taskDirectory)|Out-Null
 $taskRunWorker=$taskWorker;$taskRunContract=$taskContract
 if($taskCase -eq 'slow-native-setup'){
  $taskRunWorker=Join-Path $taskRoot 'slow-native-setup-control.ps1'
  $taskSource=[IO.File]::ReadAllText($taskWorker)
  $taskSeam='$taskNativeWatch = [Diagnostics.Stopwatch]::StartNew()'
  if(([regex]::Matches($taskSource,[regex]::Escape($taskSeam)).Count) -ne 1){throw 'Slow setup control requires the exact native probe entry.'}
  # Delay only the parent preparation; the real child and its actual UIA query remain unchanged.
  $taskSource=$taskSource.Replace($taskSeam,$taskSeam+"`n"+'Start-Sleep -Milliseconds 9000')
  [IO.File]::WriteAllText($taskRunWorker,$taskSource,[Text.UTF8Encoding]::new($false))
 }
 if(@('deadline','archive-limit') -contains $taskCase){
  $taskObject=Get-Content -LiteralPath $taskContract -Raw -Encoding UTF8|ConvertFrom-Json
  if($taskCase -eq 'deadline'){$taskObject.deadline_ms=1}else{$taskObject.max_archive_bytes=1}
  $taskRunContract=Join-Path $taskRoot ($taskCase+'-contract.json')
  [IO.File]::WriteAllText($taskRunContract,($taskObject|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
 }
 if($taskCase -eq 'produced-evidence-change'){
  $taskRunWorker=Join-Path $taskRoot 'changed-evidence-control.ps1'
  $taskSource=[IO.File]::ReadAllText($taskWorker)
  $taskSeam="$"+'taskStagingArchive = $taskArchive + '+"'.partial'"
  if(([regex]::Matches($taskSource,[regex]::Escape($taskSeam)).Count) -ne 1){throw 'Evidence change control requires the exact real archive seam.'}
  $taskSource=$taskSource.Replace($taskSeam,$taskSeam+"`n"+'[IO.File]::WriteAllText((Join-Path $taskRoot '+"'summary.md'), '"+$taskSentinel+"', "+'$taskEncoding)')
  [IO.File]::WriteAllText($taskRunWorker,$taskSource,[Text.UTF8Encoding]::new($false))
 }
 if($taskCase -eq 'first-evidence-publication-race'){
  $taskRunWorker=Join-Path $taskRoot 'first-evidence-publication-control.ps1'
  $taskSource=[IO.File]::ReadAllText($taskWorker)
  $taskSeam='[IO.File]::Move($taskStaging, $taskTarget)'
  if(([regex]::Matches($taskSource,[regex]::Escape($taskSeam)).Count) -ne 1){throw 'First publication control requires the exact no-overwrite move seam.'}
  $taskSource=$taskSource.Replace($taskSeam,'if ($Name -ceq '+"'manifest.json') { [IO.File]::WriteAllText("+'$taskTarget'+", '"+$taskSentinel+"', "+'$taskEncoding) }'+"`n"+$taskSeam)
  [IO.File]::WriteAllText($taskRunWorker,$taskSource,[Text.UTF8Encoding]::new($false))
 }
 if(@('repeated-evidence-successor','repeated-evidence-equal-successor','repeated-evidence-hardlink','exclusive-evidence-update') -contains $taskCase){
  $taskRunWorker=Join-Path $taskRoot ($taskCase+'-control.ps1')
  $taskSource=[IO.File]::ReadAllText($taskWorker)
  $taskSeam='$taskPrior = $taskEvidenceReceipts[$Name]'
  $taskInjection=@'
if ($Name -ceq 'progress.json' -and !(Test-Path -LiteralPath (Join-Path $taskRoot 'successor-proof.bin'))) {
 $taskOriginalBytes=[IO.File]::ReadAllBytes($taskTarget)
 if ('CONTROL_CASE' -ceq 'repeated-evidence-hardlink') {
  New-Item -ItemType HardLink -Path ($taskTarget+'.foreign-link') -Target $taskTarget | Out-Null
 } else {
  [IO.File]::Move($taskTarget,$taskTarget+'.predecessor')
  $taskSuccessorBytes=$(if('CONTROL_CASE' -ceq 'repeated-evidence-successor'){$taskEncoding.GetBytes('CONTROL_SENTINEL')}else{$taskOriginalBytes})
  [IO.File]::WriteAllBytes($taskTarget,$taskSuccessorBytes)
 }
 [IO.File]::WriteAllBytes((Join-Path $taskRoot 'successor-proof.bin'),[IO.File]::ReadAllBytes($taskTarget))
}
'@
  if($taskCase -eq 'exclusive-evidence-update'){
   $taskSeam='$taskOutput.SetLength(0)'
   $taskInjection=@'
if ($Name -ceq 'progress.json' -and !(Test-Path -LiteralPath (Join-Path $taskRoot 'exclusive-update-proof.json'))) {
 $taskCompetingRefusal=$false; $taskCompetingCode=0
 try { $taskCompeting=[IO.File]::Open($taskTarget,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $taskCompeting.Dispose() }
 catch { $taskCompetingCode=$_.Exception.GetBaseException().HResult -band 0xffff; $taskCompetingRefusal=@(32,33) -contains $taskCompetingCode }
 [IO.File]::WriteAllText((Join-Path $taskRoot 'exclusive-update-proof.json'),([ordered]@{writer_refused=$taskCompetingRefusal;error_code=$taskCompetingCode}|ConvertTo-Json -Compress),$taskEncoding)
}
'@
  }
  if(([regex]::Matches($taskSource,[regex]::Escape($taskSeam)).Count) -ne 1){throw 'Repeated update control requires the exact acquired-stream seam.'}
  $taskInjection=$taskInjection.Replace('CONTROL_CASE',$taskCase).Replace('CONTROL_SENTINEL',$taskSentinel)
  if($taskCase -eq 'exclusive-evidence-update'){$taskSource=$taskSource.Replace($taskSeam,$taskInjection+"`n"+$taskSeam)}
  else{$taskSource=$taskSource.Replace($taskSeam,$taskSeam+"`n"+$taskInjection)}
  [IO.File]::WriteAllText($taskRunWorker,$taskSource,[Text.UTF8Encoding]::new($false))
 }
 if($taskCase -eq 'query-timeout'){
  $taskRunWorker=Join-Path $taskRoot 'bounded-query-control.ps1'
  $taskSource=[IO.File]::ReadAllText($taskWorker).Replace('if ($UiaChild) {',"if (`$UiaChild) {`n`tStart-Sleep -Milliseconds 20000")
  [IO.File]::WriteAllText($taskRunWorker,$taskSource,[Text.UTF8Encoding]::new($false))
 }
 $taskComponents=@(
  @{id='driver';path=(Join-Path $Checkout 'static/ergopti_plus/windows/ErgoptiPlus.ahk')},
  @{id='runtime';path=$Runtime},
  @{id='native_owner';path=(Join-Path $Checkout 'static/ergopti_plus/windows/vendor/ergopti_nav_owner.dll')},
  @{id='native_manifest';path=(Join-Path $Checkout 'static/ergopti_plus/windows/vendor/ergopti_nav_owner.manifest.json')},
  @{id='collector';path=$taskRunWorker},@{id='contract';path=$taskRunContract})
 $taskRequest=@{schema_version=1;redaction_verified=$true;compiled=0;evidence_origin='worker_control';version='local';source_sha=$taskSourceSha;architecture='x64';runtime=$taskRuntimeVersion;contract_path=$taskRunContract;components=$taskComponents}
 if($taskCase -eq 'missing-component'){$taskRequest.components[0].path=Join-Path $taskDirectory 'missing.ahk'}
 if($taskCase -eq 'redaction-refusal'){$taskRequest.version='token='+$taskSentinel}
 if($taskCase -eq 'false-installed-origin'){$taskRequest.compiled=1}
 if(($taskCase -eq 'owner-observed' -or $taskCase -like 'resident-*')){
  $taskRequest.input_owner=@{pid=$PID;created_filetime=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc();mutex='exempt';mutex_handle_retained=0;dispatcher_started=0;native_started=0;native_quarantined=0}
 }
 if($taskCase -like 'resident-*'){
  # This is a controlled receipt projection, never a resident driver/native qualification.
  $taskSchema=Get-Content -LiteralPath $taskContract -Raw -Encoding UTF8|ConvertFrom-Json
  $taskStateRows=@()
  foreach($taskStateId in $taskSchema.resident_observation_fields.PSObject.Properties.Name){
   $taskValues=@{};foreach($taskField in $taskSchema.resident_observation_fields.$taskStateId){$taskValues[$taskField]=-1}
   $taskStateRows+=@{id=$taskStateId;status='UNRUN';scope='unexecuted';reason='resident_owner_unavailable';duration_ms=0
    scenario_qualified=0;values=$taskValues;evidence_class='automatic';preconditions=@($taskSchema.resident_observation_preconditions);errors=@()}
  }
  $taskStateRows[0].status='PASS';$taskStateRows[0].scope='runtime_state';$taskStateRows[0].reason='resident_generations_observed'
  foreach($taskField in $taskSchema.resident_observation_fields.hotstrings){$taskStateRows[0].values[$taskField]=0}
  if($taskCase -eq 'resident-private-field'){
   $taskStateRows[0].values.api_key=$taskSentinel
   [IO.File]::WriteAllText((Join-Path $taskDirectory 'resident-observations.json'),$taskSentinel,[Text.UTF8Encoding]::new($false))
  }
  if($taskCase -eq 'resident-native-forgery'){
   $taskStateRows[1].status='PASS';$taskStateRows[1].scope='native_readonly';$taskStateRows[1].reason='native_managed_listener_identity_observed'
   $taskStateRows[1].values.managed_owner_present=1;$taskStateRows[1].values.live_identity=1
  }
  $taskRequest.resident_observations=@{schema_version=1;captured_at_filetime=[DateTime]::UtcNow.ToFileTimeUtc();rows=$taskStateRows}
  switch($taskCase){
   'resident-stale' {$taskRequest.resident_observations.captured_at_filetime=$taskRequest.input_owner.created_filetime-1}
   'resident-future' {$taskRequest.resident_observations.captured_at_filetime=[DateTime]::UtcNow.AddDays(1).ToFileTimeUtc()}
   'resident-phase' {$taskStateRows[2].values.phase=99}
   'resident-capacity' {$taskStateRows[2].values.queued=$taskSchema.resident_native_abi.capture_capacity+1}
   'resident-fifo-census' {$taskStateRows[3].values.record_count=0;$taskStateRows[3].values.pending_count=1}
   'resident-pass-reason' {$taskStateRows[0].reason='resident_owner_unavailable'}
  }
 }
 [IO.File]::WriteAllText((Join-Path $taskDirectory 'request.json'),($taskRequest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $taskDirectory 'request.json.tmp'),$taskSentinel,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $taskDirectory 'unexpected-private.txt'),$taskSentinel,[Text.UTF8Encoding]::new($false))
 $taskAck=@{session_id=$taskId;physical_text='SKIP';physical_display='SKIP'}
 if($taskCase -eq 'foreign-physical'){$taskAck.session_id='foreign-session'}
 [IO.File]::WriteAllText((Join-Path $taskDirectory 'physical.json'),($taskAck|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 if(@('cancel','approved-name-failure','approved-name-image','produced-evidence-change','repeated-evidence-successor','repeated-evidence-equal-successor','repeated-evidence-hardlink','exclusive-evidence-update') -contains $taskCase){[IO.File]::WriteAllText((Join-Path $taskDirectory 'cancel'),'cancel',[Text.UTF8Encoding]::new($false))}
 $taskForeignName=$null
 if($taskCase -eq 'approved-name-failure'){$taskForeignName='failure.json'}
 if($taskCase -eq 'approved-name-image'){$taskForeignName='synthetic-window.png'}
 if($taskCase -eq 'foreign-evidence-output'){$taskForeignName='manifest.json'}
 if($taskCase -eq 'foreign-evidence-stage'){$taskForeignName='manifest.json.tmp'}
 if($taskForeignName){[IO.File]::WriteAllText((Join-Path $taskDirectory $taskForeignName),$taskSentinel,[Text.UTF8Encoding]::new($false))}

 if($taskCase -eq 'existing-partial'){[IO.File]::WriteAllText(($taskDirectory+'.zip.partial'),'owned existing partial',[Text.UTF8Encoding]::new($false))}
 $taskInfo=New-Object Diagnostics.ProcessStartInfo
 $taskInfo.FileName=$taskPowerShell;$taskInfo.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$taskRunWorker+'" -SessionDirectory "'+$taskDirectory+'"'
 $taskInfo.UseShellExecute=$false;$taskInfo.CreateNoWindow=$true;$taskInfo.RedirectStandardOutput=$true;$taskInfo.RedirectStandardError=$true
 $taskProcess=[Diagnostics.Process]::Start($taskInfo);$taskRetainedHandle=$taskProcess.Handle
 $taskOutput=$taskProcess.StandardOutput.ReadToEndAsync();$taskErrors=$taskProcess.StandardError.ReadToEndAsync()
 $taskExited=$taskProcess.WaitForExit($(if($taskCase -eq 'slow-native-setup'){35000}else{20000}))
 if(!$taskExited){throw ('Collector control retained PID '+$taskProcess.Id+'; no competitor was launched.')}
 $taskRow=[ordered]@{case=$taskCase;scope=$(if($taskCase -eq 'query-timeout'){'injected_query_delay'}elseif($taskCase -eq 'slow-native-setup'){'injected_native_setup_delay'}elseif(@('produced-evidence-change','first-evidence-publication-race','repeated-evidence-successor','repeated-evidence-equal-successor','repeated-evidence-hardlink','exclusive-evidence-update') -contains $taskCase){'injected_evidence_change'}else{'actual_worker_control'});worker_sha256=(Get-FileHash -LiteralPath $taskRunWorker -Algorithm SHA256).Hash;exit_code=$taskProcess.ExitCode;stderr_bytes=$taskErrors.Result.Length;archive_created=(Test-Path -LiteralPath ($taskDirectory+'.zip'));path=$taskDirectory;results=@();checks=@()}
 if($taskRow.archive_created){
  $taskCommitted=$taskOutput.Result|ConvertFrom-Json
  if($taskCommitted.schema_version -ne 1 -or $taskCommitted.session_id -cne $taskId -or $taskCommitted.archive_committed -ne $true -or
   $taskCommitted.bytes -ne (Get-Item -LiteralPath ($taskDirectory+'.zip')).Length -or
   $taskCommitted.sha256 -cne (Get-FileHash -LiteralPath ($taskDirectory+'.zip') -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Actual worker acknowledgement did not bind the exact committed archive.'}
 }
 $taskProcess.Dispose()
 if(Test-Path -LiteralPath (Join-Path $taskDirectory 'results.json')){$taskResults=Get-Content -LiteralPath (Join-Path $taskDirectory 'results.json') -Raw -Encoding UTF8|ConvertFrom-Json;$taskRow.results=$taskResults.results}
 if($taskRow.archive_created){
  $taskZip=[IO.Compression.ZipFile]::OpenRead($taskDirectory+'.zip')
  try{
   $taskAllowed=@('manifest.json','results.json','summary.md','failure.json','synthetic-window.png')
   if($taskCase -eq 'resident-observed'){$taskAllowed+='resident-observations.json'}
   $taskNames=@($taskZip.Entries|ForEach-Object FullName);$taskRow.checks+=@{id='evidence_allowlist';ok=(@($taskNames|Where-Object{$_ -cnotin $taskAllowed}).Count -eq 0)}
   $taskRow.checks+=@{id='manifest_present';ok=($taskNames -contains 'manifest.json')}
   $taskSafe=$true
   foreach($taskEntry in $taskZip.Entries){if($taskEntry.Name -eq 'synthetic-window.png'){continue};$taskReader=New-Object IO.StreamReader($taskEntry.Open());try{if($taskReader.ReadToEnd().Contains($taskSentinel)){$taskSafe=$false}}finally{$taskReader.Dispose()}}
   $taskRow.checks+=@{id='synthetic_secret_not_exported';ok=$taskSafe}
  }finally{$taskZip.Dispose()}
 }
 $taskProofs.Add($taskRow)
 [IO.File]::WriteAllText((Join-Path $taskRoot 'controls.json'),($taskProofs.ToArray()|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
 Write-Host ($taskCase+' exit='+$taskRow.exit_code+' archive='+$taskRow.archive_created)
}
$taskExpectedChecks=Get-Content -LiteralPath $taskContract -Raw -Encoding UTF8|ConvertFrom-Json
foreach($taskProof in $taskProofs){
 if(@('repeated-evidence-successor','repeated-evidence-equal-successor','repeated-evidence-hardlink') -contains $taskProof.case){
  $taskProgressPath=Join-Path $taskProof.path 'progress.json';$taskProofPath=Join-Path $taskProof.path 'successor-proof.bin'
  if($taskProof.exit_code -ne 1 -or $taskProof.archive_created -or !(Test-Path -LiteralPath $taskProofPath) -or
   (Get-FileHash -LiteralPath $taskProgressPath -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $taskProofPath -Algorithm SHA256).Hash){throw 'A foreign repeated-update successor was rewritten or its refusal disappeared.'}
  if($taskProof.case -eq 'repeated-evidence-hardlink' -and
   (Get-FileHash -LiteralPath ($taskProgressPath+'.foreign-link') -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $taskProofPath -Algorithm SHA256).Hash){throw 'A foreign hardlink alias changed.'}
  continue
 }
 if(@('foreign-evidence-output','foreign-evidence-stage','first-evidence-publication-race') -contains $taskProof.case){
  $taskForeignName=$(if($taskProof.case -ne 'foreign-evidence-stage'){'manifest.json'}else{'manifest.json.tmp'})
  if($taskProof.exit_code -ne 1 -or $taskProof.archive_created -or [IO.File]::ReadAllText((Join-Path $taskProof.path $taskForeignName)) -cne $taskSentinel){throw 'A foreign evidence output or stage was adopted, changed or archived.'}
  continue
 }
 if(@('existing-partial','archive-limit','produced-evidence-change') -contains $taskProof.case){
  if($taskProof.exit_code -ne 1 -or $taskProof.archive_created){throw 'Existing partial archive control failed.'}
  if($taskProof.case -eq 'existing-partial' -and [IO.File]::ReadAllText($taskProof.path+'.zip.partial') -cne 'owned existing partial'){throw 'Existing partial archive was modified.'}
  if($taskProof.case -eq 'produced-evidence-change' -and [IO.File]::ReadAllText((Join-Path $taskProof.path 'summary.md')) -cne $taskSentinel){throw 'The changed evidence control did not reach its actual source seam.'}
  $taskArchiveError=Get-Content -LiteralPath (Join-Path $taskProof.path 'archive-error.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if(!$taskArchiveError.partial_retained -or $taskArchiveError.reason -cne 'archive_creation_failed'){throw 'Partial archive cleanup debt disappeared.'}
  continue
 }
 $taskPrimaryRefusal=@('foreign-physical','missing-component','redaction-refusal','false-installed-origin','resident-private-field','resident-native-forgery','resident-stale','resident-future','resident-phase','resident-capacity','resident-fifo-census','resident-pass-reason') -contains $taskProof.case
 $taskExpectedExit=$(if($taskPrimaryRefusal){1}else{0})
 if($taskProof.exit_code -ne $taskExpectedExit -or !$taskProof.archive_created -or $taskProof.stderr_bytes -ne 0){throw ('Worker primary outcome or archive acknowledgement failed: '+$taskProof.case)}
 $taskTerminal=Get-Content -LiteralPath (Join-Path $taskProof.path 'progress.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($taskTerminal.phase -cne $(if($taskPrimaryRefusal){'failed'}else{'completed'}) -or $taskTerminal.session_id -cne ([IO.Path]::GetFileName($taskProof.path)) -or !$taskTerminal.archive_created){throw 'Collector primary refusal was promoted, or its valid archive became inaccessible.'}
 if($taskPrimaryRefusal -and !(Test-Path -LiteralPath (Join-Path $taskProof.path 'failure.json'))){throw 'Primary refusal lost its exact local error receipt.'}
 $taskManifest=Get-Content -LiteralPath (Join-Path $taskProof.path 'manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if(@('redaction-refusal','false-installed-origin') -notcontains $taskProof.case -and ($taskManifest.build_kind -cne 'worker_control' -or $taskManifest.source_sha -cne $taskSourceSha)){throw 'Worker controls claimed resident product provenance.'}
 if($taskProof.case -eq 'false-installed-origin' -and ($taskManifest.build_kind -cne 'unverified_input' -or
  !([IO.File]::ReadAllText((Join-Path $taskProof.path 'summary.md')).Contains('Installed binary evidence: False')))){throw 'Rejected identity retained an installed-binary evidence claim.'}
 foreach($taskCheck in $taskProof.checks){if(!$taskCheck.ok){throw ('Archive control failed: '+$taskProof.case+'/'+$taskCheck.id)}}
 if($taskProof.results.Count -ne $taskExpectedChecks.checks.Count){throw ('Result census failed: '+$taskProof.case)}
 foreach($taskId in $taskExpectedChecks.checks){if(@($taskProof.results|Where-Object {$_.id -ceq $taskId}).Count -ne 1){throw 'Missing or duplicate result.'}}
 $taskById=@{};foreach($taskRow in $taskProof.results){$taskById[$taskRow.id]=$taskRow}
 foreach($taskResult in $taskProof.results){
  if($taskExpectedChecks.statuses -cnotcontains $taskResult.status -or $taskExpectedChecks.evidence_classes -cnotcontains $taskResult.evidence_class -or
   $taskResult.duration_ms -lt 0 -or !$taskResult.preconditions.Count -or $taskResult.reason -cnotmatch '^[a-z0-9_]+$'){throw 'Structured result contract failed.'}
  if($taskResult.status -ceq 'PASS' -and $taskResult.evidence_class -ceq 'unexecuted'){throw 'Unexecuted evidence became PASS.'}
 }
 if($taskById.cleanup.status -cne 'PASS'){throw 'Native child or control cleanup failed.'}
 if($taskById.cleanup.receipt.scope -cne 'owned_window_and_control_files' -or
  @($taskById.cleanup.receipt.operations_unfinished|Where-Object {$_.operation -ceq 'host_worker_retirement' -and $_.state -ceq 'awaiting_host_ack'}).Count -ne 1){throw 'A live worker claimed its own future host-tree retirement.'}
 if($taskById.physical_text.status -ceq 'PASS' -or $taskById.physical_display.status -ceq 'PASS'){throw 'Automated controls invented physical qualification.'}
 if(@('native','slow-native-setup') -contains $taskProof.case -and ($taskById.native_uia.status -cne 'PASS' -or $taskById.native_render.status -cne 'PASS')){throw ('Actual native synthetic collection failed: '+$taskProof.case)}
 if($taskProof.case -eq 'slow-native-setup' -and $taskById.native_uia.duration_ms -lt 9000){throw 'The slow preparation control did not execute.'}
 if($taskProof.case -eq 'exclusive-evidence-update'){
  $taskExclusive=Get-Content -LiteralPath (Join-Path $taskProof.path 'exclusive-update-proof.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($taskExclusive.writer_refused -ne $true -or @(32,33) -notcontains $taskExclusive.error_code){throw 'A competing writer acquired the exclusive update stream.'}
  $taskZip=[IO.Compression.ZipFile]::OpenRead($taskProof.path+'.zip')
  try{if(@($taskZip.Entries|Where-Object {$_.FullName -ceq 'exclusive-update-proof.json'}).Count){throw 'The private ownership control entered the archive.'}}
  finally{$taskZip.Dispose()}
 }

 if(@('cancel','deadline') -contains $taskProof.case -and $taskById.physical_text.status -cne 'SKIP'){throw 'Cancellation promoted physical evidence.'}
 if($taskProof.case -eq 'missing-component' -and $taskById.components.status -cne 'FAIL'){throw 'Missing component admitted.'}
 if($taskProof.case -eq 'redaction-refusal' -and $taskById.redaction.status -cne 'FAIL'){throw 'Private identity admitted.'}
 if($taskProof.case -eq 'false-installed-origin' -and $taskById.redaction.status -cne 'FAIL'){throw 'A worker control was admitted as installed product evidence.'}
 if($taskProof.case -eq 'query-timeout' -and $taskById.native_uia.status -cne 'FAIL'){throw 'Timed-out query admitted.'}
 if(@('approved-name-failure','approved-name-image') -contains $taskProof.case){
  $taskForeignName=$(if($taskProof.case -eq 'approved-name-failure'){'failure.json'}else{'synthetic-window.png'})
  if([IO.File]::ReadAllText((Join-Path $taskProof.path $taskForeignName)) -cne $taskSentinel){throw 'Untouched approved-name evidence was changed.'}
  $taskZip=[IO.Compression.ZipFile]::OpenRead($taskProof.path+'.zip')
  try{if(@($taskZip.Entries|Where-Object {$_.FullName -ceq $taskForeignName}).Count){throw 'Untouched approved-name private evidence entered the actual archive.'}}
  finally{$taskZip.Dispose()}
 }

 if($taskProof.case -eq 'owner-observed' -and ($taskById.callbacks.status -cne 'UNRUN' -or $taskById.callbacks.receipt.observation -cne 'PASS' -or
  $taskById.callbacks.receipt.reason -cne 'exclusive_input_session_not_admitted' -or $taskById.callbacks.receipt.isolated_input_allowed)){throw 'Observed host ownership granted an isolated native input session.'}
 if($taskProof.case -eq 'resident-observed'){
  $taskState=Get-Content -LiteralPath (Join-Path $taskProof.path 'resident-observations.json') -Raw -Encoding UTF8|ConvertFrom-Json
  if($taskState.producer -cne 'worker_control' -or $taskState.scenario_qualified -ne $false -or $taskState.rows.Count -ne 4 -or
   $taskState.rows[0].status -cne 'PASS' -or $taskById.hotstrings.receipt.state_observation.scope -cne 'runtime_state'){throw 'Closed resident projection was lost or promoted.'}
  foreach($taskStateId in @('hotstrings','ai','capture_replay','callbacks','fifo','modifiers')){
   if($taskById[$taskStateId].status -cne 'UNRUN'){throw 'Resident state promoted an unexecuted functional scenario.'}
  }
  $taskZip=[IO.Compression.ZipFile]::OpenRead($taskProof.path+'.zip')
  try{if(@($taskZip.Entries|Where-Object {$_.FullName -ceq 'resident-observations.json'}).Count -ne 1){throw 'Approved state receipt missing from the actual archive.'}}
  finally{$taskZip.Dispose()}
 }
 if($taskProof.case -like 'resident-*' -and $taskProof.case -ne 'resident-observed'){
  if(!(Test-Path -LiteralPath (Join-Path $taskProof.path 'failure.json'))){throw 'Invalid resident observation was silently admitted.'}
  $taskZip=[IO.Compression.ZipFile]::OpenRead($taskProof.path+'.zip')
  try{if(@($taskZip.Entries|Where-Object {$_.FullName -ceq 'resident-observations.json'}).Count){throw 'Refused resident evidence entered the archive.'}}
  finally{$taskZip.Dispose()}
 }
}
Write-Host ('PASS: '+$taskProofs.Count+' actual Windows collection controls. Proof: '+$taskRoot)

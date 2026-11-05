param([string]$SourceRoot=$env:ERGOPTI_AUDIT_SOURCE_ROOT)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $SourceRoot){throw 'SourceRoot required.'}
$source=Join-Path $SourceRoot 'static/ergopti_plus/windows/vendor/ergopti_diagnostics.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$t,[ref]$e)
if($e.Count){throw 'Genuine collector must parse.'}
foreach($name in @('Receive-CollectionResidentObservations','Read-CollectionJson','Get-CollectionHash')){
 $fn=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
 if($fn.Count -ne 1){throw 'Genuine owner missing.'}
 . ([scriptblock]::Create($fn[0].Extent.Text))
}
$taskEncoding=[Text.UTF8Encoding]::new($false,$true)
$taskContract=[IO.File]::ReadAllText((Join-Path $SourceRoot 'static/ergopti_plus/_shared/modules/diagnostics/collection.json'))|ConvertFrom-Json
$taskStarted=[DateTime]::UtcNow
$taskId='ergopti-diagnostic-'+('a'*32)
$taskRequest=[pscustomobject]@{evidence_origin='resident_driver'}
$taskIdentity=[pscustomobject]@{source_sha=('b'*40);build_kind='interpreted_source'}
$owner=[pscustomobject]@{observation='PASS';created_filetime=($taskStarted.AddMinutes(-1).ToFileTimeUtc());pid=12345;native_started=$false;native_quarantined=$false}
function New-Observation{
 $rows=@()
 foreach($id in $taskContract.resident_observation_fields.PSObject.Properties.Name){
  $values=[ordered]@{};foreach($field in $taskContract.resident_observation_fields.$id){$values[$field]=-1}
  $rows += [pscustomobject]@{id=$id;status='UNRUN';scope='unexecuted';reason='resident_owner_unavailable';duration_ms=0;scenario_qualified=0;values=[pscustomobject]$values;evidence_class='automatic';preconditions=@($taskContract.resident_observation_preconditions);errors=@()}
 }
 return [pscustomobject]@{schema_version=1;captured_at_filetime=($taskStarted.AddSeconds(-1).ToFileTimeUtc());rows=$rows}
}
function Must-Refuse($value,$label){$refused=$false;try{Receive-CollectionResidentObservations $value $owner|Out-Null}catch{$refused=$true};if(-not $refused){throw ('Did not refuse '+$label)};Write-Output ('PASS refusal '+$label)}
$valid=New-Observation
$received=Receive-CollectionResidentObservations $valid $owner
if($received.scenario_qualified -ne $false -or @($received.rows).Count -ne 4){throw 'Missing honest UNRUN projection.'}
Write-Output 'PASS healthy four closed UNRUN observations, scenario_qualified=false'
$valid=New-Observation;$hot=@($valid.rows|Where-Object id -eq 'hotstrings')[0];$hot.status='PASS';$hot.scope='runtime_state';$hot.reason='resident_generations_observed';foreach($key in @($hot.values.PSObject.Properties.Name)){$hot.values.$key=0}
$received=Receive-CollectionResidentObservations $valid $owner
if($received.rows[0].status -cne 'PASS' -or $received.rows[0].scenario_qualified -ne $false){throw 'Runtime observation wrongly lost or qualified.'}
Write-Output 'PASS healthy observed runtime generations remain scenario-unqualified'
$bad=New-Observation;$bad.rows[0].values|Add-Member NoteProperty private_path 'CANARY-SECRET-DO-NOT-EXPORT';Must-Refuse $bad 'unknown canary field'
$bad=New-Observation;$bad.rows[0].status='PASS';Must-Refuse $bad 'unexecuted passing claim'
$bad=New-Observation;$bad.captured_at_filetime=$taskStarted.AddMinutes(1).ToFileTimeUtc();Must-Refuse $bad 'future captured time'
$bad=New-Observation;$bad.rows[0].values.registry_generation='CANARY-SECRET';Must-Refuse $bad 'free text numeric field'
$bad=New-Observation;$bad.rows[2].status='PASS';$bad.rows[2].scope='native_readonly';$bad.rows[2].reason='native_capture_state_observed';Must-Refuse $bad 'inactive native passing claim'
$private=Join-Path ([IO.Path]::GetTempPath()) ('wdg-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($private)
try{
 $file=Join-Path $private 'synthetic.json';[IO.File]::WriteAllText($file,'{"canary":"SYNTHETIC-ONLY"}',$taskEncoding)
 $value=Read-CollectionJson $file 100
 if($value.canary -cne 'SYNTHETIC-ONLY'){throw 'Private real file content mismatch.'}
 $refused=$false;try{Read-CollectionJson $file 1|Out-Null}catch{$refused=$true};if(-not $refused){throw 'Private input cap ignored.'}
 $expected=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($file)))).Replace('-','').ToLowerInvariant()
 if((Get-CollectionHash $file) -cne $expected){throw 'Private real file hash mismatch.'}
 Write-Output 'PASS genuine private Linux file JSON, cap refusal and independent SHA-256'
}finally{[IO.Directory]::Delete($private,$true)}
Write-Output 'RESULT 8 controls passed; no native collector entry, input, network or Windows APIs executed'

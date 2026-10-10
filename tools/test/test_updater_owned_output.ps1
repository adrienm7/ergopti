# tools/test/test_updater_owned_output.ps1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Module,[string]$Inverse='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Module,[ref]$t,[ref]$e)
if ($e.Count) {throw 'Invalid module source.'}
foreach($name in @('Invoke-ErgoptiUpdaterCurlDownload','Open-ErgoptiOwnedArtifactOutput','Assert-ErgoptiOwnedArtifactOutputCurrent')) {
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
 if ($nodes.Count -eq 0 -and $name -ne 'Invoke-ErgoptiUpdaterCurlDownload') {continue}
 if ($nodes.Count -ne 1) {throw 'Exact source body missing.'}
 $body=$nodes[0].Extent.Text
 $body=$body.Replace('[IO.Directory]::CreateDirectory($Parent)','(New-RecordedDirectory $Parent)')
 $body=$body.Replace('[IO.Directory]::Exists($CaptureCandidate)','(Test-RecordedCapture $CaptureCandidate)')
 $body=$body.Replace('[IO.File]::Exists((Join-Path $CaptureCandidate $Name))','(Test-RecordedCaptureFile (Join-Path $CaptureCandidate $Name))')
 $body=$body.Replace('        . (Join-Path $PSScriptRoot ''ergopti_curl_attempt.ps1'')','        # explicitly recording engine boundary, no native module load')
 $body=$body.Replace("(Join-Path `$PSScriptRoot 'ergopti_curl_capabilities_worker.ps1')", "'D:\closed-recording\capability.ps1'")
 $body=$body.Replace('$Defaults = Get-Content -LiteralPath $DefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json','$Defaults = Get-RecordedDefaults $DefaultsPath')
 $body=$body.Replace('$Input = [IO.File]::Open($Parameters.response_path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)','$Input = Open-RecordedInput $Parameters.response_path')
 $body=$body.Replace('$Output = [IO.File]::Open($NewExe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)','$Output = Open-RecordedDefaultOutput $NewExe')
 if ($Inverse -eq 'ignore-authority') {$body=$body.Replace('    Assert-ErgoptiOwnedArtifactOutputCurrent $Owner','    # omitted captured authority')}
 if ($Inverse -eq 'ignore-copy-currentness') {$body=$body.Replace('if ($null -ne $OutputOwner) { Assert-ErgoptiOwnedArtifactOutputCurrent $OutputOwner }','if ($false) {}')}
 . ([scriptblock]::Create($body))
}
class RecordedMemory : IO.MemoryStream {
 [void] Flush([bool]$Durable) {}
}
function New-RecordedDirectory($Path) {if($Path -cne 'D:\owned') {throw 'Foreign parent.'}}
function Test-RecordedCapture($Path) {return $Path -ceq ('D:\owned\curl.'+('1'*32))}
function Test-RecordedCaptureFile($Path) {return $Path -like 'D:\owned\curl.*\*'}
function Get-RecordedDefaults($Path) {return @{archive_transfer=@{transport=@{max_header_bytes=1024;revocation_best_effort=$true}}}}
function Get-ErgoptiNetworkPolicy($Path) {return @{selected_proxy_bypass='environment';environment_bypass_precedence=@('NO_PROXY');failover=@{proxy_name_resolution_exits=@(5);proxy_connect_exits=@(7)}}}
function Test-ErgoptiNetworkInt32($Value) {return $Value -is [int]}
function Get-ErgoptiUpdaterRemainingMilliseconds($Start,$Budget,$State) {return 1000}
function Assert-ErgoptiUpdaterDestination($Destination) {if($Destination.Scheme -ne 'https') {throw 'Refused HTTPS.'}}
function Test-ErgoptiEnvironmentBypass($Destination,$Bypass,$Policy) {return $false}
function Get-ErgoptiUpdaterFailureReceipt($Exception,$State) {return @{stage=$State.Stage}}
function Get-ErgoptiUpdaterNativeException($Exception) {return $Exception}
function Close-ErgoptiUpdaterResource($Resource,$Name,$Stage,$State) {if($null -ne $Resource) {$Resource.Dispose()}}
function Open-RecordedInput($Path) {return [IO.MemoryStream]::new([Text.Encoding]::ASCII.GetBytes('abc'),$false)}
function Open-RecordedDefaultOutput($Path) {
 $script:defaultCalls++
 if ($script:ownedMode) {throw 'Path-based output creation cannot replace the captured WAL capability.'}
 $script:output=[RecordedMemory]::new();return $script:output
}
function New-ErgoptiCurlAttemptEngine($Parameters,$Answer,$CapabilityPath,$PayloadPath,$ConfPath) {
 $engine=New-Object PSObject
 $engine | Add-Member ScriptMethod GetRemainingBudget {return 1000}
 $engine | Add-Member ScriptMethod GetNativeRemainingBudget {return 1000}
 $engine | Add-Member ScriptMethod ObserveCapability {return @{version='8.7.0';sspi=$true;spnego=$true}}
 $engine | Add-Member ScriptMethod ChildQuiesced {return $true}
 $engine | Add-Member ScriptMethod InvokeRoute {param($Destination,$Route,$Auth,$Method,$Body,$Secrets) if($Method -cne 'GET' -or $Body -or $Secrets) {throw 'Changed request intent.'};return @{exit=0;status=200;delivered=3;child_quiesced=$true;proxy_used=$false}}
 $engine | Add-Member ScriptMethod TestNtlmChallenge {return $false}
 return $engine
}
function Invoke-Case([string]$Mode) {
 $script:ownedMode=$Mode -ne 'default';$script:defaultCalls=0;$script:factoryCalls=0;$script:currentCalls=0
 $script:output=[RecordedMemory]::new()
 $state=@{Stage='proxy_resolve';Reason='download';Receipt=@{};CleanupDebt=@();NativeCleanupDebt=$false;OwnedCaptureDirectory=('D:\owned\curl.'+('1'*32))}
 $resolver={param($Uri,$Budget) if($script:caseMode -eq 'route-refused') {return @{Ok=$false;Routes=@();MaxRoutes=1;MaxRedirects=0;CleanupDebt=$false;Receipt=@{}}};return @{Ok=$true;Routes=@(@{Kind='direct';Endpoint='';Authentication='none'});MaxRoutes=1;MaxRedirects=0;CleanupDebt=$false}}
 $factory={param($Path,$Size)
  $script:factoryCalls++
  if($Path -cne 'D:\owned\archive.zip' -or $Size -ne 3) {throw 'Captured factory request changed.'}
  $identity=if($script:caseMode -eq 'bad-identity') {'foreign'} else {'11111111:0000000000000001'}
  return @{stream=$script:output;identity=$identity;is_current={param($Owner) $script:currentCalls++;if($script:caseMode -eq 'withdrawn') {return $false};if($script:caseMode -eq 'withdraw-before-copy' -and $script:currentCalls -gt 1) {return $false};return $true}}
 }
 if($Mode -eq 'default') {return Invoke-ErgoptiUpdaterCurlDownload ([Uri]'https://example.invalid/archive.zip') 'D:\owned\archive.zip' 1000 $state $resolver 1000 1 3 'policy' 'defaults' {param($Name)return ''}}
 return Invoke-ErgoptiUpdaterCurlDownload ([Uri]'https://example.invalid/archive.zip') 'D:\owned\archive.zip' 1000 $state $resolver 1000 1 3 'policy' 'defaults' {param($Name)return ''} $factory
}
$passed=0;$failed=0
foreach($mode in @('default','owned','bad-identity','withdrawn','withdraw-before-copy','route-refused')) {
 $script:caseMode=$mode;$failureMessage='';$result=0
 try {$result=Invoke-Case $mode} catch {$failureMessage=$_.Exception.Message}
 $bytes=[Text.Encoding]::ASCII.GetString($script:output.ToArray())
 $good=if($mode -in @('default','owned')) {$failureMessage -eq '' -and $result -eq 3 -and $bytes -ceq 'abc'} else {$failureMessage -ne '' -and $bytes -ceq ''}
 if($mode -eq 'bad-identity') {$good=$good -and $failureMessage -ceq 'Captured artifact output authority was refused.'}
 if($mode -in @('withdrawn','withdraw-before-copy')) {$good=$good -and $failureMessage -ceq 'Exact artifact output authority was withdrawn.'}
 if($mode -eq 'route-refused') {$good=$good -and $failureMessage -ceq 'Canonical artifact routing was refused.'}
 if($mode -eq 'default') {$good=$good -and $script:defaultCalls -eq 1 -and $script:factoryCalls -eq 0}
 if($mode -eq 'owned') {$good=$good -and $script:defaultCalls -eq 0 -and $script:factoryCalls -eq 1 -and $script:currentCalls -ge 3}
 if($mode -eq 'route-refused') {$good=$good -and $script:factoryCalls -eq 0}
 if($good) {$passed++;Write-Output ('PASS '+$mode)} else {$failed++;Write-Output ('FAIL '+$mode+' error='+$failureMessage+' bytes='+$bytes+' factory='+$script:factoryCalls+' current='+$script:currentCalls)}
}
Write-Output ('RESULT passed='+$passed+' failed='+$failed+' native_requests=0 filesystem_operations=0')
if($failed){exit 1}

param([Parameter(Mandatory=$true)][string]$Source,[Parameter(Mandatory=$true)][string]$ManagedSource,[string]$Inverse='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual entry must parse.'}
$f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-OllamaArchiveEntry'},$false))
if($f.Count -ne 1){throw 'Actual entry must be present.'}
$body=$f[0].Extent.Text
if($Inverse -eq 'lose-final-receipt'){$body=$body.Replace('$retainedReceipt = $result', '# omitted retained receipt')}
if($Inverse -eq 'renew-clock'){$body=$body.Replace('$entryRequest.deadline_ms $entryRequest.started_tick $entryRequest.policy', '$entryRequest.deadline_ms 1 $entryRequest.policy')}
if($Inverse -eq 'hide-refusal'){$body=$body.Replace('$completion.receipt = $failure','$completion.exit_code = 0; $completion.receipt = $failure')}
if($Inverse -eq 'cli-defaults'){$body=$body.Replace('Open-OllamaManagedRoot $entryRequest.root', 'Open-OllamaManagedRoot $ManagedRoot')}
. ([scriptblock]::Create($body))
$managedText=[IO.File]::ReadAllText($ManagedSource,[Text.Encoding]::UTF8)
$managedAst=[Management.Automation.Language.Parser]::ParseInput($managedText,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual managed owner header must parse.'}
$firstFunction=@($managedAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false))[0]
$script:managedHeader=[scriptblock]::Create($managedText.Substring(0,$firstFunction.Extent.StartOffset))
function Require($Value,$Message){if(-not $Value){throw $Message}}
function Read-OllamaCapturedSource($Path,$Hash) {
	$script:reads++
	if($script:mode -eq 'source-refused'){throw 'captured-source-refused'}
	return @{stream=[IO.MemoryStream]::new();code='';path=$Path;sha256=$Hash}
}
function Get-OllamaCapturedSourceBlock($Owner){$script:loads++;if($Owner.path -ceq 'C:\owned\files.ps1'){return $script:managedHeader};return [scriptblock]::Create('')}
function Open-OllamaCapturedVendor($Path,$Hash) {
	return [ordered]@{'ergopti_updater_download.ps1'=@{stream=[IO.MemoryStream]::new();path='C:\owned\vendor\ergopti_updater_download.ps1'};'ergopti_network_routes.ps1'=@{stream=[IO.MemoryStream]::new();path='C:\owned\vendor\ergopti_network_routes.ps1'}}
}
function Open-OllamaManagedRoot($Path,$Create){$script:rootCalls++;Require ($Create -and $Path -ceq 'C:\owned\root') 'Original root survives actual dot-sourced CLI defaults.';return @{path=$Path;identity='11111111:0000000000000001'}}
function Open-OllamaReleaseSource($Path,$Hash,$Asset){$script:releaseCalls++;Require ($Path -ceq 'C:\owned\release.json' -and $Hash -ceq ('a'*64) -and $Asset -ceq 'windows-amd64') 'Original release admission survives real helper parameters.';return @{stream=[IO.MemoryStream]::new()}}
function Invoke-OllamaManagedArchiveDownload($Root,$Release,$Ticket,$Connect,$Deadline,$Start,$Policy,$Defaults) {
	$script:downloadCalls++
	Require ($Start -eq 987654321 -and $Deadline -eq 30000 -and $Connect -eq 2000) 'Captured original clock must reach the existing acquisition owner unchanged.'
	if($script:mode -eq 'download-refused'){$ex=[InvalidOperationException]::new('transport-refused');$ex.Data['ollama_creation_receipt']=@{creation_wal_identity='11111111:0000000000000008';creation_wal_sha256=('4'*64)};throw $ex}
	return @{ok=$true;phase='downloaded';ticket=$Ticket;creation_wal_identity='11111111:0000000000000008';creation_wal_sha256=('4'*64)}
}
function Close-OllamaManagedRoot($Root){$script:closeCalls++;if($script:mode -eq 'root-close-refused'){throw 'root-close-refused'}}
function Get-ErgoptiUpdaterRemainingMilliseconds($Start,$Budget) {Require ($Start -eq 987654321 -and $Budget -eq 30000) 'Final fence retains exact original clock.';if($script:mode -eq 'late-final-close'){Require ($script:closeCalls -eq 1) 'Late expiry is observed after exact root closure.';throw [TimeoutException]::new('recorded_deadline_expired')};return 1}
$Action='download';$ManagedRoot='C:\owned\root';$CataloguePath='C:\owned\release.json';$CatalogueSha256='a'*64;$AssetId='windows-amd64';$TicketId='b'*32
$ManagedHelperPath='C:\owned\files.ps1';$ManagedHelperSha256='c'*64;$AcquisitionHelperPath='C:\owned\acquisition.ps1';$AcquisitionHelperSha256='d'*64
$VendorDirectory='C:\owned\vendor';$VendorSha256='e'*64;$ProxyPolicyPath='C:\owned\policy.json';$ProxyPolicySha256='f'*64;$UpdaterDefaultsPath='C:\owned\defaults.json';$UpdaterDefaultsSha256='1'*64
$ConnectTimeoutMs=2000;$DeadlineMs=30000;$StartedTick=[int64]987654321
$passed=0;$failed=0
foreach($script:mode in @('success','source-refused','download-refused','root-close-refused','invalid-clock','late-final-close')) {
	try {
		$script:reads=0;$script:loads=0;$script:rootCalls=0;$script:releaseCalls=0;$script:downloadCalls=0;$script:closeCalls=0
		$StartedTick=if($script:mode -eq 'invalid-clock'){[int64]0}else{[int64]987654321}
		$r=Invoke-OllamaArchiveEntry
		Require ($r -is [hashtable]) 'Entry returns exactly one typed completion, not accidental pipeline values.'
		if($script:mode -eq 'success') {
			Require ($r.exit_code -eq 0 -and $r.receipt.ok -eq $true -and $r.receipt.phase -ceq 'downloaded') 'Only real acquisition success produces a success receipt.'
			Require ($script:loads -eq 4 -and $script:closeCalls -eq 1 -and $script:downloadCalls -eq 1) 'Exact verified code and final closure are required.'
		}else{
			Require ($r.exit_code -eq 1 -and $r.receipt.ok -eq $false -and $r.receipt.cleanup_pending -eq $true) 'Every refusal stays failed with explicit debt.'
			Require (-not $r.receipt.Contains('executable')) 'Refusal cannot admit an executable.'
			if($script:mode -eq 'invalid-clock'){Require ($script:reads -eq 0 -and $script:rootCalls -eq 0) 'Unadmitted clock refuses before any acquisition.'}
			if($script:mode -eq 'source-refused'){Require ($script:rootCalls -eq 0 -and $script:downloadCalls -eq 0) 'Source refusal cannot construct native files or transport.'}
			if($script:mode -eq 'download-refused' -or $script:mode -eq 'root-close-refused' -or $script:mode -eq 'late-final-close'){
				Require ($r.receipt.Contains('creation_receipt') -and $null -ne $r.receipt.creation_receipt) 'Exact known WAL evidence must survive refusal.'
				Require ($r.receipt.creation_receipt.creation_wal_identity -ceq '11111111:0000000000000008' -and $r.receipt.creation_receipt.creation_wal_sha256 -ceq ('4'*64)) 'Original file debt identity and journal image remain exact.'
			}
		}
		$passed++;[Console]::Out.WriteLine('PASS '+$script:mode)
	}catch{$failed++;[Console]::Out.WriteLine('FAIL '+$script:mode+': '+$_.Exception.Message)}
}
[Console]::Out.WriteLine("RESULT passed=$passed failed=$failed")
exit ([int]($failed -gt 0))

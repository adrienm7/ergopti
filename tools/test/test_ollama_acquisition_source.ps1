param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$FixtureRoot, [string]$Inverse='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$t=$null; $e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$t,[ref]$e)
if($e.Count){throw 'Entry source must parse.'}
foreach($name in @('Read-OllamaCapturedSource','Get-OllamaCapturedSourceBlock','Open-OllamaCapturedVendor')) {
	$f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$false))
	if($f.Count -ne 1){throw 'Real loader function missing.'}
	$body=$f[0].Extent.Text
	if($Inverse -eq 'lose-context'){$body=$body.Replace('$ast.GetScriptBlock()', '[scriptblock]::Create($Source.code)')}
	if($Inverse -eq 'ignore-source-pin'){$body=$body.Replace("if (`$ExpectedHash -ne '' -and `$actual -cne `$ExpectedHash)", 'if ($false)')}
	if($Inverse -eq 'ignore-vendor-pin'){$body=$body.Replace('if ($actual -cne $ExpectedHash)', 'if ($false)')}
	. ([scriptblock]::Create($body))
}
function Require($Value,$Message){if(-not $Value){throw $Message}}
function Hash-Bytes([byte[]]$Bytes) {
	$h=[Security.Cryptography.SHA256]::Create()
	try{return ([BitConverter]::ToString($h.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
}
function Require-Refusal([scriptblock]$Body,[string]$Expected) {
	$caught=$null;$unexpected=$null
	try {$unexpected=& $Body}catch{$caught=$_}
	finally {
		# An omission inverse may return capabilities instead of refusing. The test
		# still closes only those exact returned streams before reporting its RED.
		if($null -ne $unexpected) {
			if($unexpected.Contains('stream')){$unexpected.stream.Dispose()}
			else{foreach($owner in $unexpected.Values){$owner.stream.Dispose()}}
		}
	}
	Require ($null -ne $caught -and $caught.Exception.Message -ceq $Expected) 'The exact intended refusal is required.'
}
$passed=0;$failed=0
foreach($case in @('context','source-pin','vendor-pin','vendor-held')) {
	try {
		$path=Join-Path $FixtureRoot 'ergopti_updater_download.ps1'
		if($case -eq 'context') {
			$owner=Read-OllamaCapturedSource $path (Hash-Bytes ([IO.File]::ReadAllBytes($path)))
			try {
				. (Get-OllamaCapturedSourceBlock $owner)
				Require ((Read-TestSourceRoot) -ceq $FixtureRoot) 'Actual filename must survive captured parsing and delayed function invocation.'
			}finally{$owner.stream.Dispose()}
		}
		if($case -eq 'source-pin') {
			Require-Refusal {Read-OllamaCapturedSource $path ('0'*64)} 'Captured acquisition source changed.'
		}
		$names=@('ergopti_updater_download.ps1','ergopti_network_routes.ps1','ergopti_windows_proxy_config.ps1','ergopti_native_proxy_ex.ps1','ergopti_network_pac.ps1','ergopti_curl_attempt.ps1','ergopti_curl_capabilities_worker.ps1')
		$inventory=''
		foreach($name in $names){$inventory+=$name+"`n"+(Hash-Bytes ([IO.File]::ReadAllBytes((Join-Path $FixtureRoot $name))))+"`n"}
		$digest=Hash-Bytes ([Text.Encoding]::UTF8.GetBytes($inventory))
		if($case -eq 'vendor-pin'){
			Require-Refusal {Open-OllamaCapturedVendor $FixtureRoot ('0'*64)} 'The captured vendor dependency inventory changed.'
		}
		if($case -eq 'vendor-held') {
			$owners=Open-OllamaCapturedVendor $FixtureRoot $digest
			try {
				Require ($owners.Count -eq 7) 'All seven exact dependencies are retained.'
				foreach($name in $names) {
					Require $owners.Contains($name) 'No dependency is omitted.'
					Require $owners[$name].stream.CanRead 'Original source stream remains held.'
					$refused=$false
					try{$write=[IO.File]::Open($owners[$name].path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);$write.Dispose()}catch{$refused=$true}
					Require $refused 'Held source denies a competing byte writer.'
				}
			}finally{foreach($owner in $owners.Values){$owner.stream.Dispose()}}
		}
		$passed++;[Console]::Out.WriteLine('PASS '+$case)
	}catch{$failed++;[Console]::Out.WriteLine('FAIL '+$case+': '+$_.Exception.Message)}
}
[Console]::Out.WriteLine("RESULT passed=$passed failed=$failed")
exit ([int]($failed -gt 0))

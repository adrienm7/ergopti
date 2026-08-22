$Command = @($args)

$Bootstrap = Join-Path $PSScriptRoot "bootstrap.ps1"
$RtkPath = & $Bootstrap print-path
$BootstrapExit = $LASTEXITCODE

if ($BootstrapExit -eq 0 -and $RtkPath) {
	& $RtkPath @Command
	exit $LASTEXITCODE
}

if ($BootstrapExit -eq 3 -and $env:CI) {
	if ($Command.Count -eq 0) {
		Write-Error "No command was supplied and RTK is unavailable in CI."
		exit 64
	}
	$Child = $Command[0]
	[string[]]$ChildArguments = @()
	if ($Command.Count -gt 1) {
		$ChildArguments = [string[]]($Command[1..($Command.Count - 1)])
	}
	& $Child @ChildArguments
	exit $LASTEXITCODE
}

exit $BootstrapExit

# tests/fixtures/system_proxy_native_paths.ps1
# Actual canonical path/defaults code over controlled owned files; no PAC call.
param([Parameter(Mandatory=$true)][string]$NativeFixturePath)
$ErrorActionPreference='Stop'
$Source=[IO.File]::ReadAllText($NativeFixturePath)
$Start=$Source.IndexOf('    $VendorRoot=Split-Path -Parent ',[StringComparison]::Ordinal)
$End=$Source.IndexOf('    $LookupSeconds=$Defaults.release_sources.proxy_resolve_timeout_sec',$Start,[StringComparison]::Ordinal)
if ($Start -lt 0 -or $End -le $Start -or
    $Source.IndexOf('    $VendorRoot=Split-Path -Parent ',$Start+1,[StringComparison]::Ordinal) -ge 0) {
    throw 'Canonical native fixture path/defaults owner is ambiguous.'
}
$Body=[scriptblock]::Create($Source.Substring($Start,$End-$Start))
$Directory=Join-Path ([IO.Path]::GetTempPath()) ('ergopti-native-pac-paths-'+[Guid]::NewGuid().ToString('N'))
$Directories=@($Directory,(Join-Path $Directory 'product'),(Join-Path $Directory 'product/windows'),
    (Join-Path $Directory 'product/windows/tests'),(Join-Path $Directory 'product/windows/vendor'),
    (Join-Path $Directory 'product/_shared'),(Join-Path $Directory 'product/_shared/modules'),
    (Join-Path $Directory 'product/_shared/modules/updater'))
$Files=@();$Created=@();$Utf8=[Text.UTF8Encoding]::new($false);$Passed=0
try {
    foreach ($Path in $Directories) {
        if ([IO.Directory]::Exists($Path)) {throw 'Owned path namespace is not fresh.'}
        [IO.Directory]::CreateDirectory($Path)|Out-Null;$Created+=,$Path
    }
    $Expected=Join-Path $Directory 'product/_shared/modules/updater/defaults.json'
    [IO.File]::WriteAllText($Expected,'{"release_sources":{"proxy_resolve_timeout_sec":10}}',$Utf8);$Files+=,$Expected
    $Worker=Join-Path $Directory 'product/windows/vendor/worker.ps1'
    [IO.File]::WriteAllText($Worker,'# Owned path-only input; never executed.',$Utf8);$Files+=,$Worker
    # The expected path and budget are independently authored fixture values.
    # The original worker receives unresolved components from AHK run_all.
    foreach ($Relative in @('product/windows/vendor/worker.ps1','product/windows/tests/../vendor/worker.ps1',
        'product/windows/tests/../../windows/vendor/worker.ps1')) {
        $WorkerPath=Join-Path $Directory $Relative
        if (-not [IO.File]::Exists($WorkerPath)) {throw 'The controlled actual worker path must exist.'}
        $Defaults=$null;$DefaultsPath=$null
        . $Body
        if ([IO.Path]::GetFullPath($DefaultsPath) -cne [IO.Path]::GetFullPath($Expected) -or
            ($Defaults.release_sources.proxy_resolve_timeout_sec -isnot [int] -and
             $Defaults.release_sources.proxy_resolve_timeout_sec -isnot [long]) -or
            $Defaults.release_sources.proxy_resolve_timeout_sec -ne 10) {
            throw 'Canonical native fixture paths must preserve exact shared defaults and original budget.'
        }
        $Passed++
    }
} finally {
    foreach ($Path in $Files) {if ([IO.File]::Exists($Path)) {[IO.File]::Delete($Path)}}
    for ($Index=$Created.Count-1;$Index -ge 0;$Index--) {
        if ([IO.Directory]::Exists($Created[$Index])) {[IO.Directory]::Delete($Created[$Index],$false)}
    }
}
[Console]::Out.WriteLine('[OK] native PAC path derivation controls='+$Passed+' network=0 compiler=0')

# Exercise the actual package dependency admission function without launching Win32.
# The authored mappings and marker bytes are independent of the helper's pair table.
param(
    [Parameter(Mandatory)][string] $Probe,
    [Parameter(Mandatory)][string] $Checkout
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($Probe, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The compiled probe has invalid PowerShell syntax.' }
$function = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-AdmittedWorkerDependencies'
}, $true)
if ($null -eq $function) { throw 'The actual package dependency admission function is missing.' }
Invoke-Expression $function.Extent.Text

$root = Join-Path ([IO.Path]::GetTempPath()) ('ergopti-worker-package-' + [guid]::NewGuid().ToString('N'))
$sha = 'a' * 40
$identity = "0.0.0-dev`n$sha"
$shared = Join-Path $root 'static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk'
$vendor = Join-Path $root 'vendor/ergopti_user_hotstrings.ahk'
$marker = Join-Path $root '.bundle-version'
$utf8Bom = [Text.UTF8Encoding]::new($true)
$passed = 0
function Expect-Refusal([scriptblock] $Call) {
    $refused = $false
    try { $null = & $Call } catch { $refused = $true }
    if (!$refused) { throw 'A foreign or incomplete worker package was admitted.' }
}
try {
    $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($shared)), ([IO.Path]::GetDirectoryName($vendor))
    Copy-Item -LiteralPath (Join-Path $Checkout 'static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk') -Destination $shared
    Copy-Item -LiteralPath (Join-Path $Checkout 'static/ergopti_plus/windows/vendor/ergopti_user_hotstrings.ahk') -Destination $vendor
    [IO.File]::WriteAllText($marker, $identity, $utf8Bom)
    $digests = Get-AdmittedWorkerDependencies $Checkout $root $identity $sha
    if ($digests.Count -ne 2 -or !$digests.ContainsKey('vendor/ergopti_user_hotstrings.ahk') -or
        !$digests.ContainsKey('static/ergopti_plus/_shared/modules/hotstrings/user_code.ahk')) {
        throw 'The independently constructed healthy bundle was refused or misidentified.'
    }
    $passed++
    [IO.File]::WriteAllText($marker, " `t" + $identity + "`r`n`t ", $utf8Bom)
    $null = Get-AdmittedWorkerDependencies $Checkout $root $identity $sha
    $passed++ # The native marker reader trims these exact ASCII characters.
    [IO.File]::WriteAllText($marker, $identity, $utf8Bom)
    Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root $identity ('b' * 40) }
    $passed++
    Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root ("other-version`n$sha") $sha }
    $passed++
    foreach ($bad in @(
        ("__BUNDLE_VERSION__`n$sha"),
        ("0.0.0-dev`r`n$sha"),
        'legacy-version-only',
        ("0.0.0-dev`n$sha`nextra-line")
    )) {
        [IO.File]::WriteAllText($marker, $bad, $utf8Bom)
        Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root $bad $sha }
        $passed++
    }
    Remove-Item -LiteralPath $marker -Force
    Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root $identity $sha }
    $passed++
    [IO.File]::WriteAllText($marker, $identity, $utf8Bom)
    [IO.File]::AppendAllText($vendor, "`n; independently changed worker fixture`n")
    Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root $identity $sha }
    $passed++
    Remove-Item -LiteralPath $vendor
    Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root $identity $sha }
    $passed++
    Copy-Item -LiteralPath (Join-Path $Checkout 'static/ergopti_plus/windows/vendor/ergopti_user_hotstrings.ahk') -Destination $vendor
    [IO.File]::AppendAllText($shared, "`n; independently changed policy fixture`n")
    Expect-Refusal { Get-AdmittedWorkerDependencies $Checkout $root $identity $sha }
    $passed++
    if ($passed -ne 12) { throw 'The package admission fixture did not cover its complete authored inventory.' }
    Write-Host "Package dependency/marker admission: $passed passed, 0 failed (Win32 unexecuted)."
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

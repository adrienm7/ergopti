param([string]$SourceRoot = $env:ERGOPTI_AUDIT_SOURCE_ROOT)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SourceRoot) { throw 'Supply SourceRoot or ERGOPTI_AUDIT_SOURCE_ROOT.' }
$helper = Join-Path $SourceRoot 'static/ergopti_plus/windows/modules/llm/ollama_managed_files.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Helper parse errors.' }
foreach ($function in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
 . ([scriptblock]::Create($function.Extent.Text))
}
$fixtures = Join-Path $SourceRoot 'static/ergopti_plus/windows/tests/fixtures/ollama-install-files'
$passed = 0
foreach ($name in @('portable','traversal','ads','rooted','device','collision','trailing-dot','receipt-collision','directory-cli','symlink','file-ancestor-cli','file-ancestor-library','file-ancestor-reverse','file-ancestor-case','prepared-receipt-descendant','owner-receipt-descendant')) {
 $stream = [IO.File]::OpenRead((Join-Path $fixtures ($name+'.zip')))
 $zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
 $refused = $false
 try {
  try {
   $entries = @($zip.Entries | ForEach-Object { Get-OllamaEntryPath $_ })
   Assert-OllamaArchiveNamespace $entries
   $cli = @($entries | Where-Object { $_.path -eq 'ollama.exe' -and -not $_.directory -and $_.bytes -gt 0 })
   if ($cli.Count -ne 1) { throw 'No regular CLI.' }
  } catch { $refused = $true }
  if (($name -eq 'portable') -eq $refused) { throw ('Unexpected result for '+$name) }
  Write-Output ('PASS genuine ZIP namespace '+$name+' refused='+$refused)
  $passed++
 } finally { $zip.Dispose(); $stream.Dispose() }
}
$private = Join-Path ([IO.Path]::GetTempPath()) ('ergopti-wrt-pure-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($private)
try {
 $path = Join-Path $private 'receipt.json'
 Write-OllamaOwnedJson $path ([ordered]@{sentinel='owned';count=1})
 $before = [IO.File]::ReadAllBytes($path)
 $refused = $false
 try { Write-OllamaOwnedJson $path @{sentinel='replacement'} } catch { $refused = $true }
 if (-not $refused -or [Convert]::ToBase64String($before) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) { throw 'Create-only receipt overwritten.' }
 $read = [IO.File]::OpenRead($path)
 try {
  $read.Position = 3
  $digest = Get-OllamaStreamHash $read
  if ($read.Position -ne 3 -or $digest -cne ([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($before))).Replace('-','').ToLowerInvariant()) { throw 'Hash cursor or bytes mismatch.' }
  $read.Position=0
  $receipt = Read-OllamaJsonStream $read
  if ($receipt.sentinel -cne 'owned' -or $read.Position -ne 0) { throw 'JSON read/reset mismatch.' }
 } finally { $read.Dispose() }
 Write-Output 'PASS genuine private-file create-only, exact hash, cursor preservation, JSON reset'
 $passed++
} finally { [IO.Directory]::Delete($private,$true) }
Write-Output ('RESULT '+$passed+' passed; native Windows functions NOT invoked')

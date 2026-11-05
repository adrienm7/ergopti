param([string]$SourceRoot=$env:ERGOPTI_AUDIT_SOURCE_ROOT,[ValidateSet(1,2)][int]$Pass=1)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if (-not $SourceRoot) { throw 'SourceRoot required.' }
$relative=@(
 'static/ergopti_plus/windows/ui/menu/menu_llm/enable_admission.ahk',
 'static/ergopti_plus/windows/ui/menu/menu_llm/backend_lifecycle.ahk',
 'static/ergopti_plus/windows/ui/model_browser/init.ahk',
 'static/ergopti_plus/windows/modules/llm/ollama_deps_checker.ahk',
 'static/ergopti_plus/windows/modules/llm/ollama_managed_bootstrap.ahk',
 'static/ergopti_plus/windows/modules/llm/ollama_runtime_owner.ahk',
 'static/ergopti_plus/windows/modules/llm/ollama_install_files_port.ahk',
 'static/ergopti_plus/windows/modules/llm/ollama_managed_files.ps1',
 'static/ergopti_plus/windows/modules/llm/ollama_download_archive.ps1',
 'static/ergopti_plus/windows/modules/llm/ollama_managed_acquisition.ps1',
 'static/ergopti_plus/windows/modules/llm/ollama-runtime-launch.ps1',
 'static/ergopti_plus/windows/modules/llm/ollama-model-pull.ps1',
 'static/ergopti_plus/windows/adapters/ollama_identity.ahk',
 'static/ergopti_plus/windows/infra/app_folders.ahk',
 'static/ergopti_plus/windows/infra/legacy_folder_migration.ahk',
 'static/ergopti_plus/windows/infra/uninstall.ahk',
 'static/ergopti_plus/windows/vendor/ergopti_uninstall.ps1',
 'static/ergopti_plus/_shared/modules/paths/app_dirs.toml',
 'static/ergopti_plus/_shared/modules/llm/ollama_release.json'
)
$inventory=@()
foreach($name in $relative) {
 $path=Join-Path $SourceRoot $name
 $bytes=[IO.File]::ReadAllBytes($path)
 $digest=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes))).Replace('-','').ToLowerInvariant()
 $inventory+= [ordered]@{path=$name;sha256=$digest;bytes=$bytes.Length}
 if($name.EndsWith('.ps1')) {
  $t=$null;$e=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
  if($e.Count){throw ('PowerShell parse failed: '+$name)}
  Write-Output ('PASS parser '+$name)
 }
}
& (Join-Path $PSScriptRoot 'pure-files.ps1') -SourceRoot $SourceRoot
$receipt=[ordered]@{pass=$Pass;source_count=$inventory.Count;sha='3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a';reviewed_phases=@('public install and AI-enable admission','captured source and archive auth','nested parent/ancestor ACL and handle custody','ZIP complete namespace','prepare and creation WAL','immutable publish and target revalidation','foreground launch and listener lineage','pull observer versus launcher leases','cancel/reload retirement','application uninstall retention');new_confirmed_findings=0;native_windows_executed=$false;sources=$inventory}
$receipt|ConvertTo-Json -Depth 6

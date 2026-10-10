# tools/test/windows_ollama_file_final_close_test.ps1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Helper)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$t,[ref]$e)
if ($e.Count) {throw 'Invalid source AST.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "$"+'MyInvocation.InvocationName -ne '+"'.'"},$false))
if ($nodes.Count -ne 1) {throw 'Actual CLI finalizer missing or ambiguous.'}
$body=$nodes[0].Clauses[0].Item2.Extent.Text
$body=$body.Substring(1,$body.Length-2)
$Action='publish';$ManagedRoot='Z:\owned';$TicketId='1'*32;$StageIdentity='11111111:0000000000000001';$ManifestSha256='2'*64
$script:closeCalls=0
function Open-OllamaManagedRoot($Path,$Create) {
 if ($Path -cne 'Z:\owned' -or $Create) {throw 'Unexpected root acquisition.'}
 return @{identity='11111111:0000000000000000'}
}
function Open-OllamaPreparedStage($Root,$Ticket,$Identity,$Hash) {return @{handle=[IntPtr]1}}
function Publish-OllamaPreparedStage($Root,$Stage) {
 $Stage.publication_receipt=[ordered]@{ticket=('1'*32);root_identity=$Root.identity;stage_identity=$StageIdentity;manifest_sha256=$ManifestSha256;version_path='Z:\owned\versions\captured';renamed=$true;cleanup_pending=$true}
 return @{ok=$true;phase='published';executable='Z:\owned\versions\captured\ollama.exe'}
}
function Close-OllamaPreparedStage($Stage) {}
function Close-OllamaManagedRoot($Root) {
 $script:closeCalls++
 if ($script:closeCalls -eq 1) {throw 'Injected exact final root close refusal.'}
}
# The actual command-entry try/catch/finally runs with only recording ports.
# Its original exit1 is intentionally retained, not intercepted into success.
. ([scriptblock]::Create($body))

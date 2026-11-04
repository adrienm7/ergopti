# tests/fixtures/updater_redirect_decisions.ps1
# Replays http/get_redirect_vectors.json through the real redirect decision of the
# updater transport. Prints one "<index><TAB><verdict>" line per case; the AHK
# consumer owns the comparison and the inventory of divergences.
param(
    [Parameter(Mandatory = $true)][string]$Module,
    [Parameter(Mandatory = $true)][string]$Corpus,
    [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
. $Module
$Data = [IO.File]::ReadAllText($Corpus, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$Lines = [Collections.Generic.List[string]]::new()
$Index = 0
foreach ($Case in $Data.cases) {
    $Index++
    $Current = if ($null -ne $Case.current_url) { $Case.current_url } else { $Data.defaults.current_url }
    $Status = if ($null -ne $Case.status) { $Case.status } else { $Data.defaults.status }
    $Hops = if ($null -ne $Case.hops) { $Case.hops } else { $Data.defaults.hops }
    try {
        $Decision = Get-ErgoptiUpdaterRedirectDecision ([Uri]$Current) $Status $Case.target $Hops $Data.defaults.max_hops
        $Lines.Add("$Index`t$($Decision.Action)")
    } catch {
        $Lines.Add("$Index`trefuse")
    }
}
[IO.File]::WriteAllLines($Output, $Lines, [Text.UTF8Encoding]::new($false))
exit 0

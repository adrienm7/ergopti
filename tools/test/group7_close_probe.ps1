# Diagnostic-only causal native replay; final CI retains the full default suite.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$probeRepo = (Get-Location).Path
$probeContract = Get-Content -LiteralPath (Join-Path $probeRepo "static/ergopti_plus/_shared/modules/updater/windows_release_toolchain.json") -Raw | ConvertFrom-Json
$probeRuntime = Join-Path $env:RUNNER_TEMP "group7-ahk-runtime"
$probeArchive = Join-Path $env:RUNNER_TEMP "group7-ahk-runtime.zip"
Invoke-WebRequest -Uri $probeContract.runtime.url -OutFile $probeArchive -UseBasicParsing
if ((Get-FileHash -LiteralPath $probeArchive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $probeContract.runtime.sha256) {
    throw "The official native runtime archive digest did not match."
}
Expand-Archive -LiteralPath $probeArchive -DestinationPath $probeRuntime -Force
$probeAhk = Join-Path $probeRuntime "AutoHotkey64.exe"
function Invoke-Group7CloseProbe {
    param([string]$Root, [string]$Label, [int]$ExpectedCode)
    $probeRunner = Join-Path $Root "static/ergopti_plus/windows/tests/run_all.ahk"
    $probeResults = Join-Path $env:RUNNER_TEMP ("group7-close-probe-" + $Label + ".txt")
    $probeManifest = Join-Path $env:RUNNER_TEMP ("group7-close-probe-" + $Label + ".json")
    $probeStart = [System.Diagnostics.ProcessStartInfo]::new()
    $probeStart.FileName = $probeAhk
    foreach ($probeArgument in @("/ErrorStdOut", $probeRunner, "--only=keylogger-shutdown-close-chain")) {
        $probeStart.ArgumentList.Add($probeArgument)
    }
    $probeStart.Environment["ERGOPTI_AHK_RESULTS_FILE"] = $probeResults
    $probeStart.WorkingDirectory = $Root
    $probeStart.UseShellExecute = $false
    $probeStart.RedirectStandardOutput = $true
    $probeStart.RedirectStandardError = $true
    $probeProcess = [System.Diagnostics.Process]::new()
    $probeProcess.StartInfo = $probeStart
    if (-not $probeProcess.Start()) { throw "Native probe admission failed." }
    try {
        $probeOutTask = $probeProcess.StandardOutput.ReadToEndAsync()
        $probeErrTask = $probeProcess.StandardError.ReadToEndAsync()
        if (-not $probeProcess.WaitForExit(60000)) {
            $probeProcess.Kill($true)
            $probeProcess.WaitForExit()
            throw "Native close probe exceeded its owned deadline."
        }
        $probeCode = $probeProcess.ExitCode
        Write-Host ($probeOutTask.GetAwaiter().GetResult())
        Write-Host ($probeErrTask.GetAwaiter().GetResult())
    } finally { $probeProcess.Dispose() }
    if (-not (Test-Path -LiteralPath $probeResults)) { throw "Native probe has no execution transcript." }
    $probeTranscript = Get-Content -LiteralPath $probeResults -Raw -Encoding utf8
    Write-Host "GROUP7_CLOSE_PROBE $Label EXIT $probeCode"
    Write-Host $probeTranscript
    node ./tools/test/validate-ahk-suite-manifest.cjs --input $probeResults --json $probeManifest
    if ($LASTEXITCODE -ne 0) { throw "Native probe execution transcript failed validation." }
    $probeReceipt = Get-Content -LiteralPath $probeManifest -Raw | ConvertFrom-Json
    if ($probeReceipt.planned -ne 1 -or $probeReceipt.executed_count -ne 1 -or $probeReceipt.timed_count -ne 1 -or
        -not $probeReceipt.executed[0].name.Contains("keylogger-shutdown-close-chain")) {
        throw "Native probe did not execute exactly its named case."
    }
    Write-Host (Get-Content -LiteralPath $probeManifest -Raw)
    if ($probeCode -ne $ExpectedCode) { throw "Native close probe has an unexpected exit code $probeCode." }
    if ($ExpectedCode -eq 1 -and ($probeReceipt.failed -ne 1 -or $probeReceipt.passed -ne 0 -or
        -not $probeTranscript.Contains("direct indexed reads must reach the frozen scalar instead of the entry Map"))) {
        throw "Production preimage did not fail the exact independent indexed-property assertion."
    }
    if ($ExpectedCode -eq 0 -and ($probeReceipt.failed -ne 0 -or $probeReceipt.passed -ne 1)) {
        throw "Candidate native close probe did not pass its exact case."
    }
}
$probePreimage = "2f836cac02f88c7742312ee0c565a161845f6537"
git fetch --no-tags --depth=1 origin $probePreimage
if ($LASTEXITCODE -ne 0 -or (git rev-parse FETCH_HEAD) -cne $probePreimage) {
    throw "Exact production-preimage fetch identity did not match."
}
$probeOwnedRoot = Join-Path $env:RUNNER_TEMP "group7-close-production-preimage"
git worktree add --detach $probeOwnedRoot $env:GITHUB_SHA
if ($LASTEXITCODE -ne 0) { throw "Owned production-preimage worktree creation failed." }
$probeSourcePath = "static/ergopti_plus/windows/modules/keylogger/keylogger_session_events.ahk"
node -e 'const fs=require("node:fs"), cp=require("node:child_process"); const blob=cp.execFileSync("git",["show",process.argv[2]+":"+process.argv[3]],{cwd:process.argv[1]}); fs.writeFileSync(process.argv[1]+"/"+process.argv[3],blob)' $probeOwnedRoot $probePreimage $probeSourcePath
if ($LASTEXITCODE -ne 0) { throw "Production-preimage byte restoration failed." }
if ((Get-FileHash -LiteralPath (Join-Path $probeOwnedRoot $probeSourcePath) -Algorithm SHA256).Hash.ToLowerInvariant() -cne "ac5622c3491f41372f78203862a1ced96d66a13b253e03f3ecc915f06fe48f7e") {
    throw "Production-preimage source bytes did not match the reviewed identity."
}
Write-Host "GROUP7_CLOSE_PREIMAGE $probePreimage SHA256 $((Get-FileHash -LiteralPath (Join-Path $probeOwnedRoot $probeSourcePath) -Algorithm SHA256).Hash)"
Invoke-Group7CloseProbe -Root $probeOwnedRoot -Label "production-preimage" -ExpectedCode 1
Invoke-Group7CloseProbe -Root $probeRepo -Label "candidate" -ExpectedCode 0

$B=$CurrentExe+".bak"
$Had=[IO.File]::Exists($CurrentExe)
$Retired=(!$Had -and [IO.File]::Exists($B))
$Installed=$false
$Token=[Guid]::NewGuid().ToString("N")
$Candidate=$CurrentExe+"."+$Token+".candidate.exe"
$RecoveryPath=$CurrentExe+"."+$Token+".recovery.exe"
$RecoveryStage=$CurrentExe+"."+$Token+".republish.exe"
$RecoveryClaim=$RecoveryPath+".claim"
$Recovery=$null
$TerminalPath=$DiagnosticPath+".terminal"
RemoveBest $TerminalPath "terminal-stale"
try {
    PublishCopy $NewExe $Candidate|Out-Null;$OldSource=if($Had){$CurrentExe}elseif($Retired){$B}else{$null}
    if($null -ne $OldSource){PublishCopy $OldSource $RecoveryPath|Out-Null;PublishCopy $OldSource $RecoveryStage|Out-Null;WriteClaim $RecoveryClaim $CurrentExe $RecoveryStage;$Recovery=$RecoveryPath}
    if($Had){RemoveBest $B "stale-bak";[IO.File]::Replace($Candidate,$CurrentExe,$B,$true);$Retired=$true}else{[IO.File]::Move($Candidate,$CurrentExe)};$Installed=$true;RemoveBest $NewExe "new-cleanup"
    $Child=StartReady $CurrentExe $BootReadyTimeoutMs $ProbationMs $false
    RemoveBest $RecoveryClaim "success-claim-cleanup";RemoveBest $B "success-bak-cleanup";RemoveBest $RecoveryStage "success-stage-cleanup";RemoveBest $Recovery "success-recovery-cleanup";exit 0
  } catch {
    $Failure=$_;if($Failure.Exception.Message.StartsWith("UNSAFE_CHILD:")){throw $Failure};$TerminalMessage="SWAP_ERROR:"+$Failure.Exception.Message;try{WriteTerminal $TerminalPath $TerminalMessage}catch{Diag("terminal-write:"+$_.Exception.Message)};RemoveBest $Candidate "rollback-candidate-cleanup";$Restored=(!$Installed -and $Had -and [IO.File]::Exists($CurrentExe))
    for($I=0;$I -lt $RestoreAttempts -and !$Restored;$I++){
      try{$Source=if([IO.File]::Exists($RecoveryStage)){$RecoveryStage}elseif([IO.File]::Exists($B)){$B}else{$null};if($null -eq $Source){break};if([IO.File]::Exists($CurrentExe)){$Bad=$CurrentExe+"."+$Token+".failed.exe";RemoveBest $Bad "rollback-failed-stale";[IO.File]::Replace($Source,$CurrentExe,$Bad,$true);RemoveBest $Bad "rollback-failed-cleanup"}else{[IO.File]::Move($Source,$CurrentExe)};$Restored=$true}
      catch{Diag("rollback-restore-"+$I+":"+$_.Exception.Message);if(($I+1) -lt $RestoreAttempts){Start-Sleep -Milliseconds $RestoreRetryMs}}
    }
    $OldTerminal=[Environment]::GetEnvironmentVariable("ERGOPTI_UPDATER_SWAP_TERMINAL");[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_SWAP_TERMINAL",$TerminalPath);try{$DriverReady=$false;if($Restored){try{$RestoredChild=StartReady $CurrentExe $BootReadyTimeoutMs $ProbationMs $false;$DriverReady=$true;RemoveBest $RecoveryClaim "rollback-claim-cleanup";RemoveBest $B "rollback-bak-cleanup";RemoveBest $RecoveryStage "rollback-stage-cleanup";RemoveBest $Recovery "rollback-recovery-cleanup"}catch{if($_.Exception.Message.StartsWith("UNSAFE_CHILD:")){throw};Diag("rollback-relaunch:"+$_.Exception.Message)}}
    for($RecoveryAttempt=0;$RecoveryAttempt -lt $RestoreAttempts -and !$DriverReady -and $null -ne $Recovery -and [IO.File]::Exists($Recovery);$RecoveryAttempt++){try{if(![IO.File]::Exists($RecoveryStage)){PublishCopy $Recovery $RecoveryStage|Out-Null};WriteClaim $RecoveryClaim $CurrentExe $RecoveryStage;$RecoveryChild=StartReady $Recovery $BootReadyTimeoutMs $ProbationMs $true;$DriverReady=$true;Diag("rollback-recovery:"+$Recovery)}catch{if($_.Exception.Message.StartsWith("UNSAFE_CHILD:")){throw};Diag("rollback-recovery-"+$RecoveryAttempt+":"+$_.Exception.Message);if(($RecoveryAttempt+1) -lt $RestoreAttempts){Start-Sleep -Milliseconds $RestoreRetryMs}}}
    if(!$DriverReady){throw "Rollback could not start either canonical or recovery driver"}}finally{[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_SWAP_TERMINAL",$OldTerminal)};throw $Failure
  }
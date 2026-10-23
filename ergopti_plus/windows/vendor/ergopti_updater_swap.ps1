# vendor/ergopti_updater_swap.ps1

# ==============================================================================
# MODULE: Ergopti Updater Swap Worker
# DESCRIPTION:
# Replaces the running ErgoptiPlus.exe with the verified staged executable and
# starts it. The staging worker copies this file next to the staged executable;
# the driver then runs that copy with -File in a suspended process, because it
# must outlive the AutoHotkey process whose executable it replaces. Its
# four-event protocol prevents any production-file mutation until the driver
# has passed every shutdown refusal gate and the inherited exact parent HANDLE
# proves that process has really exited. A failed replacement rolls back to the
# previous executable, or to its recovery copy, and leaves a terminal receipt.
# ==============================================================================

param([string]$ReadyName,[string]$CommitName,[string]$AckName,[string]$FinalExitName,[int64]$ParentHandle,[string]$NewExe,[string]$CurrentExe,[int]$ProbationMs,[int]$BootReadyTimeoutMs,[int]$RestoreAttempts,[int]$RestoreRetryMs,[string]$DiagnosticPath)
$ErrorActionPreference="Stop";$R=$null;$C=$null;$A=$null;$F=$null;$P=$null
function Diag($M){try{[IO.File]::AppendAllText($DiagnosticPath,$M+[Environment]::NewLine)}catch{}}
function RemoveBest($Path,$Label){try{if($Path -and [IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}catch{Diag($Label+":"+$_.Exception.Message)}}
function WriteTerminal($Path,$Message){$Temp=$Path+".tmp";$Utf8=[Text.UTF8Encoding]::new($false);try{RemoveBest $Temp "terminal-temp";RemoveBest $Path "terminal-stale";$Clean=($Message -replace "[\r\n]+"," ");if($Clean.Length -gt 2000){$Clean=$Clean.Substring(0,2000)};[IO.File]::WriteAllText($Temp,$Clean,$Utf8);[IO.File]::Move($Temp,$Path)}finally{RemoveBest $Temp "terminal-temp-cleanup"}}
function PublishCopy($Source,$Destination){$Temp=$Destination+".tmp";try{RemoveBest $Temp "precopy-temp";if([IO.File]::Exists($Destination)){throw "Unique publish destination already exists"};[IO.File]::Copy($Source,$Temp,$false);$Expected=[IO.FileInfo]::new($Source).Length;if($Expected -le 0 -or [IO.FileInfo]::new($Temp).Length -ne $Expected){throw "Pre-copy size mismatch"};[IO.File]::Move($Temp,$Destination);if([IO.FileInfo]::new($Destination).Length -ne $Expected){throw "Published copy size mismatch"};return $Destination}finally{RemoveBest $Temp "precopy-temp-cleanup"}}
function WriteClaim($Claim,$Target,$Stage){$Temp=$Claim+".tmp";$Utf8=[Text.UTF8Encoding]::new($false);try{RemoveBest $Temp "claim-temp";RemoveBest $Claim "claim-stale";[IO.File]::WriteAllText($Temp,$Target+[Environment]::NewLine+$Stage,$Utf8);[IO.File]::Move($Temp,$Claim)}finally{RemoveBest $Temp "claim-temp-cleanup"}}
function StopExact($Process){if($null -eq $Process){return $true};try{$Exact=$Process.Handle;$Process.Refresh();if(!$Process.HasExited){$Process.Kill()};if(!$Process.WaitForExit(5000)){Diag("exact-stop-timeout");return $false};return $true}catch{Diag("exact-stop:"+$_.Exception.Message);return $false}}
function StartReady($Path,$TimeoutMs,$Probation,$AllowLauncherExit){$Event=$null;$Process=$null;$ProcessWait=$null;$OldReady=[Environment]::GetEnvironmentVariable("ERGOPTI_UPDATER_BOOT_READY");try{$EventName="Local\ErgoptiPlus.Updater.BootReady."+[Guid]::NewGuid().ToString("N");$Event=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,$EventName);[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_BOOT_READY",$EventName);$Process=Start-Process -FilePath $Path -PassThru -WindowStyle Hidden;$Exact=$Process.Handle;if($AllowLauncherExit){if(!$Event.WaitOne($TimeoutMs)){throw "Canonical driver did not acknowledge recovery handoff"};return $Process};$ProcessWait=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset);$OldSafe=$ProcessWait.SafeWaitHandle;$ProcessWait.SafeWaitHandle=[Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr]$Exact,$false);$OldSafe.Dispose();$Wait=[Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($Event,$ProcessWait),$TimeoutMs);if($Wait -eq 1){throw "Driver exited before boot-ready"};if($Wait -ne 0){throw "Driver boot-ready timeout"};Start-Sleep -Milliseconds $Probation;$Process.Refresh();if($Process.HasExited){throw "Driver exited during post-ready probation"};return $Process}catch{$Failure=$_;if($null -ne $Process -and !(StopExact $Process)){throw "UNSAFE_CHILD:"+$Failure.Exception.Message};throw $Failure}finally{[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_BOOT_READY",$OldReady);if($null -ne $ProcessWait){$ProcessWait.Dispose()};if($null -ne $Event){$Event.Dispose()}}}
try {
  $R=[Threading.EventWaitHandle]::OpenExisting($ReadyName);$C=[Threading.EventWaitHandle]::OpenExisting($CommitName);$A=[Threading.EventWaitHandle]::OpenExisting($AckName);$F=[Threading.EventWaitHandle]::OpenExisting($FinalExitName)
  $P=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset);$H=$P.SafeWaitHandle;$P.SafeWaitHandle=[Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr]$ParentHandle,$true);$H.Dispose()
  if(!$R.Set()){throw "Ready signal failed"};$G=[Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($C,$P));if($G -eq 1){exit 20};if($G -ne 0){throw "Commit wait failed"}
  if(!$A.Set()){throw "Ack signal failed"};$G=[Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($F,$P));if($G -eq 1){exit 21};if($G -ne 0){throw "FinalExit wait failed"};$P.WaitOne()|Out-Null
  $B=$CurrentExe+".bak";$Had=[IO.File]::Exists($CurrentExe);$Retired=(!$Had -and [IO.File]::Exists($B));$Installed=$false;$Token=[Guid]::NewGuid().ToString("N");$Candidate=$CurrentExe+"."+$Token+".candidate.exe";$RecoveryPath=$CurrentExe+"."+$Token+".recovery.exe";$RecoveryStage=$CurrentExe+"."+$Token+".republish.exe";$RecoveryClaim=$RecoveryPath+".claim";$Recovery=$null;$TerminalPath=$DiagnosticPath+".terminal";RemoveBest $TerminalPath "terminal-stale"
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
} catch {$M="SWAP_ERROR:"+$_.Exception.Message;Diag($M);[Console]::Error.WriteLine($M);exit 1}
finally{foreach($W in @($R,$C,$A,$F,$P)){if($null -ne $W){$W.Dispose()}}}

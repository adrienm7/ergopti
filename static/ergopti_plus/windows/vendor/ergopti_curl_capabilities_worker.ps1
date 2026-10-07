# Scratch-only native capability producer. Must run inside an exact owned Job.
# Input contains a remaining budget only; curl sees no URL, credentials or config.
param([Parameter(Mandatory=$true)][string]$InputPath)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$Answer=@{schema_version=1;state='unavailable';backend='curl';child_quiesced=$false}
$WorkerClock=[Diagnostics.Stopwatch]::StartNew()
function Test-ErgoptiCapabilityInt32 {
    param($Value)
    # JSON integer storage may be Int32 or Int64; never coerce other JSON kinds.
    return (($Value -is [int] -or $Value -is [long]) -and
        $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue)
}

try {
    $InputValue=Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not (Test-ErgoptiCapabilityInt32 $InputValue.schema_version) -or $InputValue.schema_version -ne 1 -or -not (Test-ErgoptiCapabilityInt32 $InputValue.budget_ms) -or $InputValue.budget_ms -lt 1){throw 'Private capability request was refused.'}
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
public static class ErgoptiCurlCapabilityProbe
{
    public sealed class Result
    {
        public bool Ok;
        public bool ChildQuiesced;
        public bool Schannel;
        public bool Sspi;
        public bool Spnego;
        public bool Ntlm;
        public string Version="";
        public string FailureOrigin="unavailable";
    }
    private static int Remaining(Stopwatch clock,int budget)
    {
        return Math.Max(0,budget-(int)Math.Min(Int32.MaxValue,clock.ElapsedMilliseconds));
    }
    public static Result Observe(int budgetMs)
    {
        Result answer=new Result(); Process child=null;
        Stopwatch clock=Stopwatch.StartNew();
        try {
            ProcessStartInfo start=new ProcessStartInfo();
            start.FileName=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"curl.exe");
            start.Arguments="--disable --version";
            start.UseShellExecute=false;start.CreateNoWindow=true;
            start.RedirectStandardOutput=true;start.RedirectStandardError=true;
            start.StandardOutputEncoding=Encoding.UTF8;start.StandardErrorEncoding=Encoding.UTF8;
            child=new Process();child.StartInfo=start;
            if(!child.Start()){answer.FailureOrigin="launch";return answer;}
            Task<string> stdout=child.StandardOutput.ReadToEndAsync();
            Task<string> stderr=child.StandardError.ReadToEndAsync();
            if(!child.WaitForExit(Remaining(clock,budgetMs))){answer.FailureOrigin="application_budget";return answer;}
            if(!stdout.Wait(Remaining(clock,budgetMs)) || !stderr.Wait(Remaining(clock,budgetMs))){answer.FailureOrigin="pipe_retirement";return answer;}
            answer.ChildQuiesced=true;
            string output=stdout.Result;
            if(child.ExitCode!=0 || stderr.Result.Length!=0 || output.Length>8192){answer.FailureOrigin="native_output";return answer;}
            string[] lines=output.Replace("\r\n","\n").Split('\n');
            if(lines.Length<2){answer.FailureOrigin="invalid_receipt";return answer;}
            Match header=Regex.Match(lines[0],@"^curl ([0-9]+\.[0-9]+\.[0-9]+)(?:[-A-Za-z0-9.]*) ");
            if(!header.Success){answer.FailureOrigin="invalid_receipt";return answer;}
            answer.Version=header.Groups[1].Value;
            answer.Schannel=Regex.IsMatch(lines[0],@"(?:^|\s)Schannel(?:\s|$)",RegexOptions.IgnoreCase);
            string features=null;
            foreach(string line in lines) {
                if(line.StartsWith("Features: ",StringComparison.Ordinal)) {
                    if(features!=null){answer.FailureOrigin="invalid_receipt";return answer;}
                    features=line.Substring(10);
                }
            }
            if(features==null || !Regex.IsMatch(features,@"^[A-Za-z0-9 -]+$")){answer.FailureOrigin="invalid_receipt";return answer;}
            foreach(string feature in features.Split(new[]{' '},StringSplitOptions.RemoveEmptyEntries)) {
                if(feature=="SSPI")answer.Sspi=true;
                if(feature=="SPNEGO")answer.Spnego=true;
                if(feature=="NTLM")answer.Ntlm=true;
            }
            if(Remaining(clock,budgetMs)==0){answer.FailureOrigin="application_budget";return answer;}
            answer.Ok=true;answer.FailureOrigin="";
        } catch(Exception) {
            // Never emit raw exception text, environment, or native output.
            answer.Ok=false;answer.FailureOrigin="managed_boundary";
        } finally {
            if(child!=null) {
                try {
                    if(!child.HasExited)child.Kill();
                    answer.ChildQuiesced=child.WaitForExit(Remaining(clock,budgetMs));
                } catch(Exception) {answer.ChildQuiesced=false;}
                if(answer.ChildQuiesced)child.Dispose();
                else {answer.Ok=false;answer.FailureOrigin="unacknowledged_cleanup";}
            }
        }
        return answer;
    }
}
'@
    $RemainingBudget=[int]($InputValue.budget_ms-$WorkerClock.ElapsedMilliseconds)
    if($RemainingBudget -le 0){throw 'Capability setup exhausted the original budget.'}
    $Observed=[ErgoptiCurlCapabilityProbe]::Observe($RemainingBudget)
    $Answer.child_quiesced=$Observed.ChildQuiesced
    if($Observed.Ok -and $Observed.ChildQuiesced){
        $Answer.state='ready'
        $Answer.capability=@{tls_backend=$(if($Observed.Schannel){'schannel'}else{'other'});sspi=$Observed.Sspi;spnego=$Observed.Spnego;ntlm=$Observed.Ntlm;version=$Observed.Version}
    }
} catch {
    # Capability is unavailable; never infer unsupported native authentication
    # from an absent receipt or expose managed exception text.
}
[Console]::Out.WriteLine(($Answer | ConvertTo-Json -Compress -Depth 4))
if($Answer.state -cne 'ready'){exit 1}

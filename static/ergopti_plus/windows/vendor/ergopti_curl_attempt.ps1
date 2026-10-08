# vendor/ergopti_curl_attempt.ps1
# Native curl attempt mechanics shared by private request and artifact owners.
# Loading defines a factory only; creating an instance starts no native process.
function New-ErgoptiCurlAttemptEngine {
    param(
        $InputValue,
        [hashtable]$Answer,
        [string]$CapabilityInput,
        [string]$PayloadPath,
        [string]$CurlConfig
    )
    # Each factory call creates a module-local process slot. Public methods
    # expose scalar acknowledgement only, never native cancellation authority.
    $Module = New-Module -AsCustomObject -ArgumentList @(
        $InputValue, $Answer, $CapabilityInput, $PayloadPath, $CurlConfig
    ) -ScriptBlock {
        param($InputValue, $Answer, $CapabilityInput, $PayloadPath, $CurlConfig)
        $script:Child = $null
        $script:Stdout = $null
        $script:Stderr = $null
        function Get-RemainingBudget {
            $Remaining = Get-NativeRemainingBudget
            if ($Remaining -le 0) { throw 'The original request budget expired.' }
            return $Remaining
        }

        function Get-NativeRemainingBudget {
            $Now = [ErgoptiNativeProxyEx]::CurrentTick()
            if ($Now -lt $InputValue.started_tick) { throw 'The native request clock moved backwards.' }
            return [int][Math]::Max(0, $InputValue.deadline_ms - ($Now - $InputValue.started_tick))
        }

        function ConvertTo-CurlLiteral {
            param([string]$Value)
            if ($Value -match '[\x00-\x1f\x7f-\x9f]') { throw 'A private curl scalar was refused.' }
            return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
        }

        function Invoke-OwnedProcess {
            param([string]$Executable, [string]$Arguments, [int]$MaximumOutput)
            if (-not ('ErgoptiBoundedCurlPipe' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public static class ErgoptiBoundedCurlPipe {
    public static Task<string> Read(TextReader reader, int maximum) {
        if(maximum<1) throw new ArgumentOutOfRangeException("maximum");
        return Task.Run(delegate {
            char[] chunk=new char[4096];
            StringBuilder receipt=new StringBuilder(Math.Min(maximum,4096));
            bool overflow=false;
            int count;
            while((count=reader.Read(chunk,0,chunk.Length))!=0) {
                if(count>maximum-receipt.Length) overflow=true;
                if(!overflow) receipt.Append(chunk,0,count);
                // Drain through EOF even after overflow. Memory stays bounded
                // and the exact child's pipes must close before any successor.
            }
            Array.Clear(chunk,0,chunk.Length);
            if(overflow) throw new InvalidDataException("Native pipe receipt exceeded its bound.");
            return receipt.ToString();
        });
    }
}
'@ -ErrorAction Stop
            }
            $Start = [Diagnostics.ProcessStartInfo]::new()
            $Start.FileName = $Executable
            $Start.Arguments = $Arguments
            $Start.UseShellExecute = $false
            $Start.CreateNoWindow = $true
            $Start.RedirectStandardOutput = $true
            $Start.RedirectStandardError = $true
            $Start.StandardOutputEncoding = [Text.Encoding]::UTF8
            $Start.StandardErrorEncoding = [Text.Encoding]::UTF8
            $script:Child = [Diagnostics.Process]::new()
            $script:Child.StartInfo = $Start
            $Result = $null
            try {
                $null = Get-RemainingBudget
                if (-not $script:Child.Start()) { throw 'The owned native child did not start.' }
                $script:Stdout = [ErgoptiBoundedCurlPipe]::Read($script:Child.StandardOutput, $MaximumOutput)
                $script:Stderr = [ErgoptiBoundedCurlPipe]::Read($script:Child.StandardError, 8192)
                if (-not $script:Child.WaitForExit((Get-RemainingBudget))) { throw 'The owned child exhausted its original budget.' }
                if (-not $script:Stdout.Wait((Get-RemainingBudget)) -or -not $script:Stderr.Wait((Get-RemainingBudget))) {
                    throw 'The native pipes did not close within the original budget.'
                }
                if ($script:Stdout.Result.Length -gt $MaximumOutput -or $script:Stderr.Result.Length -gt 8192) {
                    throw 'The native receipt exceeded its bound.'
                }
                $Result = @{ exit = $script:Child.ExitCode; stdout = $script:Stdout.Result;
                    stderr_empty = ($script:Stderr.Result.Length -eq 0); child_quiesced = $true }
            } finally {
                $Retired = $false
                try {
                    if (-not $script:Child.HasExited) { $script:Child.Kill() }
                    $Remaining = Get-NativeRemainingBudget
                    $Retired = $script:Child.WaitForExit($Remaining)
                    foreach ($Pipe in @($script:Stdout, $script:Stderr)) {
                        if ($null -ne $Pipe -and -not $Pipe.IsCompleted) {
                            try { $null = $Pipe.Wait((Get-NativeRemainingBudget)) } catch { }
                            if (-not $Pipe.IsCompleted) { $Retired = $false }
                        }
                    }
                } catch { $Retired = $false }
                if ($Retired) {
                    $script:Child.Dispose()
                    $script:Child = $null
                    $script:Stdout = $null
                    $script:Stderr = $null
                } else {
                    $Answer.child_quiesced = $false
                    throw 'The exact native child has unacknowledged retirement.'
                }
            }
            return $Result
        }

        function Get-OwnedCurlCapability {
            $Request = @{ schema_version = 1; budget_ms = (Get-RemainingBudget) }
            [IO.File]::WriteAllText($CapabilityInput, ($Request | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
            # Inputs contain only the budget; URL, identity, tokens and body never enter argv.
            $Executable = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
            $Args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $InputValue.capability_path +
                '" -InputPath "' + $CapabilityInput + '"'
            $Observed = Invoke-OwnedProcess $Executable $Args 8192
            if ($Observed.exit -ne 0 -or -not $Observed.stderr_empty) { throw 'Native curl capability observation was refused.' }
            $Receipt = $Observed.stdout | ConvertFrom-Json
            if ($Receipt.schema_version -ne 1 -or $Receipt.state -cne 'ready' -or $Receipt.backend -cne 'curl' -or
                $Receipt.child_quiesced -isnot [bool] -or -not $Receipt.child_quiesced -or
                $Receipt.capability.tls_backend -cne 'schannel' -or
                $Receipt.capability.sspi -isnot [bool] -or $Receipt.capability.spnego -isnot [bool] -or
                $Receipt.capability.ntlm -isnot [bool]) {
                throw 'Actual native Schannel capability was not acknowledged.'
            }
            return $Receipt.capability
        }

        function Read-TransportHeaders {
            if (-not [IO.File]::Exists($InputValue.header_path) -or
                ([IO.FileInfo]::new($InputValue.header_path)).Length -gt $InputValue.max_header_bytes) {
                throw 'Native response headers were absent or exceeded their bound.'
            }
            $Blocks = [IO.File]::ReadAllText($InputValue.header_path, [Text.Encoding]::UTF8).Replace("`r`n", "`n").Split(@("`n`n"), [StringSplitOptions]::None)
            $Result = @{ status = 0; headers = @{}; connect_challenges = @() }
            foreach ($Block in $Blocks) {
                $Lines = $Block.Split("`n")
                if ($Lines.Count -eq 0 -or $Lines[0] -notmatch '^HTTP/\S+\s+([0-9]{3})(?:\s|$)') { continue }
                $Status = [int]$Matches[1]
                $Headers = @{}
                $Challenges = @()
                foreach ($Line in $Lines) {
                    $Colon = $Line.IndexOf(':')
                    if ($Colon -lt 1) { continue }
                    $Name = $Line.Substring(0, $Colon).ToLowerInvariant()
                    $Value = $Line.Substring($Colon + 1).Trim()
                    if ($Value -match '[\x00-\x1f\x7f]') { throw 'Native response header syntax was refused.' }
                    $Headers[$Name] = $Value
                    if ($Name -ceq 'proxy-authenticate') { $Challenges += $Value }
                }
                if ($Status -eq 407) { $Result.connect_challenges = @($Challenges) }
                $Result.status = $Status
                $Result.headers = $Headers
            }
            return $Result
        }

        function Invoke-CurlRoute {
            param([Uri]$Destination, $Route, [string]$Authentication, [string]$Method, [bool]$SendBody, [bool]$SendHeaders)
            $Budget = Get-RemainingBudget
            $Lines = @(('url = ' + (ConvertTo-CurlLiteral $Destination.AbsoluteUri)),
                ('request = ' + (ConvertTo-CurlLiteral $Method)), 'silent', 'show-error',
                ('max-time = ' + ($Budget / 1000.0).ToString('F3', [Globalization.CultureInfo]::InvariantCulture)),
                ('connect-timeout = ' + ([Math]::Min($InputValue.connect_timeout_ms, $Budget) / 1000.0).ToString('F3', [Globalization.CultureInfo]::InvariantCulture)),
                ('max-filesize = ' + $InputValue.max_response_bytes),
                ('dump-header = ' + (ConvertTo-CurlLiteral $InputValue.header_path)),
                ('output = ' + (ConvertTo-CurlLiteral $InputValue.response_path)),
                ('write-out = ' + (ConvertTo-CurlLiteral '%{http_code}|%{http_connect}|%{size_download}|%{proxy_used}')),
                ('proxy = ' + (ConvertTo-CurlLiteral $Route.Endpoint)), 'noproxy = ""')
            if ($InputValue.user_agent -is [string] -and $InputValue.user_agent -ne '') {
                $Lines += 'user-agent = ' + (ConvertTo-CurlLiteral $InputValue.user_agent)
            }
            if ($InputValue.revocation_best_effort) { $Lines += 'ssl-revoke-best-effort' }
            if ($Route.Kind -ceq 'proxy') {
                if ($Authentication -cnotin @('negotiate', 'ntlm')) { throw 'The proxy authentication scheme was refused.' }
                $Lines += 'proxy-' + $Authentication
                $Lines += 'proxy-user = ":"'
            }
            if ($SendHeaders) {
                foreach ($Header in $InputValue.headers) {
                    $Lines += 'header = ' + (ConvertTo-CurlLiteral ($Header.name + ': ' + $Header.value))
                }
            }
            if ($SendBody -and $InputValue.body -ne '') {
                $Lines += 'data-binary = ' + (ConvertTo-CurlLiteral ('@' + $PayloadPath))
            }
            [IO.File]::WriteAllText($CurlConfig, ($Lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            # Clear each attempt's private response before the child starts. A preceding
            # child's exact exit and pipes have already been acknowledged by this owner.
            [IO.File]::WriteAllBytes($InputValue.response_path, [byte[]]@())
            [IO.File]::WriteAllBytes($InputValue.header_path, [byte[]]@())
            $Executable = Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
            $Observed = Invoke-OwnedProcess $Executable ('--disable --config "' + $CurlConfig + '"') 1024
            if ($Observed.stdout -notmatch '^([0-9]{3})\|([0-9]{3})\|([0-9]+)\|([01])$') {
                throw 'Native transport metrics were absent or malformed.'
            }
            $Metrics = @{ exit = $Observed.exit; status = [int]$Matches[1]; connect = [int]$Matches[2];
                delivered = [int64]$Matches[3]; proxy_used = ($Matches[4] -ceq '1'); child_quiesced = $Observed.child_quiesced }
            if (([IO.FileInfo]::new($InputValue.response_path)).Length -ne $Metrics.delivered -or
                $Metrics.delivered -gt $InputValue.max_response_bytes) { throw 'Native response byte accounting was refused.' }
            $Metrics.headers = Read-TransportHeaders
            return $Metrics
        }

        function Test-CausalNtlmChallenge {
            param([Uri]$Destination, $Route, $Metrics, $Capability)
            if ($Destination.Scheme -cne 'https' -or $Route.Kind -cne 'proxy' -or
                $Metrics.child_quiesced -isnot [bool] -or -not $Metrics.child_quiesced -or
                $Metrics.proxy_used -isnot [bool] -or -not $Metrics.proxy_used -or
                $Metrics.connect -ne 407 -or $Metrics.status -ne 0 -or $Metrics.delivered -ne 0 -or
                $Capability.ntlm -isnot [bool] -or -not $Capability.ntlm) { return $false }
            $Ntlm = $false
            foreach ($Challenge in $Metrics.headers.connect_challenges) {
                # Parse the bounded actual CONNECT response, not an origin401 or a
                # guessed proxy target. No token or identity is retained in the receipt.
                if ($Challenge -cmatch '^(?i:NTLM)(?: [A-Za-z0-9+/]+={0,2})?$') { $Ntlm = $true; continue }
                if ($Challenge -match '^Negotiate(?:\s|$)') { return $false }
                if ($Challenge -match '^(Basic|Digest)(?:\s|$)') { continue }
                return $false
            }
            return $Ntlm
        }

        function GetRemainingBudget { return (Get-RemainingBudget) }
        function GetNativeRemainingBudget { return (Get-NativeRemainingBudget) }
        function ObserveCapability { return (Get-OwnedCurlCapability) }
        function InvokeRoute {
            param([Uri]$Destination, $Route, [string]$Authentication,
                [string]$Method, [bool]$SendBody, [bool]$SendHeaders)
            return (Invoke-CurlRoute $Destination $Route $Authentication $Method $SendBody $SendHeaders)
        }
        function TestNtlmChallenge {
            param([Uri]$Destination, $Route, $Metrics, $Capability)
            return (Test-CausalNtlmChallenge $Destination $Route $Metrics $Capability)
        }
        function ChildQuiesced { return ($null -eq $script:Child -and $null -eq $script:Stdout -and $null -eq $script:Stderr) }
        Export-ModuleMember -Function GetRemainingBudget, GetNativeRemainingBudget,
            ObserveCapability, InvokeRoute, TestNtlmChallenge, ChildQuiesced
    }
    return $Module
}

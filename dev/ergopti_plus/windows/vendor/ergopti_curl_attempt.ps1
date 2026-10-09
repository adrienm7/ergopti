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
        $script:Discovery = $null
        $script:DiscoveryIssued = [Collections.Hashtable]::new([StringComparer]::Ordinal)
        $script:DiscoveryPairs = [Collections.Hashtable]::new([StringComparer]::Ordinal)
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
            param([Uri]$Destination, $Route, [string]$Authentication, [string]$Method, [bool]$SendBody, [bool]$SendHeaders, [bool]$DiscoveryAdmitted = $false)
            $Pair = $Destination.AbsoluteUri + "`n" + $Route.Endpoint
            if (-not $DiscoveryAdmitted -and $script:DiscoveryPairs.ContainsKey($Pair)) {
                throw 'A discovered pair cannot start a legacy or third transport.'
            }
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
                if ($Authentication -cnotin @('negotiate', 'ntlm') -and
                    -not ($DiscoveryAdmitted -and $Authentication -ceq 'none')) {
                    throw 'The proxy authentication scheme was refused.'
                }
                if ($Authentication -cne 'none') {
                    $Lines += 'proxy-' + $Authentication
                    $Lines += 'proxy-user = ":"'
                }
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


        function Get-SelectionWitness {
            param($Selection)
            if ($null -eq $Selection -or $Selection.Ok -isnot [bool] -or -not $Selection.Ok -or
                $Selection.CleanupDebt -eq $true -or
                ($null -ne $Selection.CleanupDebt -and $Selection.CleanupDebt -isnot [bool]) -or $Selection.Routes -isnot [array] -or
                ($Selection.MaxRoutes -isnot [int] -and $Selection.MaxRoutes -isnot [long]) -or $Selection.MaxRoutes -lt 1 -or $Selection.MaxRoutes -gt [int]::MaxValue -or
                ($Selection.MaxRedirects -isnot [int] -and $Selection.MaxRedirects -isnot [long]) -or $Selection.MaxRedirects -lt 0 -or $Selection.MaxRedirects -gt [int]::MaxValue -or
                $Selection.Routes.Count -lt 1 -or $Selection.Routes.Count -gt $Selection.MaxRoutes) {
                throw 'Fresh canonical route retirement or bounds were refused.'
            }
            $Routes = @()
            foreach ($Item in $Selection.Routes) {
                if ($Item.Kind -cnotin @('direct', 'proxy') -or $Item.Endpoint -isnot [string] -or
                    ($Item.Kind -ceq 'direct' -and ($Item.Endpoint -cne '' -or $Item.Authentication -cne 'none')) -or
                    ($Item.Kind -ceq 'proxy' -and $Item.Authentication -cne 'current_user_proxy_only')) {
                    throw 'Fresh canonical route semantics were refused.'
                }
                $Routes += [ordered]@{ kind = $Item.Kind; endpoint = $Item.Endpoint; authentication = $Item.Authentication }
            }
            return ([ordered]@{ routes = $Routes; max_routes = $Selection.MaxRoutes;
                max_redirects = $Selection.MaxRedirects } | ConvertTo-Json -Compress -Depth 5)
        }

        function Invoke-AnonymousProxyDiscovery {
            param([Uri]$Destination, $Route, $Capability, $Selection, [int]$Ordinal = 0)
            if ($null -ne $script:Discovery -or -not (ChildQuiesced) -or
                $Destination.Scheme -cne 'https' -or $Destination.UserInfo -ne '' -or
                $Route.Kind -cne 'proxy' -or $Route.Authentication -cne 'current_user_proxy_only' -or
                $Route.Endpoint -isnot [string] -or
                $Capability.sspi -isnot [bool] -or -not $Capability.sspi -or
                $Capability.spnego -isnot [bool] -or -not $Capability.spnego -or
                [version]$Capability.version -lt [version]'8.7.0') {
                throw 'Anonymous proxy discovery admission was refused.'
            }
            [Uri]$Relay = $null
            if (-not [Uri]::TryCreate($Route.Endpoint, [UriKind]::Absolute, [ref]$Relay) -or
                $Relay.Scheme -cne 'http' -or $Relay.UserInfo -ne '' -or $Relay.Host -eq '' -or
                $Relay.Port -lt 1 -or $Relay.Port -gt 65535 -or $Relay.Query -ne '' -or
                $Relay.Fragment -ne '' -or $Relay.AbsolutePath -ne '/' -or
                $Relay.AbsoluteUri -cne $Route.Endpoint) { throw 'The exact discovery relay was refused.' }
            $Pair = $Destination.AbsoluteUri + "`n" + $Route.Endpoint
            $Key = $Pair + "`n" + $Ordinal
            if ($script:DiscoveryIssued.ContainsKey($Key)) { throw 'A discovery ordinal is single use.' }
            $Witness = Get-SelectionWitness $Selection
            if ($Ordinal -lt 0 -or $Ordinal -ge $Selection.Routes.Count) { throw 'The canonical discovery ordinal was refused.' }
            $Indexed = $Selection.Routes[$Ordinal]
            if ($Indexed.Kind -cne $Route.Kind -or $Indexed.Endpoint -cne $Route.Endpoint -or
                $Indexed.Authentication -cne $Route.Authentication) { throw 'The exact discovery ordinal disagrees.' }
            $HostName = $Destination.IdnHost.Trim('[', ']')
            if ($HostName.Contains(':')) { $HostName = '[' + $HostName + ']' }
            $Authority = $HostName + ':' + $Destination.Port
            $Descriptor = @{ version = 1; kind = 'anonymous_connect_only';
                original_url = $Destination.AbsoluteUri; relay = $Route.Endpoint; authority = $Authority }
            $Budget = Get-RemainingBudget
            # This URI constructs an HTTP proxy CONNECT frame; it is not a new
            # destination or redirect. HEAD stops after its headers even on 200.
            # Only the selected transport later receives the original HTTPS URL,
            # caller method, headers and body. No credential option enters this phase.
            $Lines = @(('url = ' + (ConvertTo-CurlLiteral ('http://' + $Authority + '/'))),
                'head', 'no-include', 'http1.1', 'no-location', 'request = "CONNECT"',
                ('request-target = ' + (ConvertTo-CurlLiteral $Descriptor.authority)),
                'silent', 'show-error',
                ('max-time = ' + ($Budget / 1000.0).ToString('F3', [Globalization.CultureInfo]::InvariantCulture)),
                ('connect-timeout = ' + ([Math]::Min($InputValue.connect_timeout_ms, $Budget) / 1000.0).ToString('F3', [Globalization.CultureInfo]::InvariantCulture)),
                'dump-header = "-"',
                ('output = ' + (ConvertTo-CurlLiteral $InputValue.response_path)),
                ('write-out = ' + (ConvertTo-CurlLiteral '%{http_code}|%{http_connect}|%{size_download}|%{proxy_used}')),
                ('proxy = ' + (ConvertTo-CurlLiteral $Descriptor.relay)), 'noproxy = ""')
            [IO.File]::WriteAllText($CurlConfig, ($Lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllBytes($InputValue.response_path, [byte[]]@())
            [IO.File]::WriteAllBytes($InputValue.header_path, [byte[]]@())
            $Executable = Join-Path ([Environment]::GetFolderPath('System')) 'curl.exe'
            $script:DiscoveryIssued[$Key] = $true
            $script:DiscoveryPairs[$Pair] = $true
            $Observed = Invoke-OwnedProcess $Executable ('--disable --config "' + $CurlConfig + '"') ($InputValue.max_header_bytes + 1024)
            if (-not $Observed.child_quiesced -or -not (ChildQuiesced) -or
                ([IO.FileInfo]::new($InputValue.response_path)).Length -ne 0) {
                throw 'Anonymous discovery has unresolved output or retirement.'
            }
            $HeaderEnd = $Observed.stdout.IndexOf("`r`n`r`n")
            $RawHeaders = ''
            $MetricText = $Observed.stdout
            if ($HeaderEnd -ge 0) {
                $RawHeaders = $Observed.stdout.Substring(0, $HeaderEnd + 4)
                $MetricText = $Observed.stdout.Substring($HeaderEnd + 4)
            }
            if ($MetricText -cnotmatch '^([0-9]{3})\|([0-9]{3})\|([0-9]+)\|([01])$') {
                throw 'Anonymous discovery metrics were malformed.'
            }
            $Metrics = @{ exit = $Observed.exit; status = [int]$Matches[1]; connect = [int]$Matches[2];
                delivered = [int64]$Matches[3]; proxy_used = ($Matches[4] -ceq '1');
                child_quiesced = $Observed.child_quiesced;
                headers = @{ status = 0; headers = @{}; connect_challenges = @() } }
            if ($Metrics.connect -ne 0 -or $Metrics.delivered -ne 0 -or -not $Metrics.proxy_used) {
                throw 'Discovery cannot claim an ordinary tunnel or transfer.'
            }
            # Preserve literal actual curl5/7 and zero statuses for canonical
            # route failover. Never translate discovery407 into tunnel407.
            if ($RawHeaders -ceq '' -and $Metrics.status -eq 0 -and $Metrics.exit -in @(5, 7)) {
                return @{ ready = $false; metrics = $Metrics }
            }
            if ($Metrics.exit -ne 0 -or -not $Observed.stderr_empty -or $RawHeaders.Length -gt $InputValue.max_header_bytes -or
                $RawHeaders -match '[^\x09\x0a\x0d\x20-\x7e]') { throw 'Discovery header admission was refused.' }
            $HeaderLines = $RawHeaders.Substring(0, $RawHeaders.Length - 4).Split(@("`r`n"), [StringSplitOptions]::None)
            if ($HeaderLines[0] -cnotmatch '^HTTP/1\.[01] ([0-9]{3})(?: [\x20-\x7e]*)?$' -or
                [int]$Matches[1] -ne $Metrics.status -or $Metrics.status -notin @(200, 407)) {
                throw 'Discovery status and literal receipt disagree.'
            }
            $Challenges = @()
            for ($HeaderIndex = 1; $HeaderIndex -lt $HeaderLines.Length; $HeaderIndex++) {
                if (($HeaderIndex % 128) -eq 0) { $null = Get-RemainingBudget }
                $Line = $HeaderLines[$HeaderIndex]
                if ($Line -cnotmatch '^([!#$%&''*+.^_`|~0-9A-Za-z-]+):([\x09\x20-\x7e]*)$') {
                    throw 'Discovery header syntax was refused.'
                }
                if ($Matches[1].ToLowerInvariant() -ceq 'proxy-authenticate') { $Challenges += $Matches[2].Trim() }
            }
            $Authentication = 'none'
            if ($Metrics.status -eq 200) {
                if ($Challenges.Count -ne 0) { throw 'Unsolicited discovery credentials were refused.' }
            } else {
                if ($Challenges.Count -eq 0) { throw 'A bare proxy challenge was required.' }
                $HasNegotiate = $false
                $HasNtlm = $false
                $IgnoredParameter = '^[!#$%&''*+.^_`|~0-9A-Za-z-]+[\x09\x20]*=[\x09\x20]*(?:[!#$%&''*+.^_`|~0-9A-Za-z-]+|"(?:\\[\x09\x20-\x7e]|[^"\\\x00-\x08\x0a-\x1f\x7f])*")$'
                foreach ($HeaderChallenge in $Challenges) {
                    # Split bounded HTTP challenge members without treating a
                    # comma inside a quoted Basic/Digest parameter as a scheme.
                    # These known unselected offers cannot mint credentials.
                    $Parts = [Collections.Generic.List[string]]::new()
                    $Start = 0
                    $Quoted = $false
                    $Escaped = $false
                    for ($Index = 0; $Index -lt $HeaderChallenge.Length; $Index++) {
                        if (($Index % 1024) -eq 0) { $null = Get-RemainingBudget }
                        $Character = $HeaderChallenge[$Index]
                        if ($Escaped) { $Escaped = $false; continue }
                        if ($Quoted -and $Character -ceq '\') { $Escaped = $true; continue }
                        if ($Character -ceq '"') { $Quoted = -not $Quoted; continue }
                        if (-not $Quoted -and $Character -ceq ',') {
                            $Parts.Add($HeaderChallenge.Substring($Start, $Index - $Start).Trim())
                            $Start = $Index + 1
                        }
                    }
                    if ($Quoted -or $Escaped) { throw 'An unterminated proxy challenge was refused.' }
                    $Parts.Add($HeaderChallenge.Substring($Start).Trim())
                    $IgnoringKnown = $false
                    foreach ($Challenge in $Parts) {
                        if ($Challenge -imatch '^Negotiate$') { $HasNegotiate = $true; $IgnoringKnown = $false }
                        elseif ($Challenge -imatch '^NTLM$') { $HasNtlm = $true; $IgnoringKnown = $false }
                        elseif ($Challenge -match '^(?i:Basic|Digest)(?:[\x09\x20]+(.*))?$') {
                            $IgnoringKnown = $true
                            $Parameter = $Matches[1]
                            if ($null -ne $Parameter -and $Parameter -ne '' -and $Parameter -cnotmatch $IgnoredParameter) {
                                throw 'An unselected known challenge parameter was malformed.'
                            }
                        }
                        elseif ($IgnoringKnown -and $Challenge -cmatch $IgnoredParameter) { continue }
                        else { throw 'A foreign or unsolicited challenge was refused.' }
                    }
                }
                if ($HasNegotiate) { $Authentication = 'negotiate' }
                elseif ($HasNtlm -and $Capability.ntlm -is [bool] -and $Capability.ntlm) { $Authentication = 'ntlm' }
                else { throw 'The observed proxy authentication feature is unavailable.' }
            }
            $null = Get-RemainingBudget
            $script:Discovery = @{ descriptor = $Descriptor; authentication = $Authentication; witness = $Witness; ordinal = $Ordinal }
            return @{ ready = $true; metrics = $Metrics; authentication = $Authentication }
        }

        function InvokeDiscoveredRoute {
            param([Uri]$Destination, $Route, [string]$Method, [bool]$SendBody, [bool]$SendHeaders, $FreshSelection)
            $Lease = $script:Discovery
            # Consume before any successor work. Discovery plus this one selected
            # transport is finite; an advertised Negotiate never becomes NTLM.
            $script:Discovery = $null
            if ($null -eq $Lease -or -not (ChildQuiesced) -or
                $Lease.descriptor.original_url -cne $Destination.AbsoluteUri -or
                $Lease.descriptor.relay -cne $Route.Endpoint -or $Route.Kind -cne 'proxy' -or
                $Route.Authentication -cne 'current_user_proxy_only') {
                throw 'The exact discovered route was not requalified.'
            }
            if ((Get-SelectionWitness $FreshSelection) -cne $Lease.witness) {
                throw 'The canonical full-URL route list changed after anonymous discovery.'
            }
            if ($Lease.ordinal -ge $FreshSelection.Routes.Count -or
                $FreshSelection.Routes[$Lease.ordinal].Kind -cne $Route.Kind -or
                $FreshSelection.Routes[$Lease.ordinal].Endpoint -cne $Route.Endpoint -or
                $FreshSelection.Routes[$Lease.ordinal].Authentication -cne $Route.Authentication) {
                throw 'The fresh selected ordinal was refused.'
            }
            $null = Get-RemainingBudget
            return (Invoke-CurlRoute $Destination $Route $Lease.authentication $Method $SendBody $SendHeaders $true)
        }

        function DiscoverProxy {
            param([Uri]$Destination, $Route, $Capability, $Selection, [int]$Ordinal = 0)
            return (Invoke-AnonymousProxyDiscovery $Destination $Route $Capability $Selection $Ordinal)
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
            ObserveCapability, InvokeRoute, TestNtlmChallenge, ChildQuiesced, DiscoverProxy, InvokeDiscoveredRoute
    }
    return $Module
}

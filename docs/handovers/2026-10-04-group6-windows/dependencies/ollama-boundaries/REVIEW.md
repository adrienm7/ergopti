<!-- Read-only audit; no child-runtime or updater implementation is integrated. -->

# Remaining Windows enterprise-network paths

Source inspection is based on ErgoptiPlus HEAD `b88d2c9689c5b7f05f8345e62ce642c782390e8d`
and local origin/dev `689d30293`; the coordinator owns subsequent fetch/merge. No repository
edit, staging, commit, push or native test was performed for this remaining-path audit.

## Actual owners and call paths

`windows/modules/llm/ollama_deps_checker.ahk:335` starts live winget installation via
ShellRunner_SpawnTreeOwned. Its last false argument disables output capture, not Job
ownership. The installer has a retained exact task and cancel/shutdown path. It passes
no network admission or private child-environment policy. The browser-download fallback
uses the native browser; it does not prove winget or Ollama networking. Existing polling
can observe a borrowed daemon becoming reachable without proving installation provenance,
binary version, network environment or owned-server identity.

There is no live Windows owned `ollama serve` start seam in this checkout. The old shared
`install/ollama_install.ps1` is not the live installer and must not be repaired as evidence.
`windows/ui/menu/menu_llm/menu_models.ahk:579` runs visible persistent `cmd.exe /k` with
OLLAMA_HOST and `ollama pull`. That CLI contacts an already running server. Registry/model
network requests are made by that server, not by the CLI, so setting proxy variables on
the CLI cannot retrofit the daemon's process environment, proxy auth or trust behavior.
The existing pull is not Job-owned and a delayed menu rebuild is not a pull-success receipt.

The AI group's `origin/feat/ai` discovery module is logical discovery/cache/ticket state.
It accepts injected native owners; invalidation is not physical server retirement.
Implementing owned runtime install/serve overlaps TODO48 and requires group-4 coordination.
Borrowed daemons must remain untouched and be labelled as externally managed.

Updater installation and previous-version installation use the same live
`windows/modules/updater/self_update.ahk` staging worker (1749+, script builder2123+).
The worker uses HttpWebRequest, default automatic redirects, default OS/.NET trust,
size/minimum/declared-length/digest checks and a final READY receipt. Local recovery swap
is filesystem rollback, not another network download. The bootstrap carries private
source data through uniquely named inherited environment variables, not argv, and clears
the parent's copy after launch. The worker is retained by the existing exact Job/epoch owner.
Its current ERR:exception-text result is not a typed network receipt and may reveal URLs.
Release-metadata requests use legacy permissive SystemProxy_ForUrl; they are another
unqualified network surface, distinct from remote-AI strict admission.

## Authoritative Ollama and Go boundaries

Official Ollama source pin: `42e911bc3d05798cad729cb474bf62f378cb2e26`.
Its go.mod selects Go1.26.0; the corresponding official Go tag resolves to
`d90b98e65320778f3b1f99a6951ab20f04d218b3`.
These are inspected source versions, not a claim about any installed winget binary.

- Ollama docs/faq.mdx129–135 documents HTTPS_PROXY and installation of the proxy CA
  into the system certificate store. It warns that HTTP_PROXY may disrupt local CLI/API
  connections. envconfig/config.go344+ lists inherited proxy variables.
- api/client.go ClientFromEnvironment uses OLLAMA_HOST and http.DefaultClient to contact
  the server. server/images.go1473 uses default transport for registry calls. The model
  download server, not the pull CLI, owns registry/CDN requests.
- Current transfer/redirect.go148–191 creates a custom http.Transport without a Proxy
  field for redirected download URLs. Thus even documented HTTPS_PROXY does not prove
  every redirected artifact download follows that proxy in this unpinned implementation.
  A supported version must be selected and tested; do not assert full static-proxy pull
  support from the documentation alone.
- Go net/http/transport.go47 and491–509 applies ProxyFromEnvironment to the default
  transport, reading HTTP_PROXY/HTTPS_PROXY/NO_PROXY. It does not read WinINet static
  settings, execute PAC or discover WPAD. net/http/transport.go994–1007 generates Basic
  Proxy-Authorization from explicit URL userinfo; it does not supply Windows SSPI
  current-user integrated proxy authentication automatically.
- Ollama server/routes.go2117 logs envconfig.Values() at INFO startup.
  envconfig/config.go344–346 and369–373 includes raw proxy environment values without
  URL-userinfo redaction. A private child environment alone does not stop upstream
  proxy-credential logging. Credential-bearing proxy URLs must be unavailable for
  app-owned launch unless an actual installed version has verified safe handling.
- Go crypto/x509/root_windows.go248–251 verifies through native
  CertGetCertificateChain(handle0), using Windows system chain trust when custom roots
  are absent. SSL_CERT_FILE/SSL_CERT_DIR handling is in root_unix.go, not Windows.
  A generic CA-file environment override must therefore not be advertised as Windows
  Ollama system-trust configuration without actual Ollama-version implementation proof.

Immutable source links:
https://github.com/ollama/ollama/blob/42e911bc3d05798cad729cb474bf62f378cb2e26/docs/faq.mdx
https://github.com/ollama/ollama/blob/42e911bc3d05798cad729cb474bf62f378cb2e26/transfer/redirect.go
https://github.com/golang/go/blob/d90b98e65320778f3b1f99a6951ab20f04d218b3/src/net/http/transport.go
https://github.com/golang/go/blob/d90b98e65320778f3b1f99a6951ab20f04d218b3/src/crypto/x509/root_windows.go

## Smallest sound updater tranche

Factor the existing documented WinHTTP resolver implementation into one canonical native
helper usable by the resolver worker and staging worker. Do not duplicate a .NET
GetSystemWebProxy result as strict PAC admission: it can silently project failure to DIRECT.
The ownership seam must return an observed typed failure or an admitted route for each
exact destination, including every redirect, under the existing global staging deadline.

On admitted DIRECT set HttpWebRequest.Proxy=null explicitly. On an admitted named HTTP
relay set a WebProxy with CredentialCache.DefaultNetworkCredentials on that proxy only.
Keep Request.UseDefaultCredentials=false, avoiding current-user identity disclosure to an
origin401. Disable automatic redirects and perform each next-hop resolution explicitly;
never forward source Authorization or credentials to an unapproved authority. Preserve
TLS validation with Windows/.NET default trust, minsize/length/SHA checks and READY.
A selected proxy does not prove proxy-auth target. WebException.Response407 establishes
an HTTP407 response only, with unknown source unless a native target receipt says otherwise.
TrustFailure is observed TLS trust failure; SecureChannelFailure alone remains unknown.
Split Input.Read and Output.Write to preserve actual local-write HResults rather than
calling every CopyTo exception a network failure.

The shared_failure62 agent owns the pure shared failure interpreter and Mac diagnostic/action
draft. It has authored no Windows staging worker changes. The coordinator must assign the
exact Windows staging receipt seam. Canonical resolver extraction touches the already
integrated HTTP worker and must be serialized with its native validation/failover follow-up.

## Owned Ollama route and honest unavailable capabilities

An owned new Go server can receive credential-free explicit static HTTPS_PROXY/NO_PROXY in a
private per-child environment, after actual installed-version pull/redirect qualification.
A current-user/system CA installed by the network administrator can supply native Windows
trust. The app should neither import enterprise roots on its own nor disable TLS validation.
Do not put proxy credentials in command lines, terminal text, diagnostics or persistent
plain-text config. Safe storage/transport of explicit proxy credentials needs a separate
credential-owner design; OS credentials do not automatically become Go SSPI credentials.

`api_ollama/curl_environment.ahk` already constructs private UTF16 child-environment blocks
without mutating parent state. ShellRunner_SpawnTreeOwned has no environment option;
PLC_CreateProcessWithInheritedHandles308 hardcodes lpEnvironment0. A coordinated native
owner enhancement would pass a private Unicode block plus CREATE_UNICODE_ENVIRONMENT,
retain it until CreateProcessW returns, preserve hidden drive variables and exact Job
assignment/cancel fences. It must not race global EnvSet around process launch.
These adapter files overlap Windows-native ownership and should not be edited independently.

A local generic CONNECT broker cannot reproduce exact per-URL PAC for HTTPS Ollama pulls:
CONNECT exposes host:port while the encrypted request conceals path/query. TLS interception
would require replacing trust semantics and is outside scope. A fixed relay produced from
one registry URL cannot cover registry/CDN/auth endpoints or PAC failover. Native PAC/WPAD
and integrated-auth capabilities must therefore be honestly unavailable for this Go child
until its transport supports them, with a working configure-system/static-proxy action,
externally-managed-server action, or refusal. Do not label a borrowed daemon as configured.

Required real Windows acceptance before declaring any child surface complete:
owned installer success/failure and cancel/descendant settlement; owned serve identity and
private environment receipt; actual server-side pull including redirected artifact/auth URL;
trusted/untrusted system CA and target-host verification; nonproxy origin401 versus proxy407;
static relay, exact per-URL PAC, WPAD absence versus configured-PAC error, ordered failover,
redirect admission and total-budget/cancellation; digest/malformed package/no-space refusals;
update and previous-version installation READY/install/launch/rollback receipts; no release.
These native results are not run here. TODO62 remains partial.

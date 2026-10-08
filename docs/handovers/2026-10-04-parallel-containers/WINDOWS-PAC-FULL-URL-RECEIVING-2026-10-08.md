<!-- docs/handovers/2026-10-04-parallel-containers/WINDOWS-PAC-FULL-URL-RECEIVING-2026-10-08.md -->

# Windows HTTPS PAC capability receiving

TODO62 and the complete release qualification remain open. The integrated
source `091743921` cannot yet qualify its full-URL HTTPS PAC promise.

## Actual receiving

The original managed-route fixture returns a failed three-route assertion.
An independently copied fixture changes only the synthetic PAC output to four
fixed classification descriptors; all original assertions, the 9000 ms lookup
budget and the 3500 ms server-retirement bound remain unchanged.

The actual Windows WinHTTP Ex evaluation returns this closed observation:

```text
PAC_URL_CLASS observed=1 class=path_stripped
```

The marker comes from an actual returned PAC proxy entry. It is not inferred
from a direct bypass or from passing a complete URL into the application API.
The observed call completes in 886 ms, with 8255 ms remaining at native admission.
It returns one marker proxy instead of the three original ordered routes.
The fixture exits naturally with status 1 after its original cleanup. No global
proxy setting, driver configuration or resident process is changed.

Receiving files remain outside the product checkout:

- `D:/ErgoptiAuditWorkspace/release-native-route-JHyKkA/receipt.json`
- `D:/ErgoptiAuditWorkspace/pac-url-shape-433af094005d452493a33208247960ba/`

The synthetic fixture SHA256 is
`0dc10eb41885bc08689b438db29374f6814c3ca7223efaba4a57c33fd3d5348c`.
It logs only the closed classification, never the evaluated URL.

## Repair constraints

The current native helper passes the unchanged URL to WinHTTP Ex; this does
not establish that the PAC receives the same URL. No documented preservation
option was found in the reviewed Microsoft SDK header or Ex API contract.

Do not change HTTPS to HTTP, weaken the full-path golden, accept a direct
fallback, increase deadlines or claim full-URL success from application input.
Microsoft explicitly marks the legacy WinINet InternetGetProxyInfo API as
unsupported on Windows 11. WebProxy.GetProxy exposes a single proxy, which
does not establish the complete ordered PAC list.

A replacement needs a supported owned evaluator, the unchanged HTTPS URL,
bounded execution and memory, the complete ordered result and acknowledged
cleanup. PAC retrieval, source/settings identity, trust, authentication, DNS
helpers and WPAD discovery need their own receiving; a JavaScript-only proof
does not complete these responsibilities.

Retain the original three-route fixture and require a new actual observation
of `class=full`, different routes for two HTTPS paths on one origin, middle
DIRECT ordering, fresh script bytes and all original refusal controls.
Linux and macOS need equivalent receiving before claiming cross-driver parity.

## Isolated prototype progress

The second prototype records 61 passing native controls, including causal
Unicode, buffer-boundary, getter-exception and stale-output regressions,
DNS cancellation and retained Job retirement. Its separate retirement grace
does not qualify the product's complete 9000 ms parent budget.

The third prototype records one complete private HTTP acquisition and frozen
script lease, full HTTPS input, three ordered routes with middle DIRECT,
zero-capability AppContainer evaluation and acknowledged retirement in 360 ms.
This is a primitive observation, not integrated driver qualification. TLS,
credential admission, source/settings changes, socket/file refusal controls,
WPAD and cross-driver receiving remain open.

The immutable evidence remains outside the repository:

- `D:/ErgoptiAuditWorkspace/pac-duktape-phase2-5b400111e4ff4b849e435bf115d77760/phase2-manifest.json`
- `C:/ErgoptiAuditWorkspace/pac-duktape-phase3-153433d052734e03adf3892a470f4bef/evidence/first-chain.json`

## Primary references

- [WinHTTP Ex API](https://learn.microsoft.com/en-us/windows/win32/api/winhttp/nf-winhttp-winhttpgetproxyforurlex)
- [Microsoft WinHTTP SDK header](https://raw.githubusercontent.com/microsoft/win32metadata/main/generation/WinSDK/RecompiledIdlHeaders/um/winhttp.h)
- [InternetGetProxyInfo support restriction](https://learn.microsoft.com/en-us/windows/win32/wininet/internetgetproxyinfo)
- [WebProxy.GetProxy result contract](https://learn.microsoft.com/en-us/dotnet/api/system.net.webproxy.getproxy)

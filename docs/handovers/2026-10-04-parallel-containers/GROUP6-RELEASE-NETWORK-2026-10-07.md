<!-- docs/handovers/2026-10-04-parallel-containers/GROUP6-RELEASE-NETWORK-2026-10-07.md -->

# Group 6 partial release and managed-network delivery

Only TODO36 and62 belong to this delivery. Both remain open; no item has been
removed. Transversal16/38 keep their independent validation requirements.
Differential updates22 remain deliberately outside scope. The maintainer
authorized partial integration after available container/CI work, followed by
device validation and any necessary fixes.

## Delivered source slices

Source-install checkpoint,2026-10-08: Linux manual37714714116 at9d26b947e
passes11,644 unit assertions, all157 E2E steps and the complete package job,
including genuine Flatpak build/install/launch. Three binary installation
variants pass. The14 failing source variants have distinct closed observations:
five lack a compiler under--no-deps; seven first-install checkouts omit the
canonical builder; two Fedora variants stop earlier at the declared unavailable
LuaJIT networking provider. The compiler/header catalogue projection repairs
source-install prerequisites without adding a compiler to binary runtime
requirements or removing any native assertion. The first-install fixture copies
only the canonical builder closure. Its shared catalogue/generator region is
owned by group6; unrelated data, workflow steps and locale files remain exact.
Local causal regression is red on the original catalogue; corrected format,
all382 JavaScript checks and portable/native producer controls pass. The first
CI guard replay exposed an incorrectly anchored fixture slice; that harness
error was corrected before receiving and is not credited as product evidence.
All manually dispatched final-source native gates remain pending for this repair.

The subsequent Fedora bootstrap is source-only until final receiving. It uses
the unchanged Flatpak luv source26e62e49b0230891ece45a78cc1f63c074e60020 and
the same six CMake choices. Shared policy declares build/GIO/schema prerequisites
without inventing a distribution LuaJIT module package. The native producer
checks the exact fetched revision, Git objects and actual LuaJIT C entry points;
its output is atomically installed inlinux/native_modules, hashed into the
ownership manifest and selected by the matching standalone launcher. Existing
unchanged native-module ownership survives subsequent installs. The first-run
fixture now also checks the installed native networking probe, preserving every
previous launcher, runtime, tray and declared-limitation assertion.

Real host compilation and actual native loading pass through a physically
closed owner. The final producer also passes with deliberately foreign inherited
GIT_DIR/GIT_INDEX_FILE values; the helper clears only its child repository
namespace. One initial negative replay had incorrectly assembled positional
arguments; its retained refusal is a harness error, not product evidence.
The complete pre-existing Flatpak module projection stays byte-exact. The
causal bootstrap policy guard fails before the new map;26 recipe/filesystem
control groups pass afterwards. Full selected gates and hosted Fedora package
manager/installation qualification remain pending at this checkpoint.

Manual37747891785 atb4ef975f1561c67603dc0679c44be1d57f171eea is terminal
FAIL: all shared/unit/E2E checks and the complete package job pass;13 of17
installation variants pass, four fail, none are skipped. Release is skipped.
The two Fedora rows retain their known unavailable LuaJIT provider refusal.
Both Alpine rows now reach compilation and expose missinglinux/magic.h;
musl-dev does not supply the kernel UAPI headers. The additionallinux-headers
source prerequisite is projected from the shared catalogue and supplied by the
no-deps CI caller. The causal independent catalogue regression is red before
this correction. No compiler/runtime assertion or installation row is removed.

- macOS archive migration, Sparkle resource/key/refusal receiving and bounded
  native lifecycle diagnostics. Historical native Sparkle acceptance passed;
  complete Brew/package/install acceptance remains incomplete.
- Linux per-hop managed HTTP, native output/temporary-file ownership, retained
  SHA256/archive publication, installed runtime declarations and endpoint-owned
  updater ETags. Real receiving covers curl7/8 and LuaJIT/Lua5.4; it preserves
  authentication, integrity, original clocks and physical closure.
- macOS opaque HF/Ollama owners refuse verified unsupported PAC/WPAD/SOCKS
  routes. Supported explicit routes, cached startup and lower-case environment
  precedence remain. Shared classification reuses the existing21 translations.
- Windows native full-URL routing, bounded owned curl, updater/failure actions
  and atomic observer publication/rollback. The current artifact downloader
  still has a bare NTLM-only CONNECT gap; see the CODE checklist below.
- Linux retained Ollama archive continuation: pinned artifact, actual retained
  descriptor hashing, same-inode tar/zstd extraction and stage publication.
  Seven independent modules retain the original two priority updater fixtures.
- Portable MLX fingerprint receiving owns its fake route and CA environment.
  All27 original assertions remain; native routing/trust guards are unchanged.

Feature commits remain separate. The final no-ff merge must preserve them.
Its integrated SHA and terminal manual CI receipt must be recorded after integration.
Tests of controlled transports or authored tiny archives do not establish
official package identity, corporate-network interoperability or device input.

## Exact historical receiving

| Run / source                                               | Passed                                                                         | Failed                                                                                    | Skipped or unrun                                                            |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| macOS37604627108 /35ef2db8fb6d6b920d51ce6ec692e7f124ffe9e7 | Shared checks, macOS units/stub E2E, native Canvas12 and actual Sparkle cohort | Brew deny-removal positive, Package and verdict                                           | Six Brew archive cases not qualified; installation skipped; Release skipped |
| Linux37612794362 /072481c3a9e890d24b16bb46cc93c28d2d277344 | Shared/unit checks                                                             | E2E conditional-NUL diagnostic, authenticated no-follow ETag and Nix metadata             | Package/install skipped; Release skipped                                    |
| Linux37628802086 /accb6bd81cf83e45f41f069d3ad3a51b04dbbb98 | Linux units, repaired HTTP/updater fixtures, native managed transport/archive  | Core fingerprint fixture; native window-switch step; Nix pinned-source metadata; verdicts | Package/install skipped; Release skipped                                    |

The historical Linux37628802086 Nix failure observes status1, no signal/owner
error and retainedfalse; its seven installed-runtime cases were UNRUN at that
checkpoint. Private stderr was unavailable,
so the original cause remains unproved. Official Nix source independently
establishes that the depth-one checkout needs explicit shallow-source admission;
the delivered correction preserves exact revision and NAR agreement.
Commit `d9a0fe9ac97ebcd7d5b19ecc354ae3613de6cccb` adds only `shallow=1` to
the local revision-pinned URL. Genuine Nix2.26.3 passes four actual offline
Git/NAR/clean-HEAD receiving controls, including the unchanged source
refusal. The original49 runner controls pass unchanged in the382-check
JS suite. That earlier host-local product qualification refused at `local-store`
because standard `/nix/store` and `/nix/var/nix` were absent. Later independent
Ubuntu OCI build/component receiving is recorded below; neither observation
qualifies the original complete seven-case runner.

The original fingerprint mirror reproduces21/27 with proxy/CA overrides absent;
the corrected mirror passes27/27 both without those inputs and with conflicting
inherited fixture settings. Windows receiving on sources composed with actual
dev33a5227ea passes382 JS checks, formatting, BOM/LF and actual Linux streaming
262/authentication48/managed18+30 controls. Native AHK was deferred locally.

## Current receiving slices

- `209b1d950076c42e77b5621401349009b9654ab6` retains pinned Ollama archive
  publication. Its11 selected local gates pass across physically closed runs:
  format,382 JS checks,17,144 controlled macOS Lua tests,11,644 Linux Lua
  tests, stub E2E and genuine Linux native temporary/archive/managed transport,
  FD SHA-256 and runtime gates. Managed native controls pass18+30, FD SHA-256
  passes12 and runtime passes82 plus two teardown controls. Six additional
  authored TLS/tar.zstd outcomes pass across genuine LuaJIT/Lua5.4 on the current
  driver. A first combined run reached its outer30-minute deadline; that failed
  receipt is preserved, and unfinished gates were replayed separately. Five
  header-only repairs preserve every original test-body byte. Controlled
  macOS tests and tiny authored archives are not physical or official-package
  acceptance.
- Manual37631791924 at6855c1e6 passes shared JS/properties, Linux/macOS units,
  macOS stub E2E and native Canvas12. Windows units fail10,242 passes/24
  failures; Windows E2E/package/install are skipped. Linux E2E passes the repaired
  window-switch step and fails only genuine Nix; Linux package/install are
  skipped. Mac Package fails Brew native receiving, global switcher and
  Shortcuts; install is skipped. All selected-OS verdicts fail and Release is
  skipped. This supersedes the earlier unexplained feature window-switch red;
  it does not establish historical exoneration.
- Linux-only manual37639299910 atd9a0fe9ac passes Core JS/properties and
  11,644 Linux Lua assertions. Official runtime/model receiving fails during
  official-https-install with child_status1, zero_descendantstrue and unchanged
  sources; E2E, Nix, package and installation are skipped. The source audit
  identifies a missing native helper build and obsolete archive/hash observers.
  Commitc18f0796b2f708a1650d4a1eb5dc316b7bf263dd prepares the original helper
  under the existing owner and observes the actual retained transport/digest.
  Its format/382JS/11,644Linux checks,14diagnostic controls and eight actual
  helper-build controls pass. The original default run was interrupted at its
  capture bound after format/JS completion; unchanged Linux receiving was
  replayed with private logs and physically closed. No bound was relaxed.
- Windows-only manual37641625052 at74ad5da0be890d43d80070c8cc806fe4cadef1c0
  fails10,257 passes/11failures; E2E/package/install are skipped and Release
  skipped. Commite25d938f9c77f49295741b0ba2eb9d5988a965e9 binds actual
  combined-output receivers, counter-owned artifact names and delegated
  integrity/timeout guards; completion admission preserves its original short
  state-only Critical semantics. Format/382JS/1875BOM-LF checks pass locally;
  native Windows parsing/unit/E2E had not run on e25 at that checkpoint.
  The integer/ordinal-inventory/CLR repairs were subsequently delivered in
  `0b0be55e37494ba9043a8dbb467f15f29f2e43c1` and received in the Windows
  run below. That later partial native pass supersedes this pending status,
  while the original historical failures remain recorded.

- Linux-only manual37646124429 atc18f0796b2f708a1650d4a1eb5dc316b7bf263dd
  passes Core JS/properties and Linux Unit, including actual official runtime
  installation, explicit model pull, streamed inference and physical shutdown.
  Original1198635318/SHA15c5 expectations and modelgranite4:350m-h remain.
  The terminal lane fails only genuine Nix at native-build: status1,
  signalnone, owner_errornone and retainedfalse. All other E2E steps pass;
  pinned-source metadata and revision/NAR agreement now pass. Package and
  installation are skipped, both strict verdicts fail and Release is skipped.
  These are actual terminal API observations, not a complete Linux lane pass.

## Latest qualification update (2026-10-07)

- `0b0be55e37494ba9043a8dbb467f15f29f2e43c1` repairs the actual
  PowerShell Int32/Int64 JSON domain, preserves the wider native started tick,
  uses ordinal proxy inventory keys and selects the exact CLR layout overload.
  Genuine portable PowerShell receiving passes64 controls, format and382 JS.
  Windows manual37651111440 reports10,265 passes and five failures; E2E,
  packaging and installation are skipped. The previous integer/inventory/layout
  paths and held HTTP response now pass, without full-lane qualification.
- The five remaining Windows failures are the original System32 curl capability
  completion deadline, canonical WinHTTP vector1 guard, TLS fixture service
  failure count, updater TLS classification and updater cleanup failure count.
  Source-reviewed diagnostic receiving preserves every old assertion, original
  native provider/call, 8-second request/10-second capability receiving clock,
  ephemeral key ownership and teardown. Routing diagnostic receiving passes30
  source-bound Node model controls plus12 genuine portable PowerShell controls.
  These portable controls do not execute AHK/WinHTTP. Commit
  `b21bea3ee3ed0f3a21b90096ab0e9607a5ac688a` delivers all six reviewed
  diagnostic source carriers. Local format,382JS,1875BOM/LF and three actual
  PowerShell parser checks pass; native AHK is explicitly deferred locally.
  The first JS run fails the uninstall preflight under the preserved `/tmp/.git`
  ancestor. All four original uninstall inputs match de7 byte-exactly; the
  canonical `/var/tmp` repeat passes every original check without source edits.
  Windows-only manual37657524885 and Linux-only manual37657530026 test b21;
  both completed with failure. Windows reports10,268 passes/four failures; the
  original curl capability now passes. Its canonical route receipt is OK with
  one route rather than three; TLS service diagnostics report Win32 HRESULT
  -2147467259 during authentication. Neither fact establishes a source fix.
  Linux passes every other E2E step and fails the original Nix build, status1,
  no signal/owner error and no retained phase; its closed lexical classifier
  reports unknown. Both runs skip package/install and Release. Original
  expectations remain unchanged, and neither lane is fully qualified.
- `de7c8bc901595f6047391c90f0162513ed35bc83` classifies only a closed
  failed native Nix build capture with fixed lexical categories. All49 original
  controls and31 independent privacy/provenance controls pass. Original native
  source identities, revision/NAR agreement, seven cases and clocks remain.
- Linux-only manual37654458562 atde7c8bc ends in global failure. Core checks,
  properties, JS, Linux11644 units and original official Ollama/runtime/model
  acceptance pass. The returned eight-job/eight-check census contains no E2E,
  Linux Install, Linux Verdict or manual verdict. Package/Release are skipped.
  Unit success should allow E2E; byte-identical c18 workflows ran E2E. Two
  timestamps in the returned census have completion before start. Scheduling
  or census completeness is unresolved; no source cause or hosted Nix result
  is established by these API facts.
- Separate actual Ubuntu24.04 OCI/Nix2.18.1 receiving builds the de7c8bc package
  successfully using independently pinned Nixpkgs
  `151fa4e8ddfdd8dd25d945ad94ed54a13de9f6e4`. The original installed help
  and five installed LuaJIT/luv/C-backend/GIO/schema/OpenSSL observations pass
  under the existing physically closed command owner. The original full
  seven-case runner still refuses at metadata because its cleaned environment
  cannot resolve the network through this container's proxy-dependent egress.
  The separate producer retains the existing configured proxy. This is genuine
  Docker package-build/help/five-component evidence, separate from the earlier
  host-store absence and from the hosted lane. It cannot replace the original
  seven-case source/closure admission. The latest hosted37654458562 census
  contains no E2E, so it supplies no hosted Nix result.
  TLS trust reuses the existing configured CA, with all original system anchors
  preserved and no verification bypass. The temporary Docker container is
  physically closed and retired after all original private captures/snapshots,
  whole actual package and derivation were verified and archived. Exact owner
  receipts and archive hashes remain private under
  `/tmp/group6-nix-container-retirement-20261007`.

## Prepared continuations and Nix prerequisite repair

The independent genuine Nix2.26.3 single-user regression reproduces a build
failure with an inaccessible build-log parent, then succeeds with exactly the
same derivation after preparing its log directory. Both phases close under the
original command owner; final status0, no signal/error and retainedfalse.
The hosted runner prepared only `/nix/store` and `/nix/var/nix`; native build
logging defaults to `/nix/var/log/nix/drvs`. The workflow now prepares the
separate standard log root for the same validation user, refuses symlinks and
occupied logs, and preserves the original seven cases, pins and deadlines.
This fixes a reproduced prerequisite defect; complete hosted receiving remains
required and is not inferred from this two-case regression.

Manual [37670051601](https://github.com/adrienm7/ergopti/actions/runs/37670051601)
at `1b0b3be0a9fb6720fd0a19c1c7780f1cecfde36d` subsequently completes the
original genuine Nix installed-runtime step successfully, including all seven
mandatory admission cases. Shared and Linux unit/official-runtime checks pass.
The broader Linux E2E job fails; package and installation are skipped. Release
is skipped. This qualifies the Nix log-root repair, not the full Linux lane.
The first GTK dependency/receiving step times out; later native cases also fail.
Raw terminal logs cannot currently be retrieved, so the full cascade's cause
remains unproved.

Commit `9d7b838d570004ba66d974a12410d7032df8eb83` adds signed GTK/process
dependency preparation before the original one-minute receiving clocks and
requires actual luv before native cases. Every original in-case acquisition,
package list, native assertion and workflow byte remains intact. The independent
signed-acquisition floor increases from34 to36 for the two additions; the
original missing-invocation mutation must still fail. Local formatting262,
JS382 and all original runtime/temporary-registration controls pass, with
status0, no signal/error and no retained owned phase. The initial local attempts
failed existing registration/mutation controls; those failed receipts remain,
and no assertion was removed or relaxed. Linux-only manual
[37677432702](https://github.com/adrienm7/ergopti/actions/runs/37677432702)
tests exactly9d7b838d5 and is still running at this checkpoint. Its native result
and final package/install verdict remain pending. Automatic exact-SHA runs are
cancelled; the manual run is preserved. No integration into dev is claimed.

[Remaining source packets](GROUP6-REMAINING-PACKETS-2026-10-07.tar.gz)
retain four inactive preparations, archive SHA256
`a9a46664b600e3a0caae090cdca843dde389566cef82c0d2e357c67b0803ab73`:

- Windows route-origin diagnostics, with unchanged native routing assertions.
- Windows native TLS/error-code and graceful-close diagnostics. Current .NET
  source documents Schannel's refusal of ephemeral private keys; the fixture's
  exact native error code remains unobserved. Persisting a PFX or assuming PS7
  fixes it would not preserve the existing ownership contract.
- Windows curl attempt-engine extraction. This is a preparatory refactor,
  without the artifact producer, authenticated byte bounds or genuine SSPI
  fixture needed to finish the NTLM path.
- macOS opaque-client audit, eleven source bindings and twelve authored future
  native cases. HTTPX offers a request-level insertion seam. A generic TLS-
  preserving CONNECT relay cannot observe HTTPS path/query or same-origin
  redirects; uv/Ollama need actual client integration or native offline staging.
  Initial stock-curl installer downloads also lack native PAC evaluation.

The archive preserves the original SOURCE-only, unexecuted preparations. The
route-origin diagnostic is subsequently applied with exact preimages and inverse
checks: every original native acceptance byte and AHK assertion remains intact.
Actual portable PowerShell AST/helper receiving passes74 cases and the
source-bound AHK receiver model passes61, with status0, no signal/error and no
retained owned phase. This passive projection is not native WinHTTP or AHK
qualification and does not fix the unproved vector1 cause. The other three
preparations remain inactive and unexecuted. No item is closed by these packets.
Inspect MANIFEST.json and actual preimages before applying any preparation;
old native providers/assertions and independent expected corpora remain
authoritative.

The new Linux manual37677432702 at9d7b838d5 passes shared checks but records
11,643 unit passes and one genuine relative-clock failure. Its actual trace
shows refreshed native timer admission, request arrival79.959ms, the original
40ms response delay and callback100.670ms under the unchanged100ms budget.
This demonstrates actual expiry after request latency; the full host cause is
not established. The failed receipt remains. A fresh-run diagnostic at
ef67fa39075f35b990dbaf0a23dd6d8a4987222a changes only the qualification
documents, preserving every unit and production byte. Early E2E prerequisite
receiving and complete Linux package/install acceptance remain pending.

The source-reviewed Windows TLS fixture candidate replaces only the server
backend with native OpenSSL3 memory BIOs over the original TcpClient streams.
Both original CNG keys stay ephemeral, with Framework-compatible PKCS8 export
only in pinned process memory and observed clearing. Actual provider PE/import/
path/hash/version/export and stream/context/DLL/fence closure receipts strengthen
the existing ready/graceful acceptance. Every original108 AHK assertion is
byte-exact;11 provider/closure call sites are added, and the updater receiving
file is unchanged. Production Schannel/.NET clients, root/CRL/PAC/CONNECT,
payloads, counters, socket timeouts and native deadlines remain intact.
Genuine portable PowerShell parsing/whole CSharp compilation and29 independent
pure-helper controls pass under the original closed command owner, status0
without signal/error or retained phase. No Windows native DLL or TLS operation
has run locally. Native trust/refusal, updater staging/cleanup and the complete
Windows lane still require actual hosted qualification; no native repair
success is inferred from compilation or metadata controls.

[Native receiving source packets](GROUP6-NATIVE-RECEIVING-PACKETS-2026-10-07.tar.gz)
preserve82 source/manifest records, SHA256
`d9d2ef1ffb91a82ead067a060d6f9619009d1692276c5ab0afa826dd5baa7903`.
They include original route/TLS candidate preimages and patches, independent
portable controls, source authorities and the new Brew permission audit.
Separate root receiving summaries distinguish actual portable controls from
unrun native Windows calls. Raw private captures, redirected signed URLs and
private keys are excluded. The old four-packet archive remains byte-exact.

Windows-only manual
[37682193508](https://github.com/adrienm7/ergopti/actions/runs/37682193508)
tests exactly `6695173f80e1560aca298ce6cab5252019529e6d` and is in progress.
Linux-only manual37679343730 at ef67fa390 passes the unchanged unit suite and
official runtime/model acceptance but its combined dependency preparation
fails after ten minutes; subsequent E2E receiving also fails. Its complete
terminal result and setup log remain pending. Do not call either lane green.

The Brew audit preserves the existing unconfined positive, then the observed
sandboxed reply-10004 and separate nonprompt permission-query-1744. A public
interactive permission request may block arbitrarily; actual responsible
identity, visible prompt, grant and its effect on the original reply remain
unmeasured. A future bounded same-executable interactive prerequisite remains
CODE, not an implemented or CI-qualified fix. The source audit supplies seven
native continuation requirements without changing any original assertion,
deadline, positive, full-policy denial or six-case Brew acceptance.

Manual37682193508 subsequently completes with10,268 Windows passes/four
failures. The canonical route diagnostic now observes native_bypass/direct
for the single entry. Origin is established; the full-URL PAC bypass cause is
not. Managed-remote graceful cleanup, updater TLS/connect classification and
updater deadline/cancellation cleanup remain failed. E2E/package/install and
Release are skipped. Raw job logs return Forbidden; exact API annotations are
retained. No complete Windows or native TLS repair qualification is claimed.

The Linux dependency owner now separates core LuaJIT/luv, GTK and compiler
setup attempts. Real luv is acquired and required in the first bootstrap;
later roles attempt signed acquisition even if an earlier role fails. Each
setup attempt remains bounded. Original in-case checks, package lists,
receiving clocks and assertions remain intact; the independently declared
signed-acquisition floor stays36. This removes the combined setup's failure
propagation without borrowing a failed prerequisite as a successful native
receipt. Complete Linux E2E/package/install receiving is still required.

The feature's84 atomic commits are integrated without squash at091743921.
Manual37688807101 receives that exact SHA on all three OS lanes without Release
and completes with the failures recorded below. Group6 releases its owned
lock0c66f2c88 after the terminal result at22:16UTC; subsequent feature
validation does not reserve the integration phase.

A subsequent observational correction routes the existing closed Windows service
diagnostic through \_TestPrint, the canonical native TAP receipt writer. CI reads
and prints that transcript only after the AHK process exits; console-only
FileAppend output is not a reliable channel for this process. The admitted
stage/kind/HRESULT values and all original native assertions/clocks remain
unchanged. Manual37690927221 receives exactlyc00cec629 and completes with
10,268 Windows passes/four failures, unchanged from the preceding native run.
No admitted service-stage notice is emitted. The channel change therefore has
no demonstrated native repair credit, and the lower causes remain unknown.

## Remaining CODE and hosted work

Manual37702753652 attempt1 at2ab4b1a32 ends in failure after audio package
acquisition exceeds10min and window prerequisite downloads exceed4min. An
owned-runner apt-get process remains at PID58097 and holds dpkg's frontend
lock; later acquisitions fail. The exact E2E census is123 successful,
32 failed/two skipped steps. Package/install and Release are skipped. Attempt2
uses the same source on a fresh runner: audio acquisition/native receiving pass,
but the initial owned GTK window misses its unchanged readiness deadline.
The terminal census is154 successful, one failed/two skipped E2E steps;
package/install and Release are skipped. The34-case native window cohort is
unqualified. No source cause or Flatpak SDK result is inferred from this failure.

Group6 takes only the package-linux job condition/comment in ci-linux.yml.
Manual diagnostics may receive packaging after E2E failure; the unchanged
E2E dependency retains prior unit success. Automatic runs, cancellation and
skipped E2E remain refused, and linux-ok still requires every mandatory job,
subject and source receipt to pass. Release admission remains push-only.
No existing assertion, receiving clock, installation leg or other workflow
region changes. The source regression fails before this admission change;
actual native package and installation receiving remain required.

Manual37688807101 at091743921 is terminal FAIL. Shared checks pass; Linux has
11,644 unit passes/zero failures and157 successful E2E steps with zero skipped.
Flatpak package configuration fails because curl requires GSS but the24.08 SDK
does not supply it. Windows retains the same four failures. Mac's exact Sparkle
case passes; Brew's unchanged deny-removal AppleEvent positive fails with send0,
reply-read-1701, error-10004 and no receiver marker; permission query is-1744.
Native global-switcher and Shortcuts package probes also fail. All installation
lanes and Release are skipped. The source's full scope remains unqualified.

Windows diagnostic candidate c00cec629 is separately received in37690927221:
10,268 passes/four unchanged failures, no admitted service-stage notice. Canonical
TAP output is used, but no successful service diagnosis or transport repair is
claimed. Raw Windows job and execution-manifest downloads subsequently succeed:
the complete independent manifest records10,272 executed/timed cases,
10,268 passed/four failed and no manifest errors. The full log admits the
same single native-bypass/direct route and no service-stage notice. Restored
artifact access is not transport qualification. After publication of the
domain1 draft, genuine Mac artifact downloads succeed;
the container's files, worktrees and pinned SDKs restore unchanged.

The next Linux correction adds a pinned MIT Kerberos1.22.2 Flatpak dependency,
commit8570e77819563e036027e1da789d08ec9333ed4d, before curl. Group6 owns only this
catalogue source inventory and flatpakModules generator region. The existing
GSS requirement stays enabled and its native prefix is explicitly/app. Missing
or malformed Kerberos pins are refused. The independent recipe regression fails
before the fix and passes afterward; complete native Flatpak receiving remains
required. Other catalogue fields and all historical requirements stay intact.

Manual37695878081 receives exactly2cbcea144 and is terminal FAIL. Shared checks,
11,644 Linux unit assertions and all157 E2E steps pass, including genuine Nix.
Package stops at network-krb5 before configuration: the upstream Git source
has no autogen, autogen.sh or bootstrap script for Flatpak's implicit Autotools
mode. Installation and Release are skipped. The repaired module instead uses
explicit SDK commands for autoreconf, configure with prefix/app, build and
installation. Source pins, library checks, required GSSAPI and all other modules
remain unchanged; full native package/install qualification is pending.

The same pinned MIT Kerberos source is actually autoreconf-generated, configured,
compiled and installed in the host container under a private prefix. The original
disable-static, disable-rpath and without-system-verto choices are preserved.
Installed krb5-config reports1.22.2 and the expected GSS libraries; the owned phase
ends with status0, no signal/error and no retained physical debt. Initial isolated
Autoconf relocation failures are retained separately. This host-source PASS does
not prove the Flatpak SDK build, recipient trust or authenticated Kerberos traffic.

Manual [37709350150](https://github.com/adrienm7/ergopti/actions/runs/37709350150)
receives exactly3161aada974499852a30bff5ac2374ee614996b0 and ends in failure.
Shared checks,11,644 Linux unit assertions and all157 E2E steps pass, with no
E2E failure or skip. Native window and genuine Nix receiving pass under their
original assertions; this does not establish the earlier window failure's cause.
The SDK actually compiles/installs MIT1.22.2 and curl with GSS-API, Kerberos and
SPNEGO. Package then stops at network-gio-proxy: Meson rejects unknown option
tests. Installation and Release are skipped; there is no complete package credit.

Group6 owns only the network-gio-proxy option vector in the shared generator.
The pinned upstream1417a8dd98c46c208853c5ed95de61c384acea21 declares
installed_tests, so the generator now uses installed_tests=false. Native GnuTLS,
libproxy/environment/GNOME provider choices, source pins and all other module
bytes remain exact. An additive independent full-vector regression fails before
the correction; every old assertion is retained. Generated projections are
regenerated through their owner. Complete SDK/package/install receiving on the
new source remains required; built GSS support is not an authenticated session.

The same actual SDK log installs libproxy under/app/lib64, while the retained
package environment admits providers only under/app/lib. Pinned GIO source
derives its module destination from libdir as well. Group6 therefore owns only
the two native Meson providers' directory flags: network-libproxy and
network-gio-proxy explicitly use libdir=lib. Independent full option vectors
reject the original implicit paths and retain all preceding provider flags.
All other module/source/runtime bytes and native assertions remain intact.
The preceding manual37713678709 at acb14576c continues unchanged; this separate
follow-up requires its own exact-SHA package/install receiving. No running
workflow is stopped, resumed or edited to add this source requirement.

Manual37713678709 at acb14576c subsequently completes with shared/unit and
all157 E2E steps passing. GIO configuration succeeds; native executable linking
then rejects unresolved Duktape math symbols. Package/verdict fail and
installation/Release are skipped. The checksum-pinned2.7.0 shared-library
Makefile ignores LDLIBS and puts LDFLAGS before source objects. Group6 owns only
network-duktape's build/install link arguments: retain libm with scoped
no-as-needed/as-needed options, preserving the SDK's preceding flags.
The independent complete command-vector regression fails against the old recipe.
Actual host-source build/install reproduces original consumer-link refusal;
the corrected library records libm and retains RELRO/BIND_NOW, then a genuine
linked Duktape consumer evaluates Math.sqrt successfully. Both normal/debug
build roles, source checksum, native tests and all other modules remain intact.
This is host-source evidence, not a complete SDK/package/install verdict.
Manual37714714116 on the earlier9d26b947e directory correction stays untouched;
the new math correction needs its own exact-source hosted receiving.

- **Windows62:** Join one packaged owned curl attempt engine to both the real
  request consumer and artifact staging producer. Bare NTLM-only CONNECT must
  use genuine SSPI evidence and one causal fallback after exact first-child and
  pipe closure. Keep full-URL PAC/redirect selection, the original absolute
  clock, Schannel trust/revocation, exclusive native destination creation,
  write/flush/integrity and staging/Job retirement. Adding another .NET
  CredentialCache entry does not implement this join. Preserve the old .NET
  unavailable-response-source oracle in its identified path; independently
  review stronger receiving for the new producer. Existing deterministic auth
  models are not native handshake proof. Main anchors are
  `windows/vendor/ergopti_managed_curl_worker.ps1`,
  `windows/vendor/ergopti_updater_download.ps1`,
  `windows/modules/updater/self_update.ahk` and
  `windows/tests/unit/test_updater_managed_transport.ahk`.
- **Linux62:** Complete current-source native E2E, all package formats and
  installed runtime receiving, including genuine Nix and portable runtime
  closure. The window-switch step passes in37631791924; do not attribute its
  historical failure to an unproved cause. The c18 Unit official
  runtime/model result above is a component PASS; later lane and final-source
  receiving remain separate. Resolve Nix or any new official-runtime failures
  without weakening source pins,
  native admission, deadlines or seven mandatory installed-runtime cases.
- **macOS62:** Full request-URL PAC/WPAD, ordered fallback/redirect routing for
  uv, HTTPX/HF/Xet and outgoing Ollama Go requests remain CODE. Complete system
  trust, loopback bypass and generic model failure/action integration on the
  actual drivers. Verified unsupported routes must keep their typed refusal.
  Qualify each real installer/server/pull/updater/remote-AI child and its recovery.
- **macOS36:** Establish a legitimate same-identity Automation prerequisite if
  the Brew cohort needs consent; the current fixture has no demonstrated grant
  path. Preserve exact Sparkle domains/codes, wrong-key refusal/retry,
  install/relaunch, native AppKit registration, nonce/markers, both positives,
  full-policy denial, all six Brew cases and physical retirement. Obtain a
  complete native Package pass and all eleven CI installation legs on the same
  final source. Filtered Sparkle success alone cannot close36.

## Windows native fix and replay checklist

The current four failures belong to terminal run37690927221 atc00cec629.
The historical System32 curl capability failure from37651111440 now passes;
do not rebuild that qualified path without a regression. Each remaining step
requires genuine receiving of its unchanged failing assertion, a source fix
only if captured evidence demonstrates one, and replay on the final source.
Lower causes remain unknown; the diagnostics are observational.

1. **Canonical WinHTTP vector1:** receive the exact native returned shape,
   ordered-route and limit facts, then fix the demonstrated guard/provider
   mismatch. Preserve the complete full-URL/PAC vector and native owner; portable
   PowerShell projections do not establish WinHTTP success.
2. **TLS fixture service failure count:** identify the fixed service failure
   stage using the actual retained service receipt. Correct only the demonstrated
   service/receiving defect; retain ephemeral key ownership, the independent
   failure-count expectation and physical server retirement.
3. **Updater TLS classification:** receive the actual route and trust failure
   before changing classification. Preserve the original TLS expectation,
   system trust, proxy refusal and provenance; do not relabel proxy_resolve as
   TLS without evidence or bypass certificate verification.
4. **Updater cleanup failure count:** receive actual service/child/Job cleanup
   acknowledgement and correct its demonstrated join/receiving defect. Preserve
   the failure-count assertion and retained debt; root-directory removal is
   not a physical service-closure receipt.

After these fixes, the complete Windows native unit/E2E/package/install lane
still requires a terminal result on the final SHA. Packaged artifact SSPI and
Mac opaque routing remain separate CODE requirements. Enterprise and real-device
UI/installer/rollback checks remain separate device requirements; items16/38,
36 and62 stay open.

## Continuation order

1. Run the full Windows native lane on the delivered source; retain every
   remaining failed assertion with its exact run/SHA and fix it using genuine
   Windows receiving. Then qualify the packaged artifact authentication engine
   above; ordinary request SSPI support does not prove artifact SSPI support.
2. Run the complete Linux lane, including official runtime/model receiving,
   all seven installed Nix controls, every package and installation matrix leg.
   Keep unchanged checksums, source identities and physical cleanup mandatory.
3. Supply the supported same-identity Mac Automation prerequisite and qualify
   the complete archive/Brew cohort before claiming full package acceptance.
4. Implement and independently receive the remaining Mac opaque-client routing
   contract, then run the corporate-network and physical UI checks below.
5. Remove36 or62 only after its complete scope passes; retain transversal16/38.

## Genuine Windows and Mac device checks

- On Windows, qualify the actual packaged application, startup and native UI:
  remote API Test, model provisioning/pull, Versions/download/retry and settings
  actions. Preserve current document/init nonce, operation epoch and exact
  native observer/Job cleanup. Check cancellation, window replacement, healthy
  retry and installer/rollback preservation after certificate, proxy, offline,
  disk and permission failures. Run the shipped AHK runtime from the canonical
  toolchain contract; use `npm run test:ahk-encoding`, `npm run test:ahk-parse`
  and the original unit/E2E owners described in `ci-windows.yml`.
- On every OS, exercise a genuine corporate test network/lab covering PAC,
  WPAD, static proxy, enterprise CA/revocation and applicable account/domain
  authentication. Observe all actual download children and redirects. Personal
  DIRECT success does not qualify those routes. Verify translated causes and
  useful retry/settings/diagnostic actions in a real desktop session.
- On Mac, observe the actual responsible sender/receiver identities and normal
  OS consent before the unchanged Brew admission. Nonprompt query-1744 proves
  consent was required for that query, not the sole cause of reply-10004.
  Granting Terminal is not a demonstrated remedy for newly generated bundles.
  Do not edit/reset/copy TCC databases or remove sandbox/assertion requirements.
  Validate signed ZIP/XZ install, upgrade/refusal preservation/retry and relaunch.

For native Mac receiving, use CPython3.13+ with WNOWAIT, the existing Node and
Swift/Xcode tools, existing Brew portable Ruby and the original private evidence
setup. Run the selected original XCTest serially; keep native and capture exit
statuses independently, exact case completion and receipt.checked closure.
The test identities and consent preflight must match the same owned attempt.
The complete workflow remains the package/install acceptance owner.

The canonical Mac launch matrix mutates disposable Actions profiles. Its gate
refuses personal machines. Never set GITHUB_ACTIONS=true on a personal Mac to
evade that guard; a reviewed isolated device owner would be separate work.

## Safe CI continuation

Use workflow_dispatch on ci.yml from an owned testing branch and choose the
actually affected os_lanes. Shared driver changes require all. Every dispatch
must be bound to its actual SHA, terminal status and skipped Release / Publish.
Cancel automatic runs of each pushed SHA; leave every manual run to completion.

Final integration alone acquires codex/ci-lock and owns codex/ci-validation.
Inspect any existing owner and wait. Merge dev with --no-ff, push immediately,
cancel exact automatic runs and qualify the integrated SHA before releasing
the owned lock. Do not force-push or modify another group's CI branch.

Private evidence/checkpoint files remain retained by their original owners.
They contain fixture data and must not be published indiscriminately.

## Preserved feature commit inventory

The inventory below precedes final receiving/documentation commits. The final
no-ff merge preserves those commits too; its second parent identifies the final
feature tip. History-only CI ancestry imports have no source delta and are not
credited as feature implementation.

```text
b21bea3ee test(windows): expose closed managed transport failure facts
de7c8bc90 test(linux): classify closed native Nix build failures
0b0be55e3 fix(windows): admit canonical JSON and proxy inventory
e25d938f9 fix(windows): bind native receiving to current owners
c18f0796b fix(ci): prepare and observe retained Ollama acceptance
74ad5da0b fix(windows): repair managed network receiving seams
d9a0fe9ac fix(ci): admit revision-pinned shallow Nix source
209b1d950 feat(linux): retain pinned Ollama archive publication
6855c1e6d test(macos): isolate the MLX fingerprint fixture network route
1605b63de feat(windows): retain managed network routing and failure ownership
accb6bd81 fix(ci): expose bounded Nix phase failure observations
0ef79d773 fix(linux): preserve authenticated no-follow updater caching
ea3cd24fa fix(linux): preserve conditional path refusal diagnostics
f7c7d368d fix(macos): refuse unsupported opaque network routes
072481c3a fix(linux): retain updater ETags at their final endpoint
35ef2db8f fix(macos): require the observed Sparkle validation error
22792d207 fix(ci): select complete Linux assertion records before decoding
704598298 fix(macos): retain bounded native acceptance diagnostics
1ce802508 fix(macos): include system trust in the frozen MLX lock
9195a6419 fix(ci): expose the completed Linux configuration assertion
89085c467 fix(macos): publish the Sparkle fixture signing key
cfe904758 fix(macos): refuse MLX downloads without system trust activation
6072016f3 fix(macos): retain typed Sparkle startup refusal evidence
4f01de5dd fix(macos): confirm existing accessory admission without a setter
cd198161b fix(ci): retain failed Linux unit reporter logs
ed979dee8 docs(release): preserve composed qualification and remaining work
c18442429 fix(macos): correct Sparkle progress enum declarations
1a2fa790a fix(linux): wait for release-check owner retirement
67d563584 test(macos): trace actual Sparkle archive update progress
8f7cecf46 test(linux): expose owned Nix phase refusal boundaries
3cfad32a6 test(macos): observe actual AppKit activation policy states
f346157c7 docs(release): record exact native qualification limits
e9db13486 test(linux): trace actual relative HTTP timer admission
1016527df test(macos): report exact AppKit receiver refusal reasons
949eb6eca fix(test): retain native Sparkle fixture root identity
7e786f7ef fix(test): observe actual asynchronous Linux updater installation
f7aa85391 fix(linux): retain exact temporary updater native lifetimes
eeb6fd58f fix(ci): stage an authenticated private curl validation keyring
5e9a545dd fix(test): distinguish pinned Nix metadata refusal checkpoints
229545c51 fix(test): expose bounded Sparkle child refusal categories
ad95a2693 test(macos): retain the updater fixture sleeper parent
29658bad3 test(macos): observe owned receivers after AppleEvent refusal
69cda111d test(macos): verify archive signatures with cryptographic oracles
b8a8363d4 test(linux): report safe native preparation checkpoints
2069853a7 test(linux): reap owned CLI descendants during settlement
622aa798b fix(linux): retain admitted legacy HTTP redirect policy
6c9b334fc test(linux): await native HTTP fixture close acknowledgements
281ee9a70 test(linux): qualify genuine Nix installed runtime
bd0a90434 test(macos): expose bounded archive acceptance failure facts
01834579c fix(linux): retain verified archives through native installation
a96b224a6 fix(test): use the imported Sparkle download delegate label
8827c9d32 fix(test): bind Sparkle fixture to numeric loopback
c9bee527e fix(test): retain owned AppleEvent marker diagnostics
435f0cf3d fix(test): retain Sparkle startup diagnostics after retirement
6a07d83a3 fix(network): retain prepared requests through native cleanup
9f4b8e9c1 docs(release): preserve reviewed group6 recovery sources
bfcd1abf4 feat(release): qualify retained archive descriptor hashing
997a71980 feat(release): stage native networking in portable Linux packages
c4ec2bf45 feat(network): admit buffered GET redirects through native owners
54493dc2a fix(release): serve Sparkle archives from the retained physical root
cd71ef559 feat(network): route Linux HTTP through owned native proxy admission
c622e45d6 fix(release): diagnose actual Sparkle server retirement
41cc59b49 fix(release): expose bounded native archive XCTest outcomes
5ce6bc2c9 fix(linux): read native WebKit loading state as a property
40ddfed7c fix(updater): fence Versions actions to their admitted document
043f32684 docs(release): record native privilege refusal and Linux inode boundary
4d026ba9a test(release): expose bounded native AppleEvent reply facts
cfa27a347 fix(release): bound idle Sparkle server request reads
7b567bd30 fix(network): retain private Linux remote failure receipts
9a95d5ce4 fix(release): retain owned canonical Sparkle census paths
7cff41c28 fix(release): use the documented receiver registration transition
00a07ff9f docs(network): preserve the corrected Linux producer continuation
a23db837d test(release): expose owned AppleEvent registration refusal
2420fe7a2 test(release): identify bounded Sparkle directory refusals
d95998c0e test(release): expose pre-path Sparkle census refusals
1d23f689f test(release): expose owned AppleEvent termination facts
6deec05a9 docs(release): record the integrated qualification verdict
```

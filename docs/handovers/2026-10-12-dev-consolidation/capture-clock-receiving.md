<!-- docs/handovers/2026-10-12-dev-consolidation/capture-clock-receiving.md -->

# Pending captured-clock boundary correction

The [source patch](pending-capture-clock-half-range.patch) is implemented and
verified against the frozen source inventory in
[capture-clock-half-range.manifest.json](capture-clock-half-range.manifest.json).
Patch SHA256: `8ee073d062ac1cbee2b29b228d45ebc44d802603e5eec3ac69ccb393b2baea1c`.
It is preserved on dev but is not applied to the live native source or DLL.
Manifest log paths record historical private evidence; receiving needs no such files.

The native producer promises adjacent admitted DWORD times strictly less than
half a cycle apart. Its backward branch rejects the exact half-range; its
forward branch incorrectly accepts it. The one-comparison correction rejects
both ambiguous directions while preserving raw capture, the preceding clock
anchor, effective source holdings and retained replay debt.

Only the native owner and its existing test change. All 1,352 original assertion
calls and their order remain, with 31 new calls in the existing FIFO snapshot
case. Seven literal boundary/wrap vectors supply 35 authenticated seam edges.
The next valid UP proves a rejected timestamp neither advances the anchor nor
loses the source hold. Partial raw acceptance preserves the exact suffix.

Actual Linux C execution using the Win32 shim: corrected selected case and full
43/43 portable cases pass; selected ASan/UBSan/LSan passes. The original producer
fails the new exact-half assertion; advancing the rejected anchor and dropping
its raw edge fail two independent mutations. The native census remains 44,
including one native-only editor case excluded from Linux execution.
These results do not qualify Windows hooks, the SDK or physical delivery.

## Native receiving

Coordinate with Root before modifying the live recipe inputs. From a freshly
synchronized dev checkout, verify every changed source preimage in the manifest:

```powershell
$clockPatch = 'docs/handovers/2026-10-12-dev-consolidation/pending-capture-clock-half-range.patch'
$clockHash = (Get-FileHash $clockPatch -Algorithm SHA256).Hash.ToLowerInvariant()
if ($clockHash -ne '8ee073d062ac1cbee2b29b228d45ebc44d802603e5eec3ac69ccb393b2baea1c') { throw 'Clock patch identity changed.' }
git apply --check $clockPatch
if ($LASTEXITCODE -ne 0) { throw 'Clock source preimages changed.' }
```

Compose any other pending native patches without losing their additive tests.
On a native Windows x64 build host with the pinned MSVC/Windows SDK and Node,
apply the reviewed source union, then execute:

```powershell
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1 -UpdateTracked
if ($LASTEXITCODE -ne 0) { throw 'Native rebuild failed.' }
powershell -NoProfile -File tools/build/build_windows_nav_owner.ps1
if ($LASTEXITCODE -ne 0) { throw 'Native recipe verification failed.' }
```

Expect the unchanged 44-case native census and an actual matching DLL/manifest.
Do not restamp the preceding E4133 artifact from Linux. Windows SDK/build/API
receiving is UNRUN and needs a native VM; this metadata correction needs no
physical keyboard to exercise its core. Actual suppression, source holdings
and hook ordering still require separate native/physical observations.

Production admission stays closed. Full handler/nonhook observer conversion,
output emission and unknown-outcome cleanup remain software work. Item 49 stays
open; missing native execution does not make that software work complete.

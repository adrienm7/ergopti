# Qualification evidence

## Passed in this Linux container

- Scratch-targeted AHK loop-capture guard: 0/0 findings, 14 detector self-test fixtures.
- Scratch-targeted AHK v2 syntax antipattern guard: 2 AHK sources inspected, no findings.
- Explicit encoding inspection: both AHK sources UTF8 BOM with LF; PS source LF.
- `git apply --check managed-remote-native-acceptance.patch`: passed against current
  checkout with run_all exact preimage df87170eb7de0aa235f7e3b76a44794e436d3581d9fec13f5f827501161f569c.

These checks are read-only and did not execute global JS, native suites or generators.
The two existing guard sources were copied unchanged into the scratch proposal solely
so their ROOT resolves to the two proposed AHK sources. They are not integration files.

## Not run

- AutoHotkey actual parse/load and registered native managed-remote test.
- Windows PowerShell Add-Type compile, ephemeral CNG certificate/CRL creation and listeners.
- Eight actual production generation/readiness requests with Schannel trust transitions.
- Actual native PAC settings snapshot/URL evaluation, revocation fetch and proxy transport.
- Graceful native service settlement, physical Job/curl/PAC termination and exact root removal.
- Full Windows unit/meta, E2E, install/packaging and manual targeted CI.
- Controlled current-user authenticated proxy or managed WPAD laboratory qualification.

## Native acceptance matrix

| Phase                   | Admission    | Generation         | Readiness | Required observed evidence                                                                           |
| ----------------------- | ------------ | ------------------ | --------- | ---------------------------------------------------------------------------------------------------- |
| Unique CA absent        | static       | refusal            | false     | CONNECT reached; zero authenticated handlers                                                         |
| Exact unique CA present | static       | managed-network-ok | true      | actual auth/body/parser, two HTTP handlers                                                           |
| Exact unique CA present | PAC          | managed-network-ok | true      | actual WinHTTP PAC fetched, exact path/query, four total handlers                                    |
| Exact unique CA removed | static       | refusal            | false     | CONNECT reached; handler count stays four                                                            |
| Cleanup                 | exact owners | retired            | retired   | native graceful receipt, Job quiescence, independent thumbprint absence, no private artifacts/events |

Unexpected service/cleanup failure, unavailable native API or inherited explicit network
overrides remain failed/unqualified; they are not fabricated successful or skipped results.

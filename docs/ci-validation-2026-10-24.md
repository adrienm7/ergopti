# CI validation of the never-compiled macOS and Linux pieces (2026-10-24)

Method: the maintainer authorised pushes of committed history to throwaway
`tmp/ci-validate-*` branches (never dev or main) and workflow runs on them.
GitHub only dispatches a workflow file that exists on the default branch, so
the macOS pieces ran from a throwaway `push`-triggered workflow
(`tmp-ci-validate.yml`, present only on the throwaway refs, selected by the
branch name). The Linux lane ran through `ci.yml` with `os_lanes=linux`.

| Run         | Branch                  | Piece                                                                                                     | Verdict                                                                                                            |
| ----------- | ----------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| 40019763489 | tmp/ci-validate-swift-1 | Swift build + XCTest (macos-15)                                                                           | red: 108 of 109 pass, `ManagedLookupStageTests.testMoreRoutesThanTheBoundNameTheRoutesStage` fails                 |
| 40021100985 | tmp/ci-validate-swift-2 | same class after the fix                                                                                  | green                                                                                                              |
| 40021395899 | tmp/ci-validate-go-1    | standalone `go vet` of native_http                                                                        | red: the module depends on `golang.org/x/sys` that only the Ollama tree provides; the step was wrong, not the code |
| 40021624397 | tmp/ci-validate-go-2    | Ollama 0.40.4 patches + native_http through `build-macos-managed-ollama.py` (applies hooks, runs go test) | green, 2m37s                                                                                                       |
| 40022432583 | tmp/ci-validate-remap-1 | Karabiner vendor-header tests                                                                             | red: accept test exits 17 on pristine headers                                                                      |
| 40023031301 | tmp/ci-validate-remap-2 | same, after the workflow fix                                                                              | green                                                                                                              |

Fixes:

- `test(macos): bound the routes-stage lookup test above the initial CFNetwork
entries`: CFNetwork lists the PAC entry plus its fallback, so a bound of one
  failed at the candidates stage.
- `ci(remap): run the accept test as a baseline failure then a repaired pass`:
  the test reproduces a defect of the pinned asio by design (exit 17) and
  passes once `hs274_raw_patch.py --stream` is applied. `-DASIO_STANDALONE` was
  not needed and is dropped.

Linux: see the section appended below.

## Linux lane (ci.yml with os_lanes=linux)

| Run         | Branch                  | Verdict                                                                                                                              |
| ----------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 40023362219 | tmp/ci-validate-linux-1 | red at the front: my throwaway workflow file failed the Prettier check (not pushed again)                                            |
| 40023779458 | tmp/ci-validate-linux-2 | red: the shared-JS inventory has a gap (ordinal 456 missing, see below)                                                              |
| 40024207179 | tmp/ci-validate-linux-3 | red: unit lanes fail on committed history that depends on uncommitted shared JSON, so every E2E, package and install job was skipped |
| 40025021077 | tmp/ci-validate-linux-4 | partial, see below                                                                                                                   |

Findings that belong to other agents' unfinished work (not fixed here):

- `tools/test/features/ai-and-network/suite.json` lacks the `js-0456` entry for
  `test-managed-proxy-route-contract.cjs` in committed history (the entry is a
  working-tree hunk). Until committed, `node tools/ci/js-feature-matrix.cjs plan`
  fails with "missing global ordinal" and nothing else runs on CI.
- Committed Lua and tests reference locale keys and menu rows that live only in
  the uncommitted shared JSON: `startup.linux_input_access_no_device_body` is
  missing in every locale, the `composer-check` row is not declared once in the
  menu manifest, and `linux-native-titles` and the translation-key audit fail.
  The coordinator's integration commit of locales, menu_manifest.json and
  schema.json is required before a Linux or common lane can be green.

Run 40025021077 used a throwaway copy of `ci-linux.yml` with the `needs` of
integration and E2E removed so those jobs run despite red unit lanes:

- E2E shards input-display, updater, network-ai, platform-metrics: green. The
  changed install steps and window-list receipt sit in these shards.
- E2E shard desktop-webview: red at "Launch option-looking application ids
  through actual GTK desktop entries" (`stage=unknown;case=0;native_exit=1`,
  the observer timed out with no receipt). Not yet attributed; the step is not
  among the changed ones. Re-run only this shard to tell a flake from a
  regression.
- Integration (native): red at `real-model-chat ... native_receipt_or_source_qualification_failed`.
  Not attributed.
- Build (.deb, .rpm, AppImage): NOT validated. `ci-stage-status.cjs admit-build`
  rejects the throwaway wiring (expects `integration-linux` as a predecessor),
  so the job stopped before building. Therefore the AppImage `.zsync` and
  `check-appimage-update.cjs` verifier, the Flatpak runtime cache and retry, and
  the install matrix were NOT run.

## How to continue

1. Commit the shared JSON integration (locales, menu_manifest, schema) and the
   `js-0456` suite entry, then push `dev`'s state to a throwaway ref:
   `git push origin HEAD:refs/heads/tmp/ci-validate-N` and
   `gh workflow run ci.yml --ref tmp/ci-validate-N -f os_lanes=linux`.
   With unit lanes green the real `needs` chain runs Build, Flatpak and
   Install, which covers the AppImage `.zsync`, the verifier and the Flatpak
   cache. Use `os_lanes=macos` only once for the full macOS lane.
2. The macOS Swift, Go and Karabiner pieces are done (green); the throwaway
   workflow lived only on the `tmp/ci-validate-*` refs and is not in dev.
3. The macOS job filters used for Swift were `ManagedLookupStageTests`,
   `ManagedDirectFallbackTests`, `ManagedProxyRouteWorkerTests`,
   `ManagedHTTPWorkerTests`, `UninstallWorkerTests`, `OwnedRuntime*` and the
   lease worker classes (109 tests in the first run, 1 failure, fixed).
   Everything else in the launcher package compiled with `swift build --build-tests`.

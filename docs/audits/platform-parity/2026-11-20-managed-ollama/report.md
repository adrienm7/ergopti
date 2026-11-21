# Managed Ollama runtime

Audited source: `8e8f5485ce` (`dev`). Date: November 20, 2026. Third campaign
in the order of the [2026-11-19 census](../2026-11-19-census/report.md), after
the [logger engines](../2026-11-20-logger-engines/report.md). The runtime was
last read by the 2026-11-05 native-ui campaign, before these adapters existed
under their names.

## Scope

The Ollama that Ergopti installs, runs and pulls models into, on the three
drivers and their shared owners:

- Windows: `windows/ai/engine/ollama/` (`managed_bootstrap.ahk`,
  `runtime_owner.ahk`, `deps_checker.ahk`, `install_files_port.ahk` and the
  PowerShell helpers `ollama_managed_files.ps1`,
  `ollama_managed_acquisition.ps1`, `ollama_download_archive.ps1`,
  `ollama-runtime-launch.ps1`, `ollama-model-pull.ps1`) and
  `windows/ai/engine/api_ollama/`;
- macOS: `macos/ai/adapters/managed_ollama_*.lua` and `ollama_*.py`,
  `macos/ai/engine/ollama/` (`deps_checker.lua`, `binary.lua`,
  `server_command.lua`, `managed_ollama_runtime.py`, `managed_ollama_serve.py`,
  `managed_ollama_pull.py`) and `macos/ai/ui/menu/models/manager_ollama.lua`;
- Linux: `linux/ai/engine/ollama/` and `linux/ai/engine/local_servers/`
  (`runtime_composition.lua`, `model_download.lua`);
- shared: `_shared/ai/adapters/python/managed_ollama_*.py`,
  `_shared/ai/engine/ollama/`,
  `_shared/ai/engine/local_servers/runtime_repair.lua`,
  `_shared/ai/data/ollama_release.json`, `managed_ollama_runtime.json`,
  `_shared/core/network/data/bootstrap_retry.json` and the `[llm]` timings.

Read for each: install, update, start, stop and uninstall; version pinning and
integrity; disk-space and network failures; model download and resume; port
and process ownership; cleanup on failure; the readiness probe and its timing
constants; the menu rows and their reasons. Source reading plus replays
through the real modules (AutoHotkey, LuaJIT under WSL) with fake transports
and clocks. Nothing was installed or downloaded: no Ollama, no model.

Checked and kept:

- **Version pinning.** Windows and Linux read the official asset's version,
  SHA-256 and size from `ollama_release.json` and check both before
  extraction (Windows `ollama_managed_acquisition.ps1`, Linux
  `install_files.lua` `extract_command`). macOS installs Ergopti's own build
  of the same tag, pinned by `managed_ollama_runtime.json` and its generated
  catalogue (`docs/memory/macos-hammerspoon.md`,
  `project-managed-ollama-catalogue-is-a-release-output`).
- **Signatures.** macOS verifies the code signature
  (`managed_ollama_runtime.py`, `codesign --verify --strict`) because it
  re-signs its build. Windows and Linux run the upstream archive's bytes,
  which the pinned digest identifies exactly.
- **Port.** The three run their Ollama on `llm_ollama_owned_port` = 11435 and
  never contact 11434 (`_shared/ai/data/defaults.json`). Windows refuses a
  listener already on the port and admits readiness only from its own child's
  socket (`ollama-runtime-launch.ps1`); macOS waits for its guardian's
  listener event (`managed_ollama_serve.py`). Linux, since OLL-13, refuses a
  listener already on the port and admits only its own process group's socket
  with the pinned version.
- **Download cleanup.** No OS keeps a partial runtime archive: macOS removes
  its temporary folder, Linux its owned stage, Windows its journalled partial
  files (it keeps one only when removing it fails). The runtime archive is
  tried once on the three, with a manual retry.
- **Model resume.** No driver deletes Ollama's partial blobs, so a retried
  pull resumes through Ollama on the three. Cancellation stops the owned
  process (the Windows task, the macOS worker's signal, the Linux curl group).

## Fixed

Each fix has a regression red on the old code. The pull classes are replayed
from one corpus,
[`ollama_pull_error_vectors.json`](../../../../static/ergopti_plus/_shared/tests/corpus/llm/ollama_pull_error_vectors.json),
by `windows/tests/unit/ai/servers/test_ollama_managed_bootstrap.ahk` and
`linux/tests/unit/ai/engine/ollama/test_model_download.lua`.

| Id     | OS        | Sequence                                                                           | Reference                                                                                                                                         | Before                                                                                                                                                                                                                                                                                                    | Regression                                                                                                                                                                                             |
| ------ | --------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| OLL-01 | Linux     | Pull a model whose layer fails Ollama's digest check                               | Windows `_PullResult` and `_MenuPulled`, macOS `manager_ollama.lua`: one more pull, since Ollama removed the layer, then `ollama.digest_mismatch` | Linux failed at once with the generic `menu.llm.download_failed`; the class vocabulary existed on Windows and macOS only, as two copies                                                                                                                                                                   | `ollama-pull-error-vectors` and three `ollama-digest-mismatch` cases (Linux); the corpus and the shared data file in `the pull output classes are the macOS vocabulary` (Windows)                      |
| OLL-02 | Windows   | Pull a large model on a slow line, at install or from the menu                     | Linux: a pull has its own ceiling (24 h); macOS: no ceiling, a stall bound                                                                        | The first-model pull ran under the install budget (`dependency_bootstrap_timeout_ms`, 30 min from the start, the 1.47 GB runtime download included) and a menu pull under the same 30 min: both failed mid-download with « Local Ollama could not be prepared »                                           | `the first model pull has its own ceiling…`, `the pull ceiling comes from the timing registry` and the re-pinned menu pull deadline cases; `ollama-model-pull-ceiling` (Linux)                         |
| OLL-03 | docs      | Read the owners that the registry and the inventories name                         | The code                                                                                                                                          | `ollama_deps_poll_ms` named a Windows `ollama_deps_checker.ahk` 3000 ms timer, which no longer exists (Linux owns it); stale names in `constants.toml`, `owned_runtimes.json`, `owned-runtimes.md` (a winget path long gone) and the macOS memory (an earlier owned runtime is now replaced, not refused) | Documentation                                                                                                                                                                                          |
| OLL-07 | Windows   | Update the pin, start Ollama once the new version is installed                     | macOS `earlier_owned_install`: the earlier install is exchanged for the new one                                                                   | `managed_bootstrap.ahk` « Keeps installed versions »: the new version installed beside the old one under `versions` and nothing removed it, about 1.4 GB per update                                                                                                                                       | five `(oll-07)` cases in `test_ollama_managed_bootstrap.ahk`, four in `test_ollama_install_files.ps1` (Windows)                                                                                        |
| OLL-07 | Linux     | Update the pin, start Ollama once the new release is installed                     | macOS `earlier_owned_install`: the earlier install is exchanged for the new one                                                                   | The new release installed beside the old one under `runtimes/ollama/` and nothing removed it: about 1.4 GB per update                                                                                                                                                                                     | `(oll-07)` cases in `test_composition.lua` and `test_runtime_seal.lua` (Linux)                                                                                                                         |
| OLL-08 | Linux     | Start Ollama from a tree installed earlier                                         | Windows re-hashes every file of its manifest before reuse, macOS its binary                                                                       | `installed_runtime.lua` admitted the tree on its metadata (inode, size, mtime, ctime) and never hashed it                                                                                                                                                                                                 | `(oll-08)` cases in `test_repair.lua`, `test_composition.lua` and `test_runtime_seal.lua` (Linux)                                                                                                      |
| OLL-09 | macOS     | « Delete this model from cache » with a CLI that never returns                     | Windows and Linux: `DELETE /api/delete` under `[llm] ollama_delete_timeout_ms`                                                                    | `ollama rm` ran with no ceiling and held the maintenance slot with no notice                                                                                                                                                                                                                              | `(oll-09)` cases in `test_requirement_descendant_pause_join.lua` (macOS)                                                                                                                               |
| OLL-12 | macOS     | Read the generated `ollama-release.sh`                                             | Windows and Linux read `ollama_release.json` at runtime                                                                                           | The shell projection was read by nothing, and its header said the size « only drives the download progress bar » while the three refuse a wrong size                                                                                                                                                      | `no unread projection of the catalogue is generated (oll-12)` in `test-ollama-release-pin-parity.cjs`                                                                                                  |
| OLL-13 | Linux     | A foreign server answers on 11435 before the owned daemon binds                    | Windows `ollama-runtime-launch.ps1` and `_VersionReceived`: no listener before the start, only the child's socket, the pinned version             | Any `GET /api/version` answer with any version, while the owned process was alive, was readiness                                                                                                                                                                                                          | `(oll-13)` cases in `test_composition.lua`, `test_listener_owner.lua`, `test_service_process_running.lua` and `test_owned_process_running.lua` (Linux)                                                 |
| OLL-10 | Windows   | Ollama answers the warmup of an installed model with « unable to load model »      | macOS `manager_ollama.lua`: one more pull of the model (`ollama.model_repair`), then the failure                                                  | `_LLM_Ollama_OnWarmupDone` dropped the body and retried the load forever                                                                                                                                                                                                                                  | `warmup model repair (oll-10)` cases, `a repair pull asks no download consent (oll-10)` and the shared vectors in `test_ollama_local_presence.ahk`                                                     |
| OLL-10 | Linux     | Ollama answers the warmup of an installed model with « unable to load model »      | macOS `manager_ollama.lua`: one more pull of the model, then the failure                                                                          | The warmup's 500 became `HTTP 500` and the chain retried the load forever                                                                                                                                                                                                                                 | `(oll-10)` cases in `test_model_warmup.lua`, `test_backend.lua` and `test_api_ollama_stream_parse.lua`                                                                                                 |
| OLL-11 | the three | Install, start, repair, delete a model or uninstall Ergopti's Ollama from the tray | The menu manifest: one row per action, checked by the parity table                                                                                | The actions were reachable only from the model page and consent dialogs, outside the parity table; no OS uninstalled the managed runtime                                                                                                                                                                  | `(oll-11)` cases in `test_ollama_runtime_uninstall.ahk`, `test_runtime_uninstall.lua` (Linux), `test_ollama_uninstall_vectors.lua` and `test_runtime_uninstall.lua` (macOS); the menu and parity gates |

Notes:

- **OLL-01.** `_shared/ai/data/ollama_pull_errors.json` is the one source of
  the closed classes and of the single digest retry. Linux reads it
  (`model_download.lua` `M.error_class`; a pull is refused, with a logged
  reason, when it is unreadable). The Windows table
  (`LLM_OLLAMA_PULL_ERROR_CLASSES`) and the macOS worker's (`ERROR_CLASSES`)
  are pinned to it by the Windows test. The Linux retry stays in the same
  download window and waits for the transport's physical settlement before it
  dispatches again.
- **OLL-02.** `[llm] ollama_model_pull_timeout_ms` (24 h, Linux's former
  literal) bounds a pull from its dispatch, on Windows (both pulls) and on
  Linux. The install budget still bounds everything before the first-model
  pull. macOS keeps no absolute ceiling, as its worker states
  (`_shared/ai/adapters/python/managed_ollama_pull.py`), and stops a stalled
  transfer after `CURL_STALL_SEC`; the registry comment says so.
- **OLL-07.** Once the pinned release is verified (OLL-08) and its own daemon
  answers with the pinned version (OLL-13),
  `linux/ai/engine/ollama/runtime_retention.lua` lists the other
  `<version>-<asset>-<sha256>` folders under `runtimes/ollama/` (real folders
  owned by the user, never the pinned one) and removes them in one
  `rm -r --one-file-system` child under the finite process port, so the event
  loop never waits. A refusal is logged and the next start lists the folder
  again. On Windows, once the daemon answers with the pinned version,
  `managed_bootstrap.ahk` `_RetireEarlierVersions` runs the
  `ollama_managed_files.ps1` `retire_versions` action only when another
  version folder exists: it skips the pinned one, refuses reparse points and
  foreign names, proves each folder by its own install receipt (identities,
  sizes, hashes, file list), journals the move to its private stage so an
  interrupted removal is finished at the next start, and logs a kept folder
  with its reason for the next start to retry.
- **OLL-08.** Decision, written in `linux/ai/engine/ollama/runtime_seal.lua`:
  re-hash at every start, no change token. The size, mtime, ctime and inode
  the descriptor already fences say a file was replaced or written through the
  file API; they keep their value through a disk or filesystem fault, a write
  below the file API or through a shared mapping, and a write within a coarse
  timestamp tick, and they cannot prove the bytes came from the pinned
  archive. The install that checked the archive writes the seal (every file's
  SHA-256 and the archive digest) in the release folder, beside the tree the
  descriptor fences; each later start hashes the files in a `sha256sum` child
  under the start budget (a few seconds) and starts only a matching tree
  (`runtime_repair.lua` `verify` stage, before the network and service). A tree
  that does not match, or has no seal (installed before seals existed), is
  never started and is removed, so the next download installs it again from
  the archive: those installs pay one more download.
- **OLL-09.** `manager_ollama.lua` arms `TimerScheduler.after` with the shared
  ceiling once the `ollama rm` task starts, stops the task when it fires and
  shows `ollama.delete_reason_timeout` (21 locales); an answered delete cancels
  it. The raw CLI output in a failure notice is unchanged.
- **OLL-12.** Retired with its generator `tools/codegen/codegen-ollama-release.cjs`
  and its `generators.cjs` entry; the pin parity test refuses its return.
- **OLL-10.** The rule is the shared local-model policy's: `load_failed` in
  `_shared/ai/engine/ollama/local_model_policy.lua` (macOS and Linux) and its
  AHK port `LLM_LocalModelLoadFailed`, an answer of status 400 or more whose
  body holds « unable to load model » without case; the three replay the
  `load_failures` vectors of `local_model_presence.json`. Windows hands the
  warmup body to `LLM_OllamaRepairModel`, which pulls through the managed flow
  (`PullModel` with `Repair`, no download consent: the model was consented to
  when installed) and warms it again once pulled. Linux returns the policy's
  `load_failure` from `api_ollama.warmup`; `local_servers/warmup.lua` ends the
  chain and calls its `repair` port, `prediction/engine.lua` `repair_model`,
  which notifies and runs `download_model`. Each model is repaired once per
  session on Windows and Linux; a model that still fails is reported by the
  ordinary retries. macOS reads the same rule, so a reworded casing repairs too.
- **OLL-11.** `llm_menu` has an « Ollama d’Ergopti » group
  (`llm_ollama_runtime`, rows in `llm_ollama_runtime_rows`): install, start,
  repair, delete the selected model, uninstall. Install is greyed once the
  managed runtime is installed and the others until it is
  (`llm_ollama_absent`, `llm_ollama_installed`). Each row runs the owner that
  already did it: Windows `LLM_Menu_BootstrapOllama` (start and repair: the
  bootstrap re-verifies every receipt and installs a version folder again) and
  `_LLM_Menu_PromptDeleteCachedModel`; macOS `runtime_install_offer.select_ollama`,
  `deps_checker.check_and_install_deps` and the page's delete; Linux
  `engine.enable` (runtime_repair) and the page's `delete_model`. The
  uninstall asks first, then whether the downloaded models go too, and runs
  the sequence `_shared/ai/engine/ollama/runtime_uninstall.lua` (macOS and
  Linux; AHK port `windows/ai/engine/ollama/runtime_uninstall.ahk`), replayed
  by the three from `ollama_uninstall_vectors.json`: refused while a download
  or an install runs; the models first, through the running daemon; then the
  daemon stops (Windows `LLM_Deps_Cancel`, macOS `retire_owned_server`, Linux
  `stop_runtime`); then the files (Windows the managed root, its `models`
  folder kept unless removed, refused when a link sits below it; macOS
  `ollama-native-http/` through `rm -R`; Linux `runtimes/ollama/` through
  `runtime_retention.remove`). The first refusal ends it and names its step in
  one of four messages, 21 locales. macOS and Linux keep their models in
  Ollama's own store, outside the folders Ergopti owns, so only the model step
  deletes them there. No migration or compatibility path: nothing had an
  uninstall to stay compatible with.
- **OLL-13.** `process_port` and `owned_process` expose the running child's pid,
  which leads its detached process group. Before the start, a listener on the
  owned port refuses it (`runtime_port_occupied`). A version answer counts only
  when every socket listening on the port is held by that group
  (`linux/ai/engine/ollama/listener_owner.lua`, from `/proc/net/tcp`, `tcp6`
  and `/proc/<pid>/fd`) and names the pinned version; a foreign answer is not
  readiness, and the owned daemon answering another version is stopped.

## Open

- **OLL-04 (medium, macOS and Linux; the message on the three):** only
  Windows checks free space, before the download (the archive size,
  `ollama_managed_acquisition.ps1`) and before extraction (the expanded size,
  `ollama_managed_files.ps1`). macOS and Linux start a 174 MB or 1.4 GB
  download with no check. No OS has a localized disk-full message: Windows
  throws English text that ends as `ollama.runtime_repair_failed`, and a
  pull's `no_space` class shows the generic pull failure on the three.
  Follow-up: one shared free-space rule (archive plus expanded size) and an
  `ollama.no_space` message.
- **OLL-05 (medium, macOS; the three):** the install's network and checksum
  failures are not told apart. macOS maps `OLLAMA_ERROR_NETWORK` and
  `OLLAMA_ERROR_CHECKSUM` to `ollama.error_network` and
  `ollama.error_checksum` (`deps_checker.lua`), but no production script
  prints either marker, only tests do: every installer failure exits 78 and
  shows `ollama.error_runtime_refused` (« send the diagnostics report »), a
  network outage included. Windows and Linux show
  `ollama.runtime_repair_failed` for every class.
- **OLL-06 (low; field):** the readiness bound and cadence differ. macOS
  bounds the daemon's readiness by the 30 s admission budget
  (`bootstrap_retry.json`, through `managed_ollama_hint.py`
  `canonical_budgets`); Windows and Linux by what is left of the 30 min
  install budget. Windows polls its child's listener every 50 ms (a literal
  in `ollama-runtime-launch.ps1`), Linux sends one HTTP probe every
  `ollama_deps_poll_ms` = 3 s, and macOS waits for an event. A daemon that
  hangs before it binds is reported after 30 s on macOS and up to 30 min on
  the two others. One bound needs the cold start measured on a quiet PC
  first (field checks below).

Native receiving, in `TODO-tests-windows.md` and `TODO-tests-linux.md`: the
owned daemon's cold start measured on a quiet PC (OLL-06), and on Windows a
model pull longer than 30 minutes, at install and from the menu (OLL-02).

## Proof

Commits `d90f2d99c5` (OLL-01), `25c0951e90` (OLL-02) and `ecdfb93d03`
(OLL-03).

Follow-up on `7b7e0eec1f`: commits `4f4c2d003e` (OLL-10), `f06a0a95e1` and
`a33a9fb6cf` (the Linux behavior owner re-pinned after review: only the warmup
gained its `repair` port) and `3b0cee1a77` (OLL-11). Fakes only: no Ollama
installed, started, stopped or removed; the Windows file step runs on a scratch
folder under `A_Temp`.

- **Red on the old code.** Linux: with the `7b7e0eec1f` `api_ollama.lua`,
  `warmup.lua` and `engine.lua` over the new policy, the 4 `(oll-10)` cases
  fail (no load failure reaches the chain, no repair port, no
  `repair_model`). macOS: with the `7b7e0eec1f` `manager_ollama.lua`, the
  repair of a capitalized « Unable to load model » fails (a case-sensitive
  search); the case that must not repair passes, as it should. Windows: on the
  old files the `(oll-10)` cases call `LLM_LocalModelLoadFailed`, a
  three-argument `_LLM_Ollama_OnWarmupDone` and a four-argument `PullModel`,
  none of which exist. The `(oll-11)` cases need modules, rows and locale keys
  the old tree does not have.
- **Green on the new code.** Windows through
  `ahk-parallel.cjs --fresh --wait=300`: `oll-1` 15 of 15 (the OLL-10 and
  OLL-11 cases), `ollama` 548 of 548, `managed bootstrap` 84 of 84,
  `llm menu` 32 of 32, `llm-menu-layout-shared` 13 of 13 (its inventory now
  seven rows, five groups). Linux (LuaJIT under WSL, from an archived copy,
  `DISPLAY` and `WAYLAND_DISPLAY` unset): `oll-10` 4, `oll-11` 14,
  `linux-model-warmup` 10. macOS (Lua 5.4 under WSL): `oll-10` 10, `oll-11`
  15, `test_llm_menu_layout_shared` 9, `test_every_submenu_populated` 20,
  `test_requirement_descendant_pause_join` 37, `test_transaction_real_sources`
  42, `ollama-loadability` 3 and `ollama-ready-toast` 3.
- **Gates.** The Menus suite lot, `test-menu-no-duplicate-actions`,
  `test-linux-feature-parity` (after regenerating the parity table: six new
  rows, supported on the three), `check_locales.py`,
  `test-locale-catalogue-complete`, `test-french-punctuation`,
  `test-i18n-referenced-keys-resolve`, `test-shared-literal-inventory` (the
  shared `delete_each` keeps the Lua-function count at its baseline),
  `test-owned-runtimes-inventory`, `test-owned-runtimes-doc`,
  `test-no-pinned-source-reads*.cjs`, `test-config-key-literals`,
  `test-timings-registry-liveness`, `test-ahk-encoding`,
  `lint-conventions.js --fail-on-violations` and the formatter. Four Menus
  gates (`test-menu-parity`, `test-menu-category-coverage`,
  `test-menu-action-handler-bijection` on `reading_font` and
  `reading_spacing`, `test-menu-manifest-keys-have-readers`) fail on
  `7b7e0eec1f` with the same output with and without this change; applied on
  the later `origin/dev`, where they are fixed, the last three pass with the
  new rows. The 10 `model browser` startup-owner cases fail with the
  unchanged `7b7e0eec1f` browser too: their child script includes no file
  this change touches.
- **Not run here.** `npm run test:js` and `verify-change` (they refuse this
  checkout's Node pin), the complete Lua suites, and a live check on each OS:
  the tray rows, the two questions and an uninstall that keeps and one that
  deletes the models.

Follow-up on `db0de8ff62`: commits `2d6d3030dd` (OLL-12), `88e4c60295`
(OLL-09), `592e62be63` (OLL-07 Windows) and `68b2c41e0f` (OLL-07 Linux,
OLL-08, OLL-13). Fakes only: no Ollama installed, no model downloaded.

- **Red on the old code.** Linux: with the `db0de8ff62` `runtime_repair.lua`,
  `runtime_composition.lua`, `runtime_factory.lua`, `installed_runtime.lua`,
  `process_port.lua` and `owned_process.lua`, 17 of the 44 `oll-` cases fail
  (no verify stage or port, no pid, a foreign or mismatched answer taken for
  readiness, nothing retired); the 27 others test the new modules or what the
  old code already did. macOS: both `(oll-09)` cases fail on the old
  `manager_ollama.lua` (no ceiling armed). Windows: 3 of the 5 `(oll-07)` AHK
  cases fail on the old production files (the 2 « retires nothing » cases
  pass, as they should) and 3 of the 4 new PowerShell cases fail on the old
  helper. `test-ollama-release-pin-parity.cjs` fails while the projection
  exists.
- **Green on the new code.** Linux (LuaJIT under WSL, from an archived copy,
  `DISPLAY` and `WAYLAND_DISPLAY` unset): the 44 `oll-` cases, the 592 cases
  matching `llama` (1 failure: the root-only `shared-loader-source … eacces`
  case, red on `dev` too), 13 `running proof` cases, and the `repair` and
  `acqui` selections, whose only failures read layout data outside the
  archived copy. The complete Linux suite could not finish: the WSL service
  dropped its client several times during the run. macOS (Lua 5.4 under WSL):
  the `menu_llm` group, 1,798 passed. Windows: 83 of 83 `managed bootstrap`
  cases, 538 of 538 `ollama` cases, 87 of 87 `locale` cases through
  `ahk-parallel.cjs --fresh`, and 39 of 39 in `test_ollama_install_files.ps1`.
- **Gates.** `test-ollama-release-pin-parity.cjs`,
  `test-owned-runtimes-inventory.cjs`, `test-owned-runtimes-doc.cjs`,
  `test-shared-literal-inventory.cjs`, `test-timings-registry-liveness.cjs`,
  `test-no-pinned-source-reads-linux.cjs` and `-lua.cjs`,
  `test-managed-ollama-no-cloud.cjs`, `test-generator-output-ownership.cjs`,
  `test-linux-feature-parity.cjs` (after regenerating the parity table, whose
  macOS owner count moved by one), `check_locales.py`,
  `lint-conventions.js --fail-on-violations` and the formatter.
  `test-no-pinned-source-reads.cjs` reports 171 pinned AHK reads over a
  baseline of 170, already red on `db0de8ff62`; `test-managed-ollama-protocol.cjs`
  needs `pwsh`, absent here.

- **Red on the old code.** The new Linux cases, run against the `8e8f5485ce`
  `model_download.lua`: `ollama-pull-error-vectors` fails (`error_class` is
  nil) and the first two `ollama-digest-mismatch` cases fail (one dispatch,
  then a generic message); `another pull error is not retried` and
  `ollama-model-pull-ceiling` pass, as they should, since Linux was the
  reference for both. The new Windows cases, run against the `8e8f5485ce`
  `managed_bootstrap.ahk`, fail 3 of 78: the install budget ends the first-model
  pull at 9,001 ms of the fixture's clock, a menu pull ends at the install
  budget, and the plan reads no pull ceiling.
- **Green on the new code.** Linux (LuaJIT under WSL, from an archived copy
  of the tree, `DISPLAY` and `WAYLAND_DISPLAY` unset): every case of
  `test_model_download.lua`, and the `modules` group with 5,940 passed. Its 5
  failures are the `shared-loader-source … eacces` cases, which cannot make a
  read fail as root under WSL and fail the same way on `dev`. Windows: 78 of
  78 `managed bootstrap` cases through
  `node tools/test/ahk-parallel.cjs --fresh --only="managed bootstrap" --wait=300`.
- **Gates.** `test-timings-registry-liveness.cjs`,
  `test-linux-feature-parity.cjs`, `test-owned-runtimes-inventory.cjs`,
  `test-owned-runtimes-doc.cjs`, `test-shared-literal-inventory.cjs` (its
  `windows.limit` count, 185 over a baseline of 184, was already red on
  `dev` before this campaign), `lint-conventions.js --fail-on-violations`
  and the formatter.
- **Not run here.** The macOS Lua and Python suites (on macOS only a comment
  changed, and its worker's table is pinned by the Windows case),
  `npm run test:js` and `verify-change` (they refuse this checkout's Node
  pin).

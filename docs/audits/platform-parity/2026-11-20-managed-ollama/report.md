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
  listener event (`managed_ollama_serve.py`). Linux: see OLL-13.
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

| Id     | OS      | Sequence                                                       | Reference                                                                                                                                         | Before                                                                                                                                                                                                                                                                                                    | Regression                                                                                                                                                                        |
| ------ | ------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OLL-01 | Linux   | Pull a model whose layer fails Ollama's digest check           | Windows `_PullResult` and `_MenuPulled`, macOS `manager_ollama.lua`: one more pull, since Ollama removed the layer, then `ollama.digest_mismatch` | Linux failed at once with the generic `menu.llm.download_failed`; the class vocabulary existed on Windows and macOS only, as two copies                                                                                                                                                                   | `ollama-pull-error-vectors` and three `ollama-digest-mismatch` cases (Linux); the corpus and the shared data file in `the pull output classes are the macOS vocabulary` (Windows) |
| OLL-02 | Windows | Pull a large model on a slow line, at install or from the menu | Linux: a pull has its own ceiling (24 h); macOS: no ceiling, a stall bound                                                                        | The first-model pull ran under the install budget (`dependency_bootstrap_timeout_ms`, 30 min from the start, the 1.47 GB runtime download included) and a menu pull under the same 30 min: both failed mid-download with « Local Ollama could not be prepared »                                           | `the first model pull has its own ceiling…`, `the pull ceiling comes from the timing registry` and the re-pinned menu pull deadline cases; `ollama-model-pull-ceiling` (Linux)    |
| OLL-03 | docs    | Read the owners that the registry and the inventories name     | The code                                                                                                                                          | `ollama_deps_poll_ms` named a Windows `ollama_deps_checker.ahk` 3000 ms timer, which no longer exists (Linux owns it); stale names in `constants.toml`, `owned_runtimes.json`, `owned-runtimes.md` (a winget path long gone) and the macOS memory (an earlier owned runtime is now replaced, not refused) | Documentation                                                                                                                                                                     |

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
- **OLL-07 (low, Windows and Linux):** a new pin installs beside the old
  version and nothing removes the old one (Windows `managed_bootstrap.ahk`
  « Keeps installed versions », Linux `install_resolver.lua`): each update
  leaves about 1.4 GB behind. macOS exchanges an intact earlier install for
  the new one (`earlier_owned_install`).
- **OLL-08 (low, Linux):** an installed runtime is admitted again by its
  metadata (inode, size, mtime, ctime; `installed_runtime.lua`) and never
  re-hashed; Windows re-hashes every file before reuse and macOS the binary.
  It needs a decision, written in the module: hashing 1.4 GB at each start
  against the metadata proof.
- **OLL-09 (low, macOS):** « Delete this model from cache » runs `ollama rm`
  (`manager_ollama.lua`) without the `ollama_delete_timeout_ms` ceiling and
  puts the CLI's raw output in the notice; Windows and Linux send
  `DELETE /api/delete` under that ceiling.
- **OLL-10 (low, Windows and Linux):** macOS pulls a model that fails to load
  once more (`ollama.model_repair`, `manager_ollama.lua`); the two others
  only report the failure.
- **OLL-11 (coverage):** the Ollama lifecycle actions (install, start,
  repair, delete a model) are not menu-manifest rows, so the
  [platform parity table](../../../platform-parity-table.md) cannot gate
  them; its one Ollama row, `llm_install_warning`, has a justified reason on
  macOS and Linux. No OS uninstalls the managed runtime, and only Linux says
  so (`linux/uninstall.sh`).
- **OLL-12 (low, macOS):** `macos/ai/engine/ollama/ollama-release.sh` is
  generated (`tools/codegen/codegen-ollama-release.cjs`) and read by nothing;
  its header says the size « only drives the download progress bar », while
  the three refuse a wrong size. Retire it through its generator.
- **OLL-13 (low, Linux):** readiness is a `GET /api/version` answer with any
  version (`enable_admission_core.lua` `M.receipt`) while the owned service
  process is alive (`runtime_repair.lua` `service_live`). Linux does not
  refuse a listener already on 11435 before the start, check that the
  answering socket is its child's, or compare the version with the pin,
  which Windows does (`_VersionReceived`). A foreign server on 11435 can
  answer the first probe before the owned daemon fails to bind.

Native receiving, in `TODO-tests-windows.md` and `TODO-tests-linux.md`: the
owned daemon's cold start measured on a quiet PC (OLL-06), and on Windows a
model pull longer than 30 minutes, at install and from the menu (OLL-02).

## Proof

Commits `d90f2d99c5` (OLL-01), `25c0951e90` (OLL-02) and `ecdfb93d03`
(OLL-03).

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

# Linux audit atomic commits

This human-readable catalogue covers the 30 atomic fixes and test repairs.
Upstream merge commits are excluded. The machine-readable metadata is in
[fix-catalogue.json](fix-catalogue.json). Overall qualification and outstanding
items are in [README.md](README.md).

Evidence member paths below refer to files extracted from
[evidence.tar.gz](evidence.tar.gz), with original provenance and hashes in
[evidence-manifest.json](evidence-manifest.json). They do not depend on the
execution container. Test-file links use the exact public Git commit; a test
repair may reuse an existing guard rather than add a second test.

## 1. test(linux): discover native source trees without LuaFileSystem

Commit: [`c110df89a4bc9de2d3fc4a085ec1382aeb7d7336`](https://github.com/adrienm7/ergopti/commit/c110df89a4bc9de2d3fc4a085ec1382aeb7d7336).
Committed: 2026-10-27T06:40:34+01:00 (Europe/Paris).

**Bug:** Native source discovery dropped POSIX backslashes and LF without LuaFileSystem.

**Root cause:** Line-oriented find and separator rewriting treated opaque filenames as text.

**Proof and regression:** Ordinary/backslash/LF real trees with and without lfs; complete native inventory and manifest.

**Regression test files:**

- [tools/test/test-bash-resolution.cjs](https://github.com/adrienm7/ergopti/blob/c110df89a4bc9de2d3fc4a085ec1382aeb7d7336/tools/test/test-bash-resolution.cjs)

**OS scope:** Common Bash fixture; Linux POSIX execution, Windows canonical conversion retained.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/common-ci113/report.json`.

## 2. fix(linux): retain watcher ownership through runtime cleanup

Commit: [`4f7f3ca6c8cae064bd1ac571aadf132dd62be9f5`](https://github.com/adrienm7/ergopti/commit/4f7f3ca6c8cae064bd1ac571aadf132dd62be9f5).
Committed: 2026-10-27T06:40:35+01:00 (Europe/Paris).

**Bug:** Runtime shutdown claimed completion with two watcher handles still open after a pump error.

**Root cause:** Main dropped the watcher reference before native close acknowledgment.

**Proof and regression:** Six stop return/exception cases retain ownership until native retirement and handle drain.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/run_watcher_runtime_retirement.lua](https://github.com/adrienm7/ergopti/blob/4f7f3ca6c8cae064bd1ac571aadf132dd62be9f5/static/ergopti_plus/linux/tests/hardware/run_watcher_runtime_retirement.lua)
- [static/ergopti_plus/linux/tests/unit/infra/lifecycle/test_runtime_guard.lua](https://github.com/adrienm7/ergopti/blob/4f7f3ca6c8cae064bd1ac571aadf132dd62be9f5/static/ergopti_plus/linux/tests/unit/infra/lifecycle/test_runtime_guard.lua)

**OS scope:** Linux runtime and watcher lifecycle only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/runtime-watcher-retirement/report.json`, `evidence/rebase-D-85c1859/report.json`.

## 3. test(linux): use the canonical system capture clock origin

Commit: [`5385e896fe152304e53cdf540913e878501024f9`](https://github.com/adrienm7/ergopti/commit/5385e896fe152304e53cdf540913e878501024f9).
Committed: 2026-10-27T06:40:35+01:00 (Europe/Paris).

**Bug:** A fixture turned a 120000 ms capture into 119999 ms in SQLite.

**Root cause:** A fabricated fractional monotonic origin violated the canonical Calendar contract.

**Proof and regression:** Use Calendar.capture().mono_ms; preserve native duration and existing assertions.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/run_system_event_capture.lua](https://github.com/adrienm7/ergopti/blob/5385e896fe152304e53cdf540913e878501024f9/static/ergopti_plus/linux/tests/hardware/run_system_event_capture.lua)
- [static/ergopti_plus/linux/tests/hardware/run_system_event_capture_origin.lua](https://github.com/adrienm7/ergopti/blob/5385e896fe152304e53cdf540913e878501024f9/static/ergopti_plus/linux/tests/hardware/run_system_event_capture_origin.lua)
- [static/ergopti_plus/linux/tests/unit/modules/keystats/storage/test_sqlite_first_open.lua](https://github.com/adrienm7/ergopti/blob/5385e896fe152304e53cdf540913e878501024f9/static/ergopti_plus/linux/tests/unit/modules/keystats/storage/test_sqlite_first_open.lua)

**OS scope:** Linux capture and SQLite fixtures only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/system-capture-origin/report.json`.

## 4. fix(linux): require successful logger probe allocation

Commit: [`31c063fc73f587a71c4cc0bfa5547ed2acd7db27`](https://github.com/adrienm7/ergopti/commit/31c063fc73f587a71c4cc0bfa5547ed2acd7db27).
Committed: 2026-10-27T06:40:35+01:00 (Europe/Paris).

**Bug:** A failed mktemp probe could write or remove a foreign file or symlink.

**Root cause:** Output was accepted as exclusive ownership without checking allocation success.

**Proof and regression:** Real exit-73 child leaves foreign file/symlink intact; successful real allocation is the positive control.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/test_logger_probe_exit.py](https://github.com/adrienm7/ergopti/blob/31c063fc73f587a71c4cc0bfa5547ed2acd7db27/static/ergopti_plus/linux/tests/hardware/test_logger_probe_exit.py)
- [static/ergopti_plus/linux/tests/unit/infra/logger/test_logger_sink.lua](https://github.com/adrienm7/ergopti/blob/31c063fc73f587a71c4cc0bfa5547ed2acd7db27/static/ergopti_plus/linux/tests/unit/infra/logger/test_logger_sink.lua)

**OS scope:** Linux logger allocation only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/logger-probe-exit/report.json`.

## 5. fix(linux): derive locale availability from native files

Commit: [`3d1a82dfdccab1ec63863fbcc83f1d555c0893ff`](https://github.com/adrienm7/ergopti/commit/3d1a82dfdccab1ec63863fbcc83f1d555c0893ff).
Committed: 2026-10-27T06:40:35+01:00 (Europe/Paris).

**Bug:** Locale discovery admitted directories, invented LF-delimited languages and partial catalogues.

**Root cause:** Unchecked shell output substituted for native file evidence.

**Proof and regression:** Real file enumeration, observation refusal, LF names and file-type controls.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/test_i18n_catalog.py](https://github.com/adrienm7/ergopti/blob/3d1a82dfdccab1ec63863fbcc83f1d555c0893ff/static/ergopti_plus/linux/tests/hardware/test_i18n_catalog.py)
- [static/ergopti_plus/linux/tests/unit/infra/i18n/test_i18n_persistence.lua](https://github.com/adrienm7/ergopti/blob/3d1a82dfdccab1ec63863fbcc83f1d555c0893ff/static/ergopti_plus/linux/tests/unit/infra/i18n/test_i18n_persistence.lua)

**OS scope:** Linux runtime locale catalogue only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/i18n-catalog-exit/report.json`.

## 6. fix(linux): restore startup preferences after publication failures

Commit: [`bad7d74317990e89c3afea002549fb8ff1bd4d9f`](https://github.com/adrienm7/ergopti/commit/bad7d74317990e89c3afea002549fb8ff1bd4d9f).
Committed: 2026-10-27T06:40:35+01:00 (Europe/Paris).

**Bug:** A failed startup publication could leave preferences changed.

**Root cause:** Publication preceded admission and rollback did not restore late refusals.

**Proof and regression:** 15 source/mode/publication/service-order/recovery scenarios, reconciled with dev i18n.

**Regression test files:**

- [tools/test/no-hardcoded-ui-strings-baseline.json](https://github.com/adrienm7/ergopti/blob/bad7d74317990e89c3afea002549fb8ff1bd4d9f/tools/test/no-hardcoded-ui-strings-baseline.json)
- [tools/test/test-linux-start-at-login.cjs](https://github.com/adrienm7/ergopti/blob/bad7d74317990e89c3afea002549fb8ff1bd4d9f/tools/test/test-linux-start-at-login.cjs)

**OS scope:** Linux installation and start_at_login only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/packaging-readonly-review/report.json`.

## 7. test(linux): preserve rejected native fixture diagnostics

Commit: [`034e4973696b4aa7dfa625152f18c50536c2896c`](https://github.com/adrienm7/ergopti/commit/034e4973696b4aa7dfa625152f18c50536c2896c).
Committed: 2026-10-27T06:40:35+01:00 (Europe/Paris).

**Bug:** Native PAC failure diagnostics could disappear before an assertion returned.

**Root cause:** Evidence was emitted after assertions instead of before propagating failure.

**Proof and regression:** Real exit-73 and ENOBUFS children retain complete stdout/stderr.

**Regression test files:**

- [tools/test/test-native-pac-source-contract.cjs](https://github.com/adrienm7/ergopti/blob/034e4973696b4aa7dfa625152f18c50536c2896c/tools/test/test-native-pac-source-contract.cjs)

**OS scope:** Common native PAC fixture executed on Linux; no native Mac/Windows claim.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/xkb-negative-control/report.json`.

## 8. test(linux): isolate missing native XKB includes

Commit: [`f6bd75fcd2173a70e1b8b091c063348e14680c8e`](https://github.com/adrienm7/ergopti/commit/f6bd75fcd2173a70e1b8b091c063348e14680c8e).
Committed: 2026-10-27T06:41:19+01:00 (Europe/Paris).

**Bug:** The missing-XKB-data negative control failed on newer libxkbcommon.

**Root cause:** A self-contained keymap needed no include; compiled search paths invalidated the premise.

**Proof and regression:** Unique genuinely required include omitted then restored alone; native 1.7/1.13 and positives preserved.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/test_xkb_native_data.py](https://github.com/adrienm7/ergopti/blob/f6bd75fcd2173a70e1b8b091c063348e14680c8e/static/ergopti_plus/linux/tests/hardware/test_xkb_native_data.py)
- [static/ergopti_plus/linux/tests/hardware/test_xkb_source_exit.py](https://github.com/adrienm7/ergopti/blob/f6bd75fcd2173a70e1b8b091c063348e14680c8e/static/ergopti_plus/linux/tests/hardware/test_xkb_source_exit.py)
- [static/ergopti_plus/linux/tests/unit/adapters/layout/test_keyboard_layout_sources.lua](https://github.com/adrienm7/ergopti/blob/f6bd75fcd2173a70e1b8b091c063348e14680c8e/static/ergopti_plus/linux/tests/unit/adapters/layout/test_keyboard_layout_sources.lua)

**OS scope:** Linux XKB data and distro controls only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/xkb-negative-control/report.json`.

## 9. test(linux): retain private native network failure evidence

Commit: [`269ae28451c3bbe2441c236d589ca3708f93a88d`](https://github.com/adrienm7/ergopti/commit/269ae28451c3bbe2441c236d589ca3708f93a88d).
Committed: 2026-10-27T06:41:20+01:00 (Europe/Paris).

**Bug:** Native network failures lost status, signal, PID, errors and captured bytes.

**Root cause:** The gate replaced child receipts with a fixed generic message.

**Proof and regression:** Seven actual controls: exit73, SIGTERM, ENOBUFS, ENOENT, false receipt, empty buffer and umask.

**Regression test files:**

- [tools/test/run-linux-network-runtime.cjs](https://github.com/adrienm7/ergopti/blob/269ae28451c3bbe2441c236d589ca3708f93a88d/tools/test/run-linux-network-runtime.cjs)
- [tools/test/test-linux-network-runtime-registration.cjs](https://github.com/adrienm7/ergopti/blob/269ae28451c3bbe2441c236d589ca3708f93a88d/tools/test/test-linux-network-runtime-registration.cjs)

**OS scope:** Linux native network evidence only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/network-runtime-diagnostics-fix/report.json`.

## 10. test(linux): stage native proxy policy before schema admission

Commit: [`469dd7e8d1e5853a2f5a8fb445be930c47d0db92`](https://github.com/adrienm7/ergopti/commit/469dd7e8d1e5853a2f5a8fb445be930c47d0db92).
Committed: 2026-10-27T06:41:20+01:00 (Europe/Paris).

**Bug:** The schema-absence control failed at an unrelated prerequisite.

**Root cause:** The fixture omitted the canonical proxy policy before schema/backend admission.

**Proof and regression:** Real policy absence followed by canonical copy reaches the original backend refusal; four native groups retained.

**Regression test files:**

- [tools/test/test-linux-network-runtime.cjs](https://github.com/adrienm7/ergopti/blob/469dd7e8d1e5853a2f5a8fb445be930c47d0db92/tools/test/test-linux-network-runtime.cjs)

**OS scope:** Linux native network fixture only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/rebase-D-85c1859/report.json`, `evidence/network-runtime-diagnostics-fix/report.json`.

## 11. test(linux): preserve native paths across Bash fixture boundaries

Commit: [`4a0ded6869281587d98a1160af006446294c90d6`](https://github.com/adrienm7/ergopti/commit/4a0ded6869281587d98a1160af006446294c90d6).
Committed: 2026-10-27T06:41:20+01:00 (Europe/Paris).

**Bug:** Ten Bash fixture callers corrupted valid POSIX paths.

**Root cause:** Callers duplicated conversion and rewrote backslashes before real producers.

**Proof and regression:** Old-red/new-green ordinary/backslash/LF paths, canonical Bash owner and original assertions.

**Regression test files:**

- [tools/test/fixtures/linux-native-bin-parents.py](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/fixtures/linux-native-bin-parents.py)
- [tools/test/test-bash-resolution.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-bash-resolution.cjs)
- [tools/test/test-linux-canonical-pack-upgrade.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-canonical-pack-upgrade.cjs)
- [tools/test/test-linux-install-layout-registry.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-install-layout-registry.cjs)
- [tools/test/test-linux-launcher-deps.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-launcher-deps.cjs)
- [tools/test/test-linux-network-runtime.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-network-runtime.cjs)
- [tools/test/test-linux-package-setup.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-package-setup.cjs)
- [tools/test/test-linux-portable-network-runtime.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-portable-network-runtime.cjs)
- [tools/test/test-linux-source-toolchain.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-source-toolchain.cjs)
- [tools/test/test-linux-tracked-copy.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-tracked-copy.cjs)
- [tools/test/test-linux-tray-icon-assets.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-tray-icon-assets.cjs)
- [tools/test/test-linux-uninstall-sandbox.cjs](https://github.com/adrienm7/ergopti/blob/4a0ded6869281587d98a1160af006446294c90d6/tools/test/test-linux-uninstall-sandbox.cjs)

**OS scope:** Common path boundary; POSIX bytes and Windows conversion each retain their native contract.

**Evidence:** `evidence/audit-master-report.json`, `evidence/posix-bash-path-sibling-inventory/report.json`.

## 12. fix(linux): preserve native paths when copying tar payloads

Commit: [`ad48b02839496bcb2010a1c9cb849725021fda8a`](https://github.com/adrienm7/ergopti/commit/ad48b02839496bcb2010a1c9cb849725021fda8a).
Committed: 2026-10-27T06:41:20+01:00 (Europe/Paris).

**Bug:** Tar payload copying failed on backslash paths and could proceed after archive refusal.

**Root cause:** GNU tar interpreted backslashes in -C and the live wrapper did not enforce the pipeline receipt.

**Proof and regression:** Native chdir before tar; creation/extraction/redirection refusals stop before install; genuine payload witnesses.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/run_updater_live.sh](https://github.com/adrienm7/ergopti/blob/ad48b02839496bcb2010a1c9cb849725021fda8a/static/ergopti_plus/linux/tests/hardware/run_updater_live.sh)

**OS scope:** Linux payload copy and live wrapper only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/posix-bash-path-sibling-inventory/report.json`.

## 13. fix(linux): restore owned files after failed uninstall

Commit: [`7aa55a1e2d7b2ebc0a5ab04a7bd6ad621032547f`](https://github.com/adrienm7/ergopti/commit/7aa55a1e2d7b2ebc0a5ab04a7bd6ad621032547f).
Committed: 2026-10-27T06:41:20+01:00 (Europe/Paris).

**Bug:** Late uninstall refusal could remove runtime files and the uninstaller itself.

**Root cause:** Owned files were not retained through transaction completion; incomplete observation was treated as absence.

**Proof and regression:** 13 native EACCES/inaccessible-source/snapshot/restoration/retry tests using the installed worker.

**Regression test files:**

- [tools/test/linux_uninstall_transaction_test.py](https://github.com/adrienm7/ergopti/blob/7aa55a1e2d7b2ebc0a5ab04a7bd6ad621032547f/tools/test/linux_uninstall_transaction_test.py)
- [tools/test/test-linux-uninstall-sandbox.cjs](https://github.com/adrienm7/ergopti/blob/7aa55a1e2d7b2ebc0a5ab04a7bd6ad621032547f/tools/test/test-linux-uninstall-sandbox.cjs)

**OS scope:** Linux uninstaller transaction only.

**Evidence:** `evidence/audit-master-report.json`, `evidence/uninstall-retirement-retry-review/report.json`, `evidence/rebase-D-85c1859/report.json`.

## 14. test(linux): isolate instrumentation logger identities

Commit: [`c3a0f409ffb9c2672c2413995457b1af6b9d5475`](https://github.com/adrienm7/ergopti/commit/c3a0f409ffb9c2672c2413995457b1af6b9d5475).
Committed: 2026-10-28T11:54:22+01:00 (Europe/Paris).

**Bug:** Instrumentation tests depended on execution order and observed a different logger from the real guard.

**Root cause:** Three fixtures replaced logger identities without restoring private consumers.

**Proof and regression:** Original full suite 19811 pass/1 fail; three causal reproductions; seven cold/warm/exception regressions.

**Regression test files:**

- [static/ergopti_plus/linux/tests/meta/harness/test_logger_fixture_identity.lua](https://github.com/adrienm7/ergopti/blob/c3a0f409ffb9c2672c2413995457b1af6b9d5475/static/ergopti_plus/linux/tests/meta/harness/test_logger_fixture_identity.lua)
- [static/ergopti_plus/linux/tests/support/logger_fixture.lua](https://github.com/adrienm7/ergopti/blob/c3a0f409ffb9c2672c2413995457b1af6b9d5475/static/ergopti_plus/linux/tests/support/logger_fixture.lua)
- [static/ergopti_plus/linux/tests/test_manifest.lua](https://github.com/adrienm7/ergopti/blob/c3a0f409ffb9c2672c2413995457b1af6b9d5475/static/ergopti_plus/linux/tests/test_manifest.lua)
- [static/ergopti_plus/linux/tests/unit/infra/lifecycle/test_boot_profiler_summary.lua](https://github.com/adrienm7/ergopti/blob/c3a0f409ffb9c2672c2413995457b1af6b9d5475/static/ergopti_plus/linux/tests/unit/infra/lifecycle/test_boot_profiler_summary.lua)
- [static/ergopti_plus/linux/tests/unit/infra/test_perf_counters.lua](https://github.com/adrienm7/ergopti/blob/c3a0f409ffb9c2672c2413995457b1af6b9d5475/static/ergopti_plus/linux/tests/unit/infra/test_perf_counters.lua)
- [static/ergopti_plus/linux/tests/unit/infra/test_phase_stats.lua](https://github.com/adrienm7/ergopti/blob/c3a0f409ffb9c2672c2413995457b1af6b9d5475/static/ergopti_plus/linux/tests/unit/infra/test_phase_stats.lua)

**OS scope:** Linux instrumentation fixtures; production unchanged.

**Evidence:** `evidence/dev-merge-20261028/ai-config-parent-review/report.json`.

## 15. fix(linux): handle help before acquiring launcher resources

Commit: [`a40f6e93f7bfd368b4f6501076c2367b193e4ff2`](https://github.com/adrienm7/ergopti/commit/a40f6e93f7bfd368b4f6501076c2367b193e4ff2).
Committed: 2026-10-28T12:39:52+01:00 (Europe/Paris).

**Bug:** Requesting help with tray could start systemd or request privilege.

**Root cause:** Help classification occurred after service/polkit/group acquisition.

**Proof and regression:** Old launcher starts service or calls pkexec then exits78; 48 added scenarios and 12 real Bash-to-LuaJIT help paths.

**Regression test files:**

- [tools/test/test-linux-package-setup.cjs](https://github.com/adrienm7/ergopti/blob/a40f6e93f7bfd368b4f6501076c2367b193e4ff2/tools/test/test-linux-package-setup.cjs)

**OS scope:** Linux launcher only; help requires no system resource acquisition.

**Evidence:** `evidence/dev-merge-20261028/post-ddd-linux-review/report.json`.

## 16. test(linux): preserve managed Python fixture path bytes

Commit: [`eaa1337e2c27b40cc5cf23ca741a569bdf56f4ba`](https://github.com/adrienm7/ergopti/commit/eaa1337e2c27b40cc5cf23ca741a569bdf56f4ba).
Committed: 2026-10-28T12:45:14+01:00 (Europe/Paris).

**Bug:** Managed-Python fixtures rejected valid backslash paths.

**Root cause:** Three local conversions bypassed the canonical Bash path owner.

**Proof and regression:** Old real Bash exit127; 18 corrected ordinary/backslash/LF calls with architecture/refusal assertions retained.

**Regression test files:**

- [tools/test/test-managed-python-release.cjs](https://github.com/adrienm7/ergopti/blob/eaa1337e2c27b40cc5cf23ca741a569bdf56f4ba/tools/test/test-managed-python-release.cjs)

**OS scope:** Common Bash fixture; POSIX preservation and Windows conversion retained.

**Evidence:** `evidence/dev-merge-20261028/managed-python-integration-checks/report.json`.

## 17. fix(linux): propagate updater cadence scheduling refusals

Commit: [`da169ee7baa2a5db525c041e3a8a7ad8b130491e`](https://github.com/adrienm7/ergopti/commit/da169ee7baa2a5db525c041e3a8a7ad8b130491e).
Committed: 2026-10-28T12:46:35+01:00 (Europe/Paris).

**Bug:** Update cadence menus reported success after timer retirement/replacement refusal.

**Root cause:** The callback ignored stop/start receipts and duplicated cancellation already owned by start.

**Proof and regression:** Four old-red/new-green false/nil/text stop and unarmed replacement controls; durable preference receipt retained.

**Regression test files:**

- [static/ergopti_plus/linux/tests/unit/ui/menu/about/test_about_menu_channel_rows.lua](https://github.com/adrienm7/ergopti/blob/da169ee7baa2a5db525c041e3a8a7ad8b130491e/static/ergopti_plus/linux/tests/unit/ui/menu/about/test_about_menu_channel_rows.lua)

**OS scope:** Linux timer/menu owner; analogous Mac source remains an unproved candidate.

**Evidence:** `evidence/dev-merge-20261028/updater-audit/report.json`.

## 18. fix(linux): preserve source watcher path boundaries

Commit: [`1435f10cc82c44ca02aef26b6ee8354a0ef689d5`](https://github.com/adrienm7/ergopti/commit/1435f10cc82c44ca02aef26b6ee8354a0ef689d5).
Committed: 2026-10-28T12:50:27+01:00 (Europe/Paris).

**Bug:** Nested source edits did not restart a daemon under an LF-containing root.

**Root cause:** find -print and line readers split filenames and discarded child status.

**Proof and regression:** Polling and genuine inotify reproduction; nine regressions, eight old-red; Lua5.4 targeted 9/9.

**Regression test files:**

- [static/ergopti_plus/linux/tests/unit/infra/config/test_file_watchers_dev_source.lua](https://github.com/adrienm7/ergopti/blob/1435f10cc82c44ca02aef26b6ee8354a0ef689d5/static/ergopti_plus/linux/tests/unit/infra/config/test_file_watchers_dev_source.lua)

**OS scope:** Linux source watcher only.

**Evidence:** `evidence/dev-merge-20261028/runtime-audit/report.json`.

## 19. test(linux): preserve native paths across Bash fixture consumers

Commit: [`31a22b607a9ef32897e13a21e09c620c6e32262b`](https://github.com/adrienm7/ergopti/commit/31a22b607a9ef32897e13a21e09c620c6e32262b).
Committed: 2026-10-28T13:26:39+01:00 (Europe/Paris).

**Bug:** Fourteen more Common fixtures corrupted POSIX path bytes.

**Root cause:** Local Bash conversion also confused the native path grammars consumed by Node, CPython and Lua.

**Proof and regression:** 14 actual targets: old ordinary passes/backslash fails; all28 corrected paths pass, physical guards and Windows/POSIX boundary models.

**Regression test files:**

- [tools/test/test-app-cloner-generated-literals.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-app-cloner-generated-literals.cjs)
- [tools/test/test-app-cloner-shortcut-maximize.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-app-cloner-shortcut-maximize.cjs)
- [tools/test/test-automation-query-ci-publisher.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-automation-query-ci-publisher.cjs)
- [tools/test/test-bash-resolution.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-bash-resolution.cjs)
- [tools/test/test-layouts-defaults-single-source.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-layouts-defaults-single-source.cjs)
- [tools/test/test-macos-keyboard-layout-bundle.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-macos-keyboard-layout-bundle.cjs)
- [tools/test/test-macos-launcher-universal.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-macos-launcher-universal.cjs)
- [tools/test/test-macos-remap-launchagent.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-macos-remap-launchagent.cjs)
- [tools/test/test-macos-sparkle-disarmed-bundles.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-macos-sparkle-disarmed-bundles.cjs)
- [tools/test/test-macos-sparkle-feed.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-macos-sparkle-feed.cjs)
- [tools/test/test-macos-stable-signing-identity.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-macos-stable-signing-identity.cjs)
- [tools/test/test-ollama-bootstrap-network-hardening.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-ollama-bootstrap-network-hardening.cjs)
- [tools/test/test-opensuse-ci-origin.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-opensuse-ci-origin.cjs)
- [tools/test/test-opensuse-first-install-tooling.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-opensuse-first-install-tooling.cjs)
- [tools/test/test-swift-xctest-evidence.cjs](https://github.com/adrienm7/ergopti/blob/31a22b607a9ef32897e13a21e09c620c6e32262b/tools/test/test-swift-xctest-evidence.cjs)

**OS scope:** Common fixtures; Windows grammar modeled, no native Windows/Mac run claimed.

**Evidence:** `evidence/path-class-remaining8-20261028/class-report.json`.

## 20. fix(linux): preserve native digest fixture root paths

Commit: [`de95505f346667dcf06f18f00ec08ad4185f3fdd`](https://github.com/adrienm7/ergopti/commit/de95505f346667dcf06f18f00ec08ad4185f3fdd).
Committed: 2026-10-28T13:44:02+01:00 (Europe/Paris).

**Bug:** The native digest helper failed standalone and on valid backslash checkouts.

**Root cause:** It normalized POSIX root bytes and relied on caller LUA_PATH to hide missing bootstrap.

**Proof and regression:** Old standalone red; canonical bootstrap; three real ordinary/backslash/LF roots before12 unchanged native NIST/retirement controls,29 contract/model controls.

**Regression test files:**

- [static/ergopti_plus/linux/tests/hardware/run_fd_sha256_native.lua](https://github.com/adrienm7/ergopti/blob/de95505f346667dcf06f18f00ec08ad4185f3fdd/static/ergopti_plus/linux/tests/hardware/run_fd_sha256_native.lua)
- [tools/test/run-linux-fd-sha256-native.cjs](https://github.com/adrienm7/ergopti/blob/de95505f346667dcf06f18f00ec08ad4185f3fdd/tools/test/run-linux-fd-sha256-native.cjs)

**OS scope:** Linux native digest helper only.

**Evidence:** `evidence/dev-merge-20261028/native-helper-path-audit/report.json`.

## 21. chore(macos): clarify layout field probe comments

Commit: [`7c3b188d71bceb44a101989fd1c3a82249d29a92`](https://github.com/adrienm7/ergopti/commit/7c3b188d71bceb44a101989fd1c3a82249d29a92).
Committed: 2026-10-28T15:01:41+01:00 (Europe/Paris).

**Bug:** Four valid Mac probe comments failed the Common plan-reference guard.

**Root cause:** Opaque P0/P5/P10 labels resembled forbidden planning references.

**Proof and regression:** Unchanged guard old-red/new-green; comments-only edit and80 layout/install Lua cases.

**Regression test files:**

- [static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_layout_install_transaction.lua](https://github.com/adrienm7/ergopti/blob/7c3b188d71bceb44a101989fd1c3a82249d29a92/static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_layout_install_transaction.lua)
- [static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_layout_registry.lua](https://github.com/adrienm7/ergopti/blob/7c3b188d71bceb44a101989fd1c3a82249d29a92/static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_layout_registry.lua)

**OS scope:** Mac comments scanned by Common; no product behavior changed.

**Evidence:** `evidence/dev-merge-20261028/common-comments-complete/report.json`.

## 22. refactor(macos): share sorted pending shortcut keys

Commit: [`8047bd4aae5aa179cfe236966d0400b603b1922a`](https://github.com/adrienm7/ergopti/commit/8047bd4aae5aa179cfe236966d0400b603b1922a).
Committed: 2026-10-28T15:06:44+01:00 (Europe/Paris).

**Bug:** Two shortcut retry owners failed the Common single-use helper gate.

**Root cause:** Each duplicated pairs-plus-sort despite importing TableUtil.

**Proof and regression:** Unchanged gate old-red/new-green;8192 differential comparisons and6+3+18 owner cases plus8 helper contracts.

**Regression tests:** No new test file is claimed for this atomic commit.
The existing guard or runner described above supplies its regression proof.

**OS scope:** Mac call sites only; shared helper already used by Linux unchanged.

**Evidence:** `evidence/dev-merge-20261028/shared-helper-integration/report.json`.

## 23. test(linux): separate Arch daemon and help launch contracts

Commit: [`43ef681018f2813878616182649b1d00624f60b8`](https://github.com/adrienm7/ergopti/commit/43ef681018f2813878616182649b1d00624f60b8).
Committed: 2026-10-28T15:10:48+01:00 (Europe/Paris).

**Bug:** The Arch fixture demanded daemon side effects while asking only for help.

**Root cause:** It conflated pure help with real startup and left three relocation shell boundaries unquoted.

**Proof and regression:** Old ordinary3/backslash4 failures; old launcher fails new help assertion;20 corrected executions and12 packaged help paths.

**Regression test files:**

- [tools/test/test-linux-arch-package.cjs](https://github.com/adrienm7/ergopti/blob/43ef681018f2813878616182649b1d00624f60b8/tools/test/test-linux-arch-package.cjs)

**OS scope:** Linux Arch install/launcher fixture, no real pacman or keyboard claim.

**Evidence:** `evidence/dev-merge-20261028/arch-help-fixture/report.json`.

## 24. fix(timings): centralize input-source refresh waits

Commit: [`58cee83b629416a77cc9343382bf68270da6e32e`](https://github.com/adrienm7/ergopti/commit/58cee83b629416a77cc9343382bf68270da6e32e).
Committed: 2026-10-28T15:14:39+01:00 (Europe/Paris).

**Bug:** Two literal TIS refresh waits failed the Common timer gate.

**Root cause:** The Python worker duplicated a duration rather than accepting the shared timing registry.

**Proof and regression:** Unchanged gate catches both literals; new argv assertion red on old worker; exact0.3s retained; Lua receipt and19 Python models.

**Regression test files:**

- [static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_input_sources_bounded_mutations.lua](https://github.com/adrienm7/ergopti/blob/58cee83b629416a77cc9343382bf68270da6e32e/static/ergopti_plus/macos/tests/unit/modules/keymap/layout/test_input_sources_bounded_mutations.lua)
- [tools/test/fixtures/input-source-confirm-refresh.py](https://github.com/adrienm7/ergopti/blob/58cee83b629416a77cc9343382bf68270da6e32e/tools/test/fixtures/input-source-confirm-refresh.py)
- [tools/test/test-input-source-python-supervisor.cjs](https://github.com/adrienm7/ergopti/blob/58cee83b629416a77cc9343382bf68270da6e32e/tools/test/test-input-source-python-supervisor.cjs)

**OS scope:** Only Mac loads Carbon; Common registry checks apply across hosts; no threshold raised.

**Evidence:** `evidence/dev-merge-20261028/tis-refresh-timing/report.json`.

## 25. test(linux): keep malformed onboarding labels valid UTF-8

Commit: [`c8469be95413cea2e43132a29adff76b9ef6e36c`](https://github.com/adrienm7/ergopti/commit/c8469be95413cea2e43132a29adff76b9ef6e36c).
Committed: 2026-10-28T15:37:19+01:00 (Europe/Paris).

**Bug:** Malformed onboarding subjects leaked invalid UTF-8 through their diagnostic names.

**Root cause:** LuaJIT percent-q preserved invalid bytes in timing labels; an initial pclose check also missed late failure.

**Proof and regression:** Old output fails strict UTF-8;20 cases/825 frames pass; genuine825-frame child exiting73 is rejected.

**Regression test files:**

- [static/ergopti_plus/linux/tests/meta/harness/test_runner_integrity.lua](https://github.com/adrienm7/ergopti/blob/c8469be95413cea2e43132a29adff76b9ef6e36c/static/ergopti_plus/linux/tests/meta/harness/test_runner_integrity.lua)
- [static/ergopti_plus/linux/tests/unit/ui/editors/test_ui_bridge_handlers_onboarding.lua](https://github.com/adrienm7/ergopti/blob/c8469be95413cea2e43132a29adff76b9ef6e36c/static/ergopti_plus/linux/tests/unit/ui/editors/test_ui_bridge_handlers_onboarding.lua)

**OS scope:** Linux tests only; eight malformed test subjects and assertion bodies retained.

**Evidence:** `evidence/dev-merge-20261028/onboarding-timing-utf8/checked-fix-report.json`.

## 26. test(menu): follow the enabled layout confirmation owner

Commit: [`d216ef460479a3289f023d119b43906ff9659a3e`](https://github.com/adrienm7/ergopti/commit/d216ef460479a3289f023d119b43906ff9659a3e).
Committed: 2026-10-28T16:00:43+01:00 (Europe/Paris).

**Bug:** Two Common menu guards rejected the current valid enabled-layout confirmation owner.

**Root cause:** The finite publication model still expected confirm_source_async instead of confirm_enabled_async.

**Proof and regression:** Both actual old guards red/new green; seven source mutations per guard plus14 existing negatives retained.

**Regression test files:**

- [tools/test/test-menu-action-handler-bijection.cjs](https://github.com/adrienm7/ergopti/blob/d216ef460479a3289f023d119b43906ff9659a3e/tools/test/test-menu-action-handler-bijection.cjs)
- [tools/test/test-menu-category-coverage.cjs](https://github.com/adrienm7/ergopti/blob/d216ef460479a3289f023d119b43906ff9659a3e/tools/test/test-menu-category-coverage.cjs)

**OS scope:** Common tests inspect all drivers; production unchanged.

**Evidence:** `evidence/dev-merge-20261028/menu-confirmation-integration/report.json`.

## 27. fix(test): reject malformed UTF-8 timing records

Commit: [`b726aab8f76da1579411c6987c18862f0731f699`](https://github.com/adrienm7/ergopti/commit/b726aab8f76da1579411c6987c18862f0731f699).
Committed: 2026-10-28T17:20:38+01:00 (Europe/Paris).

**Bug:** Malformed UTF-8 lua_timing records were silently counted as valid machine receipts.

**Root cause:** StringDecoder/file UTF-8 decoding replaced bytes before JSON admission.

**Proof and regression:** Original825-frame capture now admits823 and reports2 errors/exit1; identical50 vectors expose25 old violations and zero new;469 assertions.

**Regression test files:**

- [tools/test/report.cjs](https://github.com/adrienm7/ergopti/blob/b726aab8f76da1579411c6987c18862f0731f699/tools/test/report.cjs)
- [tools/test/test-report.cjs](https://github.com/adrienm7/ergopti/blob/b726aab8f76da1579411c6987c18862f0731f699/tools/test/test-report.cjs)

**OS scope:** Shared Lua reporter; actual Windows TAP, human bytes and stderr contract retained.

**Evidence:** `evidence/reporter-utf8-scope-review-20261028/final-report.json`.

## 28. fix(linux): isolate private runner fixture output

Commit: [`13f2d9b584a40f0ba226eb973a3a885cd639f245`](https://github.com/adrienm7/ergopti/commit/13f2d9b584a40f0ba226eb973a3a885cd639f245).
Committed: 2026-10-28T18:02:00+01:00 (Europe/Paris).

**Bug:** A deliberately failing private helper contaminated successful canonical runner output.

**Root cause:** Fresh private helper shared global print, leaking FAIL and nested headers despite a green outer tally.

**Proof and regression:** Old real runner0 but receiver1; three canonical controls/seven child-receiver observations including genuine Lua5.4+compiled luv only; real outer failure remains fatal.

**Regression test files:**

- [static/ergopti_plus/linux/tests/meta/harness/test_runner_integrity.lua](https://github.com/adrienm7/ergopti/blob/13f2d9b584a40f0ba226eb973a3a885cd639f245/static/ergopti_plus/linux/tests/meta/harness/test_runner_integrity.lua)
- [tools/test/features/test-infrastructure/suite.json](https://github.com/adrienm7/ergopti/blob/13f2d9b584a40f0ba226eb973a3a885cd639f245/tools/test/features/test-infrastructure/suite.json)
- [tools/test/test-linux-runner-private-output.cjs](https://github.com/adrienm7/ergopti/blob/13f2d9b584a40f0ba226eb973a3a885cd639f245/tools/test/test-linux-runner-private-output.cjs)

**OS scope:** Linux fixture only; no parser or product semantics changed.

**Evidence:** `evidence/dev-merge-20261028/linux-runner-private-output/report.json`.

## 29. test(linux): expose the runner output gate through npm

Commit: [`5d0bf5fbb44f972b40494d99672b2c34a32e3f3f`](https://github.com/adrienm7/ergopti/commit/5d0bf5fbb44f972b40494d99672b2c34a32e3f3f).
Committed: 2026-10-28T18:47:23+01:00 (Europe/Paris).

**Bug:** The new runner-output gate was registered without its mandatory npm alias.

**Root cause:** Suite registration and package script parity diverged.

**Proof and regression:** Existing parity gate old1/new0; seven targeted gates and actual npm execution of three controls pass.

**Regression tests:** No new test file is claimed for this atomic commit.
The existing guard or runner described above supplies its regression proof.

**OS scope:** Linux npm gate entry only.

**Evidence:** `evidence/dev-merge-20261028/npm-runner-output-alias/root-checks/report.json`.

## 30. test(menu): follow the generated gesture information command

Commit: [`b49ab43c850467e914ddebf0b8259c57b3590451`](https://github.com/adrienm7/ergopti/commit/b49ab43c850467e914ddebf0b8259c57b3590451).
Committed: 2026-10-28T21:23:13+01:00 (Europe/Paris).

**Bug:** The Common recommended-defaults guard rejected the valid Windows gesture information registration inherited from dev.

**Root cause:** A source-pattern assertion still required the retired raw string after production moved to the existing generated MenuCommand.GESTURE_RECOMMENDED_INFO constant.

**Proof and regression:** Actual whole Common check487 and direct old-source target failed with registration assertion/exit1. The one-line expected registration pattern now follows the generated constant; the unchanged target passes. Seven targeted verification commands and normal hooks passed. No defaults, gesture processing, thresholds or production code changed.

**Regression test files:**

- [tools/test/test-recommended-defaults-rule.cjs](https://github.com/adrienm7/ergopti/blob/b49ab43c850467e914ddebf0b8259c57b3590451/tools/test/test-recommended-defaults-rule.cjs)

**OS scope:** Common source-contract test for Windows registration; Mac and Linux registration assertions retained. No native Windows execution claimed.

**Evidence:** `evidence/dev-merge-20261028/closeout-20261028/stale-menu-guard/final-receipt.json`.

<!-- docs/handovers/2026-10-06-group6-recovery/README.md -->

# Group 6 restored-container checkpoint

The container was restored on 2026-10-06 without losing its checkout or private
preparations. This checkpoint preserves finite source packets outside that
machine. It is inactive evidence, not an installed feature. TODO 36 and TODO 62,
and transversal acceptance items 16/38, remain open. Delta updates 22 remain
withdrawn. Do not work on the website or change another group's TODO block.

The feature branch is `feat/release-network`. Commit `bfcd1abf4` adds retained
descriptor sealing, native SHA-256 and mandatory native evidence registration;
`a10a7e388` merges actual current dev `b6fa826fb`, preserving the upstream native
metrics token-transport correction. Both commits were pushed immediately and
their exact-SHA automatic workflows checked and cancelled when present.

## Recover source, not historical process authority

[manifest.json](manifest.json) pins all six archives. Verify their hashes before
extracting into a new owned directory. Inspect each packet's inventory, source
review, preservation proof and preimages against the actual current checkout.
Reconstruct sources and rebind the documented commands; never adopt an old PID,
descriptor, timer, native binary or private namespace as current authority.
Historical absolute paths in receipts identify provenance and need relocation.
Do not extract over the checkout or apply all patches blindly.

| Archive                                                                | Preserved scope                                                                                                    | Qualification limit                                                                           |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| [archive-and-sparkle.tar.gz](archive-and-sparkle.tar.gz)               | C publication source, tar feeder revision 4, Sparkle startup diagnostics revision 2                                | Scoped C/feeder receipts are included; no complete installed updater or macOS startup success |
| [validation-tools.tar.gz](validation-tools.tar.gz)                     | Authenticated modern/legacy curl setup, retained native GET runner and unchanged native30/output18 oracles         | Setup/build, sixteen runner models and final native30/18 remain unexecuted                    |
| [updater-sources.tar.gz](updater-sources.tar.gz)                       | Production updater revision 3, installer revision 5, private registry revision 6, preimages and 96 normal controls | Original source status was unexecuted; use the separate correction and actual receipts below  |
| [updater-control-correction.tar.gz](updater-control-correction.tar.gz) | Missing outer delimiter correction, peer review and frozen launch plan 2                                           | Exactly one `end)` added to each raw/normal control; production and all assertions unchanged  |
| [updater-model-receipts.tar.gz](updater-model-receipts.tar.gz)         | Byte-exact actual candidate/predecessor/final receipts and source binding inventory                                | Controlled models and legacy filesystem filters; no full native composition                   |
| [network-sources.tar.gz](network-sources.tar.gz)                       | Prepared headers, live queue, typed body cancellation, output-hop and fixture335 corrections                       | Models and earlier native failures remain distinct from unexecuted final compositions         |

The original updater qualifier executed zero cases and failed one module import;
all 192 intended ABI cases were unexecuted. The corrected immutable candidate
then passed all 96 controls on LuaJIT and all 96 on Lua5.4, without skips. Its
unchanged predecessor replay reports 152 passed/40 failed across both ABIs.
The eight old pre-reader cases per ABI primarily encounter a missing cleanup
operation contract; do not describe them as eight independently exercised
lifetime regressions. These controlled-port results do not qualify native C,
download-to-install composition or actual rollback. Readable command/count/log-hash
projections are [candidate](updater-model-candidate.json) and
[predecessor](updater-model-predecessor.json). Original receipt bytes are preserved
in [updater-model-receipts.tar.gz](updater-model-receipts.tar.gz).
Five unchanged legacy installer filters also pass on each ABI, including
tar-root upgrade, backup/ownership and all fourteen rollback stages. The first
package-owned JIT attempt failed its canonical temporary-directory write with
EROFS; only that failed filter and the unexecuted Lua5.4 filters were rerun with
approved sandbox escalation. All source inventories remained unchanged; see
[the final status](updater-model-final-status.json). These controlled filesystem
cases do not replace the native downloaded archive/install composition.

## Executed checks and outstanding work

The descriptor prerequisite passed 125 literal model controls on each Lua ABI
and twelve actual LuaJIT/libuv/OpenSSL NIST/FD controls. Final source verification
passed 368 JS checks, formatting of 220 selected files, twelve actual native
digest controls, 14731 macOS Lua stub tests and 9241 Linux tests. The actual
native package prerequisite previously passed 70 controls, two kernel controls
and seven original staged AppDir groups. Those AppDir results do not prove a
full-format AppImage or Flatpak install, enterprise PAC/authentication or TLS
deployment. An official appimagetool asset has been hash-verified locally but
has not yet been executed or activated.

The private C publication cohort has scoped native and shared-clock receipts.
The final tar feeder passes 30 model controls and eight actual native controls
under its sole guardian, with pending/rescue zero. Its earlier first native
attempt failed and has unknown retirement; later success does not establish
the cause of that failure. Lower-kernel and installed-package coverage remain
unexecuted.

The prepared native GET cohort passed 25 preflight controls and failed seven of
fourteen body-retirement controls. Its source-reviewed follow-up preserves every
original predicate, adds a probe during physical close-pending, and narrows the
native cancellation refusal without changing generic failed-signal behavior.
Its first model replay passes the fourteen new and 34 unchanged controls on each
ABI, but the preserved LuaJIT suite reports 527 passed/1 failed: a newly named
local refusal value shadows the canonical refusal constructor in cancellation.
This is a source defect. A rename-only correction is being reviewed; the
remaining Lua5.4, causal and native replays were not executed after that failure.
The corrected native replay, output-hop composition, fixture335 causal replay
and four historical body-pipe failures remain Linux work. They are not Windows
or macOS device-only limitations. Run local JS/model/native cohorts serially.

Next, qualify the reviewed network follow-up, genuine dual-curl setup and
retained runner; apply only qualified compositions with current preimages.
Compile the C helper through its owner, wire normal registrations and package
pipelines, then exercise the complete native checksum/archive/hash/publication/
tar/install/rollback chain. Preserve original independent corpora. Full AppImage
and Flatpak delivery needs actual tools, sandbox capabilities and installed
runtime/session receipts. Never substitute stubs or regenerate expected values.

Sparkle diagnostics remain source-reviewed and unexecuted. They reuse the
already owned output descriptor, emit only fixed startup milestones and keep
the original failure, deadlines, exit and retirement assertions. The native
startup cause remains unknown. Qualify the 34 Python controls and CJS additions,
then use the macOS runner for actual Swift/startup evidence. Windows-specific
device/network work remains in the existing
[Windows handover](../2026-10-04-group6-windows/README.md).

## CI and final integration

Manual three-OS run [37447724532](https://github.com/adrienm7/ergopti/actions/runs/37447724532)
tested exact `c2cefeff0`: core, Windows unit/E2E/package, macOS stub unit/E2E and
tooltip passed; Linux unit failed native metrics, macOS package failed Swift
launcher tests, and Windows install failed programmable hotstrings. Downstream
Linux and macOS package/install jobs were skipped. Release was skipped. The
upstream metrics fixture correction is now merged; its selected format/JS gates
pass, but an old failed run cannot credit the new source.

Manual run [37454156645](https://github.com/adrienm7/ergopti/actions/runs/37454156645)
tests exact `a10a7e3888037eb7c1fb30ffa066800d8473ff7a` with `os_lanes=all` on the
owned `codex/ci-release-network` branch. Its terminal verdict is not yet recorded
at this checkpoint. Let it finish. `ci.yml` restricts Release / Publish to push
events; manual dispatch does not publish. Check the actual tested SHA and every
unit/E2E/package/install verdict, including skipped and unexecuted subjects.

Fetch dev explicitly when its tracking ref is not updated by the checkout's
limited fetch refspec:

```sh
git fetch origin refs/heads/dev:refs/remotes/origin/dev
```

Final integration alone requires the remote `codex/ci-lock` reservation. Create
an empty commit from current dev naming group 6, feature branch and candidate SHA;
an existing lock blocks reservation and only its owner removes it. While holding
the lock, use only `codex/ci-validation`, merge without squash/no-ff, push dev,
cancel exact-SHA automatic workflows and let integrated manual CI finish.
Preserve foreign work. Delete only the owned feature/lock after its commits are
confirmed in origin/dev and the agreed final qualification is complete.

The restored environment's reusable installation/start instructions are saved
in the cloud configuration. Its reaper uses actual PPID/birth and pidfd receipts
rather than the unavailable optional proc task/children file; four controlled
checks pass, including a foreign sibling sentinel. Residual-child cleanup never
earns a green test. Saving configuration is not publication or proof of another
fresh task. The added GitHub log host `productionresultssa19.blob.core.windows.net`
is saved but remains blocked in the current runtime until settings are applied.

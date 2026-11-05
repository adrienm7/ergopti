# MRT-002 countercheck supplement

2026-11-05. Original source remains pinned at `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. This supplement narrows the original immutable report; it does not overwrite it.

**Confirmed conclusion: “Refused command watchdog leaves pending installation without its local deadline.”** The claim of a permanently unsettled installation is **conditional on the child failing to complete**. Timer refusal does not suppress ShellRunner's eventual completion callback, and no unconditional permanent hang was demonstrated. Keep the scheduler ERROR explicitly loud; do not call this a silent G2 failure.

## Actual completion path: positive executed control

`probes/countercheck-mrt002.lua` loads the actual `adapters.shell_runner`, `adapters.timer_scheduler`, `adapters.field_check_ports`, `platform.remap.runtime_install` and real task-environment sanitizer. Only native `hs.task` and `hs.timer` boundaries and unrelated diagnostic/file adapters are recording fixtures. Unlike the original missing-callback stub, it retains the exact `hs.task.new` completion callback and fires it later.

After actual native deadline constructor refusal, two install callers are waiting: one task, zero callbacks, zero signals, one scheduler ERROR. Natural completion of the role with its closed success line starts the actual activation step. Natural completion of that second task settles both waiters successfully, releases all ShellRunner GC pins and ignores a duplicate old callback. This proves eventual callback admission is intact.

Retained output (`logs/countercheck-mrt002.log`):

```text
BEFORE native completion: actual ShellRunner+TimerScheduler+FieldCheckPorts+Install, tasks=1 answers=0 signals=0 scheduler_errors=1
AFTER natural role and activation completion: answers=2 success=true live_task_pins=0; duplicate answer ignored
PASS timer refusal removes local deadline but does not prevent eventual actual ShellRunner callback settlement
```

Replay:

```sh
/workspace/scratch/parity-toolchain/ci-bin/lua /workspace/scratch/parity-native-ui/macos-runtime/probes/countercheck-mrt002.lua /workspace/worktrees/parity-2026-11-05/macos-runtime
```

`field_check_ports.lua:55–57` installs the actual completion closure before start. After successful start, timer refusal at `:63–67` causes no terminate call or immediate failure, but also does not close that completion path. `shell_runner.lua:635–660` delivers a committed completion once; `:670–697` retires the exact task, calls the completion consumer and notifies physical-settlement observers. The positive control exercises this join, not only text presence.

## Native first-install lifetime: source conclusions and limits

No independent **aggregate repository-owned 900-second lifetime guarantee** was found in this reachable native role:

- `launcher/Sources/ErgoptiPlus/main.swift:1318–1325`: the install role runs on a background queue while the main thread repeatedly waits 20ms and pumps its runloop. The repeated 20ms wait is not an aggregate deadline; normal GUI lifecycle bootstrap is below this role dispatch.
- `OwnedRuntimeInstallMainOperation.swift:113–120`: `NSAppleScript.executeAndReturnError` waits for the administrator shell; the script has `with administrator privileges`, with no explicit repository timeout clause or independent timeout worker.
- The same file `:44–55` includes synchronous `cp`, `shasum`, `pkgutil --check-signature` and `/usr/sbin/installer -pkg … -target /`; those commands have no explicit per-command budget in this program. `:105–108` then synchronously waits for `--owned-install-first` via shell command substitution and stage cleanup. These are genuine external/native operations, not a Lua counter waiting for its own callback. The absence of a local budget establishes exposure to a slow/pending operation; it does **not** measure any one taking over 900 seconds or prove Apple's framework cannot independently error/complete.
- `tools/build/owned-runtime-installer/InstallerMain.swift:18–25` dispatches the live role to `OwnedRuntimeIdleServiceEntry.runFirstInstallation`. `OwnedRuntimeIdleServiceEntry.swift:20–53` queues a worker and uses `done.wait()` without a timeout. That worker performs actual publication, native filesystem/signature checks, Core provision and VirtualHID provision.
- There **are genuine narrower native bounds**: `OwnedRuntimeCoreLaunchctl.swift:20` assigns a three-second timeout per launchctl command; its exact-child TERM/KILL/reap path retains native debt. `OwnedRuntimeCoreProvisionOwner.swift:174–180` bounds repeated Core observation by a monotonic ten-second deadline. They refute a blanket claim that the native helper contains no bounded work, but neither bounds the earlier authorization, package installation, publication, all filesystem/security calls or whole helper transaction.

No administrator prompt, package, native signing operation or live macOS service was invoked. Therefore this supplement does not prove a real installed native role exceeding 900 seconds, does not prove infinite authorization/installer wait, and does not override an OS-specific completion/timeout behavior not qualified here.

The defensible finding is the missing **local command watchdog commitment check**, plus conditional waiter retention for as long as the child remains pending. The original “permanently unsettled” title/absolute statements must not be carried into the integration summary or manifest unqualified. Existing user consent/native continuation/cancellation policy is separate (MRT-005 remains excluded).

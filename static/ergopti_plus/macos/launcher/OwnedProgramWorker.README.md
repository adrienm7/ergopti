# Native private user-program worker

The existing signed launcher accepts `--owned-program-worker` before AppKit,
preferences or Sparkle startup. This role owns a signed native guardian; the
guardian creates a separate session and a suspended direct user leader in a
new process group. User stdin/stdout/stderr are `/dev/null` before activation.
No user stream reaches Hammerspoon's task pipes.

## Request and receipts

The first stdin frame is newline-terminated UTF-8 JSON with exactly these keys:

```json
{
	"version": 1,
	"executable": "/absolute/program",
	"arguments": ["literal argument", ""],
	"source_path": "/absolute/config.toml",
	"source_sha256": "64 lowercase hexadecimal characters"
}
```

`arguments` is the argument vector after argv[0]. Paths are absolute; NUL is
refused. JSON escapes literal newlines and preserves Unicode bytes. The SHA-256
preimage is the exact acknowledged canonical source, including a BOM if present.
Symlinked source paths are supported: native descriptor/target identity is
checked after streaming the raw source hash. This final source fence does not
claim an atomic lock against external writers.

The initial request bound is `6 * sysconf(ARG_MAX) + 6 * PATH_MAX + 512` bytes:
JSON can expand one ASCII control byte to six bytes; the source path and fixed
schema add bounded overhead. Decoded argv remains subject to the real native
spawn limit, including its inherited environment. The worker buffers neither
an unlimited request nor the complete config file.

After `V1 HELD`, the current exact Lua owner rechecks source/binding, generation,
pause and admission before sending `ACTIVATE\n`. The guardian performs its own
source hash and executable identity fence before SIGCONT. Duplicate/out-of-order
activation refuses execution and orders cleanup. `CANCEL\n` is valid while held
or active. **Keep stdin open while the action runs. EOF orders cancellation.**

Stdout contains only fixed ASCII receipts; stderr is empty:

| Receipt               | Meaning                                                             |
| --------------------- | ------------------------------------------------------------------- |
| `V1 HELD`             | Exact user leader is created, monitored and suspended               |
| `V1 ACTIVE`           | Admission passed and the exact leader was resumed                   |
| `V1 PENDING <errno>`  | Cleanup or native observation remains pending; emitted at most once |
| `V1 RETIRED <status>` | Original group is non-live and exact leader has been reaped         |
| `V1 REFUSED <errno>`  | Constructor refused before any user child existed                   |

Numeric fields are canonical nonnegative decimal. Status is a native normal
exit code, or `128 + signal`, within 0..255. Errno is a closed numeric error;
`PENDING 0` is valid. Receipts include no executable, argv, raw exception,
config contents, token, stdout or stderr.

A successful bridge exit additionally requires a trusted terminal receipt and
its exact native guardian child's successful wait status. The Lua adapter must
require the expected protocol sequence and terminal receipt plus bridge status;
exit code zero by itself never proves settlement. Native failure or missing/
malformed receipt retains strict ownership debt.

## Group identity and retirement

The guardian stays outside the managed process group and owns its direct leader
unreaped. The leader PID therefore remains reserved through natural leader exit,
TERM grace, group SIGKILL and native group observation. No group operation occurs
after the exact successful reap.

Group signals preserve ESRCH versus EPERM. EPERM, ECHILD, timeouts and accepted
signals are not settlement. A complete native `PROC_PGRP_ONLY` census includes
zombies; `PROC_PIDTBSDINFO` explicitly uses arg=1 to inspect them. Two matching
checked snapshots with only irreversible zombie members, together with the exact
leader's exit, permit retirement even while that held zombie still reserves the
group. Buffer saturation, status errors, changing identities or membership keep
the owner pending. Reaping succeeds only for the exact owned PID.

The TERM grace is 50 ms of observation, followed by KILL if cancellation remains
pending. It does not change the physical settlement predicate. Group KILL can
be repeated while the exact leader identity remains held. Incoming bridge EOF
lets the guardian finish cleanup independently and preserves its outgoing half
for the terminal receipt.

This native contract covers the original managed group and exact direct leader.
Processes deliberately changing session/group, including leaving and rejoining,
are outside its containment guarantee. Unexpected guardian hard kill is also
unverified: macOS provides no established kill-on-close Job Object equivalent
through these primitives. Missing proof remains debt; do not advertise full
escaped-descendant containment or automatic crash recovery.

## Native validation

`OwnedProgramWorkerTests` is discovered by the existing SwiftPM launcher test
lane and contains 14 test methods. Debug-only `--owned-program-fixture` modes
provide real native children;
release builds exclude that role. Tests assert raw Unicode/empty/literal argv,
held activation and source invalidation, held cancellation/EOF, symlink source
compatibility, constructor refusal, exact nonzero status, 64 MiB private output,
and leader-exited TERM-resistant outputting descendants. An independent actual
POSIX script runs through `/bin/sh` from a Unicode/spaced path, records literal
empty/Unicode/quote/dollar/backtick/percent arguments as NUL-separated raw bytes,
proves interpolation markers remain absent, returns status 37, and emits private
stdout/stderr sentinels that must never reach the control pipes.

Fixtures provide an independent stop file and bounded lifetime only for failed
test cleanup. They do not weaken the production retirement assertion. Failed
cleanup preserves artifacts and fails the test. These tests still require a
real macOS runner; source inspection or Linux compilation stubs are not native
runtime evidence. Real Hammerspoon adapter, packaged/signature and installation
checks remain necessary alongside the native launcher suite.

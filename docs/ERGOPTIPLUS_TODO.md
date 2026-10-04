<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-04. Latest release: v0.0.0-dev.155 (c9e4c64ab); `dev` is
ahead of it without a release (CI cancelled on purpose).
This checklist is the current handoff; older workflow task-status files are
historical evidence.
Item numbers are stable identifiers: a finished item is removed (its durable
facts go to docs/memory), and the numbers of the others never change.

## Delivery checkpoint

The overhaul is not finished. Eight reviewed integration commits ended at
`eaa06eeba`, followed by the published handoff and CI repairs. The macOS
cold-start errors were then fixed on `dev` (`d8d171fcd`, `56eeb70dc`,
`8ee659e17`) and CI published `v0.0.0-dev.144` on 2026-09-29. Two stricter
local macOS corrections followed on top of that release: gesture event-tap
acquisition deferred to explicit startup, and configuration consumers required
only after path initialization.

Work continues from a fresh clone on a Linux container. The Windows workstation
no longer holds any worktree, branch or external working directory: `D:/ewt`
was deleted after its useful content was committed here. The historical
workflow context (prompts, task status, feature map, analysis reports and
journal) is in the handoff package's `workflow-context-2026-09-24.zip`.

Delivery now supports independent feature containers. The primary group and
branch for every remaining item are recorded in
[the parallel work contract](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md),
with ready-to-copy fresh-context prompts and saved pending candidates in
[the container-stop handover](handovers/2026-10-04-parallel-containers/README.md).
Feature workers commit one coherent slice at a time, update only their assigned
items and push their `feat/*` branch immediately. One coordinator integrates
reviewed slices into `dev`, preserving concurrent workstation/Linux work, and
pushes each integration immediately. Cancel every automatic workflow triggered
by each exact pushed SHA to avoid releases. Only the coordinator moves the
single `codex/ci-validation` branch and dispatches `ci.yml` with `os_lanes` set to
the affected OSes; manual validation never publishes a release and runs to its
terminal result. Shared checks remain mandatory. Preserve unrelated changes,
stage exact paths, and never use reset, clean, stash or force-push.

Item 22 (differential updates) is withdrawn by the maintainer on 2026-10-04:
reported release downloads are below 20 MB, so the additional delta-generation,
base-selection and reconstruction/fallback paths are not justified by a measured
current benefit. Full signed/checksummed updates and rollback remain required.
This is a scope decision, not a completed delta implementation. Archive
compression (36) and managed-network downloads (62) remain in scope.

Repository hygiene is complete. The 2026-10-03 cleanup retired 131 obsolete
CI refs; a read-only 2026-10-04 inspection confirms only `main`, `dev`,
`gh-pages`, `sparkle-appcasts`, `fix/linux` and `codex/ci-validation` remotely,
and one registered main checkout. Reuse the single CI ref with distinct manual
run groups; never create `backup/*` branches. Active source, validation fixtures
and evidence remain owned work. The overnight handoff marks its former backup,
force-push and release instructions as superseded.

Historical provenance limitation: the exact uncommitted tooltip DPI-test edit
reported in `wip/win-tooltip-border-fix` is unavailable and was not recovered.
Current committed DPI geometry coverage does not establish those old bytes.
Real Windows 10/11 rendering acceptance remains in items 19 and 38.

The Windows regression backlog (former item 72) is closed: non-release CI
run [36916568697](https://github.com/adrienm7/ergopti/actions/runs/36916568697)
at `e5da10fbc` passed native unit tests, engine E2E, packaging, install/launch
and the Windows verdict. The full run passed, including the shared core,
both Lua suites and all macOS/Linux installation variants.
The next menu migrations add shared behavioral vectors to these native lanes.

The configuration no-op slice passes the shared fixtures and native Windows
tests in run 36925266946. Its three changed-file macOS fixture cases exposed
a simulated metadata copy that depended on the runner's umask; the fixture now
carries the real source metadata through that copy and passes under umask 022.
The production permission checks remain strict; repeat the non-release CI.
The rewrite wiring gate now follows the erasing-record contract introduced by
the concurrent local commits: both corrections and rewrites must identify the
deleted suffix and original span. Negative source mutations cover either guard
being removed; the registered native parser tests cover actual admission.

**Overnight session of 2026-09-29 (supersedes the "one item at a time"
instruction: the maintainer asked for maximum parallelism).** Items 5 to 13
were implemented in parallel on `wip/*` branches, adversarially reviewed, fixed
on `wip/*-fix` branches and integrated in order on the local branch
`integration-2`, then `integration-3` after a container restart; the whole
batch was published to `dev` in one release on 2026-09-30.
The maintainer demos Ergopti on 2026-09-30 in the afternoon. Read
[the overnight handoff](handovers/2026-09-29-overnight/README.md) first: it
lists every branch, the in-flight fixes, the maintainer's decisions and the
exact release procedure.

Automatic startup placement is complete: non-release run 37039552367 at
`506931224` passed every Windows/macOS/Linux unit, E2E, package, installation
and launch gate, with Release / Publish skipped. All three native menus draw
startup immediately above Uninstall from the shared declaration. Item 110 is
removed after this full checkpoint.

## Already integrated functionality

The history on `dev` contains the following substantial parts of the overhaul.
These are software implementations; final hardware verification remains below.

- Shared scrollable configuration cleanup, offered as cleanup rather than a
  startup error; valid configurable gesture parameters remain owned settings.
- Shared title composition with one product prefix and regression coverage for
  the broader window-title family; configured action values replace placeholders.
- Bundled keyboard-layout catalogue and manager on three OSes, installation
  owners, Ergo-L support, and independent base/Shift versus AltGr emulation.
  Physical magic-key completion remains in item 30.
- Manifest-driven menus, category masters and retained child choices;
  configuration schema/migration infrastructure; substantial neutral-state and
  transactional recommended/clear machinery. W1 is explicitly incomplete.
- Shared action catalogue, Unicode case/plain-paste/wrap actions and three
  configurable number-row edge keys.
- Shared navigation-layer data, generated driver projections and web editor.
- Logger repetition handling, log-directory ownership, larger centered debug
  consoles, diagnostics/error interfaces and issue-reporting improvements.
- Shared updater channels, release notes and automatic-check scheduling.
  The common update-result interface remains C4.
- Every macOS production JSON reader now uses the shared codec, preserving
  independent mutable trees and each caller's decode-error behavior. The
  direct-call ratchet retains only the adapter's implementation. Non-release
  checkpoint [37033032620](https://github.com/adrienm7/ergopti/actions/runs/37033032620)
  at `6275cac35` passed all three OS unit, E2E, packaging, installation and
  launch lanes, with Release / Publish skipped. The JSON-reader requirement
  of item 41 is complete; remaining Hammerspoon stub audits and native contract
  acceptance stay under item 16, with Karabiner publication under item 40.

## Ordered TODO

- [~] **L5.** Linux asynchronous process-group teardown: deadlines and shell
  cancellation now signal descendants even after libuv reaps their leader.
  The three native fork/pipe/process-group regressions failed before the fix
  and pass after it; portable adapter regressions cover late EOF and exactly-once
  delivery. The native harness is registered in the Linux CI lane. Windows uses
  native process handles and macOS uses Hammerspoon tasks, so neither contains
  the Linux libuv exited-leader guard. Complete three-OS CI remains pending.
  A failed shell-runner spawn now returns its native refusal without also
  invoking the completion callback, avoiding duplicate connector failure
  delivery. A real ENOENT regression and the portable allocation-cleanup case
  fail before the fix and pass after it. The process runner retains its separate
  callback-on-refusal contract; macOS task construction uses settled handles.
  The shell runner also forces teardown after SIGTERM, matching the existing
  argv runner. Native descendants that acknowledge SIGTERM-ignore readiness
  no longer outlive a deadline or cancellation; both regressions failed before
  this fix. Physical keyboard validation remains unavailable in the container.
  Both argv runners now decode libuv's separate termination-signal receipt
  through one native helper: a real SIGTERM exit reports status 143 and failure,
  rather than a manufactured successful zero. Two portable regressions and both
  native signal cases failed before the fix. Windows receives its native process
  exit status and macOS its Hammerspoon task status; neither consumes this libuv
  receipt. Native Windows/macOS suites and manual CI are deferred by request.
- [~] **L6.** Linux plain file-write receipts: `write` and `append` now require
  both a successful native write and a successful close, including buffered
  flush errors. Files are closed even when writing throws or returns an error.
  Four real `/dev/full` ENOSPC regressions failed before the fix; both regular
  file controls pass. Portable fault cases cover returned and thrown errors.
  Layout import staging already consumes this adapter's boolean receipt;
  the shared conditional TOML writer is unchanged. Windows checks its native
  byte receipt and macOS already verifies append/close and uses an atomic write
  owner. The native regression is registered for future Linux CI; manual CI and
  native Windows/macOS suites remain deferred by request.
- [~] **L7.** Linux buffered HTTP receipts: GET, POST and archive downloads
  now require curl's completed transport as well as a 2xx status. An early
  connection close with HTTP 200/curl exit 18 reports failure and withholds the
  partial body. Complete 2xx receipts no longer carry an invented HTTP error;
  real HTTP error responses retain their diagnostics. Six native loopback/curl
  regressions and six portable regressions failed before the fix. The existing
  native HTTP gate now includes buffered controls and downloads to a real file.
  Windows already admits curl responses only after exit zero; macOS consumes
  hs.http's native completion status and explicitly clears successful errors.
  Native Windows/macOS suites and manual CI remain deferred by request.
- [~] **L8.** Linux model-pull retry retirement: successful settlement now
  clears the retained retry request instead of preserving it through Lua's
  `and`/`or` fallback. Stale direct/progress callbacks cannot dispatch another
  pull; the bridge rejects a successful session before resetting its receipt,
  so WebKit still receives success after a stale message. An HTTP failure
  remains retryable. Both portable regressions and the
  native GTK/WebKit/libuv/curl reproduction failed before the fix. The native
  fixture uses an owned loopback Ollama response, not an installed model or
  physical keyboard, and is registered for future Linux CI. Windows launches
  its pull in an independent terminal; macOS uses native task and progress
  ownership rather than this retained-request expression. Native cross-OS
  validation and manual CI remain deferred by request.
- [~] **L9.** Linux deletion receipts: plain file deletion now calls the native
  removal directly and admits failed removal only on proven ENOENT. Inaccessible
  paths cannot masquerade as absent, broken links are removed, and unreadable
  files remain deletable when their parent permits unlink. Native regressions
  failed before the fix with and without optional LuaFileSystem; the ten-case
  real permissions/symlink matrix and nine portable receipt cases pass after it.
  Windows already classifies DeleteFileW receipts. macOS still has the analogous
  ambiguous existence guard before its native removal owner; removing that guard
  and reproducing denied-path/broken-link controls is a deferred native diagnosis.
  No macOS files, conditional TOML owner or manual CI were changed or executed.
- [~] **L10.** Linux timer cancellation ownership: the scheduler now retains
  every armed token strongly until firing or accepted cancellation. Dropping a
  repeating token no longer lets GC erase it from diagnostics and `cancelAll`
  while native callbacks continue running. Five real libuv/GC regressions failed
  before the fix; all seven native cases now cover cancellation, mixed ownership,
  one-shot retirement and successor isolation. Six portable cases exercise the
  same ownership and release rules. macOS already uses a strong registry and
  Windows retains tokens in its Map. Physical input is unrelated to this proof;
  native Windows/macOS suites and manual CI remain deferred by request.
- [~] **L11.** Linux file digest receipts: allow the actual filename payload in
  sha256sum stdout without expanding its diagnostic budget. Valid absolute paths
  of 958, 1106 and 3500 bytes failed before the fix. Twelve native cases now
  exercise real hashing, boundary paths, literal UTF-8/control characters, known
  SHA-256 vectors and missing/unreadable files; six portable cases also verify
  chunk accumulation, bounded stderr/excess stdout and terminal cleanup. Windows
  Get-FileHash returns the hash separately, and macOS shasum has no matching fixed
  output cap. Native cross-OS validation and manual CI remain deferred by request.
- [~] **L12.** Linux Crypto byte receipts: embedded NUL is encoded with the
  shared Base64 codec and decoded into OpenSSL stdin before hashing. Shell
  quoting alone cannot carry NUL in a C command string. Five real OpenSSL and
  five portable regressions failed before the fix; eleven shared independent
  vectors now cover NUL position, every byte, UTF-8, literal shell characters,
  trailing newlines and long input. Ordinary text retains its existing path.
  Windows CNG and macOS `sha256_bytes` already carry explicit byte lengths; the
  macOS text `sha256` shell path still has the analogous NUL boundary and needs
  a separate native reproduction. Native cross-OS suites and manual CI remain
  deferred by request; no macOS crypto owner or native gate was modified.
- [~] **L13.** Linux JSON store read receipts: start an empty store only after
  native ENOENT, and block mutations with recovery metadata after other open
  refusals. A real mode-000 storage.json was overwritten by a successful set
  before the fix. Thirteen of eighteen native cases failed before it; coverage
  includes all four mutations, inaccessible parents, non-directory ancestors,
  missing-store creation, unrelated nested values and recovery after permissions
  are repaired and ownership reloaded. Portable cases classify individual errno
  and thrown receipts. Windows uses per-key registry writes and macOS hs.settings;
  neither has this whole-file JSON load-and-replace path. No TOML owner, personal
  menu, native cross-OS suite or manual CI was changed or executed.
- [~] **L14.** Linux JSON recovery backup receipts: choose a recovery filename
  only after proven ENOENT and block recovery on other open refusals instead of
  replacing an unreadable older backup. Three actual permission regressions
  failed before the fix at backup suffixes 0, 1 and 3. The extended native store
  matrix passes 24 cases, including readable backup chains and independent
  preservation of both byte histories; four portable cases cover errno, unknown
  and thrown refusals. This fixes read-refusal classification, without claiming
  general race-free no-clobber publication or dangling-link classification.
  Windows registry and macOS hs.settings do not use this JSON backup path.
  TOML ownership, native cross-OS validation and manual CI remain untouched.
- [~] **L15.** Linux ordinary file path receipts: the five canonical methods
  reject embedded NUL before native C-string APIs can select a different prefix
  file. A real invalid delete removed the prefix file, and invalid read exposed
  its bytes. Sixteen of forty native cases failed before the fix. The matrix now
  covers NUL positions, unchanged prefix files and valid literal POSIX names;
  twenty portable cases require refusal before any native I/O. This is the Linux
  native binding guard, without changing classified/TOML extension ownership.
  Windows built-ins and macOS native paths have no explicit matching NUL guard
  at their public boundary; native reproductions and fixes are deferred to their
  owners. No native cross-OS suite or manual CI was launched.
- [~] **L16.** Linux JSON storage snapshot ownership: publish an owned snapshot
  decoded by the shared JSON codec and detach structured getter results. Caller
  mutations no longer bypass durable writes or contaminate a refused mutation's
  rollback. Six native and six portable cases failed before the fix, covering
  single/bulk sets, input/getter references and refused publication. The native
  store matrix passes 31 cases, including scalar and independent reload controls.
  Windows decodes registry values per get; macOS hs.settings serializes values
  across its native settings boundary. No new serialization policy, TOML owner,
  personal menu, native cross-OS suite or manual CI was introduced or changed.
- [~] **L17.** Linux HTTP/digest signal receipts: both remaining libuv process
  owners now use the same exit-status helper as ShellRunner and ProcessRunner.
  HTTP 200 or valid digest bytes cannot prove a successful process when its
  separate native termination signal is nonzero. Twenty native and twenty
  portable cases failed before the fix. Thirty native cases delegate unchanged
  arguments to actual curl/sha256sum, then controlled wrappers signal themselves
  or exit normally; all payloads come from the GNU tools and owned loopback HTTP.
  Four real signals, buffered/streaming HTTP, downloads and hashing are covered.
  Windows curl process status and CNG, and macOS native HTTP/task status, do not
  expose this libuv split receipt. Native cross-OS validation and manual CI remain
  deferred.
- [~] **L18.** Linux HTTP/digest descendant retirement: keep process-group
  ownership after the leader exits and classify native ESRCH as already absent.
  A common Linux libuv helper now submits graceful and forceful group retirement
  from both adapters, retaining cancellation ownership on signal refusal. Twenty
  actual descendant cases and twenty portable cases failed before the fix. The
  fifty-case native CLI matrix uses real GNU tools and controlled descendants,
  including SIGTERM resistance, and its own Linux subreaper reclaims every child.
  Windows HTTP already launches through a tree-owned job. macOS retains hs.task
  until its exact completion callback and sends only SIGTERM; descendant or
  resistant-child retirement needs a separate native reproduction before
  proposing explicit group ownership and forceful retirement. No macOS native
  owner or gate was modified; native cross-OS suites and manual CI remain deferred.
- [~] **L19.** Linux JSON store root shape: accept only a decoded JSON object,
  instead of allowing a root array to masquerade as the key-value store and lose
  its numeric entries during the next write. Four native and four portable
  cases failed before the fix. The native store matrix now passes 38 cases;
  invalid array histories are preserved byte-for-byte before a valid replacement
  is created, and object/nested-array/whitespace controls retain their values.
  Windows registry and macOS hs.settings have no application-owned JSON root
  loader. TOML owners, unknown object parameters, personal menus, native cross-OS
  suites and manual CI remain untouched.
- [~] **L20.** Linux large-input Crypto receipts: use OpenSSL 3's native byte
  API with an explicit length and retain its library handle across Lua GC.
  Five large-input native cases and nineteen portable dispatch/refusal cases
  failed before the fix. Eighteen independent SHA-256 vectors now pass on the
  host and in the nonroot Debian native container, including NUL, all byte
  values, UTF-8 and quote expansion. Eighteen portable cases retain coverage of
  the existing CLI path when the native binding is absent; this degradation is
  logged and still carries exec limits. Native refusal is never silently retried.
  Windows CNG and macOS sha256_bytes already use native byte APIs; macOS's text
  SHA-256 shell path shares the argument-size risk and needs a separate native
  reproduction. No macOS source, native cross-OS suite or manual CI was changed.
- [~] **L21.** Linux source-watch activation receipts: distinguish protected
  invocation from successful inotify registration. Native EACCES previously
  retained an inactive handle as armed; refused candidates now close immediately
  and remain outside the committed registry. Three real permission cases and
  four portable refusal cases failed before the fix. Seven native cases cover
  delivery, filtering, pending-reload cancellation and restart after permission
  repair; seven portable cases cover refused, thrown and successful receipts.
  macOS already requires the exact watcher returned by start() before committing
  activation. Windows does not use libuv fs_event_start. Only generic Linux
  activation changed; TOML persistence, personal-menu logic, native cross-OS
  suites and manual CI remain untouched.
- [~] **L22.** Linux event-loop stop ownership: explicitly request libuv to
  return after stopping this adapter's idle/periodic callbacks. Previously a
  foreign socket, inotify watch or timer kept run() blocked after stop(). Twelve
  native cases and four portable cases failed before the fix. Fourteen native
  cases now cover idle/periodic/deferred stop, restart, ordinary cleanup and
  inactive-stop isolation, preserving foreign handles for their own owner.
  Five portable cases cover stop admission and owned callback retirement. Only
  Linux owns this luv.run adapter; Windows and macOS use their host event loops.
  Shutdown owners still need their normal resource cleanup. No physical keyboard,
  native cross-OS gate or manual CI was exercised.
- [~] **L23.** Linux logger file receipts: retire a channel when native write
  or flush refuses, including buffered ENOSPC. Durability and idempotent install
  now report the surviving main handle accurately; same-directory repoint can
  reopen a repaired owner. One failed channel cannot disable stdout or the other
  file, and its diagnostic cannot recurse into the logger. Five of six native
  cases failed before the fix; fourteen portable cases fail against the prior
  production module. All six actual /dev/full, descriptor, repair and normal-file
  cases pass on the host and nonroot Debian. Windows already checks append/fence
  receipts; macOS file fan-out ignores write/flush returns and needs native
  diagnosis of this same failure class. No shared logger policy, macOS logger,
  native cross-OS gate or manual CI changed.
- [~] **L24.** Linux private screenshot path receipts: retain mktemp's complete
  literal pathname, stripping only its final protocol newline, and refuse a
  failed creation receipt. The checked runner can stage its output in the same
  selected runtime directory so an unrelated invalid TMPDIR does not override
  XDG_RUNTIME_DIR. Five actual Xvfb captures and eleven portable cases fail
  against the prior production owners. Nine virtual X11 cases now pass through
  real maim, PNG bytes, directory permissions and mktemp on host and nonroot
  Debian; fifteen portable cases cover literal paths, refusals and native argv.
  A reuse of the old checked runner also reproduced a runtime-precedence failure.
  Windows native paths and macOS native image capture do not line-parse mktemp
  paths. This is virtual graphics validation; physical screens, interactive
  regions, Wayland, native cross-OS gates and manual CI remain unexecuted.
- [~] **L25.** Linux process snapshot receipts: preserve the last successful
  process set when ps returns partial output then exits nonzero or is signalled.
  LuaJIT pclose previously returned true, synthesizing quit/relaunch events for
  an owned process that stayed alive. The existing checked runner now supplies
  the actual terminal receipt. Twelve native and eight portable cases failed
  before the fix. Fourteen native cases pass on host and nonroot Debian using
  real named processes and GNU ps through a controlled fault wrapper that omits
  one actual row; a genuine launch/quit control remains functional. macOS uses
  native application-watcher events. Windows currently accepts these callbacks
  without emitting launch/quit events, an existing capability gap deferred to
  its owner. Focus/title logic, native cross-OS gates and manual CI are untouched.
- [~] **L26.** Linux process header collision: request GNU ps comm output
  without a header instead of discarding every row named COMMAND. One actual
  named-process case and two portable cases failed before the fix. The fifteen
  native snapshot cases pass on host and nonroot Debian, including real COMMAND
  launch/quit, refusal recovery and ordinary events. Existing empty-snapshot
  and partial-failure assertions remain intact. macOS native app events have no
  textual ps header; Windows's existing launch/quit capability gap remains
  deferred. Focus/title logic and native cross-OS/manual CI are untouched.
- [~] **L27.** Linux logger probe ownership: installation and repointing now
  prove file access through their real log handles; directory preparation uses
  an exclusively-created mktemp probe and checks write, flush, close and removal.
  The fixed .write_probe previously deleted pre-existing files and symlinks and
  created dangling-link targets. Five native and eight portable cases failed
  before the fix. Thirteen native cases pass on host and nonroot Debian, including
  real read-only refusal, literal line-break paths and prior ENOSPC recovery;
  eight portable receipt cases cover every probe failure and successful cleanup.
  Windows/macOS logger owners do not use the fixed Linux probe. Shared logging
  policy, native cross-OS gates and manual CI remain unchanged or unexecuted.
- [~] **L28.** Linux SQLite write receipts: the audited stdin command now
  optionally appends the real CLI exit status; the writer requires that receipt
  as well as empty diagnostics. Five genuine silent nonzero exits were falsely
  accepted before the fix, and nineteen new portable regressions failed against
  the prior owners. Twelve native cases pass on host and nonroot Debian with
  actual schema/write/retry checks, TERM/KILL refusal, 105032-byte quote-heavy SQL
  and an unavailable TMPDIR. Reusing the generic checked runner was independently
  rejected by ARG_MAX with zero durable rows. No SQL or receipt file is staged.
  Windows/macOS writers use native SQLite result codes on their corresponding
  write paths; native cross-OS gates and manual CI remain unexecuted. Reader
  query receipts are a separate remaining diagnostic, not claimed complete here.
- [~] **L29.** Linux SQLite read receipts: migration rows, scalar lookups and
  JSON dashboard queries now require the same native terminal status as writes.
  Failed CLI output cannot become a trusted prefix of rows or a migration value.
  Seventeen native and seventeen portable refusal cases failed before the fix;
  twenty-two native cases pass on host and nonroot Debian with genuine SQLite
  data, an explicit faulty CLI wrapper, successful empty/multi-row/scalar/JSON
  controls, marker-looking user bytes and 150000-byte output. Existing projection
  assertions remain intact. Windows queries require native SQLITE_DONE; macOS
  uses native iterators but intentionally retains partial dashboard side effects
  on an exception, a distinct unvalidated source-level concern for its owner.
  No common projection policy, native cross-OS gates or manual CI was changed.
- [~] **L30.** Linux checked-shell capture diagnostics: native popen failures
  now retain the errno instead of returning/logging an error that embeds the
  entire command and caller text. Protected capture exceptions use a bounded
  diagnostic with the shared program-name resolver. Three native and six
  portable cases failed before the fix. Six native cases pass on host and
  nonroot Debian using real ARG_MAX and RLIMIT_NOFILE refusals, restored owned
  descriptors/limits and successful stdout/empty/nonzero controls. Six portable
  cases cover returned errno and thrown open/read/close receipts. Windows uses
  native Win32 error codes; macOS also logs raw protected-exception text, an
  unvalidated source-level privacy concern deferred to its native owner. Shared
  logging policy, native cross-OS gates and manual CI remain untouched.
- [~] **L31.** Linux file-existence metadata: without optional LuaFileSystem,
  use libuv stat or in-process libc F_OK; plain Lua without native bindings uses
  the POSIX shell test builtin. Unreadable files/directories and sockets were
  falsely absent; FIFO probes actually blocked until their owned child was killed
  by the test guard. Thirteen native and eleven portable cases failed before the
  fix. Twenty-one native cases pass on host and nonroot Debian using constrained C-module availability,
  real permission/symlink/FIFO/socket receipts, LuaJIT libc and actual Lua 5.4
  shell fallback without either Lua stat library; sixteen portable cases cover
  backend/refusal/quoting contracts. Windows uses native attributes; macOS normally uses hs.fs.attributes
  but its unavailable-binding fallback has the same source-level open issue,
  deferred to its owner. An initial shell-only draft failed two existing reload
  and uninstall assertions; native libc restores both without changing those
  reserved tests. Classified TOML paths, native cross-OS gates and manual CI
  remain unchanged or unexecuted.
- [~] **L32.** Linux process-name identity: preserve every byte of GNU ps's
  headerless final comm column, including leading/trailing spaces and names made
  entirely of spaces. Trimming it collapsed distinct processes and emitted the
  wrong launch/quit names. Five native and five portable cases failed before
  the fix. Twenty native cases pass on host and nonroot Debian using real
  prctl-named processes, independently checked ps bytes and separate lifetimes
  for two names differing only by spaces. Portable cases cover exact event
  payloads and independent retirement. macOS uses native application names;
  Windows' existing missing app-event producer remains deferred. Focus/window
  title code, native cross-OS gates and manual CI remain untouched or unexecuted.
- [~] **L33.** Linux desktop notification operands: terminate native
  notify-send option parsing before caller titles and bodies. Quoted option-like
  text previously suppressed notifications or changed native option values.
  Ten native and eight portable cases failed before the fix. Twelve real Dunst
  cases pass on host and nonroot Debian with private D-Bus and Xvfb, including
  literal short/long options, separators, Unicode/newlines and four severity
  controls. Native Gio history verifies exact summary/body, application,
  urgency and timeout; portable cases verify both operands follow the native
  boundary. macOS and Windows pass text to native APIs without CLI option
  parsing. This is virtual graphical validation; physical desktops, Wayland,
  native cross-OS gates and manual CI remain unexecuted. Shared notification
  policy and the twenty-one translated product catalogues are unchanged.
- [~] **L34.** Linux at-rest encryption identity fallback: use the real
  /var/lib/dbus/machine-id when /etc/machine-id is absent, empty or whitespace.
  A repository-shaped /var/infra path made encryption unavailable on otherwise
  supported systems. Five native and three portable cases failed before the
  fix. Eight native cases pass using actual read-only Docker bind mounts and an
  isolated private mount-namespace runner, with synthetic system identity data,
  real OpenSSL and an ordinary cipher user. Six portable cases cover primary
  priority, fallback, closed handles, cached derivation and fail-closed absence.
  macOS uses IOPlatformUUID and Windows uses MachineGuid; shared key/envelope
  policy is unchanged. Initial namespace setup lacked installed mount targets
  and ran no assertions; the owned container setup supplies those targets, and
  the subsequent complete before/after matrices pass. Native cross-OS gates
  and manual CI remain unexecuted.
- [~] **L35.** Linux binary at-rest plaintext: encode NUL-containing input
  with the existing shared Base64 codec and restore its bytes before native
  OpenSSL encryption. Raw heredoc NUL previously truncated the C-string command,
  while a valid envelope acknowledged permanently shortened text. Six native
  and five portable cases failed before the fix. Fourteen native cases pass
  with real OpenSSL, every byte from 0 to 255, repeated NULs, Unicode/newlines
  and a real encrypted typing batch read after SQLite close/reopen; these run
  as an ordinary user with owned synthetic identity mounts. Portable transport
  cases verify exact shared-codec roundtrip and NUL-free command input.
  macOS uses the same raw-heredoc shape, an unvalidated C-boundary concern
  deferred to its native owner; Windows' AHK StrPut boundary cannot be equated
  with a Lua binary string. No cross-OS binary hardware claim is made. Shared
  key/IV/envelope policy, native cross-OS gates and manual CI remain unchanged
  or unexecuted; no physical typing device was used.
- [~] **L36.** Linux at-rest OpenSSL exit receipts: key derivation,
  encryption and decryption require a successful terminal native receipt before
  accepting useful stdout. Per-call framing preserves binary and marker-looking
  bytes without output files or double quoting the stdin payload. Sixteen native
  and eighteen portable cases failed before the fix. Nineteen native cases pass
  on host and nonroot Debian using real OpenSSL behind an explicit fault wrapper
  that delegates unchanged argv/stdin, then exits nonzero or signals itself;
  actual SQLite rejects a failed encrypted typing batch and admits a healthy
  retry. Eight portable protocol controls cover empty/binary output, stale or
  malformed receipts, bounds and rejection before execution. A draft helper's
  captured shell owner became stale in reload fixtures; resolving that owner
  at execution fixes the failures without weakening any assertions. macOS also
  ignores synchronous command success in its shell adapter, an unvalidated
  source-level concern deferred to its native owner; Windows uses checked native
  crypto status codes. Shared key/envelope policy, native cross-OS gates and
  manual CI remain unchanged or unexecuted; no physical typing device was used.
- [~] **L37.** Linux at-rest OpenSSL pipeline receipts: supervise both native
  decoder and encryption stages instead of trusting only the last POSIX exit.
  A failed decoder could return a valid envelope containing just one original
  byte. Eight native failure guards plus the missing-supervisor capability case
  fail before the fix; all thirty native cases pass with real OpenSSL and an
  explicit failed/partial-output wrapper, ordinary users, and actual SQLite
  rejection/retry. Healthy controls retain a 90,001-byte binary plaintext and
  permit commands without external stdin to run without Bash; checked pipelines
  fail closed when their installed Bash supervisor is absent. L39 extends this
  protection to the exact-stdin producer itself. Six portable checks fail before
  the fix, then pass with the unchanged codec/ordering assertions and explicit
  checked-pipeline policy. Only the native command is quoted, preserving the
  original stdin argument budget. macOS' separate OpenSSL shell path remains an
  unvalidated source concern deferred to its native owner; Windows uses checked
  native crypto APIs. Shared key/envelope policy is unchanged. Native cross-OS
  gates, manual CI and physical typing tests remain unexecuted.
- [~] **L38.** Linux CLI SHA-256 fallback receipts: reuse the Linux checked
  OpenSSL owner for ordinary input and checked decoder pipelines. Without FFI,
  a failed primitive or partial decoder could previously admit a useful digest.
  Seventeen native and fourteen portable cases fail before the fix. Twenty-nine
  actual Lua 5.4/OpenSSL cases pass on host and nonroot Debian, with explicit
  post-calculation failure/signal adapters, independent shared byte vectors and
  a 44,000-byte repeated-quote control. Eighteen actual native FFI vectors and
  fifty-one portable adapter checks retain normal hashing and refusal semantics.
  Existing inert POSIX words and binary exact stdin retain their transport;
  scripts without external stdin avoid quoting the native command twice.
  Native byte hashing and shared digest/encoding policy are unchanged. macOS
  text hashing similarly ignores its native command success flag (unvalidated,
  deferred to the native owner); Windows checks BCrypt return codes. Native
  cross-OS gates, manual CI and physical input tests remain unexecuted.
- [~] **L39.** Linux OpenSSL exact-stdin producer receipts: supervise head
  together with every crypto consumer, refusing useful output when input delivery
  fails. A real partial producer previously acknowledged one of twenty-seven
  original bytes. Twenty native failure guards plus the missing input-supervisor
  guard and five portable controls fail before the fix. All fifty-four native
  cases pass with actual head/OpenSSL and SQLite rejection/retry, including
  partial output, exit/signal faults, literal script delimiters and shell syntax.
  Program fd 3 and data stdin remain separate, reusing shared collision/exact-body
  policy without quoting data again. A real child syscall trace confirms 42-byte
  and 90,001-byte roundtrips with no created temporary file; observed O_CREAT
  operations target only /dev/null. Default external-stdin commands now require
  the installed Bash supervisor; commands without external stdin keep their
  existing capability contract. Portable native-wire producers understand the
  separate program/data descriptors; migration and framing assertions remain
  intact. macOS' separate exact-input pipeline is an unvalidated source concern
  deferred to its native owner; Windows uses checked native crypto APIs. Native
  cross-OS gates, manual CI and physical typing tests remain unexecuted.
- [~] **L40.** Linux native spawn NUL refusal: the existing common Linux
  argv validator rejects embedded NUL in executable names and every argument,
  before libuv supplies a shorter C string to execve. Eight native and eight
  portable cases fail before the fix. Twelve actual ordinary-user cases pass
  on host and Debian with both LuaJIT and Lua 5.4, using native subprocesses,
  GNU sha256sum, loopback curl downloads and ETag files. Invalid requests create
  no child side effect, network request or shorter-path overwrite; bounded
  diagnostics identify the argument index without its bytes. Four healthy
  controls retain empty strings, literal Unicode/newline argv and filenames,
  an independent file hash and actual download. Nine portable validator cases
  cover NUL positions and representable words. One native validator serves
  ShellRunner, ProcessRunner, FileDigest and HttpClient; no domain or encoding
  policy is duplicated. macOS' source validator also lacks an explicit NUL check
  (its native task bridge remains unvalidated); Windows constructs a native
  UTF-16 command line, which cannot be equated with Lua binary strings. Matching
  bridge regressions are deferred to their native owners. Native cross-OS gates,
  manual CI and physical input tests remain unexecuted.
- [~] **L41.** Linux curl config URL NUL refusal: reject an unrepresentable
  URL before native allocation, file/network side effects or replacement of an
  active owner. Curl's stdin config parser previously accepted the shorter
  address with a genuine HTTP 200, unlike its existing header/body refusal.
  Five native and thirteen portable cases fail before the fix. Seven actual
  loopback curl cases pass on host and Debian, covering buffered GET/POST,
  streaming, protected download bytes, retained in-flight ownership, literal
  percent escapes and already-refused config header/body controls. Thirteen
  portable cases check byte positions, exact callback ownership and no resource
  allocation. The Windows curl path rejects unsafe URL scalars by source;
  macOS uses native Hammerspoon HTTP and rejects controls in redirect parsing,
  while initial native URL bridging remains unvalidated. Neither driver's native
  gate or source was changed. Technical refusal diagnostics contain no URL
  bytes. Shared encoding policy, manual CI and physical input tests remain
  unchanged or unexecuted; Linux native socket/process tests are real execution.
- [~] **L42.** Linux HTTP redirect confidentiality: native curl forwards
  custom API-key and Cookie2 headers to another origin. Disable native follow
  for credentialed GET, POST, streaming and download requests while preserving
  their original request and 302 refusal receipt. Public redirects and direct
  credentialed responses remain usable. The header inventory lives in shared
  JSON; a JS single-source guard pins the existing macOS inventory without
  changing its reserved native owner. Windows curl does not enable redirect
  following by source inspection. Twenty-eight of forty real loopback cases
  fail before the fix; the original probe observes four actual leaking header
  kinds. Portable regressions cover every sensitive header/method, casing,
  invalid policy and request ownership. Missing or malformed policy fails
  before allocating handles or replacing an active request. Credentialed
  redirect support remains deferred until explicit per-hop ownership exists.
  Native cross-OS checks, manual CI and physical keyboard tests were not run.
- [~] **L43.** Linux HTTPS redirect downgrade refusal: native curl previously
  followed HTTPS to HTTP unless callers explicitly set https_only. Restrict
  every native-followed hop from an HTTPS URL to HTTPS, including uppercase
  schemes, without requiring that opt-in or changing caller options. Five of
  twenty-one actual certificate-verifying TLS/loopback cases fail before the
  fix. Controls cover four request APIs, direct verified responses, same-origin
  and public cross-origin HTTPS redirects, certificate hostname refusal,
  HTTP-to-HTTPS upgrades and existing no-follow/https_only fences. Portable
  regressions cover methods, URL casing and unchanged public options. macOS
  explicitly refuses downgrade in its credentialed manual-hop path by source;
  its public native-follow path remains a source concern for the reserved native
  owner. Windows curl never enables native follow by source inspection. Neither
  driver's source or native gate was changed. Manual CI and physical input
  remain unexecuted; Linux uses real TLS, curl, libuv, sockets and private files.
- [~] **L44.** Linux synchronous shell C-string refusal: libc system/popen
  previously executed a shorter command when its composed script contained NUL.
  Apply the existing common execve argv validator to the implicit sh -c vector
  before execution or a test dispatcher. run, exec, exec_line, checked capture
  and both textual stdin facades now refuse without replacing retained native
  files. Unicode/newline commands and binary stdout remain valid; binary stdin
  requires an explicit byte-safe transport such as the existing crypto Base64
  path. The asynchronous argv path already refuses NUL. Native and portable
  regressions cover shortened side effects, textual heredocs, exact return
  shapes and bounded checked diagnostics. macOS forwards synchronous commands
  to Hammerspoon without a source NUL fence; its actual native bridge remains
  unvalidated and reserved. Windows uses AHK UTF-16 strings rather than Lua
  binary strings. No native cross-OS check, manual CI or physical input ran.
- [~] **L45.** Linux HTTP replacement preflight: compose and validate native
  curl config/argv before cancelling a previous owner or acquiring timers/pipes.
  Invalid ETag/download arguments previously refused only after killing a
  valid request; config-format exceptions also escaped with allocated handles.
  Nine of twelve native held-response cases fail before; all twelve now pass,
  including real ETag compare/save, valid supersession and independent owners.
  Eighteen portable cases cover invalid paths/types/formatting with and without
  an active owner, no allocation/cancellation and exact completion ownership.
  Native formatting exceptions become bounded failures without caller bytes.
  macOS prepares/cancels a generation before native dispatch, and Windows's
  synchronous HTTPPost cancels its active request before native URL/header
  validation, both source concerns reserved for their native owner. Windows's
  async curl class is a separate path. No cross-driver source, native cross-OS
  gate, physical input or manual CI was changed or exercised.
- [~] **L46.** Linux HTTP header boundary: curl decodes config escapes before
  serializing headers, so caller CR/LF previously injected additional native
  wire headers. Validate serialized names/values against the canonical shared
  forbidden-byte inventory before owner cancellation or native allocation.
  NUL is also refused during preflight; legal tabs, Unicode, punctuation,
  quotes and backslashes retain exact wire bytes. Thirty-two of thirty-six
  actual curl cases fail before and all pass after on LuaJIT/Lua 5.4. Forty-one
  portable cases cover all four methods, malformed/missing policy and retained
  ownership. The earlier native NUL control now requires synchronous header
  refusal while retaining the body refusal and zero-request assertions.
  Windows async curl source already refuses controls; its synchronous WinHTTP
  COM path and macOS native bridge require the reserved owner's native receipts.
  No reserved driver implementation/gate, physical input or manual CI ran.
- [~] **L47.** Linux literal HTTP body transport: use curl data-raw for caller
  bodies. Quoted data-binary config values still interpret leading @ as a local
  filename or stdin, sending file contents instead of the supplied body.
  Twelve of twenty-four actual buffered/streaming cases fail before and all
  pass after on LuaJIT/Lua 5.4. Exact literal @ paths, missing files, @-, empty
  bodies, Unicode, CR/LF, tabs and quote/backslash escapes retain caller bytes.
  Twelve new portable cases fail before and pass after; existing escaping and
  stdin-privacy assertions are retained with the corrected native directive.
  Actual raw-NUL body refusal remains unchanged. Windows async curl deliberately
  stages caller bytes in its private body file before using data-binary @path,
  so it does not interpret the caller's leading @. macOS passes caller bodies
  directly to its native API. Both are source parity findings, not native
  cross-OS execution. No reserved source, physical input or manual CI ran.
- [~] **L48.** Linux HTTP protocol boundary: native curl accepted file URLs,
  emitted local file bytes to streaming callbacks and created download output
  before the missing HTTP status finally reported failure. Resolve initial URL
  schemes against the canonical shared HTTP/HTTPS inventory before ownership
  changes and apply its native curl protocol fence to initial and redirect hops.
  Keep HTTPS-only narrowing, TLS verification and uppercase HTTP/HTTPS intact.
  Thirty-two of forty actual held-owner cases fail before and all pass after
  on LuaJIT/Lua 5.4; native TLS redirect controls also pass. Fifty-two portable
  cases cover all methods, exact native fences and missing/malformed policy.
  Windows async curl validates controls but lacks an initial scheme/protocol
  fence by source. macOS restricts its explicit credentialed redirect parser,
  while public Hammerspoon initial URL behavior remains native-unvalidated.
  Those reserved native owners need independent file/stream/output receipts.
  No reserved source, physical input, native cross-OS suite or manual CI ran.
- [~] **L49.** Linux personal curl config isolation: put --disable first in
  native curl argv. An inherited .curlrc could otherwise re-enable credential
  redirects, inject headers, overwrite local output or bypass TLS verification.
  Four of five native groups fail before; all pass after on LuaJIT/Lua 5.4,
  replaying 121 native redirect/header/body/TLS receipts plus one real proxy
  transaction. Owned CURL_HOME and output files isolate these tests from actual
  user configuration. Environment proxy routing and certificate trust remain
  operational. Eight portable cases fail before and pass after, asserting the
  first-argument requirement, private stdin config and each method's redirect
  contract. Windows async curl also starts with --config by source; its reserved
  owner needs native personal-config receipts and the equivalent first flag.
  macOS uses Hammerspoon HTTP rather than this curl path. No reserved native
  implementation/gate, physical input or manual CI was changed or exercised.
- [~] **L50.** Linux JSON staging ownership: create storage.json.tmp exclusively
  and keep its original descriptor through write/close. Existing regular files,
  symlinks, hardlinks, dangling links, devices and FIFOs must not be truncated,
  renamed, unlinked or opened for blocking I/O. Foreign staging deliberately
  blocks mutation until reconciled; never auto-remove it. LuaJIT uses native
  C11 wx stdio; stock Lua uses libuv wx descriptors and completes partial writes
  before publication. A stock Lua installation lacking luv refuses unsafe writes.
  Seven of eleven real native cases fail before (including a blocked FIFO);
  all pass after on LuaJIT/Lua 5.4. Kernel RLIMIT_FSIZE exercises actual buffered
  and partial-write failure, preserving durable bytes/cache and cleaning only
  owned staging. Sixteen unit regressions cover all four mutation methods and
  four foreign aliases; existing failure spies retain their assertions at the
  exclusive mode boundary. Windows Registry and macOS hs.settings use different
  native stores and have no corresponding temporary JSON file by source. No
  TOML persistence, reserved source, native cross-OS gate, hardware input or
  manual CI was modified or exercised.
- [~] **L51.** Linux native storage harness loader arity: expose exactly one
  adapter from fresh(), because Lua 5.4 require also returns its loader path.
  A final table-list expression previously expanded that path into a second
  snapshot owner and crashed on owner.get. The failure reproduces with the
  exact preceding production source, so it is pre-existing rather than an
  exclusive-staging regression. Keep every scalar false/zero/Unicode/NUL and
  durable snapshot assertion; all thirty-eight actual file/permission receipts
  now pass under LuaJIT and Lua 5.4. The eleven new exclusive-staging/kernel-limit
  receipts also remain valid. No product behavior, TOML, reserved native gate,
  physical input or manual CI was modified or exercised.
- [~] **L52.** Linux JSON backup type inspection: inspect occupied non-regular
  paths and symlinks through checked native metadata before opening ordinary
  backup files. Existing FIFOs previously blocked recovery, dangling symlinks
  looked absent and were overwritten, and socket nodes prevented recovery.
  Skip known occupied special paths and preserve their identities/foreign bytes;
  retain conservative refusal for unreadable regular backups or denied parents.
  Unknown/refused metadata blocks mutation rather than declaring a path free.
  Six of fifteen real native cases fail before and all pass after on LuaJIT/
  Lua 5.4, including actual AF_UNIX nodes and FIFO endpoints at both suffixes.
  Twelve unit cases cover dangling-link regressions, positive alias/history
  controls and four simulated metadata failures, without weakening older
  unreadable-backup assertions. This fixes known types observed at inspection;
  adversarial pathname replacement and atomic no-clobber rename remain separate
  work. Windows Registry/macOS hs.settings have no matching file backup path by
  source. No TOML, reserved source, native cross-OS gate, hardware input or manual
  CI was modified or exercised.
- [~] **L53.** Linux release-page validator association: invalidate only the
  failed page's cached body before completing a refused, cancelled, invalid or
  truncated fetch. Native curl can save a new ETag before its response is
  accepted; a later 304 previously acknowledged an older release list with
  that new validator. Retain accepted earlier pages and healthy 304 reuse.
  Nine unit regressions fail before and pass after, including a two-page retry.
  Six certificate-verifying TLS/file/curl/libuv scenarios pass on LuaJIT and
  Lua 5.4, with origin and home providers simulated to route owned fixtures.
  Three scenarios reproduce changed-validator poisoning; the HTTP 503 control
  retains its prior ETag and conservatively retries fully after failure.
  Windows and macOS publish body/validator pairs only after usable-response
  validation by source, so they have no matching mutable curl validator file.
  No TOML persistence, reserved source, native cross-OS gate, physical input or
  manual CI was modified or exercised.
- [~] **L54.** Linux SQLite native script admission: apply the existing native
  argv validator to the complete composed command before direct popen callers
  can execute it. Raw NUL in SQL previously persisted a complete INSERT/DDL
  prefix despite returning failure after losing the terminal exit receipt.
  Refuse database/script/flag NUL without copying private bytes into diagnostics,
  staging SQL or amplifying its shell-quote/argv budget. Nine unit refusals fail
  before and pass after; a positive framing control also passes. Four genuine
  SQLite prefix-write regressions fail before and all seventeen write receipts
  pass on LuaJIT and Lua 5.4, retaining large input, exit/signal, retry and privacy
  controls. Encoded CRLF/NUL data retain exact native hex assertions. Literal
  CRLF normalization by SQLite's CLI is a separately observed remaining defect.
  macOS uses native hs.sqlite3 exec and Windows native prepared statements;
  their embedded-NUL bridging remains unvalidated and is documented for their
  native owners. No reserved source, cross-OS native gate, physical input or
  manual CI was modified or exercised.
- [~] **L55.** Linux metrics SQL literal serialization: share one native CLI
  encoder between the metrics writer and reader filters. Express CR and NUL
  as SQLite char() concatenations while retaining ordinary apostrophe escaping;
  CLI line parsing previously discarded CR from CRLF values and mismatched app
  filters, and unrepresentable scalar NUL was refused rather than encoded.
  Fourteen of seventeen genuine SQLite cases fail before and all pass after
  under LuaJIT/Lua 5.4: twelve byte-exact persisted values and five app filters
  seeded independently through hex SQL, with an unfiltered baseline control.
  Ten unit cases cover fragments, quotes, mixed boundaries and ordinary bytes.
  Existing seventeen write and twenty-two read native receipts remain valid.
  This encodes owned scalar values; arbitrary raw SQL passed to exec_sql still
  requires explicit SQL representation of data and retains its NUL refusal.
  macOS and Windows use native SQLite strings rather than CLI line parsing;
  their actual embedded-NUL bridges remain unvalidated with their native owners.
  No schema, encryption format, TOML, reserved menu/title source, cross-OS native
  gate, physical input or manual CI was modified or exercised.
- [~] **L56.** Linux dashboard read-only SQLite opens: request native -readonly
  before querying every source rather than relying on SELECT statements.
  Each of the four public projection APIs previously created an absent database
  and followed a dangling alias to create its foreign target. All eight native
  failures now refuse creation, retain exact link identity/target and preserve
  stable empty projection envelopes; thirty native read receipts pass on LuaJIT
  and Lua 5.4 without weakening earlier exit/signal/complete-output controls.
  Four simulated-CLI unit regressions cover every dispatched query's readonly
  open and JSON ABI, and the older source assertion now requires both flags.
  macOS opens its file with default flags before query_only, so its native owner
  must qualify the same missing-source case and apply open-time readonly if
  confirmed. Windows intentionally builds private in-memory reader candidates
  rather than opening this canonical disk store. Existing WAL sidecar behavior
  is separate from these absent-source checks. No reserved source, TOML,
  cross-OS native gate, physical input or manual CI was modified or exercised.
- [~] **L57.** Linux SQLite personal initialization isolation: explicitly select
  -init /dev/null in the shared native command builder. An inherited .sqliterc
  previously changed JSON mode, prefixed response bodies, prevented metrics
  bootstrap and ran personal .shell directives before the application script.
  Four actual ordinary-account receipts fail before and pass after with a real
  owned login profile; three unit modes retain native flags, data and exit ABI.
  Provision only a disposable CI account/container and validate the exact owned
  profile corpus before exercising it; never replace a host personal profile or
  repurpose HOME. SQLite values remain on stdin with the original large-input
  budget. macOS hs.sqlite3 and Windows native prepared statements do not launch
  the CLI and have no matching personal .sqliterc startup by source. No reserved
  source, TOML, native cross-OS gate, physical input or manual CI was modified or
  exercised.
- [~] **L58.** Linux SQLite multiline transaction failure: set native -bail so
  the CLI stops at the first failed SQL statement instead of resuming at the
  next input line and executing COMMIT. The previous failure receipt reported
  refusal after both prefix and suffix rows had already been persisted, using
  the same newline-separated format as native migration batches. Four real
  missing-table/syntax/unique/CHECK failures now roll back all new rows while
  retaining prior data. All twenty-three native write receipts pass on LuaJIT/
  Lua 5.4, including same-line failure, healthy multiline commit, explicit
  rollback and existing signal/privacy/large-input controls. Three unit modes
  retain init isolation, output flags, exact script and terminal receipt while
  requiring native stop-on-error. macOS native exec returns on the first error
  and its migration owner rolls back; Windows's native prepare/step loop stops
  on failure by source. Neither uses this CLI line-resumption behavior. No
  schema, crypto format, TOML, reserved source, cross-OS native gate, physical
  input or manual CI was modified or exercised.
- [~] **L59.** SQLite decryption migration literal bytes: centralize the existing
  scalar SQL encoder in shared sqlite.literal and reuse it in the shared plan
  and Linux native command helper. A real Linux decrypt pass previously reported
  a converted row while dropping its CRLF; NUL plaintext was refused instead of
  represented in SQL. Six of seven production cipher/migration/backend cases
  fail before and all pass after under LuaJIT/Lua 5.4, preserving both columns,
  foreign-device ciphertext and the ordinary-byte control. Only the machine-id
  path provider routes to a synthetic owned file; PBKDF/AES/OpenSSL, SQLite,
  cursor ownership, parser and filesystem execute natively. Three unit cases
  retain exact fragments, local-device/row scope and representable script bytes.
  macOS consumes the same pure SQL plan and encoder by source; Windows has a
  separate native SQL producer. Their native byte/bridge qualification remains
  with the principal owner. Key derivation, salt, IV rules, envelopes, schema and
  TOML are unchanged. Per the Linux task instruction, macOS/AHK suites and manual
  CI remain unexecuted; no reserved source or physical input was exercised.
- [~] **L60.** Linux corrupt JSON backup publication: use native no-replace
  rename under LuaJIT and checked link/unlink under stock Lua. Retry a competing
  destination without replacing its inode; block mutations on other failures.
  Twelve production cases create real regular files, hard links, symlinks,
  dangling links, FIFOs and directories between inspection and publication at
  two backup suffixes. All fail before and pass after under LuaJIT and Lua 5.4;
  strace delays actual syscalls to coordinate the two real processes. Four unit
  collisions and four simulated libuv receipt controls cover retry and refusal.
  Stock Lua's link/unlink pair is not an atomic move; unlink failure retains the
  backup and blocks mutations. This fixes destination clobbering, not concurrent
  replacement of the source. macOS uses hs.settings and Windows the registry,
  with no corresponding JSON recovery move. TOML, reserved source, physical
  input, macOS/AHK suites and manual CI remain outside this Linux correction.
- [~] **L61.** Linux updater temporary-file ownership: retain os.tmpname's
  reserved inode as the partial download, clean only that owned path, and
  publish the verified archive with the native no-replace move. Previously a
  failed checksum request deleted unrelated derived names; a valid download
  overwrote them. Eleven of twelve native cases fail before and all pass after
  under LuaJIT and Lua 5.4, including real certificate-verified TLS/curl/SHA-256,
  regular/hardlinked/symlink/dangling competitors, transport/parse/digest refusal,
  publication collision and healthy cancellation. strace only observes native
  allocation; the owned TLS server creates adjacent files before replying.
  Four unit cases simulate allocation and checksum refusal with real files.
  macOS uses Sparkle for automatic updates; its separate release installer has
  timestamp-derived staging directories. Windows has a separate staging worker.
  Their native staging-ownership qualification remains with the principal owner;
  no cross-OS native gate or source, TOML, physical input or manual CI was changed.
- [~] **L62.** Linux updater native temporary-allocation refusal: protect
  os.tmpname so native allocation errors return false and acknowledge a supplied
  callback once, preserving the selected release and pre-download state. Twelve
  native cases per runtime exercise both public download APIs with/without a
  callback at real per-child descriptor limits of 0 and 3, plus four ordinary
  allocation/curl-protocol-refusal controls. Eight fail before and all pass
  after under LuaJIT and Lua 5.4; only owned child limits are lowered and restored
  through real prlimit syscalls. No allocator/process/HTTP adapter is mocked.
  A fixture seam seeds the selected release before the resource limit changes.
  Four unit cases simulate allocator exceptions and forbid premature HTTP work.
  macOS delegates automatic updates to Sparkle and separate release staging to
  an exit-code-reporting script; Windows uses a separate native staging worker.
  Neither sibling has this Lua os.tmpname call. Their native resource-exhaustion
  qualification remains with the principal owner. No reserved source, TOML,
  physical input, macOS/AHK suite or manual CI was changed or exercised.
- [~] **L63.** Linux localized native audio metrics: run pactl's machine query
  under C locale so gettext's French oui/German ja are recognized as mute. A
  real 30-second sampler run previously recorded zero muted time while the
  private PulseAudio null sink remained muted. Native processes, Unix sockets,
  gettext catalogs and production sampler execute under C/French/German with
  muted/unmuted controls; two of six cases fail before and all pass after per
  LuaJIT/Lua 5.4 runtime. These regression cases supply explicit sampler time
  inputs; the additional timed reproduction uses actual monotonic elapsed time.
  Four simulated CLI unit cases cover both states and locales. This is a native
  virtual audio service, not a physical sound-device or graphical-session test.
  Windows/macOS initialize the shared metric column to zero without this pactl
  reader by source; native audio parity and the ALSA hardware fallback remain
  unqualified here. No schema, product label, reserved source, TOML, macOS/AHK
  suite, physical device or manual CI was modified or exercised.
- [~] **L64.** Linux literal directory bytes: centralize native separator
  normalization in the bootstrap resolver and reuse it in updater path handling.
  Backslash remains filename data on POSIX; Windows separators still normalize
  when the runtime reports Windows. Previously a legal backslash directory lost
  its shared data root and was classified as unmanaged by the updater. Twelve
  of twenty-four native cases fail before and all pass after per LuaJIT/Lua 5.4
  runtime, using actual copied source localization, cwd, shared locale files and
  default shell/file probes. Absolute/relative loading and both shared-tree
  layouts cover backslashes and unchanged space/quote/Unicode/CRLF controls.
  This is an actual filesystem layout fixture, not a daemon installation; PWD
  accurately reports its child cwd. Six unit metadata/probe regressions and two
  simulated Windows separator controls retain their assertions. macOS parent
  traversal treats both separators specially and needs native qualification;
  Windows disallows literal backslash in a component. Their native gates remain
  with the principal owner. No config-path/TOML policy, title, autostart placement,
  reserved source, physical input, macOS/AHK suite or manual CI was changed.
- [~] **L65.** Linux actual working-directory ownership: resolve relative loader
  and updater sources through one native cwd reader instead of inherited PWD.
  Lua 5.4 previously lost the shared tree with stale PWD; both runtimes anchored
  relative updater paths to the stale directory. Prefer libuv, retain the native
  LuaJIT fallback, and check the shell fallback's completion while preserving
  embedded newlines and trailing spaces. Expanded real filesystem fixtures
  cover accurate, absent, stale PWD and a native post-launch chdir, both layouts,
  both source modes and six filename forms. Before correction 24/96 LuaJIT and
  26/96 Lua 5.4 cases fail; all pass afterwards. Six simulated boundary regressions
  also fail before and pass after. macOS anchors from hs.configdir/module source
  and Windows from A_ScriptDir by source; neither uses inherited PWD there.
  Their native gates remain unexecuted as requested. No configuration/TOML,
  title, autostart placement, physical input or reserved source was changed.
- [~] **L66.** Linux restart zombie handoff: read the kernel's dedicated State
  record from /proc/PID/status instead of parsing line-oriented /proc/PID/stat,
  whose raw process name can contain newlines. Such a name previously left the
  native detached relay waiting forever on an already exited daemon. Four of
  fourteen native cases fail before and all pass after per LuaJIT/Lua 5.4
  runtime, including live-target waiting, actual retained zombies, prctl-set
  names and literal wrapper argument receipts. The fixture owns and reaps its
  detached process descendants through native subreaper setup. This is a real
  process/relay E2E regression; keyboard ownership and systemd service behavior
  are not qualified. Windows uses native process handles; macOS has a bounded
  kill probe without this Linux stat parser. Their native gates remain with the
  principal owner and were not run. No autostart placement, title, reserved
  source, physical input or manual CI was changed.
- [~] **L67.** Linux bounded accessibility helper interpreter: resolve the first
  negative Lua argument token through a shared launch-metadata policy. Index -1
  can be an interpreter option or its value, so launches with -joff, -O0, -E or
  -e previously failed closed despite a conclusively focused native GTK field.
  Ten of twelve virtual X11/GTK/AT-SPI cases fail before and all pass after,
  covering ordinary/password fields and six actual LuaJIT launch forms through
  the production bounded helper. Six simulated metadata/command unit cases pass
  on LuaJIT and Lua 5.4; three reproduce the old defect and three are controls.
  The graphical fixture owns its Xvfb display, window manager and private D-Bus
  session. This does not qualify physical input or a Lua 5.4 native AT-SPI backend
  (the native library binding requires LuaJIT FFI). macOS embeds Lua and Windows
  uses its native accessibility path; neither production path reads arg[-1]
  there. Their native gates remain deferred as requested. No reserved AI menu,
  title, autostart placement, TOML source or manual CI was changed.
- [~] **L68.** Linux JSON special-source admission: open the source with native
  O_NONBLOCK/O_CLOEXEC, classify its pinned descriptor and reopen only regular
  files through the kernel-owned fd alias. A FIFO or symlink to one previously
  blocked startup; an open peer can also hold a JSON-looking FIFO read forever.
  Twelve of twenty-eight native cases fail before and all pass after per
  LuaJIT/Lua 5.4 runtime. Regular-file and file-symlink controls preserve their
  behavior; FIFOs, directories and Unix sockets retain their inodes and reject
  every mutation. The native libc fallback also passes without libuv's Lua
  binding. Nine simulated descriptor receipts check classification, flags,
  close ownership and exceptions; existing read-refusal assertions remain.
  Existing native read (38), temporary-file (11) and backup-type (15) regressions
  pass in both runtimes. Windows Storage uses the registry and macOS hs.settings
  by source, so this FIFO reader is Linux-specific. No generic FileSystem/TOML
  writer, config-path policy, physical input, reserved source or manual CI changed.
- [~] **L69.** Linux generic file-read special sources: reuse the native pinned
  regular-file reader in FileSystem.read, including the updater's default read
  port. Six of twenty-two real filesystem/port cases block before and all pass
  after per LuaJIT/Lua 5.4 runtime. Controls preserve ordinary and symlink file
  reads, empty/UTF-8/CRLF/NUL bytes, and every source inode. FIFO/no-peer/held-peer,
  FIFO symlinks, directories and Unix sockets return nil without waiting.
  Three simulated admission regressions also fail before and pass after; four
  libc metadata receipts cover file type, a missing type mask and syscall failure.
  The libc fallback uses statx on the descriptor instead of a shell probe, keeping
  reload and menu reads in-process. Existing no-shell/title assertions stay intact.
  macOS already classifies regular paths before its read by source; Windows uses
  FileOpen and has no POSIX FIFO namespace. Its distinct named-pipe behavior is
  unqualified and remains with the native owner. The reserved read_with_status
  path and shared TOML reader still need the principal's coordinated fix; they
  are not covered by this generic port change. No TOML, title, autostart placement,
  physical input, reserved method or manual CI was changed.
- [~] **L70.** Linux file-read terminal receipts: publish file contents only after
  both read and close succeed, and close the owned stream even when read raises.
  FileSystem.read previously returned complete bytes after a failed fclose;
  its updater read port inherited that false success. Two of six native-process
  cases fail before and all pass after per LuaJIT/Lua 5.4 runtime. Actual files,
  interpreters and libc streams execute; strace injects EIO at the verified owned
  read or stream-close syscall. These failure receipts are simulated syscalls,
  not real storage-device failures. Six simulated stream unit cases retain
  healthy/read-refusal controls and reproduce read-exception cleanup and nil/
  false-close failures. macOS already checks its classified read/close receipts
  by source; Windows' distinct FileOpen/Close behavior needs native-owner
  qualification. No reserved read_with_status method, TOML writer, title,
  autostart placement, physical input or manual CI was changed.
- [~] **L71.** Linux build-stamp version reads: route release metadata through
  the native FileSystem read port, reusing regular-file admission and read/close
  receipts. A FIFO build_stamp.txt previously blocked version resolution on
  startup, including FIFO symlinks and a readable FIFO with a held peer.
  Three of eleven real native endpoint cases fail before and all pass after per
  LuaJIT/Lua 5.4 runtime, with regular release, symlink, malformed, empty,
  unreadable, missing, directory and UNIX-socket controls. Four simulated adapter
  unit cases check routing and the unchanged shared version-parser results.
  macOS and Windows do not use this Linux startup version module; related
  diagnostic reads use their native FileSystem ports by source. Native tests
  for those drivers remain with their owners. No shared parser policy, TOML
  persistence, reserved titles or autostart placement was changed.
- [~] **L72.** Linux diagnostic metadata reads: use native FileSystem read and
  existence ports for build stamps, git HEAD/pointers and system probes. The
  duplicated stdio readers previously blocked on FIFO sources, including the
  existence check of a FIFO HEAD. Nine of twenty-six real native cases fail
  before and all pass after per LuaJIT/Lua 5.4 runtime. Fixtures keep file and
  file-symlink commit controls, missing/directory/UNIX-socket refusal controls,
  source inodes and bytes, and real /proc PID/kernel/memory and /etc OS probes.
  Four simulated adapter unit cases check the stamp, git metadata, PID and OS
  data paths. macOS and Windows already route related diagnostic reads through
  their native FileSystem ports by source; their native gates remain with the
  principal agent. Shared commit parsing, reserved TOML persistence, window
  titles and autostart placement were not modified.
- [~] **L73.** Linux checked command capture: require a completion trailer after
  successful stdout transmission, preserve read/close refusals, and close/reap
  the pipe even when reading raises. A complete leading status/length frame
  previously certified success after its native transmitter exited nonzero;
  LuaJIT pclose can hide that exit. One of seven native-process cases fails
  before and all pass after. The failure case uses a controlled native utility
  that calls real cat then exits 17; this is a simulated utility failure, not a
  hardware fault. Five simulated libc regression cases cover read/close errors,
  exceptions and the absent trailer; existing process-status fixtures carry the
  new completion frame with their assertions intact. macOS and Windows use
  different native process-capture mechanisms without this temporary-file
  transmitter protocol. Their native suites and reserved subjects were untouched.
- [~] **L74.** Linux application operands: add the native gtk-launch option
  boundary so desktop-file ids such as --version and -help launch the chosen
  application. Quoting alone let those ids act as launcher options. Two of four
  real chooser/parameter/executor launch cases fail before and all pass after
  on synchronized dev656. Private Xvfb and D-Bus sessions use actual owned
  desktop entries whose executable records its fixed identity; these are
  virtual desktop tests, not physical keyboard tests. Registered unit controls
  preserve the shared application corpus and cover option-looking, quoted and
  spaced ids. macOS and Windows use their native application launch ports
  without this gtk-launch option parser; their native suites remain deferred.
- [~] **L75.** Linux device schema admission: read the complete SQLite table
  definition when checking its Linux platform constraint. The scalar reader
  kept only the first line and rebuilt the already-current registry at every
  opening, removing its indexes and triggers and requesting an unnecessary
  write lock. Four real SQLite regressions fail before and pass after: stable
  schema version, retained index/trigger ownership, opening under an actual
  read transaction, and a legacy migration that runs only once and retains
  device metadata. The registered unit reopens the production writer. Windows
  and macOS schema paths do not use this truncated CLI DDL probe; their native
  suites remain deferred. No shared schema or reserved configuration was changed.
- [~] **L76.** Linux digest replacement admission: validate the complete native
  sha256sum argument vector before cancelling an incumbent or allocating its
  replacement. An absolute path containing NUL previously cancelled a valid
  pending digest before being refused. Two of seven actual native process
  regressions fail before and all pass after: the original FIFO digest survives
  both ordinary and raising refusal callbacks and finishes the known abc hash
  exactly once. Controls retain relative-path refusal, accepted replacement,
  FIFO and /dev/zero deadlines, explicit cancellation and native handle cleanup.
  The registered regression uses actual LuaJIT/libuv processes and files, with
  no simulated syscall receipts or physical device validation. macOS hashes
  in-process and Windows owns its hashing worker; neither uses this Linux
  singleton admission path. Their native suites remain deferred. Separate
  caller ownership isolation is covered separately by L80.
- [~] **L77.** Linux event-loop wait completion: retry nanosleep with its
  remaining duration after EINTR and reject other native errors. Real libuv
  child exits previously shortened a successful 400 ms wait to about 50 ms.
  The registered native fixture now starts three actual sleep processes,
  requires the full wall-clock delay with bounded CPU consumption, checks that
  all children exited during the wait, and reaps them without leaked handles.
  No signal delivery or syscall result is simulated. Windows uses its native
  Sleep path without POSIX EINTR; macOS delegates to hs.timer.usleep, whose
  underlying interruption behavior cannot be established in this container.
  Their native suites remain deferred. The separate reserved injector wait
  has an analogous source diagnosis and remains unchanged for its owner.
- [~] **L78.** Linux buffered HTTP body bounds: enforce the exact caller body
  limit after separating curl's status trailer. The transport read budget
  reserves trailer space; response bytes previously borrowed that allowance
  and exposed oversized success or refusal bodies. Thirty of 84 actual local
  curl/libuv checks fail before and all pass after across GET, POST and owned
  GET, Content-Length/chunked framing, HTTP 200/401, small boundaries and the
  updater's 2 MiB boundary. Requests and sockets are real; no native result is
  simulated. Registered unit controls preserve split-trailer handling and
  single completion. Windows uses its native response budget/file path and
  macOS its native HTTP callback rather than this Linux trailer allowance;
  their runtime suites remain deferred. Existing shared size policy is retained.
- [~] **L79.** Linux HTTP refusal completeness: publish error-body bytes only
  after curl proves a completed transfer, including its ordinary exit 22 for
  fail-with-body. Keep the actual HTTP status while omitting partial transfer
  prefixes; a syntactically valid missing-model JSON prefix previously offered
  a model download after a truncated 404. Twenty-one of 262 actual local
  curl/libuv checks fail before and all pass after, including GET, POST,
  download, streaming POST and owned GET. All 15 incoming dev owned-request
  settlement/cancellation/retry checks remain intact. Four registered unit
  cases add simulated exit 18/23/56 and signal controls without weakening
  existing assertions. Windows publishes curl response bytes only after exit
  zero; macOS suppresses body bytes on negative native network status by source.
  Their native runtime suites remain deferred. Shared model policy is unchanged.
- [~] **L80.** Linux digest caller ownership: isolate updater and layout-registry
  requests so an idle updater cancellation cannot terminate a valid layout
  digest, and one caller's replacement cannot discard another caller's hash.
  Keep historical unnamed-owner replacement/cancellation and preflight refusal
  semantics. Six actual native component cases fail before and pass after,
  using real sha256sum/FIFO processes, updater.cancel_update, and the actual
  private layout digest collaborator obtained through guarded upvalue lookup.
  This collaborator check is not a network refresh or installation E2E, and no
  physical device is involved. Unit controls check archive owner forwarding;
  the E2E lane registers the native component fixture in addition to its existing
  scenarios. macOS hashes layouts synchronously and owns its updater child;
  Windows hashes in its own worker by source, without this Linux singleton.
  Their native suites remain deferred. No shared hash policy changed.
- [~] **L81.** Linux logger repoint ownership: acquire candidate append channels
  before retiring the working pair. Previously a refused destination closed
  the old handles and attempted a path-based rollback, which lost a healthy
  journal when permissions changed after its original acquisition. Three of
  18 actual native file/permission/descriptor cases fail before and all pass
  after, preserving all 13 prior write controls plus refusal, retry, partial
  candidate cleanup, successful switching and optional-mirror refusal. Twelve
  unit controls distinguish simulated open faults and assert ownership order,
  nil/false/throw refusal, stdout-only and degraded-sink behavior. macOS folder
  changes reload into a new logger session; Windows reloads and acquires files
  per batch rather than retaining this pair by source. Their native suites
  remain deferred. Reserved persistence and paths-editor production are unchanged.
- [~] **L82.** Linux SQLite event ID reservation: replace the process-local
  cursor with one BEGIN IMMEDIATE reservation acknowledged only after COMMIT.
  Interleaved actual collector processes previously reused IDs and silently lost
  accepted raw typing through INSERT OR IGNORE. Validate serialized positive
  decimal cursors and keep the entire reserved range within the shared Lua
  exact-integer policy; malformed or exhausted metadata refuses without mutation
  and retains pending typing for recovery. Seven of twelve native interleaving,
  trigger rollback and held-reader COMMIT cases fail before; thirty of thirty-four
  native cursor, recovery and boundary cases fail before; all pass after. These
  execute genuine SQLite/process paths with synthetic software key events, not
  physical keyboard input. Four registered native unit regressions and a shared
  policy source guard cover the same boundaries. Packaged graphical startup has
  its own single-instance flock; independent collector/CLI connections remain
  supported by this reservation. macOS also caches a Lua cursor and has separate
  numeric-bound/independent-writer debt by source; Windows uses native integer
  IDs and a journal recovery ledger. Their native suites and hosted CI remain
  deferred. Database schema, encryption format and reserved UI are unchanged.
- [~] **L83.** Linux literal HTTP URL admission: disable curl's URL globbing
  after its required first --disable argument. Brackets and braces in a caller
  URL previously failed parsing, changed the target or issued multiple requests
  for one get/get_owned/post/postStream/download operation. Thirty-five of
  fifty-five actual curl/loopback IPv4 and IPv6 cases fail before and all pass
  after, checking one exact target, exact POST bytes, response bytes and native
  retirement. Five registered unit cases pin every request method to the same
  native builder. Percent-encoded URLs and ordinary requests remain controls.
  Windows' curl adapter has the same source-level omission; its bounded proposal
  remains separate for the principal owner. macOS uses native hs.http without
  curl's glob language by source. Foreign native suites and hosted CI are
  deferred; no URL, endpoint or request ownership policy changed.
- [~] **L84.** Linux relative native timer arming: refresh libuv's cached clock
  immediately before arming newly requested delays through one native helper.
  Blocking work outside or inside a callback previously consumed a new delay:
  80 ms timers fired in about 0.05 ms and valid 40 ms children lost new 100 ms
  deadlines. Cover after/every, ProcessRunner, FileDigest, HTTP, ShellRunner and
  EventLoop admission without changing their start receipts or teardown policy.
  Seven of eight core and eight of nine sibling native cases fail before; all
  seventeen pass after with actual timers, FIFO/sha256sum, loopback curl, shell
  children, process-group termination/reaping and zero retained handles. Five
  registered unit cases include the two native fixtures, native result-tuple
  preservation and two explicitly simulated refresh exceptions. Native void-style
  update_time is accepted; existing test backends now model it faithfully without
  weakened assertions. These are native component receipts, not keyboard hardware
  or a physical graphical session. Windows SetTimer and macOS hs.timer/hs.task
  do not expose this cached Lua/libuv clock by source; their native duration
  qualification remains deferred. No reserved input, menu or title source changed.
- [~] **L85.** Linux diagnostics export completion: delegate report saves to
  the established FileSystem.write owner and require its exact true receipt
  before revealing the path. Previously a buffered write could succeed while
  fclose failed with EFBIG, leaving a truncated report advertised as complete.
  Two of seven actual kernel/file/permission cases fail before and all pass
  after on LuaJIT and Lua 5.4: partial and zero-byte closes, immediate write
  refusal, read-only file, unwritable directory, exact literal path/content and
  redaction controls. Native write/close results are unmodified; reveal alone
  is a simulated UI observer, not a physical graphical validation. Eight unit
  controls explicitly simulate adapter receipts and preserve failure, directory
  admission and successful save/reveal separation. macOS has the same unchecked
  report close by source; its existing checked FileSystem.write is the bounded
  follow-up proposal for the principal owner. Windows uses its native Write/Close
  exception boundary by source. Foreign native suites and hosted CI are deferred.
  No new writer policy or reserved configuration/diagnostic gate was introduced.
- [~] **L86.** Linux process supervision admission: require the returned
  native timer/stdout/stderr start receipts as well as their protected call
  status. Libuv returns nil/error without raising; pcall success previously
  admitted an unsupervised process. Refusal now terminates the owned group,
  retires handles and publishes one failure, while native zero remains success.
  Three of four component checks fail before and all pass after: the fixture
  explicitly simulates invalidation of an actual timer or pipe before its
  genuine EINVAL start receipt. Child processes, group termination, reaping and
  handle cleanup are real; ordinary production invalidation is not claimed.
  Six unit cases simulate nil/false receipt forms and preserve the existing
  clock, argv, output and late-callback assertions. The native clock helper
  remains in use. Windows uses native process/SetTimer paths and macOS hs.task
  by source; their native admission behavior remains unqualified and deferred.
  No reserved source or public process API changed.
- [~] **5.** Complete W1 neutral configuration and recommended/clear scopes.
  Finish macOS Hotstrings and TapHold, Linux Hotstrings and TapHold, then global
  composition. Keep unknown fields, verified backups, exact runtime
  acknowledgement, external-write conflict detection and retryable rollback.
  Recommended delay values must match effective runtime inheritance: deleting
  `autocorrection.caps` currently inherits 1.0 s while the manifest recommends
  0.5 s. Do not assume deletion implements the recommendation. Hotstrings: Linux
  categories, sections and scalar settings are canonical config.toml leaves,
  with a one-shot import of legacy storage.json choices; both Lua drivers have a
  two-file recommended/clear owner whose planner writes explicit delays where
  inheritance differs, bound Ergopti groups included. Published in the second
  2026-09-30 release: `hotstrings_menu` declares `scope_restore`/`scope_clear`
  beside the switch and all three drivers register them (Windows from
  `_HS_ScopeCommands`); macOS constructs its owner once per session and composes
  it into the global restore (skipped and named when its override file cannot be
  served), its transaction now reverting and releasing, and a scope's retained
  inverse is settled through the writer fence so the other categories' reverts
  and every later writer are admitted again; the macOS Hotstrings switch starts
  the typing engine « Clear » stopped. Linux word delimiters are config.toml
  leaves (`[hotstrings.terminator_states]`, `hotstrings.terminators`, the macOS
  paths) imported once from storage.json; a save writes only what the menu
  changed; both Linux modes return the shipped delimiters to their defaults and
  keep the user's own (user data, as the delimiter submenu does). macOS now
  shares that policy, resets the file, runtime and next-save states, and keeps
  its exact inverse on refusal.
  Windows now restoresshipped word and consumed delimiter defaults through one
  shared AHK policy, preserving personal strings in the tray restore and both
  admitted Hotstrings scopes. Independent cross-driver vectors preserve
  Unicode, duplicates, disabled consume-only markers and unknown personal
  states; the existing journal retains exact inverse recovery on refusal. The
  eight unchanged source files retain their prior full portable qualification;
  the two rebased include files passed the selected encoding gate on the
  current integration. Windows native unit/E2E, packaging and installation
  validation remains pending. Recommended-delay native verification and
  editable handwritten [[hotstrings.terminators]] support remain open under
  item 34.
- [~] **7.** Complete W2: seven-page first-run opt-in wizard, per-category
  recommended choices, consistent WebView behavior and genuine translations in
  21 locales. The tap-holds page lists each engine's recommended keys from the
  shared tap-hold catalogue and imports only the checked ones through each
  driver's tap-hold writer: Windows renders them into the tap_hold.toml beside
  config.toml in the wizard's own transition, macOS goes through the remap
  owner's settings transaction (a file save before the bridge starts or for a
  moved folder), Linux through tap_hold_writer into the chosen folder, where
  macOS and Linux also switch the Tap-Holds on. A re-run reads the keys each
  folder already configures: the page opens at the switch in force, shows a key
  at its recommendation checked and one of the user's as kept, locks both, and
  every writer refuses to import over the latter and backs up the file it
  replaces. Published in the second 2026-09-30 release. Remaining: a real-device
  re-run of the wizard on each OS (Windows was verified by CI only), and Linux
  trigger selection in the wizard. Linux already writes its hotstring section
  choices into the selected config.toml through the shared answer planner and
  acknowledged writer. The shared wizard trigger choices remain excluded on
  Linux because they do not satisfy its keymap validation policy; the tray
  retains its existing physical-key preference owner.
- [~] **13.** Complete F2: honor the Karabiner integration switch before leases
  and guardians; preserve personal rules; back up and restore Windows touchpad
  registry values through one owner. Remaining: turning the switch off or «
  Retirer Ergopti de Karabiner » does not unregister a guardian LaunchAgent
  registered while it was on (needs a headless unregister role in the launcher,
  verified on a Mac). Legend: `[x]` implemented, reviewed and integrated on
  `integration-2` (published only once `dev` is pushed); `[~]` integrated with
  the precise remainder recorded in the item or in the overnight handoff.
- [~] **16.** Publish final corrective commits, verify CI and release assets,
  and write the final report with completed scope, limitations and manual test
  results. Published twice on 2026-09-30 (v0.0.0-dev.147, then the morning's
  work with the Homebrew provenance fix). Local gates of the second tip: JS
  320/321 (only the root-sandbox install check), macOS Lua 12333/12333, Linux
  4367/4367, macOS E2E 67/67, Linux E2E 118/118, strict conventions, AHK
  encoding (1740 files), gen:check (40 outputs of 23 generators); full CI
  without release: run 36697666039 (CI #633). The maintainer's manual test
  results remain.
  Non-release checkpoint
  [37033032620](https://github.com/adrienm7/ergopti/actions/runs/37033032620)
  at `6275cac35` passes the complete Windows/macOS/Linux pipeline, including
  native units, E2E, packaging, installation and launch; Release / Publish is
  skipped. Personal-menu fixtures now release their owned submenu trees before
  AHK interpreter teardown. The five targeted owner/lifecycle cases require a
  clean native exit, while foreign detached dispatcher registrations stay live.
  Both asynchronous launchers retain their process handle, join before reading
  ExitCode and refuse a missing receipt. Strict execution identities and timings
  remain blocking. Hosted diagnostics use stdout through PowerShell, and native
  timing probes consume the runtime actually selected by CI.
  The isolated LLM runners now own separate canonical result paths and strict
  manifests so their small suites cannot replace the main suite's later
  annotation. This receipt-isolation follow-up awaits its full native CI.
  CI reporting now emits one bounded aggregate notice with every ordinary
  failure, alongside unchanged error annotations and strict native statuses.
  Checkpoint 37056318950 had 17 failures but GitHub retained only ten error
  annotations. An actual CLI regression fails against the previous reporter;
  68 assertions now cover all causes, escaping, bounded oversized details and
  unchanged streamed output/counts/JSON/exit status. Full native CI remains
  pending for this evidence-only follow-up.
  Both real detached-worker probes now capture exact owned launch/exit and
  stdout/stderr receipts before a script window exists. Missing readiness and
  cleanup retain the original failure together; the shell control and every
  icon/title/priority assertion remain blocking. Checkpoint 37061649827 lacked
  the worker parser output; the next native run must qualify its cause.

  Checkpoint 37089270207 failed the native healthy-guardian presence fixture
  after its caller dropped the runtime reference. The fixture now blocks the
  actual acknowledgement callback to prove that presence remains valid while
  the observer retains the singleton, then requires weak-runtime retirement
  and physical singleton release within the existing two-second bound before
  the unchanged absent-owner assertion. Portable source gates do not qualify
  native Swift behavior; native XCTest and complete three-OS CI remain pending.

  Concurrent Windows performance commits are integrated without replacing the
  pending editor, model or remap slices. The committed delay policy and its
  independent vectors remain intact. This merge retains the original native
  failure assertions and requires a new complete non-release checkpoint.

Packaged macOS window observations now bind exact live application PIDs
before reading properties. After an acknowledged Quit, they attest process
absence without opening a global Accessibility query. Refused UI inspection
remains explicitly unavailable and cannot qualify window behavior; the five
application criteria, native timer assertions and primary/cleanup errors
remain strict. Fifty Python regressions pass; native CI remains pending.

A refused live Linux update retains the same sanitized HTTP response and
underlying child/owner verdict before fixture cleanup. The probe preserves
transport arguments, callback returns and failure status; unavailable
headers are reported explicitly rather than inferred to be a rate limit.
Registered CLI regressions, Linux units and portable E2E pass; the actual
updater response and complete native checkpoint remain pending.

Checkpoint [37087943283](https://github.com/adrienm7/ergopti/actions/runs/37087943283) qualifies the second sample of the exact installed Hammerspoon server, while the clean-launch AppleScript observation still exceeds its unchanged ten-second budget. Failure logs now preserve bounded thread identities, native queue names and call ancestry, explicitly mark omitted ancestry, and redact private source locations. Main-thread Lua frames and background semaphore waits remain separate observations; neither loaded images nor flattened frames establish TCC causality. Sixty-one registered portable Python regressions and the selected format/JS gate qualify the diagnostic change. The new native context output, the actual timeout cause and all 18 timer measurements still require a non-release macOS checkpoint. Exact PID/executable and native Process/Path identity checks remain strict.

Checkpoint [37091050694](https://github.com/adrienm7/ergopti/actions/runs/37091050694) qualifies a cleanup-time server sample with the main thread dispatching timers and waiting in its native event loop, but GitHub cuts the next thread's ancestry at the error-annotation limit. The existing sampling owner now retains bounded, path-redacted observations in the durable report and emits them as prefixed plain-log lines, independently of unchanged annotations. Observation and cleanup retain separate command identities; extra commands and oversized diagnostics are explicitly marked as omitted. Portable regressions cover the actual timeout owner, complete late ancestry, privacy, bounds, workflow-command injection and the unchanged failed verdict. The actual AppleEvent timeout cause, all 18 native timer measurements and the Karabiner native scenario remain unqualified until the next non-release checkpoint.

The Windows live-expansion fixture now owns its foreground-focus probe and
restores the exact prior port. Actual deferred observers still reject absent
or changed focused controls and re-arm only for a stable verified target.
Checkpoint 37085309234 exposed a host-dependent re-arm failure; its exact
native guard branch was not emitted. All original expansion and transport
assertions remain, with native Windows requalification pending.

The two packaged native probes now first request a separate exact owned-nonce AppleEvent control from their already bound live Hammerspoon PID. This uses the same ten-second request and acknowledged child-cleanup owner, requires an exact nonce line and checks the live identity again before recording success. The original timer and Karabiner observations still run after control refusal; a control receipt cannot substitute for either feature proof or hide either failure. Diagnostics identify control, observation and cleanup separately and retain up to three bounded, path-redacted command receipts. Portable regressions cover exact and foreign replies, whitespace, nonzero status, dispatch refusal, changed identity, retained transport debt and combined verdicts. Actual native control admission, the timeout cause and the original 18 timer and eight Karabiner measurements still await CI.

Keep item 16 partial. Checkpoint37095444894 times out on both the literal nonce control and original feature requests in clean and Karabiner scenarios. The original AppleEvent still addresses the embedded bundle path; validating a runtime PID did not make it the event destination. A distinct diagnostic now sends the same pinned HmSp/EXEC direct-text command to an exact kernel-PID descriptor from /usr/bin/osascript through its Foundation bridge. It preserves the enabled preference, exact nonce line, ten-second request deadline, acknowledged child cleanup and live identity checks before dispatch and admission. Retained scripting debt rejects the diagnostic. Its receipt cannot replace path control, timer measurements or Karabiner proof, and all original failed verdicts remain. Four independently named phases retain bounded, path-redacted diagnostics without publishing script argv. Portable lifecycle, strict-identity and verdict regressions qualify the implementation; actual JXA/Foundation API admission and path-versus-PID interpretation await the next non-release macOS checkpoint. A PID reply would establish a difference between delivery chains; another timeout would not prove TCC or deadlock.

The packaged clean and Karabiner scenarios now execute a distinct constructor-only smoke in /usr/bin/osascript before the alternative PID send. It reuses that send owner’s exact JXA/Foundation event constructor and never sends an AppleEvent or launches a target. Its bounded strict receipt measures the actual event address as kpid plus canonical four-byte PID data, HmSp/EXEC, and the exact Unicode direct parameter including the owned nonce. Live identity is checked before dispatch and after receipt; the original ten-second child deadline, acknowledged cleanup and retained-debt refusal remain unchanged. Construction, path control, PID delivery, timer observations and Karabiner observations have separate contracts and cannot substitute for one another. Five explicitly bounded phases retain redacted diagnostics. Portable regressions qualify ownership, receipt rejection, native-scenario wiring and the shared constructor; actual Foundation construction remains pending a non-release macOS checkpoint. Constructor refusal identifies a bridge/descriptor failure before event delivery and does not establish TCC, deadlock or handler admission.

The selected portable gate passes 353 JS checks and 97 diagnostic lifecycle
cases. These results do not qualify native Foundation construction; the real
packaged macOS scenarios must supply that receipt. Item 16 remains partial.

Six native clean/Karabiner scenario executions now qualify actual kernel-PID,
event and Unicode descriptor construction. Their original bundle-path and
exact-PID sends still time out; this does not establish a permission or deadlock
cause. A separate exact-PID no-prompt diagnostic now retains strict terminal
OSStatus, NSError domain, direct reply, nonce and live identity through the
same event constructor and owned sender. Only send-origin errors -1744/-1743
in NSOSStatusErrorDomain identify consent-required/denied; other errors remain
unclassified refusals. Original controls, ten-second production deadlines,
child retirement and feature admission remain required. Bounded primary errors
stay visible beside native samples. Portable regressions also prove that only
the first sleeping timeout fixture gets 50 ms; its real retry keeps ten seconds.
The original timeout, reaping and retry assertions remain intact. All 104 unique
portable tests and selected JavaScript checks pass; native no-prompt outcomes
and the original timer/Karabiner feature measurements still require CI.

A supplementary diagnostics-only startup owner now invokes
those same original native timer and Karabiner probes in the unchanged signed
installed embedded Hammerspoon app, independently of external AppleEvent
admission. It temporarily owns only MJConfigFile, binds an exact fresh
nonce/PID/executable/bundle/version ready-to-admit receipt before dispatch,
requires original measurements and native cleanup acknowledgement, retires the
actual runtime and restores the exact physical preference while preserving
unrelated current values. Timers retain their original ten-second watchdog and
fifteen-second receipt observation; synchronous Karabiner keeps ten seconds;
late answers and retained ownership debt refuse admission. The result explicitly
qualifies only installed native feature measurements: full managed boot,
AppleEvent permission/delivery and physical hardware remain separate. Required
original controls, scenarios, failed verdicts and deadlines are unchanged and
cannot be satisfied by the supplementary namespace. The registered portable
package suite has 121 unique tests; eight executable Lua lifecycle boundary
replays and three independent rejection mutations qualify the new owner with
explicit doubles. Actual supplementary Darwin measurements remain pending the
next non-release checkpoint; keep the original native/physical limitations open.

Incomplete native Karabiner feature receipts now retain a bounded summary of actual variant/error counts, fixed observation flags and whitelisted public failure stages. Every runtime identity and private publication scope must match before any observed detail is rendered; unknown Lua text, source paths, script arguments and configuration data remain omitted. The original ValueError, failed verdict, deadlines, native retirement and preference restoration contracts remain unchanged, including the retained primary error when cleanup also refuses. The registered packaged diagnostic suite covers 127 unique cases. Portable regressions qualify the evidence path; actual Karabiner feature measurements and native control admission remain pending.

TODO 16 remains partial. The compiled Windows launch failure now emits bounded native initial executable/start-time identity, descendant PID/parent/creation/path observations with explicit parent-lifetime qualification, and the actual bootstrap/unified log tails resolved from the shared application-directory catalogue. Observation refusal and truncation remain explicit; process argv is not printed. These diagnostics cannot qualify a replacement, readiness or cleanup and leave the original 120-second process/marker/dialog verdict unchanged. Portable baseline collector regression and 14 mutation controls passed with all 353 JS checks; actual Windows PowerShell/native receipt qualification and the startup cause remain pending CI.

Manual CI validations now use an independent concurrency group per run, so advancing the single persistent CI branch does not cancel an earlier manual validation or replace a pending one. Automatic runs retain their branch-level supersession policy. The existing push-only release plan, publication gate, permissions and mandatory OS jobs are unchanged. The registered pipeline guard rejects branch-only/manual-SHA collisions and loss of automatic supersession/cancellation. Native three-OS validation and release-skipped confirmation remain required; item 16 stays partial.

TODO 16 / 40 remains partial. The native Karabiner probe now projects exact generator merge refusal boundaries into bounded public codes after strict receipt identity/schema admission; arbitrary paths, configuration, provider errors and descriptions remain omitted. Independent tests keep unknown producer messages omitted and preserve the original complete/publication/cleanup verdict. Checkpoint 37112320507 proves the first generated batch reaches a refused merge with zero variants, private source restored and independent codec trees; the exact native refusal code still requires the next macOS CI checkpoint. Original AppleEvent transport failures remain mandatory, and no Karabiner driver or runtime lease is enabled by this diagnostic.

TODO 16 remains partial. The shared Node test reporter now lets forwarded stdout/stderr and final failure annotations drain before natural shutdown, preserving wrapped process statuses and the existing fitting-detail assertions. Actual slow-reader CLI regressions cover native child and PARSE_FILE failure, complete bounded notices and all full error annotations, exact JSON counts, large stderr, success, spawn refusal and usage refusal. This fixes diagnostic transport truncation only; application/native failures retain their original mandatory verdicts. Windows/macOS execution of the portable Node lifecycle tests remains pending CI.

The CI pipeline keeps one approved concurrency owner in ci.yml: workflow_dispatch uses its own run ID, while automatic runs supersede the previous automatic run on the same ref. The wiring guard now refuses extra groups in reusable-workflow callers and every called OS workflow/job, including quoted YAML keys, so one native lane cannot silently cancel a different manual validation. Real Windows-caller, macOS-workflow and Linux-verdict mutations demonstrate the prior hole; missing and duplicate root groups are refused, while embedded run-block text is not interpreted as a YAML key. Release conditions, permissions and secret gating remain unchanged. This follow-up is qualified by local proportional format and JavaScript gates; complete three-OS validation remains under the existing native checkpoint requirements.

Native reporter lifecycle self-tests are now mandatory on the Windows
unit host and the macOS Swift-unit host, after the repository Node runtime
and before product units. Linux keeps the registered Core JS execution.
Real workflow mutation guards reject missing, conditional, forgiven,
duplicated or reordered native self-tests. Hosted Windows/macOS execution
remains pending; this wiring change does not alter release gates.

TODO 16 remains partial. The supplementary exact-PID no-prompt native send now spends eight seconds inside the unchanged ten-second subprocess deadline, retaining the existing two-second native deadline margin for JXA construction and numeric status delivery. A real-process regression reproduces the former receipt loss; original PATH, PID, feature, cleanup, admission and timer assertions remain mandatory. Actual macOS no-prompt status and the cause of the original PATH failure remain pending native CI.

Compiled Windows first-use bootstrap now derives its reload capability
from the actual A_IsCompiled state and the existing startup-smoke owner.
The same acknowledged atomic source/stub publications continue in the
resident compiled process; source-mode changes keep their terminal
Reload/Exit handoff. Native child regressions exercise the real generator,
filesystem and leases for missing, changed, matching and refused stages.
The actual compiled startup smoke and native AHK regressions still require
the next Windows CI checkpoint; lineage or exit zero is not readiness.

The supplemental no-prompt PID diagnostic now records two fresh, exact-owner server witnesses and a bounded monotonic sender-stage prefix. Entry, completed execution, native send status and reply admission remain distinct; a witness cannot replace either original ten-second control or feature proof. Strict scalar receipts reject stale identity, replaced inodes, symlinks, nonregular or oversized files and malformed stage order. Acknowledged cleanup retains the exact receipt scope while its sender remains unsettled, rejects replacement requests and removes witnesses only after physical child retirement. Cleanup refusal keeps the scope owned for a later retry. Malformed supplemental JSON errors remain closed and cannot expose private receipt keys. Original controls, preference restoration, native eight-second send and ten-second child deadlines are unchanged. Portable causal regressions and generated-body execution qualify instrumentation only; the actual macOS bridge, SIGSEGV stage and readiness cause remain pending the next non-release native checkpoint. Signal 11 is not classified as a consent refusal, and item 16 remains partial.

Compiled Windows smoke runs 37120948767 and 37121403261 failed the
existing tracked-parent/marker guard after a native parent exit 0; CIM
same-executable descendants did not establish a readiness/handoff ACK.
The lane now retains fresh negative JSON before compiled startup and
closed native identity/exit/phase observations on failure, with an
always-run upload of that owned JSON. Original marker/wait/deadline/exit
and mandatory verdicts remain strict. Registered mutation guards and
actual aggregate refusal tests cover incomplete/failed receipts; hosted
failure-artifact execution and the separate bootstrap cause fix remain
pending native qualification.

Windows qualification now reads actual menu item types independently of packed submenu counts and retains native ten/eleven-child probes with real leading, trailing and doubled separator controls. The build-identity fixture accepts only the two known provider signatures and checks the actual default version row. Bootstrap fixtures resolve their already-owned temporary directory through native GetLongPathNameW before deriving expected forwarding bytes, matching the independently observed child identity. All existing byte, durability, terminal handoff and refusal assertions remain intact; production code is unchanged. Corrected native execution and complete packaging/install qualification remain pending the next non-release Windows checkpoint.

CI updater qualification remains partial: the Linux installed-old-build live
updater authenticates only the trusted shared-catalogue release endpoint
through its fixture HTTP wrapper and existing contents:read workflow token.
Authenticated requests forbid redirects, preserve native
ownership/cache/limits, and keep real403/3xx refusals red. Controlled
actual-adapter origin/privacy/getter/redirect regressions pass; full
selected and hosted real download/SHA/install/restart remain required.

TODO 16 remains partial: supplemental native readiness diagnostics now test
the exact NSError code/domain and AppleEvent int32 getters using
independently constructed -1712/-50 controls, a fresh nil reference and an
absent error descriptor. Fresh nonce/PID-owned receipts retain strict scalar
and send/handler read boundaries separately from native admission. Original
AppleEvent controls, verdicts, deadlines, preferences, restoration and the
default JXA script remain unchanged. The eight new portable cases fail
against the original source and pass with the candidate; all 70 original
probe tests remain byte-identical. Actual Cocoa scalar/branch qualification
and the original macOS clean/Karabiner readiness controls remain pending a
complete native CI run. Neither missing server witnesses nor SIGSEGV
establish a permission verdict.

CI updater authentication accepts opaque RFC 6750 bearer credentials rather
than imposing a GitHub prefix or arbitrary length. The original validator
refused a masked nonempty CI credential before HTTP. Controlled short, long
and punctuation-bearing credentials reach the actual adapter; malformed
padding, controls, whitespace and injection still refuse. Diagnostic
response text removes the exact owned credential before generic redaction
and clipping, preserving actual HTTP status and bounded response context.
Trusted release authority, authenticated redirect refusal, caller ownership
and private-stdin header transport are preserved. TODO 16 remains partial:
release download, verification, installation and restart still require
hosted validation.

The first openSUSE install in manual run 37117084223 stopped in test
tooling before the product installer (environment exit 2); the same image
and unchanged harness had passed in run 37116696443. The native zypper
exit and bounded solver/download/TLS/unknown token flags now survive the
tooling boundary without raw output, retries or package-policy changes.
Controlled package-manager regressions retain the exact native return,
original outer refusal and unchanged install arguments; a fresh hosted
failure is still needed to identify the original cause.

Checkpoint 37132404823 completes the actual Linux update and restart step,
while five ordinary conditional HTTP 304 responses produced error annotations.
The observational probe now reports those responses as notices; cache admission
still belongs to the unchanged updater manager. Exact transport response,
callback and cleanup receipts are preserved, and an updater refusal keeps its
original nonzero verdict. Registered native-adapter regressions reproduce the
old diagnostic level and retain missing headers and empty-body evidence.
Complete three-OS qualification remains pending.

TODO 16 remains partial: the native AHK suite passed 8,061 cases and the full-driver startup smoke passed, but the fresh private source clone reached READY and was refused by the observer before warm qualification. Add a closed five-boolean refusal receipt for CIM presence, image presence/equality, command presence and exact first-script-argument identity. Preserve the actual admission, generation, image, handle and cleanup predicates. Native PowerShell regression vectors and actual cold-clone receipt still require Windows CI; no alias cause or identity-admission correction is claimed.

TODO 16 remains partial: supplemental constructor and decoder facts are now retained as closed diagnostic summaries after the owned packet scope is retired. Constructor integers report only the independently expected -1712/-50, unavailable, or unexpected_integer; domains, nil references and error descriptors report only validated primitive types and flags. Actual decoder integers report presence, not a native status verdict. This exposes which existing getter failed without raw private payload or a guessed Cocoa conversion. All 78 original probe test bodies, the entire original/default instrumented JXA source, control verdicts, deadlines, packet schemas, physical retirement and cleanup remain unchanged. The original macOS clean/Karabiner controls and actual Cocoa scalar qualification remain pending native CI.

Linux X11 source qualification now recognizes the native serializer's horizontal alias-column spacing while comparing complete alias names and targets. The existing exact-map, group-epoch, changed-alias, and native-Wayland refusal checks remain intact. An actual owned Xvfb reproduction fails with the former matcher and passes with the corrected matcher, including reordered aliases with different input spacing. This qualifies the controlled X11 source owner, not physical hardware or a native Wayland seat; the complete three-OS release-free checkpoint remains required.

TODO16 remains partial. Native source run37134285521 reported exact executable identity but refused the first script argument. AutoHotkey v2.0.26 normalizes the source filename, including 8.3 expansion, before Reload. Normalize only the caller-selected existing absolute file before initial launch; preserve exact first-script-argument admission, generation, image, handle and cleanup checks. A real native Reload control requires supplied dot-segment spelling to fail exact comparison and its canonical spelling to succeed, then verifies both generations retire. The observation retains caller-selected spelling. Actual cold/warm private clone qualification and the real failing runner alias remain pending Windows CI; no parser-option or file-ID admission fallback is introduced.

TODO16 remains partial. The real native Reload preflight imports its observer by dot sourcing, which shares parameter-variable scope. Preserve the actual interpreter and private root during that LibraryOnly import, and assert exact post-import identity before the unchanged nine admission vectors and real Reload control. Product clone cold/warm qualification remains pending Windows CI; this fixture correction does not grant new process cleanup authority or change its deadlines.

A separate bounded Cocoa calibration now compares the current Ref out-slot with an explicit object holder through real NSJSONSerialization NSError\*\* calls using inert malformed UTF-8 JSON. It records strict NSError identity, code 3840, NSCocoaErrorDomain and a native nullable-descriptor projection independently of the original raw scalar facts and AppleEvent verdict. The default sender, mandatory transport/feature gates and existing deadlines are unchanged. Portable generated-source regressions pass; actual Cocoa calibration and the unresolved packaged AppleEvent transport still require native macOS CI.

TODO 16 remains partial: the compiled-startup admission C# fixture now normalizes its actual own executable through checked native GetLongPathNameW, matching the pinned AHK receipt producer. A native controlled short-alias child requires independent open-file volume/index equality and an exact long-path receipt before admission; foreign same-basename files, invalid paths and unknown modes remain refused. The validator, workflow and cleanup authority are unchanged. Portable admission and producer mutation checks pass; native Windows execution of the corrected positive and all seven negative scenarios, followed by the real compiled installer launch, remains pending. Historical native failure on run 37142330761 is preserved.

The supplemental packaged AppleEvent decoder now uses the NSError object holder qualified by actual Cocoa calibration, and projects nullable descriptors only after native bridge provenance and exact nil acknowledgement. Raw callable bridge types remain separate closed facts. The original unscoped/PID sender bodies, constructor, send options and 8-second native / 10-second outer deadlines remain unchanged. The 96 Python regressions include exact generated-source Foundation-port replay, strict malformed/class/type/provenance refusals, and mandatory server-witness admission. Native qualification of the corrected sender and complete packaged launch remains pending; calibration does not acknowledge transport or readiness.

Partial native qualification: the Windows indentation fixture now retains closed Boolean collector, borrowed-writer and notification observations in its unchanged writer-count assertion. This diagnostic delegates to the actual production owners without changing persistence, admission, native deadlines or expected values. The pre-write refusal remains unclassified until actual Windows CI produces those observations.

Partial native qualification: the Windows transaction fixture now supplies the mandatory system_multi string in its stored profile. The actual stored-profile serializer and complete full-save collector are exercised with that valid image and an independently detached missing-field refusal. Existing native indentation writer-count, source, refusal and one-owned-leaf assertions remain unchanged. Hosted Windows qualification is still required.

TODO 16 remains partial. Add bounded owned native NSError integer-getter observations for the inert Cocoa calibration, known constructor and actual no-prompt sender. Record raw getter type, NSError/NSNumber native provenance and closed integer projection agreement without admitting callable getters or changing native deadlines, phases, result predicates or status policy. The exact diagnostic has 102 portable Python/Node-port tests, an original-source missing-receipt red case and three failing ownership/scanner mutations. Actual Foundation getter/NSNumber qualification and full cold/warm/compiled macOS validation remain pending hosted CI.

Partial native qualification: Windows own-module alias control failures now retain a closed classification of the actual captured stderr: whitelisted exception type, an exact authored fixture refusal, fixture method names, and output character counts. Raw native error text, paths, arguments and stdout remain withheld. All existing own-file 8.3 controls, native exit/stderr assertions, readiness checks, deadlines and cleanup remain unchanged; the underlying runtime exception is still unclassified until hosted Windows executes this diagnostic.

Actual macOS Cocoa observations now prove that the owned NSError and independently boxed NSNumber integer getters are bridged as strings. The supplemental no-prompt decoder qualifies that representation only with exact native NSError/NSNumber provenance, a matching safe integer and the retained current getter; arbitrary strings, callable/Boolean values, foreign classes and mismatches remain refused. All 102 prior portable tests and the original sender/deadlines/gates remain intact. The next actual native run must qualify the new projection before interpreting any transport or TCC status; the original AppleEvent readiness and native feature verdicts remain mandatory.

The compiled native fixture now admits a real 8.3 alias only when Framework-normalized input and independently obtained native canonical image agree and both identify the same physical file. Absolute regular canonical output remains mandatory; drive-relative, root-relative and dot spellings are refused, with actual same-file negative controls. All original native alias/foreign/launch/status/cleanup assertions remain. The prior hosted failure exposed a Framework input-spelling contradiction; portable source qualification passes, while actual corrected Framework/Win32 execution and complete native acceptance remain required.

Actual Windows native C# short-alias identity controls now pass, but the following compiled startup fixture used the short TEMP directory spelling while its strict process-bound observer returned the native long path. The fixture now resolves only its acquired private directory through Node native realpath and verifies independent BigInt volume/file identities before constructing package paths. The product recorder, native observer and C# validator remain unchanged. Portable real filesystem alias and strict-recorder controls pass and reject the original policy plus foreign or unavailable identity; actual Windows compiled startup qualification remains required.

A Windows native independent-CIM enrichment control once reached the minimal fallback despite earlier success with unchanged code. The test now retains closed primary completion status, received UTF-8 byte counts, exact deadline/attempt/task observations and the owned deadline marker in its unchanged strict-primary failure. Production enrichment, five-second primary budget, thirty-second test wait and exact cleanup are unchanged. Two native callback/privacy receipt cases are registered; local source/convention/encoding qualification does not establish native Windows execution or repair the underlying cause. Actual Windows CI remains required.

TODO 16 remains partial. The Windows native launch evidence gate now reads log paths through the exact Python standard-library catalogue command already owned by its workflow, instead of importing an unavailable npm TOML parser in the package-only job. The canonical-directory, C# alias, native observer, log-root selection and cleanup assertions remain intact. Package-less Node loading and real canonical/independent TOML parsing pass locally; hosted Windows startup-log controls and the actual compiled artifact launch still require complete CI qualification.

TODO 16 remains partial. The native Windows brightness provider fixture now retains closed owner-stage facts before mandatory teardown when its unchanged five-second settlement assertion fails. The native acquisition, WMI ABI, percentage/readback expectations, and physical cleanup contract remain unchanged; this diagnostic does not attribute the earlier timeout to hardware or host scheduling. Hosted AHK execution and the full downstream compiled controls remain pending.

Windows startup-log fixture now constructs its native environment from the flat catalogue base returned by the workflow-owned strict reader. The entire actual consumer is covered by an isolated four-scenario regression with real temporary files and cleanup; exact old nested access and wrong-key/no-consumer mutations refuse. The production collector, canonical physical-directory owner and compiled C# controls are unchanged. Actual PowerShell/native startup qualification remains pending hosted CI. TODO 16 remains partial.

Added failure-only Windows full-driver startup evidence at the existing logger shutdown refusal. The optional native logger receipt contains only the refusal phase and atomic ownership/queue counters; it never includes log messages, sink names, paths, file objects, handles, or an inferred native error. The existing Boolean preflight, I/O order, durability error, ready publication, and smoke deadlines remain unchanged. The smoke emits the fixed packet on its already captured stdout without adding logger debt. Registered native tests retain the full original sink tests and add active-owner, real sharing-denial, detached-receipt, and primitive privacy checks. Focused source/inverse/encoding/loop checks passed; full selected verification and Windows execution remain pending. This diagnostic does not establish the underlying cause of the observed refusal or complete item 16.

Supplementary received-Lua location evidence now uses only the already-loaded BootJournal append owner, an actual typed managed PID and the fresh command nonce before later identity/JSON/witness prerequisites. The existing launch consumer reads its already-owned boot journal after child retirement and exposes only a closed observed/unobserved stage. A complete matching line proves an attempted journal write: publication acknowledgement remains unobserved, qualification remains false and entry timing remains unknown, including when write/flush/close refusal leaves complete bytes. All original command, transport, entry, feature, cleanup and 8/10/2-second bounds remain mandatory. Author-focused Python/physical Lua journal calibration passes332 tests; actual managed macOS execution and causal diagnosis remain pending. TODO16 stays open.
The existing package-macos verdict self-test now provisions Lua5.4 and LuaJIT explicitly and binds their checked Homebrew keg paths only to that step. The physical tests reject configured invalid paths or a different interpreter ABI without PATH fallback. Homebrew installation and the managed macOS stage remain pending hosted CI; author workflow recording ports and both actual local interpreter calibrations pass.

Windows native CI transcript ownership correction: checkpoint 37196891594 reached the real runner but its first plan append was refused with ERROR_SHARING_VIOLATION (32). The live CI reader held the same receipt that AutoHotkey FileAppend opens exclusively. Both Windows suite owners now wait for the exact retained native process to exit before opening and publishing the complete UTF-8 transcript; native exit, deadlines, planned/executed completeness and strict printer refusal assertions remain unchanged. The actual workflow contract and old-reader negative replay pass focused portable qualification. Controlled real Windows held-reader/refusal and retired-reader/Unicode cases are registered for hosted CI; native correction and complete three-OS integration remain pending. Items 16 and 101 are not closed by this CI fix.

Partial native macOS diagnostics: the two existing serial keyboard-source XCTest owners now record bounded source identities, enabled/selected/select-capable states, monotonic timestamps and exact status around their original selection/restoration calls. The production translator, all expected glyph/receipt and noErr assertions, both restoration calls and enable/disable order remain unchanged. No retry, wait, observer or additional source mutation is introduced. Portable source-contract controls pass; the four recorder XCTest controls and actual Swift/TIS execution remain unexecuted locally and require hosted CI. These diagnostics do not establish a cause for the intermittent native restoration -50/sourceChanged failure or complete TODO16.

The managed macOS clean/Karabiner diagnostic now starts a separate public NSRunningApplication launch-state observer at exact child selection while the original first PATH control proceeds immediately. Parent monotonic method-entry brackets report before/overlapping/after/unknown without promoting a getter into AppleEvent readiness; owned observer cleanup is required after the unchanged original controls. Cleanup exceptions retain debt and expose only a fixed refusal; native calibration verifies fresh exact private executable/PID ownership before retirement. Physical enumeration refusal cannot skip controller reaping or discard outstanding owned-app evidence. A native AppKit/NSWorkspace identity and Boolean calibration is registered in the existing package self-test and remains mandatory on macOS. The 8/10/2 transport and cleanup budgets and all existing admission assertions remain unchanged. Portable focused tests pass14/0 and causal counterfactuals fail; native calibration and full selected qualification remain pending, so this observation does not identify a TCC, registration, deadlock, signature-cache or handler cause.

TODO 16 / 36 remains partial. Native Observer4 run37208812034 at d7c80bf completed290 XCTest cases with zero failures, but three completion receipts were glued to incomplete TIS_TEST_EVIDENCE output fragments. The strict native reporter correctly refused those incomplete anchored receipts. The diagnostic now assembles its full UTF-8 prefix, JSON (or closed encoding-refusal receipt), and newline into one Data buffer before one FileHandle output call. Native mutation/restore order, all old assertions, reporter gates and resource limits are unchanged.

Three pure XCTest controls exercise the actual emitter for Unicode success, encoding refusal and a bounded receipt larger than4KiB. These are authored but unexecuted locally because Swift/macOS is unavailable. Portable source controls reject five counterfactuals; replaying the unchanged reporter with only the three modeled record boundaries recognizes all290 existing native receipts. This replay does not reconstruct truncated JSON or qualify the new native emitter. Actual macOS CI must confirm full diagnostic framing. One FileHandle call does not establish global atomicity against other output producers.

Manual CI can select all, a single OS, or one of the three two-OS pairs through the strict os_lanes choice. Shared checks always run. Push and pull-request runs keep all OS lanes, and the release job remains push-only with its original all-platform prerequisites and secret guards. The manual verdict rejects missing, failed, unexpectedly skipped or unexpectedly executed work and validates the actual plan selection outputs. Local portable selector/CLI/wiring controls pass; root full selected validation and actual hosted dispatch remain required.

## Maintainer requests added on 2026-09-29 (see the overnight handoff)

Checkpoint 37046411788 at `ea6b21bed` passes all three OSes, including
7,726 Windows unit cases, E2E, packages, installation and launch; release is
skipped. It validates the GUI title policy and navigation case preservation
after native captions were captured through explicit UTF-8 receipts.

The native deferred-logger fixture now takes its immediate observation
inside a bounded Critical region and restores the exact prior state.
The unchanged causal assertion distinguishes inline delivery from a timer
interrupting the observation; an isolated actual-production probe requires
the same assertion to fail under a private inline mutation. Native Windows
qualification remains pending.

The verification planner now selects native AHK parsing/unit/E2E gates for
every shared AHK source, including pure shared policies. Independent planner
regressions fail against the missing selection and retain platform-specific
deferral behavior; changing only a portable AHK policy cannot bypass its
native qualification.

The Windows migration owner now renders explicit deltas from physical TOML
records instead of rebuilding unrelated content. Shared independent byte
corpora cover comments, empty headers and occupied inline namespaces;
physical ownership guards refuse multiline/array-of-table parser inventions
before both planning and boot classification. A schema version forged inside
a multiline string cannot bypass the guard. Current bytes, receipts and
unknown user data remain protected; native Windows qualification is pending.

Native macOS launch diagnostics now sample the exact owned AppleScript child
before timeout retirement and require its actual exit. Timer observations
keep the same ten-second script deadline and all eighteen checks; bounded
diagnostic sampling does not turn timeout into success. Collected native
frames are included in annotations without assigning an unproven cause.
System Events collection failure cannot replace the primary failure or
prevent result.json publication; primary and cleanup errors remain distinct.
Forty-five diagnostic regressions pass, including a real blocked child that
is sampled before termination and reaped. Native cause and qualification
remain pending in the next macOS install/launch run.

Remaining Hammerspoon runtime acceptance, separated from the completed
JSON-reader migration: audit other stubs and qualify their actual native
contracts. The real Karabiner publication vectors remain item 40.

The settings stub now snapshots valid acyclic values on write and returns
independent graphs per read, retaining native equal-child aliasing within a
read. Its clear receipt matches native true/false; set remains void. Direct
snapshot regressions failed before the fix, and a real learning/debounce
regression prevents unflushed updates from appearing persisted. Focused
cases passed, and the settings slice passed the complete three-OS pipeline
in non-release run 37039329959 at `ea5d64ef6`. The delayed timer now keeps a configured default separately from
one-start overrides, provides native running/nextTrigger and chainable
setDelay receipts, and retains callback rearming. Five direct contract cases
failed before the fix and now pass; a real SyntheticInput listener retry
regression failed with one delivery before passing with two. Generic doAfter
semantics stay separate. The stub slice passed complete three-OS
checkpoint 37046598989 at `051504e0a`, including packages and installation,
with release skipped.
The packaged clean macOS launch requires these contracts to be qualified in
its real signed Hammerspoon process through a temporarily owned scripting
preference.
Strict receipts require 18 measured observations, runtime identity, nonce,
self-rearm deliveries and acknowledged preference restoration; aggregate
evidence refuses missing or partial proofs. Local probe judges passed their
red/green regressions; actual native execution is not yet qualified. Run 37046757566 exposed
a clean-launch scripting timeout and a refused physical preference restore;
no incomplete proof is accepted.
Audit other hs stubs for remaining divergences from native behaviour.
The probe now restores an initially absent scripting preference with an
acknowledged targeted deletion and exact physical readback, preserving
unrelated runtime changes. Observation and cleanup refusals retain both
causes; 14 focused and 40 aggregate Python cases passed after the new cases
first reproduced merged-import and masked-error failures. The 18 native
measurements remain mandatory; the real control channel still needs CI.
The pasteboard stub now retains isolated UTI-to-bytes snapshots, returns
nil for absent text and keeps clearContents void. Four direct cases and the
actual SyntheticInput consumer first exposed missing payload publication;
they now pass, including exact text at Cmd+V and later text/RTF/PNG recovery.
The complete pipeline remains pending for this stub slice.
The shared Hammerspoon canvas stub now copies frame values at construction,
assignment and reading, matching the pinned native 1.1.1 NSRect API. Actual
GraphicsRenderer callback observations are asserted outside its production
pcall; four original alias failures precede five focused passing cases.
The complete macOS unit gate passes 12903 cases on the isolated candidate;
native three-OS qualification remains pending.

- [~] **19.** Windows tooltip border hidden under its content and white corner
  pixels (pooled border z-order + ring drawn from the content region).
  Integrated; verify visually on Windows 10/11.
  Ergopti-only distance and SFB reduction, rolls and repeat corrections now
  come from the Ergopti extension. Their declared bindings preserve the historical
  categories, preference sections and `common` priority. These source files are
  unchanged since non-release checkpoint
  [37008038530](https://github.com/adrienm7/ergopti/actions/runs/37008038530)
  at `b92d9dec8`, which passed the complete three-OS unit, E2E, packaging and
  installation pipeline with release publication skipped. Item 37 retains the
  installed-layout visibility and French suffix/magic-key placement decisions;
  item 104 separately tracks the common-autocorrection section split.

- [~] **24.** macOS tap-hold outage: a not-ready remap guardian held every
  Karabiner regeneration forever and pinned the first bulk edit (Restore
  defaults), refusing later edits and Reload. Fixed, with a Tap-Hold menu row
  saying why tap-holds wait. Guardian approval UX: registration was already
  automatic; a requires_approval answer now opens numbered Login Items steps in
  the native permission dialog (once per launch, after the Accessibility dialog,
  closed automatically on approval; not while Tap-Holds are off, where the
  banner stays). Integrated; verify on a Mac.
- [~] **30.** Physical magic-key setting on all three OSes: one
  `hotstrings.magic_key_source` (a KeyboardEvent.code, `auto` by default),
  config schema v5 migrating every spelling of the Windows
  `magic_key_source_scan`, and a Layout menu row that captures the next physical
  key or lists the candidates. Published in the second 2026-09-30 release. A
  chosen key replaces only its plain press (Windows keeps the layout's
  Shift/AltGr/Ctrl/Win), the Windows capture reads the physical key state, Linux
  refuses a key it cannot type without the clipboard and cancels a pending
  Compose. Remaining: real-device checks on each OS (Windows capture under the
  emulation, macOS on ISO and ANSI boards where Backquote and IntlBackslash both
  answer, Linux grab and injection). The Linux Layout menu now renders its
  existing shared replacement switch before the physical-key picker, through
  the canonical hotstring choice owner: only an acknowledged durable write
  changes the active catalogue and notifies the tray; refused writes preserve
  the original bytes and runtime, and paused or closed-group callbacks cannot
  write. Its focused native Linux regression covers the menu and transaction;
  full three-OS CI and real-device acceptance remain pending. Linux follow-ups:
  choosing Backquote, Minus or Equal silently
  overrides a tap-key action. An acknowledged Linux tap-key consumption now
  retires only the previous wrap-on-type PRIMARY window before its deferred
  action runs; unassigned, modified and refused tap keys still reach ordinary
  wrapping, and a new pointer selection can open another window. Actual daemon
  E2E cases check screen output and exact queue/action/PRIMARY receipts. Native
  CI and real-device checks remain pending.

The selected local gate passed 353 JS checks, 4,946 Linux unit cases and
144 Linux E2E checks. Nine causal menu/transaction regressions and the three
existing macOS placement cases pass. The Windows renderer and shared menu
declaration are unchanged; complete native qualification remains pending.

The tap-key lifecycle fix reproduced two stale-selection failures before the
change; its qualified component gate passes all 154 Linux E2E checks, including
the 144 existing checks, 17 X11 source checks and 4,937 Linux unit cases.
The current composition reruns JavaScript and the complete Linux E2E suite.
Windows and macOS use separate selection cache owners; their native freshness
and physical-device acceptance remain unqualified by these Linux results.

The macOS registered Tap Keys callback now retires positive and negative AX selection-cache freshness only after the actual deferred producer acknowledges scheduling. Independent registered-callback regressions use the real AX text reader within the unchanged 0.2-second TTL, verify fresh selection creation/removal, preserve deferred execution, and retain rejected-queue, modifier, unassigned, closed-admission, synthetic-provenance and autorepeat behavior. Portable macOS units/E2E qualify this source slice; native three-OS CI and physical input remain separate requirements. Windows physical input epoch invalidation is source-reviewed only; its real tap-to-UIA epoch transition is not yet qualified.

An acknowledged chosen Linux magic-key press now owns its auto-repeats through a strict per-source/key callback receipt. Its published native-origin and active-XKB epochs, preference generation, pause, modifiers, capture and injection acknowledgement must remain valid. An initial Compose-cancellation refusal retires optional repeats while preserving the consumed first output. A refused or stale repeat stays suppressed until physical release; ordinary tap and capture consumers remain once-only. Completed initial keyboard startup publishes native-origin admission before the first eligible press, without per-repeat device rescans. Independent actual-daemon screen/receipt cases reproduce the former behavior. Separate watchdog recovery gaps, real-device three-OS acceptance and the magic-source/tap-action collision remain pending.

Completed Linux keyboard recovery publishes its actual native origin before the first eligible fresh press. Retained consumed source/key owners keep suppression through reopening and successive reacquisitions while their previous repeat callbacks are retired. A conclusive native released-key snapshot also retires debt when the release event was lost while the descriptor was closed; an unreadable query acknowledges no release and retains suppression until an observed key-up. One snapshot per indebted retained source covers multiple keys, without per-key or per-repeat queries. Added and retired sources keep separate ownership for the same key code, and warm acquisitions reuse already-qualified native origin. Independent real start/pump/watchdog regressions reproduce the missing epoch, raw-repeat leak and swallowed fresh press. Physical hotplug/manual Windows/macOS/Linux parity remains pending.

Completed L4 layout scope: the [Ergopti manifest](../static/layouts/registry/ergopti/manifest.toml)
and [shared extension owner](../static/ergopti_plus/_shared/lua/layouts/extension.lua)
route geometry-dependent sections; Windows keeps base/Shift, AltGr/ShiftAltGr
and number-row choices independent. Existing
[Windows registry tests](../static/ergopti_plus/windows/tests/unit/test_keylayout_emulation.ahk),
[Linux geometry tests](../static/ergopti_plus/linux/tests/unit/modules/hotstrings/test_extension_geometry_routing.lua)
and [macOS binding tests](../static/ergopti_plus/macos/tests/unit/modules/keymap/test_registry_bound_sections.lua)
have named passing cases at [checkpoint 37216141887](https://github.com/adrienm7/ergopti/actions/runs/37216141887),
with their audited sources and independent corpus unchanged. Item 6's layout
requirements are complete. All unresolved magic-key ownership, watchdog
recovery, native freshness and real-device requirements above remain in item 30.
Hosted Lua owner tests do not qualify physical input.

- [~] **31.** HS-274 exact physical key accounting with an Ergopti-owned
  background Karabiner runtime (no Karabiner-Elements app). Plan, decisions and
  ADR 011 in the overnight handoff and `static/ergopti_plus/docs/adr/`. WP0-WP2
  are published (decision record, one accounting policy whose default `legacy`
  mode is byte-identical to dev.147, HID usages with aliases in
  `_shared/data/keycodes/hid_usages.json`, a key-identity policy). Remaining, in
  order: WP3 production consumer owner (plan section WP3 lists the review notes:
  settle held modifiers when the source changes, map a refused producer version
  to one unavailable WARNING), WP4 headless fork producer emitting baseline v2
  (the native harness refuses early until then), WP5 reproducible runtime
  artifact, WP6 install/launchd ownership and the default-on "close other
  Karabiner instances" option, WP7 owned configuration, WP8 native acceptance,
  WP9 real-Mac acceptance (internal keyboard: verify the ISO 0x35/0x64
  assumption and fn/globe), WP10 enable and retire. Open: an identity for media
  keys without a macOS keycode (play/pause, track skips, brightness), and a
  VirtualHIDDevice version-skew policy. About 30-40 agent-days plus maintainer
  hardware time.

WP3 prerequisite: the actual macOS physical accounting owner now requires exact held-modifier settlement before accepting source transitions. The keylogger retires each crossing physical release without emitting an orphan hold or a new press, including pause and secure-context crossings; ordinary legacy and collision behavior remains unchanged. Existing native fixture parents restore their settlement child through the scoped cache owner, while normal production stop/restart retains the same CoreState. Portable focused tests pass (32 held-key cases, 24 policy cases, 3 legacy collision cases, 23 existing cache-scope cases, and 9 unchanged alias configuration/privacy cases); the original real gap-release source fails all eight side-key cases. This does not enable a producer or headless mode, alter transport/baseline versions, or complete WP3/WP4/native acceptance. Full root and hosted macOS qualification remain required.

## Remaining work after the 2026-09-30 releases

- [~] **33.** Config policy for the files other than config.toml (the former
  item 25): Published in the second 2026-09-30 release for the files the review
  listed; see `docs/memory/text-input-and-config.md`. Still open everywhere:
  sites 76 (no catalogue of parameter bindings), macOS 14/93 and order overrides
  (no "catalogue published" signal), 16/91 (expert `[script]`/`[features]`
  layer), 18 (dynamic model list), 19, 24, 26, 28, a Karabiner key bound to a
  plain string (saves refused with a generic ERROR), Linux layers.toml refused
  as a whole still stops the daemon, Windows sites 32, 34, 36, 37-60 and its
  whole-file installed.json refusal, and the macOS boot-time unread-entries
  scan cost (36-56 ms on the
  main thread). Two maintainer decisions are pending: config_migrate's
  fail-closed guard for invalid stamps (site 108) and a migrations.toml
  exception for key removals handled by the cleanup (site 112).

  Windows tap_hold.toml now reports each obsolete entry once per exact file,
  rendered path and reason during the process, through the shared warning
  owner. Repeated real reads retain valid bindings and preserve unknown
  scalars, arrays and inline tables byte-for-byte. Known-field ERROR/refusal
  behavior is unchanged. An independent twelve-observation corpus runs on
  all three drivers; portable unit/E2E checks pass. Logger callbacks retain
  their caller's Critical state and reentry observes the claimed report.
  Native Windows and complete three-OS acceptance remain pending.

Linux ordinary TapHold saves and recommended imports now use the existing shared classified reader: only native ENOENT permits an absent document; access, other open, read and close failures refuse before mutation, backup/staging/publication or reload. Malformed-source behavior and unknown fields remain unchanged. The registered real-writer module retains all 26 original cases and adds 13 controls: the original writer gives 28 passes / 11 failures, the corrected writer 39 / 0. macOS and Windows already refuse classified unreadable sources through their existing owners. Full selected verification and hosted native CI remain pending; TODO33 stays partial.

The Linux daemon now isolates only the existing shared loader’s classified whole-file layers.toml refusals during its initial tap-hold engine load. It logs the refused navigation file, leaves its bytes untouched and installs the independently valid tap-holds with an empty navigation layer, matching the existing Windows and macOS boot policy. Shared registry and native compilation failures still raise; every subsequent reload and scope candidate remains strict and retains the acknowledged engine on refusal. The registered real-manager regressions fail five cases against the original owner and pass all ten after the fix; all 29 existing hook/manager/writer integration cases pass with LuaJIT. This is bounded portable owner evidence, not physical Linux startup or complete three-OS acceptance. Full selected verification and hosted native qualification remain required, and TODO33 stays partial.

After the classified-read prerequisite, Linux TapHold ordinary setters and recommended imports now require an acknowledged temporary-file write and close before rename or reload. Genuine LuaJIT/Lua5.1 Boolean true and Lua5.4 same-file write receipts are both accepted; nil, false, wrong objects/strings and exceptions refuse. Refused candidates are cleaned only at the owned temporary path; cleanup refusal still leaves the original source and runtime untouched. Unknown fields and existing post-publication reload semantics are preserved. All 39 prior registered cases remain exact; 13 added controls give old 40 passes / 12 failures and corrected 52 / 0 on both Lua runtimes. Windows and macOS already require their native staging writer acknowledgements. Full selected/hosted native qualification remains pending; TODO33 stays partial.

The Linux hotstring editor now reads one classified save-time source snapshot, validates those exact bytes with the canonical TOML codec, and requires the hotstring projection’s explicit commit receipt before preserving tuning and replacing its owned model. Publication carries the existing exact-source precondition; malformed/unreadable sources and observed concurrent replacements refuse without reloading or reporting saved. The five old persistence cases, ten existing editor cases, twenty native-file admission cases, five deployed TOML dialects, and three causal mutations were checked privately. The independent 140-rule corpus is unchanged. This is a TODO33 preservation prerequisite; opening-time stale-page ownership, unknown fields/comments, other data-file writers, TODO104 fanout migration, and complete native/root CI remain open.

- [~] **34.** Match the Windows recommended hotstring delays to the shared
  manifest, and make hand-written `[[hotstrings.terminators]]` lists editable.
  The shared AHK override policy now writes an explicit recommended delay only
  when inherited source metadata differs; clear restores that inheritance.
  Independent delay vectors run through Lua and native AHK contracts, keeping
  personal/unknown parameters and transactional refusal recovery intact.
  Both Lua drivers share shipped-delimiter restoration; macOS applies it to
  file/runtime/next-save state and restores its snapshot on refusal.
  Windows native units, engine E2E, packaging and installation passed in
  validation run 37084553184. The overall run remains unsuccessful because of
  the macOS clean-launch gate. Editing hand-written array-of-table delimiters
  remains unfinished.

The measured-delay native fixture now isolates the real corpus metadata
cache from the earlier resolution-cascade double and restores the exact
prior cache identity. Its original inherited 1.0-second, recommended
0.5-second, resolver and refusal-recovery assertions remain intact and passed
in the native Windows qualification above.

macOS custom-delimiter deletion now requires exact runtime acknowledgement
before changing state or saving preferences. Runtime refusal preserves the
original definition and source; disk refusal restores the real registry and
settings through the existing preference transaction and permits explicit retry.
Eight regressions first failed against the original caller, then passed; the
selected portable suites passed 353 JavaScript checks, 13,177 macOS unit cases
and 101 E2E checks. Linux and Windows retain their existing acknowledged owners.
Five real-owner regressions now cover macOS Add/Delete and publication-refusal
recovery for independently hand-written delimiter arrays. Boot replay retains
unknown nested fields in each admitted record and normalizes only its owned
label/consume defaults. Untouched valid neighbors, standalone comments and
foreign array-of-table siblings survive the actual preference writer. The same
five cases fail against the original replay. Linux already merges untouched
stored records; Windows manages delimiter strings in its existing override
transaction instead of projecting custom record fields.

The shared writer intentionally replaces a changed array-of-table list with an
inline list. Its inline record comments normalize with that rewritten value;
standalone comments and foreign table bytes remain preserved. Complete native
three-OS qualification remains pending, so item 34 stays partial. Item 42
retains its separate parser and outdated-setting decisions.

The selected source gate passed 353 JS checks, 13,191 portable macOS unit cases
and 101 E2E checks; its two code files remain byte-identical. Fresh composition
with the shared Word menu passes five preservation and eight Delete transaction
cases; the existing Linux persistence case also passes. Native qualification
remains pending.

Linux custom-delimiter saves now claim only the stored occurrence admitted by
the existing reader. Unrelated Add and acknowledged Delete preserve unusable
same-key neighbors, their ordering and unknown nested metadata, including an
invalid record before a valid one. Twelve independent regressions failed against
the original planner and now pass through the real catalogue, preference lease
and source-fenced writer, including publication refusal and explicit retry.
The selected source gate passed 5,002 Linux unit cases and 176 E2E scenarios;
strict conventions passed. The unchanged macOS repair-owner module passed its
19 existing portable tests. Windows uses delimiter strings through its existing
native override transaction; no custom-record migration was invented.
Explicit cleanup and the reader's first-usable policy are unchanged. An otherwise
valid duplicate retained after removal may become admitted on a later reload.
Complete three-OS native qualification remains pending, so item 34 stays partial.

Pending custom-delimiter additions and changes are now admitted through the real reader against the planned preserved list before publication or an empty-plan acknowledgement. A retained duplicate cannot silently mask a new key, character, label or consume choice. Semantic refusal preserves source bytes and leaves the delta available for rollback or retry after explicit cleanup; actual writer source fencing and unknown record/comment preservation remain intact. Linux focused registered tests qualify both Delete→Add cases and changed-record collisions; complete three-OS native qualification remains pending.

- [~] **35.** Unregister the remap guardian LaunchAgent when key remapping
  is turned OFF or its rules are removed. The same owned transaction now joins
  STOPPED, exact native unregistration and the persisted OFF/rule removal.
  Refusal retains the prior preference and a fresh READY recovery; unsettled
  registration tasks block retirement instead of hiding process debt. Native
  acknowledgement proves the exact launcher identity, empty durable lease,
  absent legacy job and ServiceManagement registration status. The hosted
  signed-helper acceptance lane also checks wrong-inode refusal, successful
  unregistration and idempotence, retaining primary and cleanup errors.
  Focused registered macOS tests pass 315 cases and the diagnostic judge passes
  six regressions. Complete native Swift, helper registration and three-OS
  qualification remain pending.

Signed-helper acceptance run 37081066757 passed actual native registration,
unregistration and idempotence without a release. The replacement fixture
now acknowledges both weak runtime retirement and actual singleton-lock
release within its existing two-second bound. A retained native ACK callback
must continue to block replacement until it truly exits; every generation
and transport assertion remains intact. Native XCTest requalification and
the complete three-OS checkpoint remain pending.

- [ ] **36.** Packaging remainder (the former item 21): macOS release archive as
      `.tar.xz` (verify Sparkle, the Homebrew cask and CI install first).

TODO36 remains partial. The Versions installer's actual release path now reads an ordered archive policy from shared updater defaults: prefer the declared `.app.tar.xz`, accept historical ZIP only when that preferred asset is absent, and refuse a present malformed or ambiguous preferred archive. Both formats retain exact repository URL and GitHub SHA-256 admission. The macOS extraction adapter preserves digest-before-extraction, version, designated signing requirement, bundle modes and relative symlinks before READY; existing swap/backup/rollback remains unchanged. Current ZIP producers, Sparkle feed/signing, Homebrew cask and Hammerspoon ZIP stay unchanged in this consumer prerequisite.

Focused Lua tests pass 20/20 on Linux with the saved subprocess reaper; all 54 pre-existing assertion lines remain exact and ordered. Actual original installer replay fails five added cases, and three independent original/current selection controls prove XZ-only admission, preferred choice and refusal instead of ZIP fallback. A real Linux tar/shasum shell fixture passes four cases after catching and correcting umask-induced mode loss. These portable results do not qualify native macOS extraction. Two registered Swift XCTest cases are authored for actual macOS ZIP/XZ extraction of a privately signed bundle, exact bytes/modes/symlinks/xattrs, native signing and refusal/retirement; they remain unexecuted until the macOS Package job. Shared full selected gates, native macOS verification and the later producer/feed/cask/CI-install migration remain required before closing item36.

Actual macOS archive tests exposed a designated-requirement display boundary failure and private signing-tool crash-backtrace noise. The native staging owner now captures both codesign display streams and its true status before admitting one nonempty designated requirement, while retaining strict staged-signature verification. Private Swift fixture children use the already qualified enable=no backtrace setting while parent XCTest retains its diagnostics; no stderr assertions are weakened. All original34 signature/archive assertions and native child retirement deadlines remain intact. Actual native extraction and signature cases must pass again before treating this consumer phase as qualified; TODO36 remains partial.

The signature display owner requires exactly one designated-requirement record before shell newline stripping, including refusal of a second empty record. Controlled shell ports preserve the withdrawn first correction's trailing-empty authorization failure and prove refusal before verification on both output streams. Native macOS remains pending.

Native macOS requirement-display qualification remains blocked: the actual owned codesign child exits zero but the designated-record census is zero. The existing signed-bundle test now attaches separately bounded, control-escaped stdout/stderr packets, byte counts, truncation facts and its actual status to the unchanged strict status/designated-requirement assertions. A native calibration checks exact stream retention and independent 2,048-byte bounds. Signature matching, archive validation, deadlines, child retirement and all earlier assertions remain unchanged. The actual display grammar and native calibration await hosted macOS CI; no output-format cause or archive success is inferred. TODO36 remains partial.

The actual macOS codesign display packet in run37165861602 exits zero and emits one commented "# designated => " record containing its native cdhash alternatives. The extraction owner now recognizes exactly that observed prefix alongside the existing bare prefix, counts both before stripping or trimming, and still refuses missing, empty, mixed/duplicate and nonzero displays. The unchanged deep/strict requirement verifier owns signature admission. All earlier XCTest assertions and archive-byte/mode/symlink/metadata, source, environment and physical-retirement checks remain intact; the native test additionally requires the parsed requirement to match its actual signed source. 54 actual Linux-shell profiles/cases with typed native-tool ports pass; three causal mutations fail. Native macOS signature/extraction and Swift execution remain required before consumer qualification or producer delivery. TODO36 remains partial.

TODO 36 remains partial. The pending dual-archive producer accepts only the observed native bare or fixed commented designated-requirement prefix, rejects duplicate/empty requirements before any archive writer, and verifies both restored bundles against the exact extracted requirement. The maximum exposed native XZ preset is 9; the existing ZIP and helper ZIP remain unchanged. Native macOS consumer PASS is required before producer delivery, then actual native producer signing/extraction/readback tests, Sparkle feed and Homebrew migration remain pending.

The stable-signing replay admits only the actual archive producer path with its signed app and build directory, and checks both signature verifications precede that call. Native-helper ZIP behavior and all existing identity/keychain cleanup assertions remain intact. The original replay fails; the corrected replay passes, while the original identity defect, permissive producer port and missing archive-order guard each fail. This fixture-only evidence does not qualify physical native archive/signing; final composed and hosted native validation remain pending.

CI smoke and install/launch now prefer the first available archive declared by the shared macOS install policy. ZIP remains compatible only when the preferred XZ file is absent; malformed, changed or refused preferred input fails without fallback. The native signed source supplies the bundle snapshot, independent designated requirement and exact archive digests through a separate CI-only artifact. Launch evidence hashes the retained bytes actually installed. Public release assets, Sparkle ZIP signing/feed, Homebrew and ordinary helper ZIP output remain unchanged.

The five-file source slice has 22 portable native-owner cases, seven actual workflow cases, two actual evidence controls, two original causal failures and six guard-removal failures. The original producer contract passes with closed filesystem and physical POSIX ports. Native extraction/signing/xattr and the two added Swift cases still require hosted macOS CI; root full selected qualification is pending. Item 36 remains partial until public archive migration and native acceptance are complete.

- [ ] **37.** Ergopti-extension decisions: whether « Hotstrings Ergopti »
      should appear only when the layout is really installed (today: always,
      shipped copy), and whether to move French `suffixes_a` and the magickey
      `replace` section into the Ergopti extension. Common distance reduction
      already belongs to the extension; the French distance category remains
      independent.
- [ ] **38.** Real-device checks the container cannot run: macOS tap-holds and
      the guardian's Login Items steps, the Homebrew install writing settings
      (provenance fix), Windows tooltip rendering on 10/11, every new menu row and
      the wizard re-run on the three OSes; on a Mac with an Ergopti layout,
      startup logs no « Lease-bound input startup failed » ERROR and no
      « Layout poll detected change » between the two names of one layout; every
      settings menu opens with its switch, « Restaurer les valeurs conseillées »
      and « Tout effacer » (no question asked), Configuration offers the global
      clear, and the macOS Gestures menu shows its conflicts row after them; the
      layer editor shows the input source legends and the wheel slots run volume
      only while the layer is held; Right Option + Return, Delete, Backspace and
      Escape run the script actions out of the box (Linux: AltGr); opening the
      app starts no Python and shows no Rosetta notice; the MLX install works
      behind a company proxy; a rollback from the Versions window swaps the app
      and keeps the previous one. Windows still needs a physical-device
      reproduction check of the previously reported AZERTY + AHK Ergopti+
      emulation to native Ergopti layout switch and its reverse: AltGr stays
      usable without a manual reload, including same-window changes and
      switches during held/deferred input ownership. Existing foreground,
      polling and deferred-owner regressions passed complete non-release
      checkpoints 36931498806 and 36940286440. This consolidates former item 99
      under hardware acceptance; it does not establish physical acceptance or
      a new runtime fault from the supplied unpublished snapshot.
- [~] **40.** The packaged-launch gate never builds a Karabiner configuration:
  the CI runners have no Karabiner-Elements, so dev.148 passed every launch
  scenario while every real Mac refused the deploy (« generated rule 1
  manipulator 3 has inconsistent managed conditions », fixed with
  `json-shared-tables`). Add a launch scenario that makes the app build and
  merge its Karabiner configuration in the real Hammerspoon runtime (into the
  runner's own `~/.config/karabiner/karabiner.json`) and fails on any ERROR,
  without needing the Karabiner driver.

The packaged macOS launch matrix now contains a Karabiner configuration scenario. It uses the real Hammerspoon JSON runtime and production build, merge and conditional atomic-file owners for eight default/recommended and switch vectors in a runner-owned private destination, preserves foreign profiles and personal rules, proves independent codec trees, and restores exact original bytes. It acquires no remap lease and installs no driver. The selected local gates pass 353 JS checks and 13,074 portable macOS cases, including five registered publication/restoration lifecycle regressions; 65 Python judges pass. Actual signed native execution remains pending and the existing scripting transport deadline is blocking, so TODO40 stays partial until that proof is green.

The signed native checkpoint 37116923472 reached the actual independent JSON codec and production build/merge owners, then refused its first variant because the canonical French action registry gives distinct Cmd+Tab and Option+F17 outputs the same localized label. Legacy reconstruction now keeps validated action-label candidates: unused descriptive ambiguity cannot block foreign profiles, while a complete historical block referencing distinct candidates remains unowned and refuses publication. The eight real-catalogue default/recommended switch vectors prove merge, exact-source publication and unchanged confirmation locally. Signed native qualification of all eight variants remains pending; the original AppleEvent controls and deadlines remain mandatory.

- [~] **42.** config.toml batch writer follow-ups (`toml-batch-existing-key`):
  an old build's scalar where a table is now expected (`magickey = true` under
  `[hotstrings.modules]`, `groups = "x"`) still makes a menu save fail with «
  the batch cannot address the destination without ambiguous TOML keys » —
  maintainer decision: may an ordinary save overwrite a value flagged outdated?
  The shared macOS/Linux decoder now resolves hand-written dotted assignments
  (`a.b = 1`) as semantic nested keys while quoted dots remain literal keys.
  Windows document/config dotted assignments remain unsupported; its existing
  inline-table reader already resolves them and replays the common corpus.
  Linux now delegates whole custom-delimiter lists to the shared TOML writer,
  including `[[hotstrings.terminators]]` and quoted table-array headers. The
  obsolete local refusal and its unsupported-format warning are removed.
  Regressions cover additions, removals, sparse states, restart, unknown and
  unusable records, nested fields, comments and byte-stable no-op writes; a
  malformed destination and superseded source remain refused. An installed-
  driver E2E scenario saves the list and verifies it at the next real daemon
  start; that scenario failed against the original owner before passing with
  the fix. Local gates passed (349 JS, 4607 Linux unit and 143 Linux E2E
  checks). Full three-OS checkpoint 37033032620 at `6275cac35` passed unit,
  E2E, packaging and installation gates with release skipped. The scalar
  migration decision and Windows document dotted-key reader remain open.

The shared dotted-key reader now uses the existing strict key-path owner for
root, section-relative, multiline and inline assignments, including independent
array-of-table generations. Forty hand-authored vectors checked against Python
`tomllib` preserve quoted Unicode and literal dots, reject semantic duplicates
and refuse scalar, array, closed inline or explicit-header namespace conflicts.
Both registered Lua runners replay the same expectations; Windows replays the
17 inline vectors through its real typed native decoder. Writer regressions
retain unknown source bytes, preserve exact no-op images and refuse changed
unaddressable dotted leaves, duplicate destinations and stale source snapshots
before publication. The legacy macOS feature override adapter now consumes the
shared scalar-path projection and marks the original source segments for cleanup.
A literal and nested path that target the same legacy setting refuse the full
projection before any setting write, including the preceding script section.
Its existing dotted-key assertions remain intact; arrays, flat script settings
and unknown sections retain their separate contracts. Native Windows
qualification and the complete three-OS
checkpoint remain pending; no ordinary scalar migration policy changes here.

The full selected local gate passed 353 JS checks, 13,229 macOS unit cases,
4,931 Linux unit cases and 101/144 macOS/Linux E2E checks. All production,
test and corpus bytes match that gate; the subsequent memory correction
passed formatting and strict conventions. Actual Windows replay and native
three-OS packaging/installation qualification remain pending.

The Windows migration owner now uses a typed semantic document reader before source classification and after rendering. Independent hand-authored document and inline vectors distinguish nested dotted assignments from quoted literal dots, preserve native Boolean/integer/string intent and table-array owner generations, and refuse duplicate or redeclared namespaces that the legacy flat readback cannot detect. Current-version files also require the read-only semantic source proof before boot admission; refusals preserve exact bytes and prevent backup, publication and subsequent writes. The legacy Windows cache, ordinary batch writer and settings bootstrap remain unchanged; full dotted-key configuration loading and safe ordinary saves, and the existing scalar migration decision, remain pending. Native AHK unit, compile and E2E qualification is pending CI.

The source-selected local gate and explicit shared checks pass formatting,
353 JS checks and 1,802 AHK UTF-8 BOM/LF files. Every pre-existing native unit
test byte is unchanged; actual Windows replay and compilation remain pending.

Native Windows checkpoint 37104220317 executes the independent 40 document and inline-table vectors, duplicate source/candidate refusal and current-boot refusal successfully. Its preservation case incorrectly assumed all foreign records remain a contiguous prefix even when the metadata owner inserts its new table before the first header. The regression now pins an independently handwritten complete candidate byte image, including both owned insertions and every foreign root, table-array, legacy scalar and source byte; all typed assertions remain. The parser and renderer are unchanged. Portable JS and BOM/LF gates pass; this corrected native case and complete three-OS validation remain pending.

TODO 42 remains partial. The Windows ordinary and detached writers now compare their fresh flat source model against the typed semantic document before staging: a genuine no-op preserves an unrepresentable dotted/root/table-array source verbatim, while changes that would lose its namespaces refuse. Exact source readback fences concurrent preparation and staged publication; ordinary source drift invalidates stale reader cache without mutating prior cache objects. Existing canonical output remains for representable sources. Seven registered native cases cover detached/ordinary no-ops, changed/deleted/unrelated leaves, quoted literal dots, duplicate aliases, hidden-root and exact-subtree deletes, and actual concurrent native file mutation. Portable verification: AHK BOM/LF + 353 JS checks passed; native Windows unit/include/E2E qualification pending CI. Bootstrap/cache semantic consumption, full-save physical comment preservation and the scalar migration decision remain pending.

Native Windows checkpoint 37116696443 passed 7,978 unit cases; two historical tests still required the previous serializer to discard unowned comments. Those test contracts now pin independently handwritten complete source images and decode the actual detached/published candidates through the typed document reader, distinguishing Boolean true/false from numeric zero/one. Canonical rendering still owns explicitly changed assignments; unchanged source order, comments and values remain exact. No production writer, parser or scalar migration policy changes in this test alignment. Portable selected verification and a new native Windows checkpoint are required before qualification.

- [~] **43.** A Mac upgraded from a pre-lease release could not deploy (dev.149:
  « Merge aborted: 25 ambiguous legacy ErgoptiPlus rules … matches the
  historical CapsWord anchor »): its karabiner.json keeps an untagged historical
  block the merge cannot prove. The refused deploy now offers « Retirer les
  anciennes règles » (listed, confirmed, backed up next to karabiner.json), also
  from a Tap-Hold menu row while the rules are pending
  (`karabiner-legacy-cleanup`); untested on a real Mac. Still to do: find why
  the proof fails from the backed-up file.

Legacy label candidates coalesce only exact non-semantic aliases. Tap, hold and chord reconstruction accepts only one equivalent class; ambiguous references in selected or inactive historical blocks preserve every source byte and perform no publication. Dense catalogue, unique IDs, key/combo labels, immutable release graph proof, private signatures, managed tags and conditional publication retain their assertions. A descriptive marker-free personal chord remains personal. This fixes the independently reproduced canonical-catalogue obstruction; it does not diagnose an unavailable user's backed-up historical configuration or qualify real Karabiner input.

- [~] **44.** CapsWord is no longer cancelled by the pointer when Karabiner
  activated it (AltGr + CapsLock): the watcher probed the variable with
  `karabiner_cli --get-variable`, an option karabiner_cli has never had (exit
  2), so it only ever worked for a CapsWord this driver activated; since dev.150
  it stops probing after that refusal (`capsword-probe-unsupported`). Give the
  activation a way to tell Hammerspoon (for example a sentinel key the
  activation rule emits, like the script-control ones) so every CapsWord is
  cancelled.
  macOS generated remaps now publish owned Caps Word activation/clear signals
  consumed by one shared policy and the existing sentinel port. Layout-only
  watchers do not acquire that owner; real gesture startup acquires it lazily.
  Refused native variable writes recover only the same revision/token state.
  Independent old graph generation explains every intended preset digest
  change; application-visible typed output retains its existing assertions.
  Registered macOS tests pass 12908 cases, and private eager-acquisition and
  consumer-refusal mutations are rejected. Native macOS qualification and
  manual hardware acceptance remain pending.
- [ ] **46. (partial)** Local-model presence and download offers now share one
      policy on Windows, macOS and Linux. Agent and screen-reading requests
      distinguish an absent model from an unavailable or malformed model list;
      a model removed after listing is reported through the same owned offer.
      Linux streaming HTTP keeps real status and complete bounded error-body
      receipts, and consent resumes only after modal input ownership is restored.
      Complete the three-OS native CI, packaging and installation validations
      before removing this item. Cloud loopback transport and scripted owner
      regressions do not qualify physical desktop input.
      The Windows native run 37088969640 exposed two contract regressions:
      deferred preflight now declares one-shot/cancel timer semantics, and each
      reserved curl slot declares its transitory tags-owner fields before
      acquisition. Timer delivery/cancellation and the real dispatcher have
      added regressions; the repaired native Windows gate remains pending.
- [~] **47.** **Partial: catalogue-owned optional authentication.** Manually configured
  OpenAI-compatible entries for oMLX, LM Studio, llama-server/LocalAI and Jan
  can use an explicitly empty key on all three drivers. The shared local
  catalogue owns that capability; cloud, generic and unknown providers still
  require a typed key. Configured HTTP(S) addresses and provided secret bytes
  remain authoritative, and empty credentials do not create Authorization
  headers. Linux keeps foreign row order and unknown fields during private
  saves; Windows refuses unsupported source replacement under the existing
  transaction owner. Linux already supports address, key and model text
  prompts. Independent credential/models fixtures, actual entry restart and
  configurable curl loopback models/chat/refusal/cancellation regressions
  qualify this prerequisite locally. Native Windows/macOS application and
  complete three-OS CI remain pending. Remaining work: Windows/Linux automatic
  asynchronous discovery and model/menu rows matching the existing macOS
  local-server owner, with source fencing and physical acceptance. This
  tranche does not install or start a server.

The controlled Linux HTTP lane independently qualifies unauthenticated models
and chat requests, supplied secret bytes, authentication refusal, cancellation,
source changes and complete task retirement. Its original 55 streaming checks
remain mandatory beside the 28 new local-API checks. macOS and Windows use the
same catalogue capability and independent credential/model vectors through
their existing API owners; actual Windows execution and complete native CI
remain pending. Automatic local-server discovery remains a separate tranche.

The Linux HTTP port now exposes an optional retained GET operation for
discovery. Signal acceptance and logical inactivity remain the historical
boolean ABI; the new operation fences delivery on cancellation and blocks
same-owner successors until exact process exit and every native handle-close
callback acknowledge retirement. Independent constructor, refusal, timeout
and premature-settlement regressions, 70 actual curl streaming/owned-GET
checks and the unchanged 28 local-API checks qualify this prerequisite
locally. Automatic discovery and model/menu rows remain unfinished.

The macOS local-server owner now consumes a shared logical discovery controller
for ordered joint publication, cache age and superseding search generations.
Captured provider/address snapshots and a dispatch fence prevent a changed
target or a synchronously reentrant newer search from dispatching the old loop.
The existing credential, HTTP and persistence owners remain authoritative.
Independent traces run through both Lua drivers; native task retirement and
Windows/Linux discovery/menu integration remain separate requirements. The
macOS probe also checks a shared generation ticket and its live in-memory
provider/address/stored-key identity before credential callbacks acquire HTTP
and before responses publish. Held old credentials and independent address/key
changes are refused; this does not assert fresh private-file reads or physical
HTTP retirement.

The Linux private API-entry owner now captures its actual classified disk
source and rechecks it before private staging and immediately before rename.
Observed external replacements, absent-to-created drift, failed reads and
reentrant publications are refused while cached list/selection mutations roll
back. Independent physical-file regressions retain all existing credential,
foreign-row and 0600 assertions. This synchronous source fence does not claim
a cross-process kernel compare/exchange or complete automatic discovery.

Linux now consumes the shared catalogue-ordered local-server menu and discovery controller through four independent owned HTTP GETs. Actual configured endpoints, typed models and private-source receipts fence model/configuration callbacks, including held dialogs and observed source drift. Same-provider successors wait for exact native process exit and all handle-close acknowledgements; pause/shutdown invalidate logical tickets while keeping the last cache. Model selection uses the private 0600 publisher before the separate acknowledged backend preference. A backend refusal after JSON publication leaves a truthful saved-but-not-selected result rather than claiming multi-file atomicity. Address/key edits without a saved model remain session-pending, matching macOS. The controlled native curl fixture retains its prior 28 assertions and now qualifies 48 models/menu/selection/chat/restart/refusal/cancellation checks; focused Linux65 and Mac22 pass locally. Windows automatic discovery/model-menu rows and complete native three-OS CI remain pending. The existing Linux shutdown coordinator is unchanged: retained native cleanup debt is reported, not presented as a physical retirement acknowledgement. The final native admission callback runs before the final classified source comparison, so a callback that independently replaces disk bytes cannot borrow the earlier source check or acknowledge an overwrite. The Linux backend-provider context is composed over the Personal, Info Bar and privacy controls without replacing their menu owners.

The 48-check native curl fixture exercises real loopback models and chat, private-file restart, HTTP/model refusal and exact owned cancellation settlement. Its backend selection callback is injected; it does not itself prove the production prediction engine's second admission check or native desktop application behavior. The separately prepared real-engine preference-owner regression and full hosted three-OS qualification remain distinct obligations. Shared generations invalidate logical discovery tickets; native HTTP successor admission still requires the exact process exit and every owned handle-close acknowledgement. No server installation, start or automatic Windows discovery/menu completion is claimed.

Actual root integration command for the extended mandatory native fixture, after activation and in the Linux driver directory:

```sh
luajit tests/hardware/run_local_api_auth.lua
```

The existing registered native HTTP runner also invokes this fixture as its second mandatory owner; preserve the original streaming suite and all 28 pre-discovery local-API assertions.

Partial: the Linux prediction engine now has causal coverage for its second local-backend admission check after actual dismissal. Real canonical preference and filesystem owners preserve exact source bytes when the dismissal changes pause, source or explicit admission; an unchanged control acknowledges a durable backend through a fresh reader. Focused 18 cases pass, while removing only the second check from the actual engine produces 4 failures. This strengthens the frozen Discovery 15 owner; complete native discovery and multi-OS qualification remain pending.

A registered Linux regression now observes the existing native private-file owner when quarantine of malformed API registry bytes is refused. It preserves the exact foreign source, refuses publication and acknowledgement, and leaves no staged replacement or RAM entry. The original defective quarantine branch reproduces the failure; the delivered source publisher and corrected local-server admission keep the full owner suite green. This additional native-file proof is independent of the real-engine second-admission regression. Complete hosted qualification and the remaining Windows local-server UI keep item47 partial.

- [~] **48.** **Partial: shared read-only enable admission.** Ordinary Ollama activation now waits for a complete, successful response from the configured `/api/version` endpoint before publishing `llm.enabled = true` through the existing preference owner. Redirects, unreadable responses, HTTP or transport failures, stale backend/model/source generations, pause and scoped-writer refusal keep the AI off. Native refusal offers name the configured address and keep the AI off. An explicit Retry requests a new receipt only after the same source and native restoration are acknowledged; existing macOS repair choices retain their own consent. API activation remains independent of a local Ollama model or server. The shared Lua/AHK policy and independent receipt corpus are consumed by all three drivers. Existing explicit macOS repair actions retain their ownership and require a fresh response before enabling. Remaining work: Windows/Linux owned runtime start/install and server discovery/replacement actions, the dependencies listed in item 47, and physical/manual acceptance. Do not remove this item until those remaining behaviors and complete three-OS validation are finished.

The native Windows strict version receipts exposed an older test that leaked
an intentionally unsoldable zero-handle process record into the genuine global
cleanup ledger. Its synthetic ledger now restores the exact predecessor ledger,
retry timer, counter, delay and native Critical state even after interruption.
The refused release and retry still retain their exact synthetic owner; no PID
reopening, termination, fabricated handle or settlement is allowed. Production
admission and the physical-wait/foreign-origin assertions remain unchanged.
Portable gates pass; repaired callbacks await native Windows CI. Explicit
Windows/Linux start/install and local-server discovery remain unfinished.

Windows live-mode unit fixtures now share one protected invoke-and-retire boundary for the actual gesture action and both actual live-menu callbacks. The real pending notice is captured and retired before the fixture releases its fake typing ports, including refusal and thrown callbacks. AllowTimers=true and every existing live-mode/state/task-count assertion remain unchanged. The new native unit regression checks exact false/error/notice behavior, exact caller Critical restoration, pending notice/surface retirement and preservation of an opaque foreign task identity/count. Run37098105470 demonstrates the original unprotected menu case task count0→1 and a later28-case foreign-task precondition cascade; these are not30 independent production faults. Local source plus qualification-onlyTODO48 selected gates passed353JavaScript checks, formatting and1801AHK BOM/LF files. Native execution and full suite recovery require the next Windows CI.

Native checkpoint 37102040657 stopped before executing any selected Windows
case: the live-mode test fixture's same-line captured catch was parsed as an
invalid class. The catch body now uses a legal block, with every observation,
exception assertion, Critical restoration and notice/timer retirement unchanged.
The existing registered AHK syntax guard rejects this exact original file and
checks thirteen legal, typed, multiline, comment and literal controls. Selected
portable gates pass; the repaired include graph, native notice lifecycle and
semantic TOML corpus still require the next non-release Windows execution.

- [ ] **49.** Windows keyboard-hook order audit: AutoHotkey removes and
      reinstalls its own low-level keyboard hook around every SendInput (upstream
      `keyboard_mouse.cpp`, `SendEventArray`), so after the driver's first send its
      hook runs before the native arbiter's. Windows guarantees no order anyway: a
      program that hooks later runs first, and a hook that exceeds
      `LowLevelHooksTimeout` is dropped. The prediction navigation no longer depends
      on it (`llm-nav-cycle-windows`), but the paced expansion terminal capture
      still assumes the native hook runs first (the comment above
      `LLM_NavEventOwner_EnsureStarted()` in `ErgoptiPlus.ahk`). Audit every native
      arbiter route, make each one order-independent, and test both hook orders like
      `test_llm_nav_cycle_windows.ahk`. Needs a Windows machine.
- [ ] **50.** Measure SendEvent against SendInput on Windows. While the native
      arbiter's low-level hook is installed, SendInput is interruptible anyway,
      which is the only reason AutoHotkey removes its own hook, so SendInput now
      only costs the rehook of item 49. `ErgoptiPlus.ahk` sets `SendMode("Event")`,
      yet `hotstring_send.ahk`, `hotstring_dispatch.ahk`, `text_sender.ahk` and
      `config_io.ahk` still call SendInput. Measure long expansions, pastes and
      accepted predictions (latency, dropped or interleaved keys) before switching;
      not before the demo.
- [ ] **51.** Windows checks on a real machine for the 2026-09-30 evening fixes
      (AutoHotkey cannot run in the Linux sessions): the four arrows (↑/← back, ↓/→
      forward) and the left and right Shift+Tab over a multi-slot AI prediction move
      the marker once per press, wrap at both ends and never move the caret, also
      right after a reload, with `nav_modifiers` set to ctrl and with a tap-hold's
      Tab tapped under one Shift; the footer shows "⇧G + Tab ou ↑/←"; Tab then
      inserts the chosen slot; the hotstring bubbles and the delayed expansions work
      with the layout emulation off and on; an accepted prediction no longer types
      "eeee"; a Ctrl+V paste adds one row to the clipboard log with the emulation
      off and on; AltGr+Entrée, AltGr+Suppr, AltGr+Retour arrière and AltGr+Échap
      run their script action out of the box, and the « Raccourcis de gestion du
      script » switch makes them native again; opening the versions window
      repeatedly logs no error; the AI menu has no clear row, its Backend row
      reads « API 🌐 » (or Ollama, MLX), and adding an API entry asks no name
      and lists it as `provider/model`; the layer editor shows the emulated
      Ergopti legends and each action; « Revenir à cette version » rolls back
      with a backup; « Désinstaller » is greyed on a source run.

## Maintainer requests on the evening of 2026-09-30

Each item is removed once it is integrated and pushed; what must still be
checked on a real machine moves to item 51 (Windows) or its macOS twin.
Releases: push to `dev` without a release until every item below is
integrated, then publish one grouped release.

- [~] **54.** Every menu is declared in the shared menu manifest, never in
  driver code. The ratchet `npm run test:native-menu-rows` counts the rows
  drivers still build (current baseline: Windows 103, macOS 180, Linux 111, each
  site listed in tools/test/native-menu-rows-baseline.json); migrate them to
  zero. Each OS-limited row declares `unavailable = "hide"` (not
  applicable) or `"grey"` (not yet ported, with its reason); classify the
  existing rows during the migration (proposal in the menu-first-group
  report: most hide; greyed: Linux edit_shortcuts, Linux key
  combinations, Linux metrics shortcut rows, Windows preview_bubbles).

The fixed AI-agent Mode submenu now belongs to the shared `llm.agent_mode`
enum and `agent_menu` choice declaration on Windows, macOS and Linux. The
shared renderers own its labels, order, checked state and selected-value
caption; native ports supply only the current value and existing durable
setter. Automatic-mode prerequisites and refusal rollback remain intact.
An independent three-mode corpus drives each native menu regression, including
shared-choice reordering and refused writes. Native menu-row counts fall from
Windows 110 to 109 and macOS 195 to 194; Linux stays at 121. Items 54 and 81
remain partial while the other native/provider rows still exist. Windows
native unit/E2E, packaging and installation validation is pending CI.

The Windows Mode corpus reader now uses the initialized `_SharedDir` owner
shared by the real boot entry point and native test stubs. Checkpoint
[37092132946](https://github.com/adrienm7/ergopti/actions/runs/37092132946)
failed both native Mode cases before they could replay their corpus because
`SharedDir` was unset. The explicit directory separator, independent three-mode
expectations, native flags, shared-order mutations and refusal assertions remain
unchanged. Native Windows replay still requires the next non-release checkpoint.

The four Debug log-level choices now share a validated enum subset, order,
technical labels, icons and current caption across Windows, macOS and Linux.
The existing eight-value severity API is preserved. macOS publishes the new
threshold and invalidates its cached menu only after exact persistence
acknowledgement; refusal, nil and throws preserve both. Independent choice and
owner-refusal regressions pass locally; the current Linux suite and real X11
checks pass, with unchanged macOS sources covered by the prior full suite.
Native Windows, packaging and installation validation remain pending CI.
Items 54 and 81 remain partial for the other native menu groups.

The Windows native three-state Mode replay now binds each current corpus state
as an explicit callback argument. Checkpoint
[37094197821](https://github.com/adrienm7/ergopti/actions/runs/37094197821)
reached the real menu assertions, then refused an unset loop variable because
AutoHotkey captures a different cell from its active `for` enumerator. Every
independent checked-state, label, order, caption and refusal assertion remains
unchanged; the bound callback still runs against the actual native menu. Local
encoding and JavaScript gates do not qualify its native behavior. Windows replay
and the complete three-OS checkpoint remain pending.

Checkpoint [37096024096](https://github.com/adrienm7/ergopti/actions/runs/37096024096)
failed both new Windows Debug cases before their severity assertions: the native
runner deliberately omits the boot lifecycle owner, leaving its four unrelated
command references undefined. The severity fixture now supplies fail-loud
callback identities and proves menu construction does not invoke them. The
independent four-state matrix, shared ordering, native captions and refused
writer assertions remain intact; actual Windows replay is still pending.

The Word Expander menu's three bulk commands and separator now have one shared
child declaration, followed by each driver's existing entry provider. Independent
historical vectors preserve order, labels, custom consumption and shipped states;
reordered declarations reach the real Lua providers. Native callbacks preserve
their durable owners and recheck current readiness, including pause, before any
mutation. Lua refusal cases retain exact source and runtime state. The native
row census falls by four on every driver to Windows 105, macOS 189 and Linux 116.
The original full local run passed 13,189 macOS and 4,886 Linux unit cases plus
101/144 E2E checks; its three static integration failures were then closed by
353 passing JavaScript checks on the exact final delta, without weakening the
original guards. Native Windows stale-pause/transaction cases and complete
three-OS packaging and installation still require CI. Items 54 and 81 remain
partial for the other native menu groups.

The About update-channel submenu now consumes one shared choice declaration,
projected from the existing validated updater registry rather than a second enum.
The registry owns its stability order and separate short-caption/full-leaf labels;
all 21 existing translations are retained. Each driver supplies its current
subscription and existing durable setter. Linux redraw and Versions publication
still follow an accepted write, while false/nil/throwing refusals preserve the
subscription. An independently captured two-state corpus and alternate published
order are replayed through the real menu providers; Windows also observes Win32
checked flags and registered dispatcher callbacks. Current focused About/Word contracts and all source
checks pass; unchanged updater runtime bodies are linked to the earlier full
portable unit/E2E component receipts. Native Windows, packaging and installation
qualification remain pending the next non-release CI. The native-row census is unchanged because these
pickers already returned provider data. Items 54 and 81 remain open for the other
native and fixed provider policies.

The common AI Display Info Bar check now has one shared declaration for its
label, checked state and native readiness getter. Existing leading and remaining
providers preserve each driver's surrounding display controls, and the Windows
and macOS native setting transactions are unchanged. Linux refreshes its menu
only after the existing strict display-setting writer acknowledges the change;
refusal preserves runtime and durable preferences. Independent two-state
expectations and shared-label mutations exercise the actual three-driver menu
consumers. Qualified component suites and the current JavaScript composition
pass; native Windows and complete three-OS packaging and installation still
require CI. At the Info Bar checkpoint, the native-row census was Windows 105, macOS 188 and Linux 116.
Items 54 and 81 remain partial.

The automatic temperature-diversity check has one shared Generation child,
beside the unchanged native numeric providers. All three commands reread the
current prediction-count owner before an acknowledged mutation; Linux also
rereads its live AI and pause gates, preserves the sparse shared default and
refreshes only after a strict settings receipt. Independent boolean-by-count
expectations, stale-command refusal, failed writes/deletes and shared-label/order
mutations exercise the actual callers. Qualified component gates and the current
composition pass; native Windows, complete packaging and installation remain
pending CI. The current native-row census is Windows 105, macOS 187 and Linux 115.
Items 54 and 81 remain partial.

The common Show All At Once check now belongs to the shared display child. The
canonical `llm.display.streaming_multi = true` means progressive variant display
on all three drivers; Windows projects this to its existing native
`show_all_at_once = false` field at both default loaders and the saved-value
restore/write boundaries. Linux now suppresses intermediate completed variants
when the canonical flag is false, as its token callback already did. The shared
checkbox is checked for false and rereads count and native readiness before
using each existing acknowledged persistence owner. An independent polarity,
count and sequential-event corpus covers the actual menu and display callers,
including delayed callbacks and false, nil or throwing writer refusals.

Historical Windows preferences already use the same canonical path as macOS and
Linux and contain no platform provenance. Existing true values now receive the
canonical progressive interpretation; no guessed migration or automatic byte
rewrite attempts to infer their origin. The native Windows engine field keeps
its existing meaning and its original all-at-once/progressive assertions.
The current native-row census is Windows 105, macOS 186 and Linux 115. The prior
automatic-temperature census above is a historical checkpoint. Items 54 and 81
remain partial; native Windows, packaging and installation confirmation requires
CI. Token-level streaming remains a separate native/provider policy follow-up;
Windows still explicitly refuses unsupported token transport.

The Windows indentation catalogue now initializes beside its display-row reader,
so the resident boot graph and definitions-only native test graph share the same
owner. CI checkpoint 37104220317 failed four existing AI submenu assertions
because the former `_index.ahk` assignment was absent from the headless include
graph. The initializer and range are unchanged; a new native regression checks
the complete ordered range and the selected negative, neutral and positive rows.
The original submenu, restore, backend-caption and category-checkbox assertions
remain intact. Local JavaScript and encoding gates are qualified separately;
Windows native unit, parse and E2E confirmation still requires CI. Items 54 and
81 remain partial and native row counts are unchanged.

The common Show All At Once check is declared in the shared display child. Canonical `llm.display.streaming_multi = true` means progressive display on all three drivers; Windows inverts only at its unchanged native all-at-once boundary. Linux withholds intermediate complete candidates when all-at-once is enabled. Actual native owners retain strict acknowledged writes, live count, pause and master admission. Windows held and real dispatcher-deferred callbacks refuse after an acknowledged master withdrawal. Historical Windows stored booleans now follow the canonical progressive meaning, with no guessed migration or data rewrite. The native census after this tranche is Windows 105, macOS 186, Linux 115. Items 54 and 81 remain partial; actual Windows native execution, packaging and installation require complete three-OS CI. Token-level streaming remains a separate capability follow-up.

The Instant On Word End and After Hotstring checks now share one declared
trigger child on all three drivers. Native debounce, privacy and application
providers retain their existing positions and owners. Commands reread effective
booleans and the live master/pause admission before using the unchanged Windows
lease transaction, macOS setting transaction or Linux durable trigger setter.
Linux redraws only after an exact acknowledged write, and retained callbacks no
longer toggle a captured obsolete value. Trigger settings remain independent
of prediction count. Independent four-state pairs, actual menu label/order
mutation, refused writers, restart and held-callback regressions cover the
native callers. The current census is Windows 105, macOS 184 and Linux 115;
the Show All census above is a historical checkpoint. Items 54 and 81 remain
partial, and actual native Windows, packaging and installation require CI.

The update-check frequency picker now consumes the existing shared updater
registry on all three drivers. Its ten numeric intervals, order, translated
labels and selected-value caption are declared once; native getters retain the
existing nearest-preset snap without rewriting stored values. Source-run rows
remain grey with their translated reason and no callable submenu. The existing
Windows lease/schedule owner and macOS save/rollback owner remain unchanged.
Linux now requires an exact durable acknowledgement before retiring or restarting
its timer or redrawing the menu. Independent preset/snap cases, refused writers,
unknown-neighbour preservation, held callbacks and shared order/label mutations
exercise the actual menu providers. The current census is Windows 105, macOS
183 and Linux 114; the earlier trigger census is a historical checkpoint. Items
54 and 81 remain partial; native Windows, packaging and installation confirmation
requires CI.

The token-streaming option now belongs to one shared Display declaration and
capability/admission policy. macOS Ollama/MLX and Linux Ollama use their actual
partial-frame transports. Windows retains a grey row with its reason in all
21 locales and preserves stored intent until a partial-frame transport exists.
The menu census is Windows 105, macOS 182 and Linux 114.

Commands collect current master, pause, backend, progressive-mode and setting
revisions before the existing acknowledged writers. Linux carries the exact
canonical source into its sparse writer. macOS requires its retained pre-owned
source to match the current physical view; only an exact owned full-save receipt
advances forward, compensation or retry authority. Four real preference-owner
races preserve external master and temperature edits, including an edit after
true forward acknowledgement. Refused compensation remains recovery debt.
Existing assertions and strict false, nil and throwing refusal contracts remain
intact. Other native/provider rows keep items 54 and 81 partial; native Windows
unit/E2E and complete three-OS packaging/install qualification still require CI.

Windows token-streaming admission now refuses unset, non-map and incomplete native engine owners before reading their fields. The actual shared Display projection remains visible and grey without modifying stored streaming intent, future neighbours or acknowledged setting owners. A registered native regression covers six missing/retired owner shapes, and the source audit follows the authoritative shared declaration, capability/readiness bindings and retained-command admission instead of the superseded native row provider. All previous native assertions remain intact. Items 54 and 81 remain partial; the four observed Windows menu failures and obsolete source audit were reproduced by hosted CI, while execution of this correction still requires Windows CI. Portable source-contract checks pass with the original source red and six independent negative mutations refused.

The AI display indentation menu now has one shared numeric choice declaration
on Windows, macOS and Linux, with the same trailing position, fifteen signed
visual prefixes from -7 through +7, existing translated units and current-value
caption. Numeric configuration storage is unchanged; negative offsets control
the display prefix and never delete application text. Native ports collect
fresh master, pause, count, runtime and exact source evidence before invoking
their existing acknowledged setting owners. macOS reuses one canonical source
publication guard for streaming and indentation, retaining the actual pre-owned
source and advancing compensation authority only through its own save receipts.
Linux retains its sparse exact-source CAS writer; Windows writes only the typed
indentation leaf under its configuration lease, preserving unrelated values.
All 128 existing macOS setting transactions plus 12 new indentation cases pass,
as do ten Linux indentation cases and the independent shared admission corpus.
Focused current-root compiler, convention, formatting, encoding and native-row
checks pass; complete current-root portable verification and native Windows,
packaging and installation validation remain required. Items 54 and 81 remain
partial for the other native/provider rows.

TODO54 remains integrated pending full native qualification. Repair the Windows indentation test corpus reader to use the existing UTF-8 JSON owner, follow the shared declared choice after retiring the raw provider, and audit the new leaf writer before admitting the exact 29-caller census. Preserve all numeric, checked-state and command assertions; add real command-value receipts and strict refusal of truthy non-Integer-1 writer statuses. Native Windows execution is pending.

Partial: the personal hotstring editor command now shares its declaration, translated label and readiness key across Windows, macOS and Linux. Native providers preserve the personal settings, default sections, extension tree and existing file/scope mutation owners. Held callbacks recheck the live pause owner; macOS also rechecks after acknowledged deferred scheduling. The canonical native-row inventory decreases from 104/181/112 to 103/180/111 on the authored baseline. Focused owner and regression gates passed; composed verify-change and actual three-OS CI remain required before completion. TODO 54/81 remain partial.

TODO 54/81: The already shared Info Bar row now resolves retained clicks through one shared live-owner policy on all three drivers. Single predictions and every backend remain supported. macOS retains its pre-owned complete source and own-ACK compensation receipt; Linux uses its existing sparse source CAS; Windows publishes one typed leaf under the existing configuration lease and binds the canonical publisher to the admitted source. Paused, disabled, replaced, stale and sparse runtime owners refuse publication. Actual native AHK menu/publisher qualification remains pending the hosted Windows run; no additional native row was introduced or retired.

Privacy controls also retain the Linux prediction engine admission epoch separately from the canonical preference revision. A real pause/resume or master OFF/ON cycle retires held callbacks; invalid or unavailable native epochs leave controls disabled. Independent Linux regressions reproduce the old pause/resume acknowledgement gap and preserve both epochs at the floating-point boundary. Complete native CI and the remaining Trigger/AI menu work are still pending.

Partial: custom word-expander Delete now uses one shared command declaration, semantic label and live-readiness policy across Windows, macOS and Linux. The existing 21 delimiter translations are reused. Native providers retain their captured delimiter identity, confirmation and transaction owners; Linux retains its separate custom activation toggle and flat Delete position. Linux deletion returns success only after the existing durable owner acknowledges it, and retained callbacks refuse after pause without writing or redrawing. Original macOS runtime/persistence refusal and recovery assertions remain intact. Focused real-owner tests pass (Linux 41, including the actual provider in all 21 locales; macOS 8). Both owning generators reproduce the parent and run deterministically. The measured native-row census moves from 102/168/111 to 102/167/110; the updated ceiling also locks prior independently retired rows. The existing scanner did not count the old multiline Windows child row, so no Windows decrement is invented. The Windows corpus reader uses the actual initialized `_SharedDir` owner and preserves every assertion; its native declaration/ACK/refusal/pause regressions and complete three-OS CI remain pending. Add and the remaining native/provider menu rows keep items 54 and 81 partial.

The custom-delimiter Add command now uses one shared menu declaration and the existing `menu.hotstrings.add_delimiter` label on Windows, macOS and Linux, preserving each native position and persistence owner. Native callbacks reject cancellation, unavailable readiness and pause changes before publication; macOS also checks readiness before retrying an invalid-input prompt. The macOS callback accepts the affirmative label actually supplied to the native dialog, fixing successful Add selection in the eight locales whose affirmative label differs from `OK`.

Isolated actual-generator validation passed 53 Linux transaction tests, 21 macOS Add tests (including accepted and cancelled native receipts in all 21 real locales), and all eight unchanged macOS Delete tests. Original Linux and Windows predecessor test files remain exact prefixes. Controlled missing-admission, false-publication and hardcoded-button mutations fail the independent owner assertions. The two owning generators reproduced their output twice, preserving all non-owned inputs; the native fixed-row census changes from Windows/macOS/Linux 102/167/110 to 101/166/109. Hosted AutoHotkey execution, physical native dialogs and final three-OS integration remain pending; TODO 54 and TODO 81 stay partial.

The native Windows corpus readers use the `_SharedDir` initialized by the test harness. Reader-only corrections preserve all assertions; native AHK execution remains pending CI.

The existing custom-terminator validation, category-delay refusal and bulk-transaction fixtures retain the native-bound shared command-row renderer when isolating their menu builder. Their Add callbacks use the canonical translated label and the exact supplied acceptance button. All existing assertions and invalid-input/runtime-refusal scenarios remain intact; the twelve focused cases pass. The complete composed gate and hosted native qualification remain required.

Items 54 and 81 remain partial. The configured top-level Reload and Quit commands now take their command types and all 21 existing translated labels from their existing shared root declarations. All three native providers consume the shared command owner; Windows preserves explicit startup-safe lifecycle admission through the shared callback wrapper, macOS retains its native monochrome presentation, and Linux retains daemon dispatch and its final Quit position. Independent label, command-type, callable-owner and readiness regressions fail against the previous Lua providers. All four historical Linux reload cases and all four macOS root drift cases are unchanged and pass. The measured native-row retirement is two rows each on macOS and Linux, with Windows unchanged; earlier or subsequent retirements are accounted separately by the owning census. Cold-start Windows bootstrap rows remain a separate pending surface. Focused macOS/Linux and menu-generator checks qualify this tranche locally; native Windows startup, packaging/installations and complete three-OS validation remain pending.

The ordered projection preserves the preceding shared Word Expander Delete and Add owners and their native transaction tests. Owning generators reproduce their exact parent artifacts before composing this tranche. The measured census changes from Windows/macOS/Linux 101/166/109 to 101/164/107; only this tranche's 0/−2/−2 retirement is attributed here. Focused macOS 7/0 and Linux 7/0 cases plus the registered menu-manifest test pass on the composed sources; complete integration and native Windows remain pending.

The first fixed “Configure delays and colours” command under the delay submenu now uses one `hotstrings_delays_menu` command declaration and the existing `menu.hotstrings.config_item` label on all three drivers. Native ports supply the existing window callback and retain their previous pause posture; all variable quick-delay rows, positions, singleton windows, preference publication and save-refresh callbacks remain intact.

The actual old Linux and macOS providers fail the declared-label replay (55/1 and 26/1), while the new providers pass 56/0 and 27/0. The macOS replay covers all 21 real locale labels, actual acknowledged/refused preference writes, paused admission and a missing window owner; ignoring the existing save receipt makes both refused-write cases fail. Every original test assertion is retained. Both owning generators reproduce the candidate twice and regenerate the exact ordered Add parent on inversion, with native fixed-row counts changing from Windows/macOS/Linux 101/164/107 to 100/163/106. Final integrated gates, hosted AutoHotkey and physical native window execution remain pending; items 54 and 81 stay partial for other native/provider rows.

The graph parity guard now follows the actual `delays_colors` provider to `hotstrings_delays_menu`, preserving the earlier custom-delimiter graph edge and every existing assertion/floor. The composed Lifecycle/Add parent reports the new child as unreachable without this edge; the actual corrected graph passes with all 21 locale inputs. The composed Linux56 and macOS27 focused owner replays pass. Frozen earlier cohorts and their original qualification receipts remain unchanged.

The native Windows corpus readers use the `_SharedDir` initialized by the test harness. Reader-only corrections preserve all assertions; native AHK execution remains pending CI.

The macOS preview callbacks now acquire the existing global preference writer fence before changing menu or native state. Native preview setters must acknowledge exact success; refused publication uses the ordinary preference transaction rollback, and refused native compensation retains the owning fence. Focused real menu/global-owner/preference-file regressions pass, including held admission, live pause, native refusal, source preservation, sparse reload and recovery; the original 57-call strict persistence census remains intact. These preview rows still need shared declarations, and native macOS preview execution plus the remaining platform/menu work are not claimed complete.

The Windows startup menu unit fixture now supplies both observable native lifecycle callback identities required by the real shared reload/quit builders. The production boot owns them in infra/lifecycle.ahk, deliberately excluded from the unit graph because it owns suspension/watchdog effects. All original label, command-type, delayed-admission and lifecycle-precedence assertions remain intact; fixture fallback effects are recorded and refused rather than reloading or terminating the runner. Source-level old-negative/new-positive and four mutation controls pass, with BOM/LF/convention/loop-capture checks. Full selected verification and actual Windows CI remain pending. TODO54 remains partial.

The Windows hotstring delays-menu source regression now reads the existing central driver function-body owner instead of calculating a path relative to an included test file. Under tests/run_all.ahk, A_ScriptDir belongs to windows/tests, so the former two-parent path missed the real windows/ui/menu source. An explicit nonempty source guard precedes the unchanged native singleton-owner assertion; all 173 original assertions remain intact. Bounded source/path controls, three mutations and canonical conventions pass with BOM/LF retained. Full selected verification and native Windows CI remain pending; TODO54 remains partial.

The fixed Browse Models command now uses one shared declaration on Windows, macOS and Linux. Its native browser owners and existing translated label are preserved. macOS rechecks its existing live pause policy before deferred presentation; Linux and Windows retain their configuration-browser admission. Browsing remains available while the AI is off and does not start or select a model. Targeted native-bound Lua regressions, deterministic menu generation and the measured native-row census pass. Complete repository validation and hosted Windows/native UI qualification remain required. TODO 54 remains partial for other native menu rows.

The coloured hotstring-preview checkbox now consumes one shared typed declaration and the existing 21 translated labels through a shared provider-data projector. The other three preview-presence switches and their separator/order are unchanged. macOS delegates to the preview mutation-admission prerequisite; Linux refreshes only after the actual scalar preference owner acknowledges its conditional write. Existing Windows unavailability remains explicit because this preview surface belongs to the Lua drivers. Actual portable provider regressions cover all 21 catalogues, retained readiness, durable-lease and writer refusal, preserved foreign data and restart. Hosted AutoHotkey/Hammerspoon UI and complete current integration remain pending; this does not complete TODO 54 or 81. After the independently approved Browse-models command, native allocator census counts stay 99/162/105; regenerated sites retain both cohorts and the earlier Preview4 line shifts without claiming a new allocator retirement.

The coloured-preview shared row is registered in the Linux discovery manifest. Existing macOS terminator fixtures delegate the added checkbox port to the actual shared renderer without changing their assertions. Japanese and Korean unavailability reasons keep their explanations and expose the required compact reason headings. Full composed verification and hosted native validation remain required.

The Windows shared Models Browser provider now checks whether its actual native browser function exists before adopting the default callback. The definitions-only native menu graph can retain a disabled shared command without dereferencing an unavailable WebView owner; an explicitly supplied callable still returns its exact native presentation receipt. Every prior backend/model/menu assertion remains intact, and an additive registered regression exercises the genuinely absent default port rather than installing a stand-in. Source-only BOM/LF and ownership checks pass; hosted AutoHotkey and full selected qualification remain pending. Items54 and81 remain partial.

The fixed disabled “Check for updates” row in source runs now consumes one shared `about_source_menu` command on Windows, macOS and Linux. Its existing caption and source-run reason remain localized in all 21 languages; source rows expose no update action or window, while packaged update/check/install and cadence owners remain unchanged. Independent declaration-label and reason mutations fail against the old Mac/Linux consumers and pass through the actual native-bound shared renderer. Owning menu generation and the native-row census are reproducible; this tranche retires only its measured Mac/Linux row sites (0/−1/−1). Native Windows execution and the complete three-OS validation remain required for this partial TODO54/81 slice.

The fixed Live mode Off choice now comes from one shared checked command on all three drivers, retaining the existing 21 labels, first-row ordering and dynamic rewrite prompts. Native cancellation owners remain authoritative: Windows LiveStop, macOS set_live_prompt(nil), and Linux set_live(nil). Retained Mac rows recheck admission before entering the bridge; Linux redraws only after a literal true cancellation receipt and returns the native result. The Windows uniqueness owner reserves the admitted shared row label and refuses an invalid declared row, including a regression for a changed label colliding with a real profile. No persistent Live setting or new activation/pause policy was added.

Independent focused regressions ran every existing live-engine assertion: Mac 11/0 and Linux 24/0, with actual old-provider and negative-mutation failures, refused cancellation state and all 21 locale labels. The separately reviewed About → Live source composition preserves complete About/Colored/Browse parent hunks; both semantic orders and inverses match whole bytes. Owning generators were repeated and inverted with exact input guards, measuring 99/161/104 before Live and 99/159/103 afterward (Windows was not a counted scanner site). Original Live qualification at 99/162/105 → 99/160/104 remains an immutable earlier parent proof. Full current-parent verification and hosted AutoHotkey/macOS UI qualification remain pending. TODO54/81 remain partial for other declarations and native parity.

The Live-off shared row retains its original native owners. Three existing macOS test fixtures now borrow the actual shared renderer check_row/get_array ports; all original assertions and the twelve Live source candidates remain byte-identical. The eleven affected modules pass 247 cases after the original current-root 94 failures. Full current-root qualification and hosted native admission remain required.

The isolated Windows disabled-model catalogue runner now owns the actual shared command renderer, manifest decoder and native menu dependencies instead of outdated renderer doubles. Actual run 37175315386 passed all 8,121 main AHK checks but refused its isolated catalogue case when MenuRenderer_CommandRow was missing; the original four catalogue assertions remain, with new actual shared-metadata and unavailable-port regressions. Native candidate qualification is pending CI, and TODO 54 remains partial.

Profile creation now consumes one shared command declaration and the existing 21-language label on Windows, macOS and Linux. Each driver keeps its actual editor, retained scheduling, candidate recovery and acknowledged persistence owners. Live pause is re-read for retained command delivery; macOS also checks before its deferred editor and candidate callback, Linux before opening and saving, and the Windows native wizard before opening or committing (its existing WebView context/save guards remain unchanged). The bounded author checks cover declaration changes, refused editors, held/deferred pause and candidate refusal without replacing the persistence owners. At the exact ordered Browse/Colored/About/Live checkpoint the canonical native-row census changes from 99/159/103 to Windows 99 (unchanged), macOS 158 and Linux 102. Initial authored headless owner proofs remain separate from this mechanical composition; dependency-cap setup attempts do not qualify the composed root. TODO 54/81 remains partial. Full selected verification and hosted native Windows/modal/packaging qualification remain required; headless language tests do not qualify physical native UI or a whole lifecycle.

The canonical menu graph now records the actual llm_profile provider opening its shared llm_profile_commands child. All three actual native Create providers consume that child. The complete registered parity owner refused the prior future tree as orphaned and accepts the one-edge correction, with every old assertion unchanged. Original twelve feature candidates and generator outputs remain byte-exact; this is an additive graph dependency, not an orphan exemption. Current-root selected and native qualification remain required.

Create Profile now also uses the actual shared command renderer in the existing profile Delete/shortcut transaction fixture. Its original identity-preserving row-data seam remains, with borrowed command_row/get_array ports and explicit restoration of the pure transitive module owners. The original fixture reproduces 28 failures before those existing assertions; the corrected fixture passes all 39 registered cases (10 fixture scope, 9 shortcut prompt, 20 profile Delete), including absent/false/existing module restoration and retained transaction/refusal behavior. No production fallback, assertion weakening or native success claim is introduced. This corrects the Create13 root-gate fixture dependency; full combined validation and hosted native AHK remain required, and TODO54/81 stay partial.

The fixed Clone built-in profile command is now declared once in the shared menu and consumed by the three existing native profile owners. Held callbacks re-read the existing strict pause admission before clone publication and editor/save delivery; native refusal and durable profile acknowledgements remain authoritative. The existing platform-specific editor timing is unchanged. Targeted registered modules passed (macOS ports 62 tests, Linux 14 tests), and unchanged predecessor consumers and removed-admission mutations fail the new regressions. Native Windows execution and complete three-OS packaging/install qualification remain pending. TODO 54/81 remain partial.

The first preview-presence checkbox (magic key) now consumes a shared checked command and the existing 21 labels, alongside the already shared colored checkbox. macOS retains its actual global admission and preference/native rollback owner, and retained rows recheck current pause before entering that owner. Linux retains the scalar lease and conditional writer, returns only its literal true acknowledgement and redraws only after that acknowledgement. Windows remains truthfully unavailable under the existing Lua-preview reason; no native preview behavior was invented. Autocorrect/AI still use the existing generic factory and remain separate declaration work.

All original selected assertions remain, with genuine old-consumer and negative-mutation failures, physical-source preservation, refusal/rollback, reload and 21-locale checks. Final focused author results are Mac24/0 and Linux13/0. Both canonical generators were repeated and inverted on the exact future About/Live/Colored parents. The original author checkpoint retained native-row counts 99/159/103; the later ordered Create→Clone→Magic projection retains 99/157/101: these presence rows were dynamic scanner sites, so no retirement is fabricated. Full current-parent selected gates and actual hosted Windows/macOS UI qualification remain pending. TODO54/81 remain partial.

The Linux Profile Auto-detect checkbox now switches both on and off through the existing profile preference owner. Delivery rereads the current boolean and native pause state rather than writing true or trusting the old checkmark; only an exact persistence acknowledgement redraws the menu. Independent actual menu/profile regressions cover both states, a changed live value, held pause, read-time reentry, malformed boolean receipts and false/nil/text/throwing write refusals while retaining future preference data. All 13 existing affected cases and 10 new cases pass on LuaJIT; the same final cases produce nine failures on the original callback with the thrown-writer control still passing. Windows retains its existing transactional boolean toggle, and macOS retains its recommendation-dialog command rather than being silently reclassified as a checkbox. No label, default, schema, generator or native-row count changes. TODO54/81 remains partial; complete current root verification and hosted native/packaging/installation qualification remain required.

Autocorrection and AI preview presence now use one ordered shared checkbox group with the existing 21-language captions and truthful Windows unavailability reason. macOS rechecks the current menu pause state before its existing global/native/preference transaction; Linux keeps configuration access while paused and redraws only after an exact durable-owner acknowledgement. The last dedicated macOS preview-row allocator is retired. All prior preview and management assertions remain intact, including the six management fixtures now delegating the real shared declaration-reader port. Focused owner tests, 21-locale canonical/reversed-order replays and causal readiness/ACK mutants qualify the slice; the native row census remains unchanged because those rows were supplied dynamically. Root composition and hosted native Windows/macOS UI validation remain pending.

The Windows Magic and autocorrection/AI preview capability tests now inspect the actual public-rendered disabled Menu stand-in, including its translated reason, native leaf/state and absence of a registered mutation callback. The prior fixture called a different private helper and read a nonexistent disabled_reason_key. Declaration and native-provider refusal assertions remain unchanged; a supported native callback positive control verifies observable effects and cleanup. Product capability behavior is unchanged. Portable source/convention/encoding checks pass; actual AutoHotkey/Win32 execution and full selected qualification remain pending. TODO54/81 remain partial.

The optional category Open file command now comes from one shared declaration on Windows, macOS and Linux. Existing native opening owners retain the captured loader path and their acknowledgement/refusal behavior; opening configuration remains available while input is paused. Held callbacks recheck native source/port availability. Existing 21 labels are reused, with no configuration or category-scope migration. The canonical native-row census for the exact Presence17 parent changes from 99/157/101 to 98/156/100 (Windows/macOS/Linux), one actual row moved per driver. Focused Linux (31 existing/composed cases) and macOS (4 new owner cases), old-consumer causal failures, shared graph/declaration, generator inverse/repeat, encoding and convention checks are qualified locally. Full current-root validation and native AHK/OS qualification remain required; TODO54/81 stay partial.

The existing Linux category-count/tick fixture now locates the declared enable-all command by its canonical shared ID and current translated label instead of positional file slot 3. All original assertions remain intact; unique/actionable-row checks strengthen the original clickable assertion. The complete existing module fails5/1 with its old selector and passes6/0 with the correction; greying the actual enable-all command still fails5/1. The original12 candidate files and patch prefix are unchanged. Final composed validation and hosted native UI remain pending.

Linux selection operations now consume the shared CapsWord checkbox with its existing translated label, live checked state and intentional Linux-only scope. The callback rechecks the actual configuration reservation and redraws only after the runtime owner returns exactly true. The owner rechecks reservation after protected shortcut-metric delivery, preserving a reservation acquired by a reentrant callback. The current master/pause policies, configuration bytes and Windows/macOS binding owners are unchanged. Actual registered Linux owner/menu tests, independent platform/state corpus and causal original/mutation failures are qualified; complete verify-change and three-OS packaging/install CI remain required.

- Active API-entry Test and Remove now use one shared command declaration and the existing 21 captions across all three drivers; Windows retains Edit between them. Linux refreshes only after exact private-file publication ACK, with real rejected-publication source/RAM rollback verified. macOS passes the existing live ScriptControl pause getter through the actual menu builder and rechecks it before a retained command and after deletion confirmation; missing, throwing or untyped pause receipts refuse. Existing native requests, Keychain/private-file persistence and rollback owners remain intact. Targeted Lua source/owner controls pass; hosted AutoHotkey, macOS UI and final root selected checks remain pending. API Add/Edit, per-entry controls, server installation and discovery are outside this tranche.

The active API command slice remains partial. Its original full selected verification exposed an obsolete macOS token-resolution fixture port. The corrected fixture delegates command_row/get_array to the actual shared renderer, borrows real codec/renderer ports before installing stubs, and restores both cache identities through its existing protected scope. Every old assertion remains exact, including zero credential resolution during menu construction; two additional assertions verify cache restoration. The full registered module fails 23/1 with the old fixture and passes 24/0 with the corrected fixture. All nineteen feature candidates remain byte-exact. Full corrected root verification and hosted native qualification are pending.

The Windows shared category-file command fixture now mutates its declaration to an existing translated caption distinct from both category controls in all 21 locales. The former alternate caption duplicated Disable all, so native Menu.Add updated that existing item instead of appending the file row. Both original strict opening receipts and withdrawn-source assertions remain; the real native menu additionally proves three distinct rows, separate tracked leaf identity and refused held delivery after source withdrawal, with owned menu cleanup. Product labels, renderer and opening/persistence owners are unchanged. Portable source/data and encoding/convention checks pass; hosted native AHK execution remains required. TODO54 remains partial.

Linux selection-case commands now consume one shared ordered declaration with the existing translated labels and explicit Linux-only placement. Retained callbacks require current native configuration admission and an exact true clipboard-owner acknowledgement. The existing transform owner rechecks configuration reservation after protected Metrics delivery, including its direct catalogue and wrap aliases; Unicode transformations, defaults and persistence remain unchanged. Registered focused tests preserve all prior CapsWord tests and cover refusal, retry, held callbacks and metric reentry. This slice claims no native allocator retirement; complete selected verification and the three-OS native CI checkpoint remain required before closure.

The existing Linux wrap-on-type feature callback now reads the live master, configuration reservation and Boolean preference before toggling. A held checkbox targets the latest preference and requires the existing native setter's exact true acknowledgement before refreshing. Refusal leaves runtime and private configuration bytes unchanged; the existing master restriction is preserved without adding a pause gate or changing shared declarations/defaults/writer semantics. All 11 original tests remain byte-exact; 12 additional registered cases cover actual durable publication, stale callbacks, reservation, writer refusal and strict receipts. The native census only updates source line references (zero retirement); full selected verification and three-OS CI remain required.

- The macOS retained API-provider Add action now reads the actual ScriptControl pause receipt before and after every input prompt and after both prediction-reset callbacks, before entering the existing normal or System 1 staging owner. Missing, untyped or throwing pause receipts and a changed visible backend refuse without opening further prompts or publishing credentials. All earlier API owner tests remain intact; focused registered Lua admission controls pass. Actual Keychain/UI and final root/hosted checks remain pending. The Add menu declaration is still unfinished: Windows has a direct prompt command while macOS/Linux have genuine provider-choice submenu heads, so this prerequisite does not invent a common head action or claim shared-menu completion.

Linux automatic update scheduling now rejects held and duplicate record/notification completions after its stop/restart owner retires. Failed timer cancellation still retains the exact cleanup handle and refuses replacement. Eight new causal unit cases fail on the original manager and pass with the fence; all nine original schedule cases, 48 manager cases and six channel/cache cases pass. macOS already checks its active schedule generation, and Windows already validates its request background generation. Generic in-flight Linux check cache/state publication and physical timer/HTTP retirement are outside this narrow fence. Full selected verification and hosted native acceptance remain pending; TODO54 remains partial.

Linux Shortcuts master menu now reads the current typed runtime posture and requests its actual setter, accepting only literal true before repainting. Refused, unavailable, throwing, or non-boolean receipts use the existing localized keyboard-released failure dialog. The manager requires exact native writer ACK before RAM publication; existing toggle() posture ABI, configuration reservation, defaults, pause policy, CapsWord reset, and unknown future config fields remain unchanged. Final isolated registered modules: 59 manager +32 menu +41 Case/CapsWord =132/0; original owner/consumer regressions and three causal mutants are retained. Actual pinned native menu predicate remains95/95 (delta0), no declarations/locales/generated outputs changed. Windows/Mac existing native owners were source-audited; this Linux prerequisite does not close the entire shortcut/menu TODO or qualify physical UI. Ordered parent is approved Delay ACK after Bulk3/Extension/Wrap/OpenFile and Case/CapsWord. Full root integration and hosted native validation remain required.

The fixed Off checkbox in both AI Agent system submenus now comes from one shared declaration on Windows, macOS and Linux. The three providers retain their backend/model choices and existing setting transactions, checked states, pause policy and Windows already-Off no-op. Linux refreshes only after the current system owner returns an exact true acknowledgement. The independent shared-state/label tests include refusal and retry; the Linux test additionally exercises the actual canonical writer against a reserved owner and changed physical source, preserving foreign data. The canonical menu generator reproduces its exact shared parent. After Wrap/Bulk/Delay/Master, the native-row owner preserves the raw Wrap baseline as its patch preimage, separately normalizes only its stale site offsets against the actual latest parent sources, and reproduces that normalized checkpoint under source inversion with byte-exact repeated output; this tranche measures Windows 98 → 98, macOS 155 → 154 and Linux 99 → 99, crediting only its one macOS retirement. Focused macOS Lua and Linux LuaJIT tests pass; native Windows/UI execution and full integrated verification remain required. TODO54/81 remains partial.

Linux shared script-management chord switch now reads the current typed native state at click time, protects the existing setter call, and accepts only literal true before repainting. Refused, missing, malformed or throwing ports use the existing localized keyboard-released failure dialog. Native chord writer, configuration reservation, dispatch generation, global pause policy, defaults and sparse deletion remain unchanged. Actual private source/slot/comment/future-field preservation, both directions, default deletion, refusal and held callback after independent real publication qualify; all Master4 old test bytes remain exact. Final existing registered menu67/0; exact original36/29 plus added real held0/2 causal RED and three meaningful mutations retained. Actual native predicate95/95 (delta0), no generated outputs or locale/declaration/schema changes. Windows existing current-state commit/reload was source-audited; macOS captured-state/full-save compensation/runtime receipt gap is a separate unfinished tranche. Entire shortcut/menu TODO and physical UI remain unqualified until root selected and hosted native gates.

Linux onboarding now calls the existing i18n storage owner through explicit `persist_locale` and requires its exact true acknowledgment before writing wizard answers, completing, hiding or requesting restart. An invalid stored locale can fall back to French; explicitly selecting French must still acknowledge storage. Ordinary same-locale menu choices keep their existing no-op/default policy. This partial fix adds no schema, default flush or cross-owner transaction. Original production fails nine of thirteen new real wizard cases; the candidate passes all 13, plus 8 new locale-owner cases and the 44 selected onboarding/21 locale registered cases. Actual private JSON/TOML bytes and future neighbors are checked; native UI/Windows/macOS and full-root qualification remain pending. Existing runtime rollback after a later configuration refusal is retained, without claiming raw invalid-source restoration.
Ordered after the reviewed active-hotstring editor and personal-editor reload fixtures: their complete test assertions and source changes are retained by an exact whole-parent inverse; author focused receipts remain for the original four-source cohort. Root must qualify the final composed bytes.

The ordered cohort preserves the corrected PersonalReload joint-result assertion (510e478) as a complete prefix before the unchanged Wizard regression append. Source composition introduces no new behavior; full root and native qualification remain required.

Navigation and validation child rows now consume one shared declaration for their labels, presence, and order on all three drivers. Windows keeps its native modifier prompts; macOS and Linux keep their existing modifier picker subtrees. Linux now requires the actual durable setter to return exactly true before refreshing or acknowledging the choice; a refused publication retains the old source and chord and can be retried. Isolated registered tests replay all 21 locale captions, native range states, changed declarations, and real private-file publication faults. Full current-root verification and hosted Windows/macOS native qualification remain pending; TODO54/81 remain partial.

TODO 54/81 — Mac script-control toggle prerequisite (partial)

The existing Script control switch now enters the global action fence before changing RAM or the logical native chord gate. It reads the current native gate, requires exact Boolean setter acknowledgement and readback, and publishes through the unchanged ordinary Preferences transaction/source owner. A refused publication restores the previous RAM checkpoint and the independently observed native inverse, including across whole-preference rollback. Failed inverse or a changed native binding retains recovery debt and blocks a successor; no foreign setter is invoked.

The original registered cases remain intact. Controlled native filesystem publication refusals, canonical sparse default reloads, retained pause/reentry, exact native identity and inverse ordering have portable focused proof. Windows and Linux owners are unchanged. Karabiner sync is asynchronous: this receipt acknowledges the logical native gate, not physical deployment or keyboard capture. Generic whole-feature postpublication rollback remains outside this slice. Shared row migration, hosted Hammerspoon/native CI and complete TODO 54/81 closure remain pending.

About channel callback receipt follow-up: macOS and Linux now protect the actual
native channel setter and acknowledge only Boolean true. Linux redraws the tray
and updates an open Versions page only after that receipt; Windows keeps its
existing direct owner forwarding. Existing channel persistence, declarations,
labels and native publisher implementations remain unchanged. Private registered
modules cover rejected receipts, actual durable-owner refusal and retry, unknown
TOML fields, and a post-publication exception without manufacturing rollback.
Actual selected/full and native UI acceptance remain pending (TODO16); this does
not close the remaining TODO54 menu migration or updater ownership work.

Mac About retained-release callbacks now detach the displayed release tag and channel, re-read the actual channel/check owners before dispatch, and return success only when the launcher accepts with Boolean true. Held rows refuse cleared/replaced offers, a changed channel, mutated borrowed offer data, invalid owners, and launcher refusal or exceptions. The four existing About cases remain byte-exact; 24 new cases exercise the actual menu/renderer and real Channel/AutoCheck public retirement paths with recording infrastructure ports (28/0, original callback 4/24, five causal mutants red). This is separate from the release-channel setter ACK prerequisite. Windows reads its live update request/cache owners and Linux validates the current cached release URL; neither shares this retained Mac feed callback. TODO54/81 remains partial: automatic notification callbacks and global/native acceptance are separate. Native macOS/Sparkle and full selected qualification are pending; no generation identity, readiness, or obsolete-tag-installation claim is made.

- [ ] **62.** Downloads on managed company networks, Windows and Linux:
      system trust store and system proxy for every download child (the Ollama
      installer and server for `ollama pull`, the updater and rollback, remote
      AI APIs), and the shared failure contract (certificate, proxy, host
      blocked, offline, disk, permission) whose dialogs name the cause in
      French with actions that can work. macOS is integrated (uv from a
      checksummed PyPI wheel, `UV_SYSTEM_CERTS`, the `scutil --proxy` relay,
      the `network.failure.*` keys). The Windows and Linux work stayed
      uncommitted in the local worktree of `fix/downloads-on-managed-networks`
      when the session stopped; redo it if that worktree is gone.
- [~] **63.** Layer actions: screen brightness up/down are now shared, labelled
  through the existing 21-locale action catalogue, and implemented for keyboard
  layers on all three drivers. Windows and macOS also support their existing
  wheel-layer sources; Linux pointer-layer sources retain their explicit
  localized capability refusal. Windows replaces invalid Send key names with
  a bounded Job-owned WMI backlight worker and requires complete native target
  readback; absent providers and cleanup debt cannot become success. macOS
  uses its existing NX/Karabiner producers, and Linux uses native brightness
  keys or brightnessctl restricted to the backlight class. Independent shared
  corpus, dispatch and ownership regressions are added. Complete hosted
  Windows native worker/owner tests and three-OS packaging validation before
  retiring this item; physical display luminance is not measured by portable
  or provider-double tests.

The Windows brightness owner also fences cancellation and post-start retirement by the captured request ID: a synchronously acquired successor cannot be retired by its predecessor. Registered native Job/quiescence and synchronous-refusal regressions preserve exact successor identity, generation, action and zero borrowed handles. These native Windows cases remain pending CI.

Native Windows provider replay now avoids a String-constrained fixture
Policy variable shadowing the dot-sourced worker JSON object, and forwards
the exact nested-script LASTEXITCODE to its owned PowerShell process.
Closed fixture-only stage, write-count and policy-type observations retain
all original status/exit/readback assertions. A native typed-scope negative
deliberately reproduces the original refusal without touching hardware.
Corrected replay and that causal control still require Windows CI; the
shipped worker and its real provider behavior are unchanged.

      The Windows backlight owner is registered in the required suspend transaction,
      which now requires its exact native retirement acknowledgement. A refused or
      missing receipt retains cleanup debt and compensation; both short-lived worker
      and debt polls expose the canonical shared 50 ms period to the strict fast-timer
      inventory. Hosted AHK validation of these owner and period cases remains pending.

## Maintainer requests on 2026-10-01

Every request the maintainer makes is written here first and removed once it
is committed; one request is one commit with its regression test.

- [~] **71.** Retire the dedicated Metrics-window shortcut machinery.
  The Windows and macOS legacy fields no longer belong to defaults,
  loaders, full-save, native binding or scoped reset owners. Existing
  values and comments remain unknown configuration data; no migration
  guesses a replacement. Collection consent, privacy filters, encryption,
  menubar and widget transactions keep their existing acknowledgement and
  compensation boundaries. The shared `open_metrics_typing` and
  `open_metrics_apps` actions remain available through ordinary Shortcuts
  and Gestures on all three drivers. Linux's exclusion-list reason no
  longer mentions the retired shortcut UI, in all 21 locales. Local
  unit, E2E, unknown-source preservation and refusal regressions cover the
  retirement; complete native three-OS CI, packaging and installation
  validation remain pending.

The exact composed source retirement passes 13,281 macOS unit cases, 4,960 Linux cases and E2E suites of 101 and 154 checks. Four comment-banner widths caused the initial JS parent failure; the exact comment-only correction range and complete 353-check JS rerun pass, with the original failed receipt retained. Both canonical generators produced the owned artifacts. Exactly two save calls disappeared with the retired binding methods; every one of the remaining 57 calls and strict acknowledgement predicates is unchanged, and independent missing-call and unguarded-call mutations are rejected. Fresh integration retains the existing native Metrics consent and compensation owners, general action catalogue and exact historical unknown-source preservation. Native Windows and complete packaging/installation qualification remain pending.

Native Windows checkpoint 37107656277 retains 7,958 passing unit cases but exposes two genuine source-preservation failures: the real full save retains the retired Metrics values while its canonical serializer discards their unowned comments. Ordinary candidate composition now retains unmatched physical records and comments around explicitly owned canonical rows, checks the complete requested semantic model, and keeps source, lease, staging and publication refusals unchanged. Independent handwritten byte vectors run through both shared Lua ports and the actual Windows builder/publication owner; the original collector assertions and namespace no-op controls remain intact. The shared corpus also qualifies header-only comments and fully owned scalar records; a changed quoted literal-dot assignment stays explicitly refused before IO on the Lua ports, while Windows keeps its existing writable canonical contract. Portable full qualification passed 13,289 macOS units, 4,989 Linux units and 101/176 E2E checks; the final formatting/comment delta reruns the required static gates. Keep item 71 partial until a non-release native Windows checkpoint qualifies this repair and the complete three-OS package/install/launch gate finishes.

Checkpoint 37116696443 no longer reports the two real full-save retired-Metrics comment failures. Its remaining two Windows assertions concern obsolete comment-removal expectations, which are aligned separately with the approved source-preservation contract using complete-image and typed-value assertions. Linux unit, E2E, package and all 17 installation/run variants passed; macOS unit, E2E, package and nine installation profiles passed, while clean and Karabiner AppleEvent probes remain blocked. Windows downstream package/install gates were skipped after the unit failure; Release/Publish was skipped. Item 71 remains partial pending a complete native three-OS checkpoint.

The maintained AHK and Hammerspoon configuration-schema draft examples no longer recommend the retired dedicated Metrics-window shortcut table. The existing CJS retirement gate checks their actual semantic table headers, including quoted and array-table aliases, while literal-dot foreign table names remain distinct. All other draft consent, color and privacy records remain byte-identical, and the generator registry confirms the examples are separate from generated runtime templates. Whole-document draft schema validation remains separate; item71 still requires a complete native three-OS package/install/launch checkpoint.

- [ ] **73.** Partial: Windows combination families and pairs already use
      the canonical translated tap-hold key labels; macOS now resolves both
      physical keys through the same catalogue and invalidates its picker
      cache when the locale changes. The complete 182-entry native matrix,
      action IDs, press order and setter refusal boundaries stay unchanged;
      the three script-management pairs remain hidden. Linux still has no
      combination engine and retains the shared availability reason. The
      real macOS provider regression covers all 21 locales; shared contracts
      also replay each driver's physical catalogue. Native CI qualification
      remains pending. Find which action left the three French hotstring
      categories off in the maintainer's config.toml on 2026-09-30 (a
      restore, a clear or the wizard), since « ct★ » did nothing only because
      `category_enabled.french_magickey` was false; no historical attribution
      is established yet.

The physical-label contract is independent of the native matrix and stored action
IDs. Original provider cases fail before the fix; the qualified component suites
pass with all 21 locale catalogues. Full native CI remains required.

- [~] **81.** The maintainer asks to treat item 54 now (every menu row is
  declared in the shared manifest, none built in a driver's folder):
  Windows 103, macOS 180 and Linux 111 rows are still built by the
  drivers (`tools/test/native-menu-rows-baseline.json`). Read on
  2026-10-01, the sites are of four kinds, and three of them need the
  manifest to say more than it can today:
  (a) rows a `dynamic` entry leaves to the driver (Windows `register`,
  `append` and `add`: the WPM widget rows of Metrics, the AI menus):
  convert each to `check` or `command` with its predicate, as the
  conversions of 2026-08-07 did; the rows that tick themselves on the
  live menu need a rebuild after the click instead;
  (b) fixed-key rows inside the result of a `list` provider (the
  disable, tap and hold rows under each Tap-Hold key, the rows under a
  gesture slot, a hotstring file or an AI profile): the manifest needs a
  declared child template for a list parent, read by the three
  renderers;
  (c) separators a provider inserts between its own rows (155 of the 459
  sites): they follow (b), as part of the template;
  (d) the tray root bootstrap (Windows `tray_bootstrap.ahk`,
  `menu_init.ahk`).
  Metrics widget rows are now shared `check` declarations on all three
  drivers. Native getters retain stored colors/graph checks while disabled;
  Windows commands rebuild through the normal tray owner after durable
  acknowledgement. One golden fixture covers all 16 state combinations
  in each native menu suite; command regressions fence refused writes and
  ensure a refused Linux stop never starts the widget instead. Native CI
  run 36920222032 passed the new widget behaviors but exposed an API-family
  census that counted Menu( inside domain-helper names. The counter now
  recognizes complete native tokens (including whitespace calls); a source
  fixture covers every family, helper suffixes and comments without raising
  any baseline. Native run 36922684126 now passes Windows unit, engine E2E,
  packaging and installation, as well as the macOS and Linux test lanes.
  Order: finish other computed Metrics rows, then the template of (b)
  on Tap-Holds (the smallest menu that has one), then Gestures and
  Shortcuts, Hotstrings (Windows 35, macOS 59 sites), the AI menus
  (Windows 41, macOS about 70), and Linux `menu_builder.lua` (123) along
  each. One commit per menu, the baseline lowered in the same commit.
  The update rows greyed on a local version (2026-10-01) were added as
  provider rows and join the About slice.
  The fixed agent Mode choices now use the shared declaration and renderers; see item 54 for the regression and remaining native-row scope.

- [~] **88.** AI prediction tooltip style (`llm-line-style`): the line rule
  is now `_shared/lua/tooltip/llm_line.lua`, read by macOS and Linux and
  ported by Windows, pinned by
  `_shared/tests/corpus/tooltip/llm_line_vectors.json`. Seen on a real
  Windows 11 on 2026-10-01 (grey typed, green corrected, orange next,
  indentation 0, +2, -1 and -3). Remaining: look at the Linux GTK panel
  and the macOS canvas on real machines (the suites cover the rows, not
  the pixels). Windows now retains the shared suppression/emphasis receipt
  through parsing and prediction execution, paints corrected/next segments in
  the declared weight and measures each actual font before placing the panel.
  Its native GDI cache owns separate family/height/weight identities and
  preserves deletion debt. Shared corpus assertions now require the Windows
  bold result; native HFONT/Text-control regressions cover real font weights,
  widths and painted geometry. Focused portable checks passed; full integration
  and native Windows CI remain pending. The Mac/Linux visual acceptance remains
  under this item.
  Native checkpoint 37069995600 exposed missing typography initialization in
  the headless Windows paint fixture. It now reads the canonical font family
  and size, asserts valid values and restores the prior aliases in finally.
  Actual WM_GETFONT bold/regular weights, geometry, control counts and GDI
  retirement assertions remain unchanged; native Windows confirmation is
  pending.
- [~] **91.** Windows: « Combinaisons de touches » as on macOS. Done on
  2026-10-02: every ordered pair of the keys of `[tap_hold.catalog]`
  (key 1 then key 2 is not key 2 then key 1), each with « hold 1 + tap
  2 » and « hold 1 + hold 2 », listed by hand; the three former families
  are the recommended pairs (`infra/key_combinations.ahk`). The shared
  group now offers recommended/clear commands on Windows and macOS. Its
  native owners preserve unrelated shortcuts and recover rejected reloads;
  clear keeps the combination switch. Every Windows pair shows its action
  directly, including an explicit disabled label, before opening the picker.
  Restoring imports the three historical shared recommendations (AltGr +
  left Alt: previous word; AltGr + CapsLock: next word; left Alt + CapsLock:
  CapsWord). Linux still needs the combination engine tracked by item 93.
  The Windows bulk owner now limits action-parameter cleanup to known
  catalogue pairs, preserving future pair parameters as well as their
  slots. Both existing native preservation assertions remain intact.
  The menu fix passed full three-OS checkpoint
  [37008038530](https://github.com/adrienm7/ergopti/actions/runs/37008038530)
  at `b92d9dec8`: unit tests, E2E, packaging and installation, with release
  publication skipped. Remaining:
  (a) the chord slot (both keys within the simultaneity delay), with its
  symmetry, its delay and « copy tap to chord »: the first key of a chord
  must wait for the second, while every Windows tap-hold owner takes its
  hold at key-down; (b) on a standard AltGr layout a pair that ends on
  AltGr loses to the `~SC01D & ~SC138` combination that reads AltGr's
  fake LCtrl, and a pair that ends on LCtrl fires on that fake LCtrl; (c)
  a real-keyboard check of the order rule (a key held alone, then joined
  by another, must not fire the pair), which rests on AutoHotkey
  recording a key's physical state after its criteria have answered.
- [ ] **93.** Linux: the key combinations of item 91. The tap-hold engine
      binds no combination (`platform/remap/tap_hold_engine.lua` only cancels
      taps when a second tap-hold key goes down) and the Shortcuts menu draws
      no `key_combinations` group. Port the pair model of item 91 (same pair
      ids, slots and config sections as Windows), decide the chord inside
      `M:process` / `M:tick`, and widen the manifest group to `linux`.
      `caps_word` and `one_shot_shift` are `ahk`-only catalogue actions
      today. Left out of the 2026-10-01 session on purpose (the maintainer:
      « fais seulement pour Windows »).

- [ ] **96.** Remove the separate Ergopti+ AltGr-adjustments option from the
      Layout menu. Selecting the Ergopti+ keylayout in the emulation picker must
      suffice. Verify that the layout supplies every intended change, retire
      redundant feature gates and settings through their migration owner, and
      add native regressions for the selected layout without an extra switch.

Added a test-only characterization prerequisite for the legacy Windows Ergopti+ switch: all six historical AltGr descriptors are compared with independently frozen selected-layout neutral outputs, and eight SC012 roll cases execute exact production helper definitions in an owned native child. The reviewed TODO107 test prefix and historical golden remain byte-exact. Shift percent/ligature and whitespace deviations, wrapping requests, and configurable word spacing are recorded without claiming equivalence. Portable source/corpus contracts and scoped convention/encoding/loop checks passed; native AHK interpretation, owned child retirement, physical hotkey precedence, recent-chevron timing and final root verification remain pending. The switch, defaults, settings, migrations and all production/layout data are unchanged; TODO96 remains partial.

- [ ] **97.** Replace the fixed accent/direct-symbol shortcut submenu with
      user-owned entries, empty by default and offering "+ Add". Let a user on
      any keyboard layout choose an action from the shared catalogue or enter
      a character, then assign a physical key or modifier chord. Include é, à,
      è, ç, ù, circumflex/diaeresis dead keys and arbitrary punctuation (comma,
      period, colon, etc.). Ergopti emulation/keylayouts already supply their
      symbol mappings, so do not duplicate them as default shortcuts. Share the
      entry model, picker and persistence contract across drivers; test capture,
      custom Unicode output, dead-key composition, neutral defaults and refusal
      behavior through automated native and parity suites.

- [ ] **98.** Replace the fixed "make J the star key" setting with a physical
      key and output chosen by the user: any keyboard position and arbitrary
      character, including choosing no star at all. Integrate with item 97's
      shared user-owned shortcut model rather than another fixed-layout switch.
- [ ] **101.** Investigate the supplied Windows diagnostic's retained keylogger
      shutdown debt (watchers=0). Keep privacy filtering fail-closed;
      distinguish measured stalls from causes before changing tooltip/hook code.

The navigation-editor checkpoint (run 36928152648) passes all 72 Chromium/WebKit
rendering scenarios, Windows unit/engine/installation and macOS unit/E2E/all
installation variants. Linux unit passes, but its real accessibility-bus probe
exceeded the five-minute step timeout; Linux packaging/installation did not run.
Keep that failure separate from the passing browser and native results.
The next non-release run 36931498806 passes the complete Windows, macOS and Linux
pipeline, including the previously timed-out accessibility-bus probe and every
installation variant. It also proves the diagnostics correction: the rich page
is attempted below the old RAM cutoff, warm browsers bypass the cold-start
heuristic, and actual browser failures retain schema-ordered native controls.
Windows unit tests create those controls and verify sections, separate logs and
resize; the original three JS guards failed before the correction.

The macOS typing-rollover slice resolves the shared canonical key list through
its backend aliases. Native taps cancel pending holds on the next press; a long
hold activates at the configured threshold, preserving prior physical modifiers.
An inactive hold cannot clear another owner's navigation layer. Thirty-five
actual generated-graph timer replays cover taps, holds, cancellation, key release,
per-key timing, cleanup and inactive/revoked generation authority. Saved timer
outputs carry live mode and tombstone conditions, while historical fingerprints
retain the pre-timer immediate-hold graph (a deliberate mutation is rejected).
The shared alias/refusal contract runs on both Lua
runtimes for all three backend columns. Karabiner's lack of release-order rules
means a very fast chord on these typing keys becomes a tap, as requested.
Non-release run 36935089945 at `be5a40fee` passes the complete three-OS pipeline,
including all installation variants. Its temporary branch has been removed.

The metrics privacy filter now reads "Ignore system authentication" in
all 21 locales. The existing setting and system-authentication exclusion
behavior stay with their current owners; only the label is shortened.

The supplied diagnostic's three unsupported-bound-file warnings were obsolete:
Windows already routes repeat corrections, rolls and SFB reduction through the
real TOML loader. Successful discovery no longer raises those warnings or the
diagnostic warning count. The portable source guard fails on the original claim
and rejects its reintroduction; the registered native regression captures enabled
warning output and verifies all 83 shipped source entries remain readable.
That native case passes non-release run 36935760620 at `21de5dcea`: the complete
three-OS pipeline, including every installation variant, is green. Its temporary
branch has been removed; the run also covers the 21-locale privacy label.

The order-dependent macOS terminator failure is resolved by the production-root
module isolation already committed in `612000595`. Two additional regressions
poison the shared terminator module and catalogue cache slots with boolean true,
reproduce a real require failure, then run the actual purge and reload the real
catalogue while preserving test infrastructure. The full macOS suite and the
reported LLM tooltip case pass checkpoint 36957664162 at `68a8f1462`; these new
exact-boolean regressions also pass the focused runner.

- [~] **102.** Simplify each Hotstrings category submenu to two commands,
  "Enable all" and "Disable all", replacing the duplicate category and
  whole-section activation controls. Declare the structure once in the
  shared manifest and translate its labels into all 21 locales. Apply the
  effective category/section changes through their persistence owners;
  retain unrelated choices and fence refused writes/runtime publication.
  Replay the same full-enable/full-disable behavior on every driver.
  The macOS lifecycle helper now rejects the preference owner's returned
  refusal as well as a thrown publication error. Three regressions first
  showed false acknowledgements after false/nil/throwing writer results;
  they replay the real save/rollback owner, preserved choices and runtime,
  withheld cache updates and the visible failure notice. Void UI-only
  callbacks remain valid. Category bulk operations now share one Lua
  planner and a Windows port with a 17-vector common corpus. Both commands
  explicitly set the category and its actionable sections, preserving the
  independent engine master and legacy Layout remapping. Linux commits
  through its existing canonical-choice owner; macOS includes persistence
  acknowledgement inside the registry/settings rollback; Windows uses its
  existing lifecycle-fenced reload journal. Native-owner cases cover real
  settings/source bytes, unrelated choices and immediate/late publication
  or writer refusal. The full native-owner checkpoint 36954011552 at
  `7ad954b22` is green on all three OSes, including Windows unit/E2E,
  packages and installation. Standard and language-category submenus now
  consume `hotstring_category_menu`: two explicit commands, optional source
  file, separator and native section data. Both commands remain available
  behind a closed category or paused engine. Two new label keys have all
  21 translations; source and native-menu tests reject duplicate switches,
  inverted intent and duplicate rendering. macOS save-refusal tests retain
  category state and withhold a success refresh; Windows native menu clicks
  replay the real reload journal. Linux treats only exact true as an
  acknowledgement and surfaces one localized, keyboard-released error dialog
  on false/nil/throw; eight native-menu cases cover both requested postures.
  The category-menu checkpoint 36957664162 at `68a8f1462` is green on all
  three OSes, including native Windows menu callbacks, packages and installs.
  This checkpoint precedes the following extension-file owner changes.
  Windows extension-file submenus now consume the same shared commands as
  their existing macOS/Linux category views. Their owner rediscovers the
  extension under the configuration lease and commits the group plus every
  section as one sparse batch. Two common vectors preserve colon namespaces
  and Unicode section names; native cases retain the engine master, sibling
  categories, private source and package contents across immediate/late
  refusal, and reject unknown or uninstalled content before writing.
  Personal menus now use the shared explicit commands on macOS and for the
  primary Windows personal file; Linux's existing personal category rendering
  is covered by four parity cases. macOS commits all selected personal/custom
  gates and sections together, restoring prior and absent gates after a refused
  canonical save without starting capture. Individual personal file submenus
  select only their own group. Windows uses the conditional reload journal,
  reads personal section inventory afresh under the lease, preserves native
  repaint references and restores exact configuration bytes after immediate or
  late replacement refusal. The native CI owner cases passed in run
  37016239316; its two remaining Windows failures exposed a direct native call
  and a default-menu freshness guard. Rendering now reads item counts through
  the tray adapter and keeps an explicit fresh default path, with native
  regressions proving independent default menus and refusal of populated targets.
  Full three-OS checkpoint 37033032620 at `6275cac35` passed native unit,
  E2E, packaging, installation and launch gates with release skipped, after
  correcting owned submenu teardown in the Windows fixtures.
  Windows Dynamic now renders the shared explicit commands and journals the
  seven canonical family choices, rediscovered under the lease. Its scope owns
  no extra category gate and preserves the Hotstrings master and pause. Native
  cases cover both targets, immediate/late refusal, exact recovery, unknown
  neighbours and concurrent ownership; full CI remains pending for this slice.
  Additional Windows personal-file views still need an identity and gate owner
  shared by the live engine and previews. macOS's personal-info placeholder
  still needs admission
  to its otherwise shared dynamic scope.
  The Windows discovery boundary now filters its mixed legacy tray map to
  the Hotstrings namespace before requesting any feature metadata; a native
  case excludes Layout, Gestures and Shortcuts from both discovery and selection.
  Runs 37046976773 and 37047412149 exposed missing boot-owned globals in
  headless Dynamic fixtures. They now consume the actual tray declarations,
  validate their manifest families and restore previously set or unset state.
  All ten native cases retain their ownership, pause and refusal assertions;
  production still uses its curated boot order. The corrected native CI is
  pending. The Dynamic child rows now have one canonical declaration in the shared menu
  manifest. Windows derives both its legacy family aliases and tray order from
  those records; macOS and Linux retain their native live dates, prefix counts,
  preference owners and personal-information section names. An independent
  pre-centralization snapshot retains all seven families, their separator and
  metadata. Both Lua native callers first failed the deliberately reordered
  manifest case, then followed it; native Windows cases inspect actual row
  positions, the separator and personal-information editor. Portable local
  validation is recorded separately. Full native Windows and complete three-OS
  packaging, installation and launch qualification remain pending. The personal
  file identity/gate remains pending. The macOS personal-info placeholder now
  participates through its acknowledged native owner, as qualified below.
  Linux Dynamic now consumes the same explicit command pair and shared bulk
  planner. Its existing transaction commits the declared dynamic master and
  seven manifest families as one conditional cohort under both real leases,
  with exact backup, runtime acknowledgement and retained inverse on refusal.
  Scoped adoption validates only owned leaves; unrelated outdated previews,
  global master, pause, overrides, personal sources and unknown neighbours stay
  preserved. The old menu failed eight meaningful cases; 57 affected cases
  pass locally. Full three-OS validation remains pending for this slice.
  Native checkpoint 37052939737 then exposed a missing label-module include
  in the headless runner. It now loads the actual pure manifest descriptions
  owner, and the Dynamic fixture rejects its absence before menu construction.
  The eight transaction assertions remain unchanged; native validation remains
  pending for this additional harness correction.
  Checkpoint 37056318950 exposed the next omitted boot dependency: dynamic
  counting reads the personal-information map. The fixture now derives that
  map from the real entrypoint and owns a fresh count cache, restoring both
  assigned or unassigned globals afterwards. All transaction assertions remain
  unchanged; actual AHK execution awaits the next native checkpoint.
  Checkpoint 37060216766 reached the transaction assertions and exposed
  stale text-cache reuse by the pending-reload fixture. Its detached candidate
  now reads an exact owned copy through the real config reader, matching a
  replacement interpreter while preserving this process's cached authority.
  The original posture/backup/refusal assertions stay intact; an additional
  assertion proves the pending live text cache still contains the old source.

The macOS Dynamic scope now admits the shared-index personal-info module placeholder through the existing acknowledged runtime façade and canonical preference owner. It applies the native module choice before publishing config.toml, restores the module/menu/registry snapshots on rejection, refuses unsupported declared owners, and retains unrelated groups, unknown fields, sparse state, pause, and master posture. The checkbox reads the same native owner. Unchanged or never-applied module state is not reset.

Thirty new actual-owner regressions cover enable/disable, false/nil/throw module and save acknowledgements, sparse rollback, conditional-writer refusal, external stale bytes and retry, selected-group isolation, unsupported declarations, exact mapping identities, unchanged native state, the checkbox action and post-commit refresh refusal. Independent initial failures and full receipts remain outside the repository.

The selected local gates pass 353 JS checks, 13,302 macOS units, 101 macOS E2E checks and 65 focused scope cases in the private baseline. Complete native three-OS packaging, installation and launch qualification and Windows personal-file identity remain pending.

Windows native registration now retains an explicitly supplied default group when category/section provenance is also present. Both metadata containers derive a group only when no explicit group exists; four registered native cases retain exact group indexes, matching, specification identity and insertion sequence for explicit default, named, future, legacy-empty and omitted owners. Supplemental actual Lua-owner probes retain their existing explicit-group behavior. Selected portable syntax, encoding and JS gates pass; actual Windows execution remains pending CI. This is a prerequisite for personal-file provenance: Windows personal-file identity, live/preview gates and menu commands remain incomplete, so item 102 stays partial.

Windows ordinary personal packs now retain the authoritative recursive source label and parsed section in live metadata, matching their preview rows without changing the historical default activation owner. Selected official sections keep their existing derived group, resolved delay and priority. Registered native regressions and portable 353-check/encoding gates cover this prerequisite; actual Windows qualification remains pending CI. The shared personal-file identity, live/preview gate owner and menu commands remain incomplete, so item 102 stays partial.

The native Windows checkpoint 37118530448 passes the two source-retaining TOML contracts and reaches 7,988 successful tests. Its two remaining personal-provenance failures compare the short A_Temp spelling with the existing native enumerator's canonical long path before reaching the metadata assertions. The fixture now obtains its expected path independently through Win32 GetLongPathNameW and checks both actual root spellings, preserving the Unicode labels, exact live specifications, insertion order, activation owner and preview assertions. Portable source and encoding gates pass; execution of these corrected native cases and complete three-OS packaging/installation remain pending CI. Item 102 stays partial.

TODO 102 remains partial. The shared personal-file policy now supplies reversible UTF-8 relative-component descriptors in a distinct, dot-free namespace; Windows, macOS and Linux transport owned descriptor snapshots through their real discovery, registry and compiled live/preview owners. Independent goldens distinguish nested names, dotted names, double underscores, Unicode normalization, bundled names and the historically admitted empty-stem `.toml` filename. Legacy activation, sparse settings, root overlays, registry order and output semantics are preserved.

The descriptors are provenance, not an adopted settings key or a file lease. The next cohort must admit these exact shared identities into the existing acknowledged Dynamic scope/menu/persistence owners, with stale-source and file-alias refusal, before claiming personal-file collisions or per-file gates are fixed. Native Windows execution and full three-OS packaging/install validation remain required.

Personal file commands bind the shared descriptor admission policy before
the macOS registry transaction. File and section callbacks require a current
native owner, configured route and exclusive source binding; legacy group
collisions, physical aliases and stale callbacks refuse before mutation.
Existing localized failure notices and canonical ACK/rollback owners remain
in charge. The master switch, pause state, unrelated mappings and unknown
disk neighbors are preserved. Eleven literal admission decisions are
replayed through all three test ports, including Linux overlay losers and
the Windows additional-file default group that has no exclusive file gate.

      TODO 102 remains partial: Windows additional-file persistence ownership and
      collision-free personal view adoption still need work. Native Windows
      qualification also awaits the separate inline descriptor transport and
      canonical-path fixture repairs; their original assertions remain intact.

Windows additional personal TOML entries now carry their validated source
descriptor through both simple and inline native factories. Historical
flags, priorities, delays, registration order and default-group activation
are preserved. Original live/preview identity and copy-ownership assertions
remain intact. The eight-file discovery test independently resolves its
fixture root with bounded Win32 GetLongPathNameW and replays short/canonical
spellings under an exact root fence. TODO 102 remains partial; corrected
native Windows execution is pending CI.

Linux whole-tree and language hotstring aggregate checkboxes now require an exact durable true acknowledgement from the existing preferences owner. False, nil, exceptions and truthy nonboolean refusals retain the prior native catalogue, private source and checkbox state, and report the existing localized error through the keyboard-released modal owner. The actual callback regression fails against the previous consumer; 35 focused checks pass locally, including eight genuine preferences-writer refusal cases. Remaining personal/dynamic views and complete native three-OS validation are still tracked separately.

Linux category-section menu callbacks now acknowledge only the real preference owner's boolean `true`. A missing, refusing or throwing owner returns `false` and shows the existing localized save-failure notice with the keyboard released. The canonical choices writer remains the sole publisher; failed publication preserves the original source and compensates the active engine before any success notification.

The registered category module passes 37/0, including four actual conditional-writer publication refusals and a durable success followed by real disk reload. The old callback fails the same tests (25/12); truthy-acknowledgement and silent-refusal counterfactuals fail as well. All 25 original cases and 36 original assertion lines remain; the old successful test double now returns the real owner's `true` receipt. The separately approved Wrap changes are preserved by exact two-order composition and whole-file inverse. Actual native row counts do not change. Whole integration and hosted native UI qualification remain pending; this is a TODO102 prerequisite, not complete personal/dynamic-menu retirement.

The final ordered sibling also retains all OpenFile12 category-file cases and assertions. Its registered module passes 43/0; whole source inverses recover the complete OpenFile test and the original ACK2 candidate independently. The earlier standalone preimage did not include those future OpenFile tests and remains preserved as historical proof, not the final queue preimage.

Linux extension-bound hotstring section callbacks now acknowledge only the actual canonical owner's boolean `true`. Missing, refusing or throwing owners return `false` and show the existing localized save-failure notice through the keyboard-release modal owner. The extension's direct section row retains its captured category/section identity, checkbox and disabled-category policy; its preference writer and runtime compensation remain unchanged.

The registered category module passes 55/0: all 43 corrected OpenFile/Wrap/category-ACK parent cases plus twelve extension-owner cases. The same tests against the actual previous extension callback fail 43/12; truthy and silent-refusal controls fail 53/2 and 45/10. Actual private-file publication refusals preserve every source byte and active engine choice without success notification; true publication is reread from disk. All parent assertions and complete test prefix remain exact, and the canonical native-row scanner measures zero added sites. This is a separate TODO102 prerequisite. Extension bulk callbacks and other remaining dynamic-menu ownership work stay open; root-wide integration and hosted native UI qualification remain pending.

Linux extension Check all / Uncheck all commands now publish category gates through one existing canonical choices transaction. The new gate-only entrypoint uses the existing shared scope planner to validate known category identities while selecting zero section leaves, then delegates to the unchanged commit_choices owner. Individual section choices, independent categories and future source records remain outside the update. Native callbacks require boolean true before their explicit redraw; refusal shows the existing keyboard-release save-failure notice.

The original native callback and original configuration owner demonstrably make two separate publications. When the first succeeds and the second refuses, enable leaves rolls=false/sfbs=true and disable leaves rolls=true/sfbs=false. The corrected registered module passes 78/0, retaining all 55 parent cases and 109 assertion lines. Tests use actual private-file canonical publication, real engine compensation, disk reload, held configuration scope, foreign source comments/nested values and typed target refusals. Both real positive directions commit once; each refused transaction restores the entire source and engine without notification/redraw. A section-reset counterfactual fails the independent byte-preservation assertions. Missing-new-API old cases establish only the added interface contract, not the partial-publication cause.

The native row scanner measures zero new sites; no generated baseline change is needed. Private menu availability checks encounter the sparse profile's absent startup script and remain refusal-only; they are not product/native-startup qualification. This prerequisite does not retire all TODO102 dynamic-menu work or claim hosted native UI/full integration success; those gates remain pending.

Linux’s global and category delay menu callbacks now repaint and return true only after the existing override owner acknowledges publication with exact boolean true. Refused or throwing owners return false and show the existing keyboard-released save-failure notice. Private native-file regressions preserve the original source and RAM on publication refusal or a held-prompt source change, then verify a successful retry and disk reload. The 78 prior category-menu cases remain intact; root full validation and actual GUI/native CI remain pending. This is a bounded acknowledgement prerequisite; broader per-file editor and unknown-data ownership work remains partial.

Linux’s active personal-information editor now consumes the canonical catalogue reload’s second return as an exact boolean publication acknowledgement, instead of treating its mapping count as success. A legitimately empty catalogue can return 0,true and close normally; a saved edit followed by a refused reload remains explicitly saved but not reloaded, with no page close or refresh. Private native-file tests exercise the actual personal-data writer, dynamic rule refresh, catalogue producer and failed engine publication, then verify retry. Existing assertions are preserved with a faithful count,true success fixture. This fixes a bounded runtime acknowledgement prerequisite; broader per-file ownership, opening-view admission and schema work remain partial. Full root validation and actual GUI/native CI are pending.

The canonical section-publication fixture now delegates directory creation and cleanup to the existing ShellRunner.run strict Boolean owner across all four Category/Bulk/Delay fixture boundaries. No production callback, schema or publication policy changes. Immutable bf589 Fedora/Alpine CI failed five new cases at the numeric-only mkdir precondition; the exact installed Alpine package recipe enables Lua52 compatibility and its upstream implementation returns true/exit/0 on success. Actual local Lua5.4 physical commands reproduce the rejected success, while LuaJIT numeric0 and the controlled compatibility boundary both preserve strict failed-process refusal and physical file cleanup. The complete ordered110-case prefix is retained: old compatibility replay74/36 becomes117/0 under both forms with seven independent process/refusal regressions. Fedora compilation flags remain unobserved after denied public source reads, and corrected distribution-native CI remains pending. TODO102 stays open.

The macOS baseline hotstring-delay prompt now enters the existing global writer fence before changing RAM or the live keymap, and requires an exact native setter acknowledgement plus getter readback before invoking the ordinary canonical preference save. Refused publication uses the existing whole-state rollback; a baseline-native inverse remains retained until the entire rollback returns and its acknowledgement is observed. A distinct foreign native value or replaced captured binding is left untouched and keeps the writer fence closed until an owned retry can restore it. Zero, finite millisecond values, existing prompt/cancellation/default-label semantics, per-key neighbours and unknown disk bytes are preserved. Actual registered Lua coverage is 36/0 versus the original callback 9/27, with five causal mutants rejected and eight unchanged existing cases passing. These are repository-owner tests over private physical POSIX files with controlled native ports; physical macOS qualification and full selected integration remain pending. This baseline-only correction changes no schema, defaults, Windows/Linux owner or per-key delay callback, and does not equate macOS expansion_delay with Linux category/global delay semantics or close TODO102. The native scalar getter has no mutation epoch; same-value foreign mutations are not claimed independently observable.

The real-file Personal reload fixtures now use the existing ShellRunner strict normalized success receipt for their private mkdir and cleanup boundaries. This corrects the numeric-only precondition seen in the six Fedora/Alpine Personal cases without changing save/reload owners or assertions. Actual LuaJIT and Lua5.4 focused cases pass69/0; actual Lua5.4 old fixtures reproduce57/6. The exact Fedora build flag is unobserved, and the corrected hosted distribution/full checkpoint remains pending. TODO102 stays open.

Linux dynamic-family menu callbacks now re-read the retained native owner and canonical family before writing, require the exact true preference publication receipt, and refresh/reload only after that receipt. Real refused writes retain source bytes and support retry; stale row, detached owner, category-off and malformed receipts refuse. Prefix catalogue reload remains its existing separate post-save operation; this change does not claim compensation or whole-transaction success. Focused actual LuaJIT tests pass58/0; hosted distro/native menu and the remaining TODO102 owners remain pending.

Linux personal hotstring views now retain the exact classified opening bytes/path and trusted manager window epoch delivered to the view. Missing, malformed, refused or retired openings create no editable save authority. Saves refuse external section edits and use the retained precondition through the existing writer; only its exact committed payload advances consent for a second save. Reopening deliberately admits new bytes. Both complete registered bridge modules pass227/0 under Lua5.4 and LuaJIT; the original bridge gives185/17 and13/12, and six causal mutations fail. All original assertion lines and registrations are preserved. Existing direct-save fixtures now establish a classified opening, and source/publication faults record actual execution outside protected callbacks; the unchanged capture spies remain payload-dispatch tests, not durable acknowledgement tests. Actual private files, staged CAS and manager route are exercised with recorded GTK/JS boundaries. WebKit delivery acknowledgement does not prove DOM display. Existing saved-but-reload-refused policy stays separate. macOS retained-source ownership is unchanged; Windows stale-editor consent and additional personal/dynamic scopes remain unqualified. TODO102 remains partial pending full root/hosted distro and native GUI qualification.

TODO102 remains open. The Linux real-WebKit fixture now creates its own valid Personal source and initializes the actual configuration owner before the editor opening; it verifies the real classified bytes and canonical projection, retaining the existing Manager route and all four window/page/payload assertions for each page. The fixture shuts down its view and retires only its owned source paths after success or refusal. Physical LuaJIT and Lua5.4 source-boundary controls reproduce the absent-path refusal and admit the owned source, with malformed source refused. Both actual isolated Xvfb host attempts stop at the mandatory environment check because LGI/WebKit2GTK are unavailable locally; native payload-null OLD RED / received-payload candidate GREEN remains pending source-qualified CI. No production opening-source, CAS, editor UI, GPU, timeout, or save/refusal policy is weakened.

Windows personal-editor opening-source consent is a bounded TODO102 prerequisite. The native GUI and WebView now obtain their displayed model and consent receipt from one classified fresh read, independently of the ordinary untagged reader cache. The receipt retains exact path, presence, UTF-8 image and actual window/session identity. A missing, unreadable, replaced, deleted or stale-session source cannot authorize publication. Web initialization uses the existing native script-outcome receipt; that receipt does not certify application rendering.

The existing personal-file lease, detached request generation, deferred last-wins queue, durable staging and atomic replacement remain the mutation owners. The final physical comparison occurs after arbitrary authorization and outside Critical; a short pure owner/session check follows. After exact replacement acknowledgment, the receipt advances only to the staged own image. Same-session A→B saves remain admissible. A durable save whose reload is refused returns FAILED, keeps the form incomplete and retains its resync obligation; a foreign source refuses before replay of that older live image. The four existing file/section metadata override fields are parsed from the admitted image through their existing parser.

This is cooperative opening-byte consent, not kernel CAS against an external writer after the last read. Successful saves still use the existing whole-model serializer: general unknown-field/comment preservation and TODO104 leaf migration remain separate. No schema, new WAL, generic scope, lock, polling, locale or writer fallback is introduced. macOS's retained opening snapshot and Linux's separately delivered opening-source owner are unchanged; their runtime and serialization contracts are not claimed equivalent to the Windows lease/deferred owner.

All existing test bodies and assertions are retained. Twenty-two additional cases are registered through the existing Windows runner and exercise real private file publication, hidden Gui identities, the existing WebView Promise port, source drift, actual read/rename sharing refusals, own coalescing, failed reload/resync and metadata neighbors. Local proof consists of bounded source/registration, encoding and existing syntax/loop scans only. AutoHotkey and native GUI execution are unavailable locally; original/candidate native RED/GREEN, full root validation and Windows CI remain required. Root integration must reconcile exact five-path preimages with concurrently delivered Windows changes before applying this historical private candidate.

Windows personal opening-source checks now compare the exact String image returned by their existing classified read. The previous calls passed TOML text to a helper whose first parameter is a file path, causing present-file saves and retained resyncs to refuse before reaching publication. The retained durable-image String guard, configured path/session/lease checks and native journal remain authoritative. Two metadata fixture replacements now pass the native limit in the sixth argument, leaving the fifth OutputVar argument omitted. All existing native assertions remain intact. Native run 37221758669 supplied the seven failures; corrected native Windows execution is still required. TODO 102 remains partial, including additional-file gate ownership.

- [~] **104.** Split common autocorrections into meaningful selectable sections.
  An independent pre-split corpus now freezes all 140 rules, flags, metadata,
  delays, common priority and historical order. The shared editorial catalogue
  classifies 34 names, 95 abbreviations and 11 technical terms outside runtime
  category discovery. Actual reader/registry/cache regressions compare the
  complete legacy corpus on every driver; native Windows CI remains pending.
  No source, section ID, label or activation choice changes in this slice.
  The runtime split still needs conditional fan-out migration of config.toml
  choices and the independent hotstrings_overrides.toml timing/presentation
  overrides, preserved global order, 21-locale names and per-section E2E.
  Never regenerate these historical expectations from the split source.
  The Windows value-clone owner now preserves Map comparison modes and
  independently owns typed TOML Boolean wrappers. Four registered native
  regressions cover distinct quoted keys, nested mutation in both directions,
  typed render/readback and an isolated generic clone without the TOML class.
  Native Windows proof remains pending; unsupported opaque objects keep their
  previous identity contract.
  The native clone probe now sets Map.CaseSense while the fixture map is
  empty, before inserting values; AHK forbids changing that setting afterwards.
  Checkpoint 37056318950 demonstrated the fixture setup error. Production
  cloning and all independence/case-sensitivity assertions remain unchanged.
  Checkpoint 37061649827 additionally exposed the redundant global class
  declaration through the unchanged native namespace audit. Read-only class
  references already resolve the global constant, so the clone owner now
  keeps its IsSet guard without redeclaring TOML_Bool. The absent-class probe
  and every typed-copy assertion remain intact; native validation is pending.
  Shared Lua, Windows and the JS reference now specify `copy_if_absent`:
  copy an existing source into an unoccupied destination, retaining the source
  and every explicit destination, including false and occupied ancestor or
  descendant namespaces. Copies independently own supported collections and
  preserve source records. Three independent fixtures and five registry
  defects cover ordering, repeated/no-op copies and strict shape validation;
  the original engine failed five new cases. Focused JS, macOS 40/40 and Linux
  LuaJIT 37/37 passed; full/native Windows validation remains pending.
  Schema version remains 8 and no runtime subsection split is introduced.
  The Windows registry now owns every registration sequence identity;
  transported builder or caller metadata cannot replace it. The independent
  140-rule corpus exposed the second sequence allocator in native CI; its
  historical order assertions remain intact. Four registered native cases
  cover prebuilt metadata, mixed factories, override attempts and group
  isolation. The corresponding Lua registries retain their existing single
  sequence owners. Checkpoint 37061649827 then exposed a distinct Windows
  admission bug: an earlier case-conform rule wins mixed input it subsequently
  refuses, hiding an executable exact-case entry. STAR and END matchers now
  consult the existing pure conform policy before arbitration, matching the
  shared Lua engine. Regressions cover both insertion orders, actual priorities
  and sequences, valid case forms, exact mixed fallback and no-op masking,
  without invoking callbacks during matching. The original circumflex matrix
  and independent historical corpora remain intact; native validation is pending.

TODO 104 remains partial: the shared hotstring reader now retains physical entry order, and common autocorrection consumes it through the three native registry/cache owners. Independent interleaving tests preserve cross-section insertion precedence while French packs and bound-source owners keep their existing declared order. The current caps identity and all 140 historical rules, flags, metadata, delays and common priority remain unchanged. The runtime family split, config/override migration and full hosted parity validation remain outstanding.

Windows native qualification follow-up: the new ordered-cache fixtures now use the existing JsonParse owner. Privacy/options and two-sided magic-marker source guards inspect the shared native row registrar and explicitly verify both the legacy generated-section and source-ordered category routes, including the bound-source fallback. Two additional native route cases preserve privacy, preview snapshots, both marker replacements and caller-map independence. Portable source/convention/encoding checks pass; actual Windows CI qualification remains required. TODO104 remains partial: the runtime family split and owned migration are not implemented.

Partial: Windows source-order regression inputs now use independently authored legal native inline-table fields and explicit flags, preserving the frozen shared interleaving expectations, metadata, defaults and historical 140-rule corpus. The real parser must admit every fixture record before cache and registry order are judged. Portable controls reproduce the old zero-row admission and qualify all six interleaved/four bound inputs; actual native AHK and full three-OS CI remain pending. No production parser or registration policy changed.

Linux ordinary hotstring override setters and clears now edit only changed owned delay/color/show_tooltip/priority leaves through the existing shared TOML writer. Classified load checkpoints fence preparation and publication; unknown records, quoted identities and untouched comments survive, stale/unreadable/malformed sources and refused I/O retain RAM/cache, and scope publication/restoration threads the actual ScopeFile classified target (including absent versus present-empty). Ten focused Linux cases pass; seven of the original nine fail against the original writer, and an additional absent-scope case fails against the first candidate. The unchanged real engine priority/restart fixture and all 52 original assertions remain. Root selected verification and full three-OS CI remain pending. This is an override ownership prerequisite only: the runtime section split, schema/config fanout and override migration remain unfinished. The existing isolated delay/priority fixture now initializes its real classified source checkpoint before saving; all former assertions remain intact and its previously failing actual case passes.

- [ ] **105.** Let users define programmable dynamic hotstrings on Windows,
      macOS and Linux, separately from the ordinary hotstrings editor. Provide
      a documented user-code entry point under "Dynamic hotstrings", examples
      and a callback API that lets users compute any replacement/action rather
      than limiting them to the editor's fields. Share the trigger, callback,
      enable/disable and lifecycle contracts; isolate native implementations.
      Preserve user source files, report load/execution errors visibly, and
      cover real callback execution, live enable/disable, cancellation and
      suspended/privacy-filtered input with automated cross-driver tests.

- [ ] **106.** Expand the shared gesture/keyboard action catalogue for user
      automation. Discover and offer Apple Shortcuts on macOS; inventory and
      expose available Windows/Linux equivalents, installed automation tools,
      shell/PowerShell scripts, launchers and application actions. Verify each
      provider's real invocation contract and availability rather than listing
      unimplemented actions. Let every driver assign a user script, Python file
      or other executable with explicit parameters. Use the same parameter model,
      picker and persistence for gestures, keyboard shortcuts and other action
      consumers; keep discovery and execution in platform adapters, with
      translated reasons for unavailable OS-specific actions. Test real fixture
      scripts, paths/arguments with spaces and Unicode, process-start refusal,
      execution errors, lifecycle/cancellation and cross-consumer parity.

- [~] **107.** Make the number-row policy explicit: native behavior, digits
  directly or symbols directly, with an acknowledged migration of the old
  Windows Boolean and preserved unrelated settings. The earlier Boolean slice
  resolved actual desired KLE base descriptors before falling back to native
  HKL probing. Already-direct Ergo-L over AZERTY retains Shift symbols; an
  emulated swap emits through the existing KLE owner rather than flattening
  actions/dead states to text. Inspection preserves Caps and pending state.
  Independent ten-key vectors and captured registered criteria/callbacks cover
  actual AZERTY/QWERTY HKLs, base/category/navigation changes, AltGr, Caps
  descriptors and dead-key composition; native CI remains pending.
  The earlier Boolean slice did not change the enum or schema. The shared
  native/digits/symbols policy now owns the three translated choices and
  schema9→10 migration; only the legacy Windows Boolean is converted. Windows
  symbols use the current supported KLE descriptor source. macOS/Linux expose
  native posture without acquiring forced input or persistence authority.
  Remaining: native-HKL and Lua forced-symbol owners, actual native Windows
  acceptance of the new policy, and physical keyboard validation.

TODO107 — tranche préparée, validation native restante : politique partagée native/digits/symbols et schéma9→10 ; seule la migration booléenne Windows est reconnue. Le mode symbols utilise exclusivement les dix paires de descripteurs de la source KLE actuelle, avec son émetteur et son état de touche morte existants. HKL natif et les deux pilotes Lua n’acquièrent aucun nouveau mode forcé : les choix indisponibles portent une raison traduite dans les21 langues, Lua affiche son état natif en lecture seule. Les sources inconnues/malformées restent préservées ; le scope macOS refuse leur acquisition avant sauvegarde et publication. Le menu Windows conserve la source brute, les propriétaires de configuration/pause/master et l’identité \_LayoutPollRetry avec HKL ; seule une transition OBSERVÉE est ainsi clôturée. Les tests Windows ajoutés (émission, répétition, touches mortes, légendes, publication/refus et callbacks retenus) ne sont pas exécutés localement : CI Windows et vérification physique requises. Le forçage symbols HKL natif/Lua reste à réaliser ; TODO107 reste partiel.

Composition préparée après Navigation12/DynamicACK2 et BaselineDelay macOS : les133 autres candidats restent identiques à la version initiale ; les sept sorties sont recalculées par leurs générateurs, avec retour exact au parent puis répétition exacte. Les43cas Lua ciblés passent sur la composition. Le census natif réel du parent97/154/98 reste inchangé. Les gardes menu/graph/census ciblées passent ; aucune qualification complète de cette composition ni exécution Windows native n’est revendiquée.

Windows follow-up: the parse-time number-row criterion now retains native input until the actual Layout category map is admitted with an Integer true switch. A contained call publishes symbols capability only after the existing source owner returns exact true; unpublished emulation dependencies cannot escape during Bundle_Init. The AltGr provider was already excluding the global digit-row policy: its stale marker assertion is replaced by actual provider count/order/action and exact single global placement checks, without changing menu production. Existing digit-row tests retain their whole prefix, and all other accented-shortcut assertions remain unchanged. New registered native tests cover unpublished, malformed, missing, false and true sources, model refusal, and a genuine KLE symbols positive. Portable scoped loop, syntax, convention, BOM/LF and source-envelope checks passed; no local AHK execution is claimed. Full selected root qualification and Windows native CI remain required. Existing unsupported native HKL/Lua and physical input requirements remain open.

- [~] **108.** Make the default hotstring-editor shortcut follow the effective
  physical key that directly types the selected magic character: Ctrl on
  macOS, Win/Super on Windows and Linux. The shared conditional policy now
  represents this as one ordinary editable slot. Missing values select the
  default; explicit none and existing personal physical-chord assignments win.
  The slot follows direct sources for star, `ù`, `;` and other admitted magic
  characters on any layout, and refuses missing, ambiguous, dead or modified
  sources. Native binding owners retain their pause, inhibition, generation
  and publication fences. Its editable row and unavailable reasons are
  translated in all 21 locales.
  Windows resolves neutral physical keys from the acknowledged layout and
  native HKL. macOS probes the exact active TIS Unicode layout through its
  signed native launcher, then retargets through its existing registrar.
  Linux owns an X11 keymap/group probe and verifies source/device identity;
  Wayland source ownership remains unavailable, with an explicit translated
  reason and the editor still reachable from the menu.
  Fresh configuration omits neutral ordinary shortcut rows on all drivers;
  an explicit user none is retained by the acknowledged shared writer.
  A closed schema-v9 migration transfers representable macOS legacy editor
  shortcuts only to published assignable chord slots, preserves occupied or
  unknown destinations and refuses ambiguous sources without publishing.
  Historical saved Win+D/editor choices remain; the old fixed magic hook and
  Win+D recommendation are retired.
  Legacy macOS built-ins retain their existing native factories and publish
  physical claims through their exact lifecycle; late claims suspend only the
  conflicting conditional owner, with acknowledged compensation and cleanup
  debt. A revoked owner cannot be restored after a refused deletion.
  Focused local regressions cover native source admission, collision/none
  precedence, configuration publication/refusal, scope restoration, migration
  parity and independent corpora. Complete local integration passed the selected JS, macOS/Linux unit
  and E2E gates. Native three-OS CI, packaging, installation and launch
  remain pending. Native macOS/Windows
  layout delivery and genuine Wayland seats are not qualified by Linux-host
  stubs or the Xvfb source probe.

The Windows physical catalogue now uses the existing entry-point \_SharedDir owner when called without an injected root. The previous undefined SharedDir stopped legacy Win shortcut registration before the suite or application could start. A direct zero-argument catalogue and actual legacy-registration regression checks independent physical identities and exact callback/root preservation; existing native lifecycle assertions and warning policy stay intact. Encoding and strict conventions pass locally, while native Windows unit, compile and E2E qualification remain pending.

Native CI run 37085780111 exposed a macOS launcher compile failure before
source-probe tests could run: Swift imports Carbon's UniCharCount as Int.
The translator now uses that imported type; its exact selected-source,
direct-output and dead-key contracts are unchanged. Native rebuild and the
existing real US/French Carbon tests remain pending.

Native CI run 37087943283 exposed six Windows contextual fixture failures. The repair preserves absent global state, uses the actual registrar spelling, separates shifted Digit8 refusal from the direct numpad source, counts the contextual group without an Add row, and keeps the declared editor default behind its closed master. The private native probe retains strict warnings in a local scope. The complete selected local gates pass 353 JS checks; native Windows revalidation remains pending.

The physical magic-key chooser and capture now refuse candidates owned by a configured, recognized tap assignment on Windows, macOS and Linux. The candidate stays visible with the existing translated personal-assignment priority reason; Automatic and explicit none assignments remain available. Canonical physical and tap catalogues resolve native identities, including both existing macOS ISO/ANSI aliases. Refusal preserves source intent, tap action/parameters and unrelated configuration bytes. Previously stored conflicting intent cannot override an acknowledged active tap dispatcher; transient Shortcuts OFF and pause gates retain their established runtime behavior. The actual macOS tap owner retires logical delivery before a refused native stop, while retaining cleanup ownership. Portable real-owner regressions and selected checks pass; Windows native tests, native Hammerspoon ordering and three-OS CI qualification remain pending. This does not complete the physical-hardware acceptance requirements.

- [~] **109.** Give every application window the same "ErgoptiPlus — Title"
  format. GUI/WebView titles now use one prefix/separator policy in
  `_shared/ui/apps.manifest.json`, with generated Lua/AHK composers; an empty
  prefix removes branding. All captioned Windows GUI factories, including the
  navigation-layer editor and keyboard-layout manager, and live retitles use
  that owner. Shared app metadata selects brandless translated keys; Linux
  native captions use them across every supported app and all 21 locales.
  Native caption/retitle and private generated-policy regressions cover the
  hosts; the CLI regression failed against the original translated raw-Gui
  bypass before passing with its stronger audit. Complete three-OS
  checkpoint 37046411788 at `ea6b21bed` passed unit/E2E, packaging, installation
  and launch with release skipped. Its private native-policy probes now write the actual Gui caption to
  UTF-8 receipts and use ASCII stdout acknowledgements; runs 37040137327 and
  37040369275 exposed ANSI decoding in the previous test transport. Native exit,
  stderr and the independent expected-caption assertions remain strict.
  Swift updater panels now use a generated composer from that same policy,
  bare captions in all 21 locales and live retitling of the retained progress
  panel. Actual AppKit tests and seven private generated/compiled policy cases
  cover empty, custom, quoted, interpolation-looking and Unicode prefixes;
  native Swift CI remains pending. The private environment receipt now reads
  each variable in its own native `printenv` invocation: Apple BSD `printenv`
  accepts one name, so the previous GNU-style two-name call omitted `PATH`.
  Both exact values, unchanged parent environment, child exit and empty stderr
  remain asserted. The official Apple command reproduces the old mismatch;
  complete macOS XCTest qualification remains pending. Captionless overlays retain their separate
  native presentation owner.
  Ninety-one post-bootstrap Windows message/input calls now compose actual
  native captions through one delegate; bodies, options, defaults and results
  retain their native semantics. Bare startup/uninstall captions have all 21
  translations. The production-wide owner audit has 43 mutation cases and
  exactly seven bounded bootstrap exclusions; focus, no-confirm and fixable
  error audits recognize the delegate with independent regressions. Five
  generated-policy native probes cover real captions/bodies, timeout, password,
  default-button and cancellation receipts. Focused JS checks passed after the
  old audit accepted a caption bypass; actual AHK and full CI remain pending.
  The macOS Package lane now prepares the repository-pinned Node before
  Swift tests and retains their exact PTY transcript. A strict reporter preserves
  both native and capture failures, requires complete non-vacuous XCTest
  receipts, and annotates actual errors with an uploaded failure transcript.
  Private verification passed formatting and all 350 JS checks, including the
  actual reporter and pipeline wiring. Checkpoint 37059479394 exposed the
  exact private Swift probe failure: forced crash backtracing is unsupported
  for executable capabilities classified as privileged by the runtime. Each
  private child now receives the supported enable=no option, preserving its
  inherited environment and parent XCTest setting. An actual printenv child
  asserts this boundary; all seven exact caption/exit/empty-stderr checks stay
  intact. Native macOS qualification remains pending.
  Native checkpoint 37056318950 exposed two premature newline escapes in the
  child AHK probe source. The producer now retains the child escape, preserving
  every actual caption/body/options/timeout/cancellation assertion. Checkpoint
  37060216766 then exposed a fixture local named Edit shadowing AHK's built-in
  class under #Warn All. It now uses InputControlHwnd; warnings and exact
  receipt assertions remain enabled. Production dialog code is unchanged;
  the corrected probe awaits native Windows CI.
  Linux native text prompts now obtain the actual child exit status from the
  existing checked shell owner. Real LuaJIT child regressions distinguish
  exit-one cancellation and exit-seven failure from successful empty/text
  answers; the existing rendered tap-hold callback still asserts zero writes
  on Cancel and exactly one 0.3-second write on confirmation. This prerequisite
  preserves modal keyboard ownership and leaves native caption integration
  pending.
  Linux entry prompts, application/config-folder pickers, gesture-conflict and
  action-confirmation dialogs, error prompts and detached uninstall captions
  now consume that same shared composer. Eleven registered public regressions
  preserve arguments, modal keyboard delegation, cancellation/results and the
  distinction between an omitted error caption and an explicitly empty one.
  Thirty real Zenity cases across five privately generated title policies
  qualify exact mapped PID/X11-window/session captions, results, retirement,
  zero child exit and empty stderr. Native Qt/KDE captions and the complete
  three-OS CI checkpoint remain pending.
  Remaining native caption paths include file pickers, notifications and
  genuine Linux dialog title APIs.
  Non-release checkpoint 36949562328 at `5b4d9e8a3` passes the complete
  Windows/macOS/Linux pipeline, including package and installation lanes. It
  validates the shared "Ergopti+" extension name in the actual tray providers,
  Windows four-finger tap's monitor-local Alt+Tab recommendation and invocation,
  all thirteen pending-dead-state reset cases and the consuming arrow hooks.
  The Windows menu-name fixture owns neutral category collections and restores
  assigned or unassigned globals. The arrow fixture derives scan codes from the
  shared registry, retaining its action, criterion, consumption and order checks.
  The native checkpoint also passes CI's real formatting check. Its temporary
  branch is removed after validation.

Scoped verification now executes the actual Prettier/Ruff `format:check`
before suites, using the formatter owner's extension inventory. A regression
rejects the formerly missing command, and a simulated formatter refusal makes
the CLI fail. Checkpoint 36947209412 exposed three formatting misses that are
corrected. The real formatting check, all 349 JS checks and both XKB Python
suites pass locally; formatter self-tests alone cannot validate source files.

The shared Shortcuts declaration separates modifier-shortcut groups from key
combinations. Linux currently omits the combinations group, so the same boundary
separates its modifier shortcuts from script controls. Existing renderer tests
exercise all manifest menus with empty-edge and doubled-separator provider probes
on the three drivers; the renderer retains one separator between visible rows.

The Windows Layout menu now has one disabled "Emulated layout: none/name" status
before "Manage layouts…". A disabled category cannot claim a stored choice is
active; Ergopti, Ergopti+, registry names and an absent catalogue entry stay
distinct. Selection is owned by the shared manager, and the obsolete second
built-in selector is removed. macOS and Linux's existing picker selects native
OS input sources, so it retains that platform implementation. Both status forms
are translated into all 21 locales. Eight registered native cases cover status
data and the actual Win32 disabled row, with management remaining usable;
the original Windows row was clickable and did not name its current emulation.
Non-release run 36937408564 at `56efa2bd8` passed these cases and the full
Windows/macOS/Linux test, package and installation lanes.

The supplied diagnostic also proves released-SC138 dispatch on Kana. Its hotkey
criterion accepted the Kana family without querying the physical key; the later
callback rejected the output after the suffix had been captured. Eligibility now
requires physical SC138 on Kana, preserving the unconditional first-press anchor,
and still requires physical RAlt on other families. Seven new registered cases
exercise the pressed/released queries of all three families and the actual native
query on a released host key. Existing hold-owner cases explicitly model a held
key and retain their non-AltGr rejection assertions. This AHK prefix-latch repair
does not establish the cause of item 99's exact layout-switch report; Linux and
macOS do not use AutoHotkey's custom-combination latch. Non-release run
36938644227 passed the seven new cases, but caught two older fixtures that
assumed Kana alone meant a held key, and one additional direct platform call.
The gate now uses the existing KeyState port, with an injectable query shared
by captured criteria. The old fixtures explicitly model held/released presses,
retain their slot/emulation assertions and restore the query after each case.
The script plan now also rejects assigned chords on a modeled released key;
the actual emulation criterion rejects the released magic-key suffix.
Non-release run 36940286440 at `64edbf898` passed the complete shared,
Windows/macOS/Linux unit and E2E suites, packaging and installation lanes,
including this correction and the maintainer's four new commits. No release
was published.

The registry emulation's dead-key resets now use the scan-code identities of
all 13 cancel/navigation keys. The shared physical-key registry independently
pins the captured names; thirteen native cases drive the actual registered
criteria and callbacks on Ergo-L, Ergopti and Ergopti+, covering pending/idle,
disabled layout and active navigation ownership. The precedence guard on Linux
and Windows now resolves the bounded literal-array/prefix-loop form, with a
fixture that rejects the pre-fix names and leaves unknown expressions unjudged.
Before the production change, the Linux guard failed on five shadowed reset
names (Backspace, Escape, Enter, Tab and Delete). macOS/Linux use installed OS
layouts for dead-key handling and have no corresponding AHK registration.
The four prediction-navigation arrow hotkeys now share those scan-code
identities too; their existing ownership, hook-order and step assertions remain
intact. Non-release runs 36941345120 and 36944695471 caught incorrect new
fixture seeds for Ergopti+: plain SC01B types j, Shift+SC01B types underscore,
and Shift+AltGr+SC01B starts diaeresis. The five seeds now live in the shared
keystroke corpus, replayed by the Windows reset cases and independently checked
against the Linux conversion's actual dead-state triggers, including custom
Ergo-L triggers. The portable regression rejected the old underscore seed;
all five conversion/keystroke tests pass after correction. Thirteen native
cases refused the wrong seed. Checkpoint 36947209412 passes all thirteen
corrected cases and identifies the remaining old failure: the tooltip hotkey
fixture still expected name-based arrow declarations. It now derives physical
identities independently from the shared registry while retaining every
consuming-hook, action, criterion and ordering assertion. Its native rerun passes checkpoint 36949562328;
the production identity repair remains unchanged.

Windows and macOS now render each key-combination pair from the shared
`key_combination_pair_menu` declaration. Native providers supply their supported
slots; Clear is disabled for an unassigned pair on both drivers. A macOS
regression first rejected the old native assembly when the real declaration's
order changed, then passed after migration. All five focused menu tests, 12,801
Lua tests, selected E2E scenarios and 349 JS checks pass; the menu parity ratchet
now requires 17 shared-rendered macOS menus. Two Windows cases inspect the actual
menu's disabled flag in native CI. Item 91's remaining engine issues stay open.

Native AppleScript dialogs and numeric tap/hold prompts now compose their
captions through the shared owner before escaping; five existing bare keys
retain all 21 translations and their bodies/buttons/defaults/focus semantics.
Independent regressions reject both original Mac bypasses. The seven
pre-bootstrap Windows modals now use the same hoisted native-dialog delegate;
no entry include order changes or duplicated product prefixes are needed.
The title audit has zero bootstrap exclusions and rejects all seven original
consumers; 46 independent mutation cases pass. Native probes invoke the
actual delegates before their includes and preserve caption/body/options/
cancellation checks. Actual Windows and AppleScript GUI qualification remains
pending.

Native dialog tests snapshot caption, body, buttons and password properties
before file I/O can pump messages and retire a timed dialog. Delayed
persistence must observe actual retirement while retaining every original
caption, body and result assertion. The independent expiry mutation must
fail; native Windows qualification remains pending.

Checkpoint 37085309234 showed that the capture callback prevented its
interrupted modal loop from acknowledging window retirement. The fixture
now returns that callback, waits for the actual Timeout result, then persists
its complete snapshot. The retired-window receipt and exact expired-read
rejection remain strict. Native Windows requalification is pending.
Native Windows file-picker captions now pass through the same shared title
composer; option flags, root/default paths, filters and native return shapes
are preserved. Independent audit mutations and actual five-policy dialog
probes retain strict result and exact process-retirement assertions. Native
FileSelect and folder-picker qualification remain pending Windows CI.
Folder chrome now uses one scoped SHBrowseForFolderW caption owner; the
native explanatory prompt, option flags, initial/root selection and empty
String cancellation remain independent of the shared title policy. Exact
callback cookies, HWND leases and PIDL/COM retirement receipts preserve
partial-acquisition and refusal ownership. Five actual generated-policy
folder probes and independent native-port refusal cases retain their strict
assertions; portable checks do not qualify this new native ABI at runtime.

Native checkpoint 37090610890 isolated a folder-picker parse warning: its
local Thread identity shadowed the built-in Thread function. The scoped
identity locals now use explicit owner names without changing callback state,
window leases or retirement. A separate actual-child parse regression keeps
strict warnings, exact ASCII acknowledgement, zero exit, empty stderr and
owned process-tree retirement. Portable verification cannot execute AHK;
native Windows qualification remains pending.

The folder-picker native ABI now belongs to its adapter. Its 17 direct
system-call lines leave domain orchestration, restoring the unchanged core
OS-purity count from 269 to 252. Both production and headless include graphs
reach the same owner; the native class body, callbacks, window leases and
PIDL/COM retirement semantics are preserved. Independent scanners reproduce
the original excess and six provenance mutations reject ownership bypasses.
The architecture inventory was regenerated through its owner. Selected
portable checks pass; actual AHK and full three-OS qualification remain
pending.

The Linux caption-inventory regression now enumerates source through the
existing checked-shell owner instead of requiring LuaFileSystem. The
LuaJIT-only CI profile reproduced the original exception; all 4,809 Linux
cases pass with and without native Lua extensions. The same seven owners and
exact counts remain mandatory. Foreign consumers and failed, empty or
incomplete discovery are still rejected. Production captions and the real
30-case Zenity proof are unchanged; fresh CI qualification remains pending.

The native Windows file-picker case now retains a bounded receipt of control
classes and numeric IDs from its fixture-owned dialog. The original display-label
and exact filter-pattern predicate remains unchanged; failure includes up to
24 control records with explicit truncation, without control text or user paths.
Completed native logs prove the owner parse smoke and native-folder port/lease
cases pass, but the earlier filter failure prevents the real folder UI cases.
The next Windows checkpoint must establish the actual control structure before
repairing its observation; neither the filter cause nor folder UI is qualified.

Windows native message/input dialogs, file pickers and folder pickers now have
independently registered policy cases. A file-filter assertion can no longer
prevent real folder UI measurement. Each family retains all five original
policy variants, exact assertions and native process arguments; the generated
fixtures and child-retirement owner are unchanged. Seven independent coupling
mutations fail the isolation guard. Local 353 JavaScript and encoding checks
pass; actual file-filter semantics and real folder UI still await native CI.

The Windows file-selection policy test captures bounded labels and selected type only from the unique owned file-type ComboBox descendant1136. Filename-history controls are excluded. Generated diagnostic statements preserve physical LF separators while escaped CR/LF remain inside child string literals; independent source mutations and the actual AHK source producer regression cover this distinction. The original exact filter predicate remains unchanged pending measured native rendering/filter semantics. Native SHBrowse selection/cancellation, all five shared title policies, option-dependent controls, leases and actual HWND retirement now pass in Windows run37097121618 and37097438949 after the separate file case fails. Local diagnostic selected verification passes353 JavaScript checks plus formatting/encoding; this new diagnostic and generated-source unit still require Windows execution.

The original file-picker assertion remains intact while a separately registered
native family qualifies genuine filtering for all five caption policies. An
owned UI Automation client observes controlled TXT visible/BIN absent, changes
the native file type to All Files to observe BIN, and restores the restricted
filter before selection and cancellation. Exact PID/HWND/control fences, native
exit/stdout/stderr and retirement receipts stay strict, as does the existing
15-second process-tree limit. Removing both actual filter arguments must fail
with the independently fixed controlled-BIN-visible reason. Local source guards
reject eight mutations; selected JavaScript, formatting and encoding gates pass.
Actual UIA behavior and the native negative control still require Windows CI.

Windows IFileDialog displays the supplied friendly name separately from its wildcard pattern. The title regression now requires the complete independently observed friendly-name list and exact selected native file-type receipt. Checkpoint 37104220317 executed the stronger registered five-policy acceptance/cancellation family and its genuine no-filter mutation successfully: real TXT visibility, BIN exclusion, All Files selection and restored filtering remain mandatory. A later checkpoint 37104842079 exceeded the existing owned UIA-client bound; the next receipt adds only nine fixed progress tokens and elapsed milliseconds to that same refusal. All process/window ownership, actual output/status, physical retirement and 500/4,000/5,000/15,000 ms bounds remain unchanged. The corrected composed assertions and diagnostics pass 353 JS checks, 1,802 AHK BOM/LF files and independent rejection mutations. Native candidate stability and complete three-OS qualification remain pending.

Partial: the macOS application-action picker now forwards the existing translated parameter caption through the shared title composer to an actual AppKit NSOpenPanel using the existing in-process AppleScript port. Application-only filtering, /Applications, single selection, alias resolution, focus and cancellation are preserved. Focused actual Lua callers cover all 21 locales and retain no-write cancellation; a native Swift construction test executes the real panel template. Hosted AppKit and Hammerspoon modal qualification remain required; this prerequisite does not complete all native panel coverage.

Windows Variables and Key History remain a native-caption limitation: both use A_ScriptHwnd, whose exact default title is part of AutoHotkey's existing #SingleInstance and Reload identity. The proposed direct console retitle was withdrawn before delivery because it could break that lifecycle ownership. A separately owned visible debug window or a demonstrated identity-preserving owner is required, together with real Windows duplicate-start/Reload/retirement regressions. Existing shared GUI/WebView composers remain implemented; item109 stays partial while this console boundary and complete native panel qualification remain open.

The native application-panel caption regression now retains a bounded, verified copy of its exact retired child stderr in the existing Swift failure evidence channel, with closed count/status facts and no raw diagnostic payload in job logs. The original stderr.isEmpty, caption/selection policy, deadlines and exact fixture-child retirement assertions remain unchanged. Three additional native file-evidence controls cover exact bytes, bounds/unknown images/local absence, and source/owner symlinks; their actual macOS execution is pending. The current native failure cause remains unobserved until the next evidence artifact is collected. TODO109 remains partial; this diagnostic does not relax or complete the application picker qualification.

The native application-panel test now exposes only its retired child's bounded escaped stderr in readable job logs, while retaining the existing strict empty-stderr assertion and exact artifact copy. Exact owned paths, panel title/message and URLs are removed; 2 KiB of sanitized UTF-8 is captured on one physical line. Three actual Swift XCTest controls cover redaction, boundaries/escaping and refusal of unknown input ownership. Native Swift execution and the underlying 79-byte AppKit stderr cause remain unverified; TODO109 stays partial.

The native application-panel XCTest child now uses the same owned Swift backtrace environment as archive and title-policy probes, through one test-target owner. Actual run 37173332907 proved that all three prior children exited successfully but emitted the same unsupported privileged-backtrace warning. Strict empty-stderr, caption/filter checks, deadlines, child retirement and owned diagnostic capture remain intact. Actual macOS Package qualification is pending; TODO 109 remains partial, including the unsafe native Windows console caption and unqualified remaining native dialog-title boundaries.

Partial: the existing macOS native install diagnostic now owns a bounded sampler during the exact no-prompt AppleEvent send. Sampling is associated only while the checked sender stage remains send_entered; late, foreign, or unretired observations cannot claim that interval. The native 8-second send, 10-second sender deadline, original caption/installation assertions, and cleanup authority remain unchanged. Portable process/phase tests do not qualify actual macOS transport: clean and Karabiner installation still require native CI evidence.

TODO 109 remains partial. The managed macOS bootstrap now records the public hs.allowAppleScript() getter, a validated in-process PID and the callable Lua bridge through the existing synchronous boot journal before onboarding can defer boot. Getter observation uses no setter argument and preserves bridge identity; malformed, thrown or missing getters remain unknown. Exact Boolean publication ACK is required, and refusal cannot gain boot authority. Portable registered journal/lifecycle tests pass 16/0 and 9/0; original-source and five behavioral mutations fail. Actual managed macOS observations are pending CI. Callable Lua bridge state does not prove native AppleEvent handler registration or entry, and the existing strict send/timeout/cleanup assertions remain unchanged. The previously observed clean/Karabiner no-prompt -1712 boundary is still unresolved.

- [ ] **111.** Provide two distinct, explicitly labelled shared window-switching
      actions on Windows, macOS and Linux: the operating system's normal Alt+Tab switcher
      (the native equivalent on macOS), and switching only among windows on the display
      containing the **current mouse cursor**. Resolve that display at invocation; never
      substitute the active window's display or silently fall back to the global
      switcher. Reuse existing action identities where their contracts match, preserving
      saved bindings and current native window/lifecycle policies. Native adapters own
      window eligibility, monitor geometry and activation; define the existing placement
      rule for windows spanning displays. Offer a translated unavailability reason where
      the desktop/compositor cannot provide the scoped operation. Do not add a
      monitor-selection setting. Test cursor and active window on different displays,
      moved cursors, spanning/minimized/closed windows, activation refusal and
      unsupported display access through the real action providers, then qualify actual
      two-display behavior on each supported OS.

Windows already has `app_switcher` (native Alt+Tab) and `alt_tab_monitor`
(current pointer display, candidate-window centre filtering); verify that the
picker exposes both intended contracts clearly. macOS has cursor-display
window cycling, while the native system switcher is currently unavailable.
Linux currently emits global Alt+Tab for `alt_tab_monitor`: this alias does not
fulfil the scoped contract and must be implemented or explicitly unavailable.
Existing distinct action labels already have all 21 translations.

## Time estimate

Order-of-magnitude estimate: 40–70 agent-days for the current remaining
product and verification scope. Item 31 alone records 30–40 agent-days plus
real-Mac acceptance. Parallel work can reduce elapsed implementation time;
shared integration, native CI and genuine hardware acceptance still constrain
completion. This is a budget range, not a fixed delivery date.

## Current local evidence

Portable specifications, pending changes, branch accounting and verification
results are in [the handoff package](handovers/2026-09-28-ergoptiplus/README.md).
Read its `VERIFICATION.md` and `VERIFICATION.json` for composite gate results.
Paths under `D:/ewt/` in those files are historical; that directory no longer
exists.

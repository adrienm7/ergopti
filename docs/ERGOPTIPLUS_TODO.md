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
- [~] **L87.** Linux event loop startup ownership: admit idle and periodic
  handles only after their native start receipts succeed; unwind partial
  construction on an exception or nil/false receipt, clear the running state
  and raise the original refusal so the next run can retry. The rollback
  retires only loop-owned handles, preserving an independently active timer.
  Seven native component cases fail before and pass after: constructor/start
  exceptions and allocation refusals are explicitly simulated; invalidating a
  real timer produces the genuine EINVAL receipt. Acquired handles, foreign
  ownership and healthy recovery runs use installed libuv. The registered
  regression preserves existing clock and stop-boundary assertions. Windows
  and macOS use their host message loops and native timer backends by source;
  there is no equivalent Lua-owned loop startup transaction. Their runtime
  suites and hosted CI remain deferred; physical input is untested here.
- [~] **L88.** Linux SQLite device registration: refresh only mutable host
  fields with a transactional UPSERT, preserving creation/import metadata,
  unknown schema columns and existing UPDATE triggers. REPLACE previously
  deleted that durable history and bypassed update refusals. Registration now
  returns the checked native write receipt and logs success only when accepted.
  Eleven real collector/SQLite cases have ten failures before and none after;
  the intermediate UPSERT alone still fails the AFTER UPDATE rollback case.
  BEGIN IMMEDIATE/COMMIT therefore keeps row and trigger writes atomic when
  an AFTER trigger raises FAIL or an independent native reader refuses COMMIT.
  Healthy retries, first insert, reopen, row bytes, schema/index/trigger and
  actual CLI receipts pass. Three registered native unit regressions preserve
  all allocator/cursor and schema assertions. The fixture reuses L75's genuine
  shared-reader child. macOS still uses REPLACE by source and can reset import
  and extension fields; its persisted device creation timestamp differs. That
  bounded native follow-up remains with the principal owner. Windows has no
  equivalent devices-table registration by source. No metrics enable/fallback,
  reserved input/configuration policy, foreign runtime suite or hosted CI changed.
- [~] **L89.** Linux asynchronous shell admission: capture each allocation
  before another constructor can fail; protect and require native timer and
  stdout/stderr activation receipts, retaining NativeTimer and zero-valued
  success. Refused startup returns nil/error synchronously with no completion
  callback, preserving callers' single-report contract. Partial native handles
  are retired and any spawned group follows the existing termination/late-exit
  cleanup path. Five of eight native component checks fail before and all pass
  after: constructor refusals and handle invalidation are explicitly simulated;
  actual EINVAL, real handles, stdout/stderr, child groups, deadline/cancellation
  and reaping are observed. Nineteen registered units cover each nil/false/raised
  allocation/start receipt and invoke the native fixture. Healthy termination
  is proved for those children; kill-refusal settlement/debt is not qualified
  or redesigned here. macOS checks hs.task construction/start and retains a
  task on terminate refusal by source; Windows uses native startup/termination
  accounting by source. Foreign runtime suites, hosted CI and physical input
  remain deferred. No caller, shared API or reserved surface changed.
- [~] **L90.** Linux owned HTTP replacement admission: validate and compose
  metadata before cancelling an active regular predecessor, then reuse that
  exact configuration. An invalid owned replacement previously cancelled a
  still-usable request before rejecting its NUL/type/raising metadata. Seven
  of twenty-four actual loopback/curl/libuv cases fail before and all pass
  after. Existing regular preflight, literal ETag/download files, exactly one
  wire request, valid replacement, single construction and native settlement
  controls remain. An already-owned slot still refuses before evaluating
  hostile metadata; first owned construction retains its existing late
  allocation and physical close-acknowledgment contract. Ten unit cases
  preserve delayed ACK, predecessor delivery and every incoming owned test.
  This follows the existing native owner protocol rather than adding an
  operation API. Windows uses native generation/staging ownership and macOS
  hs.http/hs.task by source; equivalent replacement behavior remains unqualified
  without their runtime suites. No foreign source, reserved surface or hosted
  CI changed; sockets/processes/files are real, not physical keyboard tests.
- [~] **L91.** Linux native POST redirect semantics: let the data option select
  POST instead of forcing a method word that survives curl's retrieval rewrite.
  Optional followed 301/302/303 requests now become GET without the original
  body; 307/308 retain POST and exact bytes. Six of thirty-three actual
  loopback/curl/libuv cases fail before and all pass after, including direct
  nil/empty/literal bodies, explicit no-follow, synthetic credential fences,
  ordinary/owned GET and downloads. Seventeen registered units preserve flag
  and callback contracts. No active LLM caller is claimed to follow redirects;
  this fixes the supported optional adapter path. Windows async curl does not
  enable native following; its synchronous WinHttp and macOS hs.http delegate
  redirects to their platforms by source. Foreign runtime suites remain
  deferred. Native regression is registered for Linux CI without launching
  hosted CI; no TLS, credential, owner, shared API or reserved policy changed.
- [~] **L92.** Linux literal POST body transport: send text through a genuine
  inherited anonymous pipe instead of curl's size-limited configuration line.
  Buffered and streaming POST preserve exact large JSON, quotes, leading at
  signs and escaped JSON NUL. Literal NUL previously reached a truncating
  parser; it now refuses before replacing an owner. Twelve of twenty actual
  loopback/curl/libuv controls fail before and all pass after, covering 7/10/12
  MiB bodies, complete/incomplete refusals, backpressured cancellation and
  deadlines. Capture stable native handles and original raw descriptor identity
  before transfer; exceptional close debt fences successors and withholds the
  result until physical settlement. Fourteen explicitly simulated refusal
  cases on real pipes/children/descriptor reuse fail before hardening and pass
  after. Twenty-nine registered units cover delivery and cleanup boundaries.
  Actual current Ubuntu 22.04 curl/libcurl and luv/libuv packages also pass
  both fixtures using native pipe2 where luv.pipe is unavailable; remaining
  runtime/kernel are this container's, not a full Ubuntu session. Request body
  bytes stay off argv and owned transport files. Windows uses its own staged
  body and macOS hs.http by source; foreign runtime suites remain deferred.
  No public/shared API, credential/TLS, reserved surface or hosted CI changed.
- [~] **L93.** Linux digest partial allocation: capture each native pipe and
  timer immediately inside the existing protected constructor block. A later
  raised constructor previously lost earlier handles while reporting refusal.
  Two of four actual-handle controls fail before and all pass after; constructor
  refusal seams are simulated, while pipes, foreign timer ownership, real abc
  hashing, child reaping and zero retained handles are observed natively. Seven
  registered regressions preserve nil/raised admission, exactly one error
  callback, no spawn and inert cancellation. Existing path preflight, owner
  isolation, hash/argv limits, NativeTimer and cleanup policies stay intact.
  No memory-pressure failure or native kill/close-refusal debt is claimed.
  macOS uses hs.hash and Windows Get-FileHash by source, without this libuv
  allocation frame; foreign runtime suites remain deferred. No caller, shared
  API, reserved surface or hosted CI changed.
- [~] **L94.** Linux file write/append endpoint admission: pin a writable
  nonblocking descriptor without truncation, require native regular-file
  metadata, then reopen that exact inode for buffered overwrite or append.
  FIFOs with or without readers, directories and sockets refuse without
  blocking or emitting bytes. Regular symlinks, creation/umask and exact NUL/
  UTF-8/CRLF bytes remain supported. Actual RLIMIT_FSIZE failures exercise
  partial write and buffered close receipts; simulated path-edit timing and
  metadata refusal are explicitly labeled over real native resources.
  Twenty-four checks have ten original failures per FFI/luv backend and pass
  after; Lua 5.4's actual luv backend also passes all twenty-four. Each case
  checks descriptor retirement. Thirty-four simulated units and one native
  matrix registration preserve existing write/close assertions. macOS's current
  atomic overwrite already rejects nonregular destinations by source, while
  its direct append still needs equivalent native admission; that reserved
  native work and Windows runtime checks remain with the principal agent.
  Windows FileOpen is not this Linux POSIX FIFO implementation. No claim of
  atomic publication or recovery from ambiguous raw-close errors is added.
  Register all three native backend runs without launching hosted CI.

- [~] **L95.** Linux ProcessRunner partial allocation: capture stdout, stderr
  and timer immediately inside the existing protected constructor block.
  A later raised constructor previously hid one or two earlier native handles
  from terminal cleanup. Two of four actual-handle controls fail before and all
  pass after; nil/raised constructor receipts are explicitly simulated while
  preceding libuv handles, foreign timer isolation, later real child output,
  reaping and zero final handles are native. Seven registered regressions retain
  all previous assertions, exactly one allocation-error callback and no spawn
  or extra constructors after refusal. No OS memory-pressure, descriptor
  exhaustion or new kill/close-refusal debt behavior is claimed. macOS's
  hs.task and Windows's shell/native collaborators have no equivalent Linux
  three-constructor frame by source; foreign runtime gates remain deferred.
  The native fixture uses genuine handle ownership without recent-only libuv
  introspection so current and verified Ubuntu 22.04 bindings are exercised;
  stock Lua 5.4's actual native backend also passes. No caller, shared API,
  reserved feature or hosted CI changed.

- [~] **L96.** Linux queued WebView messages after retirement: reject every
  captured native epoch that differs from the current page epoch, including
  when public hide has removed the page. An actual WebKit document posts two
  messages; an explicitly injected public-hide timing seam in the first
  handler retires the real window before the second native signal arrives.
  Original behavior executes an extra handler; four virtual-GUI receipts go
  from three passing to all four passing, including a live control, healthy
  sibling and explicitly reopened responding document. Five registered unit
  regressions go from three passing to all five passing, preserving current
  epochs and legacy epochless calls. GTK/WebKit execute under owned Xvfb,
  Openbox and D-Bus with private profiles; this is no physical desktop claim.
  Windows deferred dispatch already rejects reset/retired epochs; macOS
  metrics delivery checks generations and exact owned WebViews by source.
  Foreign runtime gates remain deferred. No titles, metrics policy, menus,
  input, shared API or hosted CI changed.

- [~] **L97.** Linux updater conditional cache completion: require the HTTP
  adapter's existing completed-response receipt before reusing a cached page
  for status 304. A native TLS server sends a new ETag in an interrupted 304
  header, then performs a real TCP reset. Curl exits 56 while retaining status
  304 and saving the new ETag; the original updater incorrectly reuses its old
  release page. Refuse that incomplete response through the existing error
  path, invalidating the page/validator association. Preserve the physical ETag
  sidecar, omit conditional headers until a fresh complete 200, then resume
  ordinary complete-304 reuse. Five actual TLS controls have two original
  failures and pass after with current and verified Ubuntu 22.04 curl/libuv;
  exact wire headers, one callback and native handle settlement are checked.
  Four registered simulated completion-shape regressions preserve all existing
  assertions and completed-304 fixtures now carry the actual empty-string
  receipt. Register the native fixture for future Linux CI without launching
  hosted workflows. Windows WinHttp rejects failed Send/Wait before cache
  interpretation and its curl adapter publishes status only after successful
  exit; macOS maps negative native network failure to status zero by source.
  Foreign runtime gates remain deferred. No shared contract, release/install
  behavior, reserved surface or native transport policy changed.

- [~] **L98.** Linux native HTTP empty-field serialization: curl interprets
  `Name:` as removal, silently omitting a caller's valid present-empty field.
  Serialize empty or SP/HTAB-only values using curl's semicolon syntax after the
  unchanged shared header validation. Preserve ordinary values, absent fields,
  native default overrides and sensitive-header redirect policy across GET,
  owned GET, POST and streaming POST. Fifty-six real native controls retain the original forty-four and add
  twelve whitespace cases, passing after with current and verified Ubuntu
  22.04 curl/libuv, plus stock Lua 5.4's actual native backend. Thirty-two wire
  requests check field presence/defaults and redirect receipts; twenty-four
  actual metadata refusals retain callback policy and never spawn curl. Sixteen
  registered unit regressions preserve every previous HTTP assertion; exact
  nonempty configuration bytes and narrow whitespace handling are checked. Register
  both native interpreter runs for future Linux CI without launching workflows.
  Windows's curl serializer has the same colon-only empty-value bug by source;
  a matching native serialization proposal is documented without editing the
  principal agent's driver. WinHttp and macOS consume native header maps;
  foreign runtime qualification remains deferred. No common header policy,
  duplicate-field rule, reserved surface or shared port changed.

- [~] **L99.** Linux historical metrics calendar boundary: derive yesterday
  from the already captured local date using native calendar normalization at
  noon, instead of subtracting 86,400 elapsed seconds. A late 25-hour day had
  duplicated today's rows into history; midnight after a 23-hour day had omitted
  the preceding day's rows. Eight actual SQLite/public collector controls have
  two original failures and pass after, conserving selected row bytes and
  revision. The deterministic fixture explicitly supplies wall-clock input
  while libc DST/date normalization, native CLI processes, database writes and
  public range readers remain real. A separate actual-clock reproduction is
  preserved. Six registered units cover ordinary/midnight/leap/month/year dates
  and a clock crossing midnight after capturing today, with one original
  failure; their CLI and clock inputs are explicitly simulated. Register the
  native matrix for future Linux CI without launching hosted workflows.
  macOS already derives the previous calendar day at noon; Windows uses native
  DateAdd by source. No suitable shared exported calendar owner exists, so the
  bounded Linux native calendar adapter follows that existing policy without
  adding a framework. Foreign runtime gates remain deferred. Range selection,
  date validation, persistence and reserved surfaces are unchanged.

- [~] **L100.** Linux localectl variant alignment: preserve an empty first
  variant slot instead of borrowing the second layout's variant. Real native
  compilation, checked files and libxkbcommon capture/inverse resolution expose
  three failures in eight controls before the fix and pass all eight after.
  Three registered units cover empty, explicit and absent first variants plus
  existing sibling parsers; one fails before and all pass after. Localectl's
  text is supplied by fixtures; neither systemd nor a physical keyboard is
  claimed. Register the native matrix for future Linux CI without launching
  hosted workflows. Windows uses native keyboard-layout handles and macOS TIS
  identifiers, so neither parses Linux variant lists; foreign runtime gates
  remain deferred. Multi-group recovery and reserved input paths are unchanged.

- [~] **L101.** Shared release asset JSON boundaries: use the existing pure
  JSON decoder at the common asset selector instead of scanning balanced text.
  Valid labels containing closing braces or brackets had hidden canonical
  assets; nested uploader fields could supply a different identity or URL, and
  escaped URLs retained raw JSON escapes. Preserve exact first matching asset
  names and the existing string URL/empty refusal contract. Twenty new common
  corpus vectors and a registered direct-type case retain every original
  assertion: fifty-two focused checks have twelve failures before and pass
  after. Eight real verified-TLS/public updater cases have six failures before
  and pass after on current curl/LuaJIT, the signed Ubuntu 22.04 dependency mix,
  and actual stock Lua 5.4. Each checks complete response bytes, one callback,
  exact canonical URLs and native handle settlement; no archive is requested
  or installed. Register both interpreters for future Linux CI without
  launching workflows. Windows and macOS actual asset owners already inspect
  decoded object fields by source; foreign runtime gates remain deferred.
  Other parser helpers, URL admission, update policy and reserved surfaces
  are unchanged; no duplicate Linux selector is introduced.

- [~] **L102.** Shared release-notes JSON decoding: read the selected release
  object's string body with the existing common decoder. Sequential manual
  substitutions had corrupted literal backslash examples, left tab/Unicode
  escapes encoded and captured extra metadata after empty/trailing-backslash
  notes. Nested body/null fields could hide the real description. Decode once,
  preserve the established Lua carriage-return removal and single return
  value, and retain every prior assertion. Ten universal common vectors and
  an explicit shared Lua contract cover twenty-one new registered checks;
  all seventy-three focused checks pass after sixteen original failures.
  Twelve real verified-TLS/public updater cases have eight original failures
  and pass after on current curl/LuaJIT, signed Ubuntu 22.04 dependencies and
  actual stock Lua 5.4. Preserve exact independently authored text, canonical
  assets, complete responses, callback count and native handle settlement;
  no archive is fetched or installed. Register both native interpreters for
  future Linux CI without launching workflows. Windows already decodes the
  universal escapes by source but retains distinct legacy wrapper, textual
  field and CR behavior; those differences remain documented, unmodified and
  unexecuted. macOS displays notes through the shared JSON.parse frontend.
  This fix depends on L101's shared decoder import. Other parser helpers,
  Markdown policy, native transports and reserved surfaces are unchanged.

- [~] **L103.** Linux event-loop reentry ownership: retain a separate active-run
  guard until the owning call requests cleanup. Calling stop then run inside
  idle, periodic or deferred callbacks had overwritten the outer idle handle
  and leaked it. Preserve stop semantics and reject reentry during that window;
  normal or raised cleanup still permits later healthy runs. Nine real libuv
  controls have four original failures and pass after on current LuaJIT,
  actual stock Lua 5.4 and the signed Ubuntu 22.04 dependency mix. Exact native
  handle inspection preserves a healthy foreign timer and proves final zero
  owned handles; throwing callbacks and sequential restarts are exercised.
  One start-refusal receipt is explicitly simulated after real activation.
  Eight registered regressions retain every existing assertion and include the
  native child fixture. Register both native interpreters for future Linux CI
  without launching workflows. Windows SetTimer and macOS Hammerspoon timers
  have no equivalent synchronous run/stop owner by source; foreign runtime
  gates remain deferred. The separately diagnosed no-luv periodic clock issue
  stays unmodified pending coordination; reserved surfaces are unchanged.

- [~] **L104.** Shared selected-release tag decoding: read the release object's
  own tag through the existing JSON decoder. Valid escaped tags were ignored,
  while a preceding nested author tag could offer the wrong version. Preserve
  the documented first-entry array wrapper, raw decoded string identity and
  existing version/channel admission; do not fall through an unusable first
  wrapper entry. Ten real verified TLS/public Linux updater controls have six
  original failures and pass after on current LuaJIT, stock Lua 5.4 and the
  signed Ubuntu 22.04 dependency mix. Full-list selection and stable/beta
  controls remain intact; the server sees only release-list requests, with no
  artifact fetch, installation or publication. Twenty shared Lua vectors and
  one typed/single-return case retain all earlier corpus assertions: 94 focused
  checks have 14 original failures and pass after. Register both native
  interpreters for future Linux CI without launching it. macOS production
  checks consume the corrected shared helper; Windows' analogous raw regex
  flaw is documented with a source-only proposal, without editing its reserved
  native work. Foreign runtime gates remain deferred. Depends on L101/L102.

- [~] **L105.** Linux finite timer admission: use a tiny pure shared finite-number
  predicate before native allocation. NaN or infinite seconds, and finite
  seconds whose millisecond conversion overflows, had armed invalid timers;
  NaN/infinite deferred work could remain permanently queued. Preserve ordinary
  finite negative clamps, zero/fractional delivery and large finite delays;
  introduce no native range ceiling. Twenty-four genuine libuv controls have
  twelve original failures on current LuaJIT and signed Ubuntu 22.04 dependencies,
  eight on stock Lua 5.4, then all pass. Stock54's four existing native conversion
  refusals remain healthy controls. Callback delivery, cancellation, following
  healthy work, deferred payload GC and exact final resources are exercised;
  no backend is replaced in that fixture. Twenty-three registered checks have
  twenty-one original failures and pass after; their adapter seams are explicitly
  simulated and the native child is included. Preserve every existing assertion
  and replay all nine native reentry controls across the three runtimes. Register
  both native interpreters for future Linux CI without running workflows. Windows
  already bounds native milliseconds by source; macOS protected construction
  remains unexecuted and has a proposal reusing the common predicate. Foreign
  gates stay deferred. The separate native huge-range and no-luv clock diagnoses
  remain unmodified; physical input and reserved surfaces are unchanged.

- [~] **L106.** Linux UTF-8 inverse-plan admission: validate the complete input
  with the existing strict shared UTF-8 owner before checking layout availability
  or walking characters. Malformed bytes could be skipped and return a partial
  successful plan; rejected malformed sequences also reported invalid blockers.
  Refuse every malformed input with nil/nil in both genuinely absent and loaded
  map states. Preserve valid unsupported characters, empty/nonstring receipts
  and the established first-byte blocker when a valid input has no loaded map.
  Genuine native French compilation, owned file loading and libxkbcommon replay
  pass all sixteen loaded-map controls after nine original failures; the public
  absent/loaded availability fixture passes thirty-eight checks after eighteen
  original failures. These cover the same nine malformed categories in both
  states, not eighteen separate defects. Five registered cases have two original
  failures and pass under LuaJIT and Lua 5.4, retaining every earlier assertion.
  Registered table injection is simulated; actual native compilation and library
  events require LuaJIT FFI and are not physical keyboard injection. Register the
  two native fixtures for future Linux CI without launching it. No graphical
  session or physical device is used. Shared scalar-validation policy is unchanged;
  foreign adapters do not share this missing-table/plan API by source, and their
  runtime gates remain deferred. Physical selection and reserved surfaces stay
  unmodified.

- [~] **L107.** Shared release publication-time decoding: read the selected
  object's own string through the existing JSON decoder. Equivalent escaped
  timestamps could falsely announce an older dev release, hide a newer release
  or leave encoded bytes in offered/cache metadata; nested timestamps could
  replace the release's own date. Preserve existing date/version/channel rules,
  exact decoded identity and the selected-object contract; do not normalize dates
  or add wrapper selection. Twelve real verified TLS/public Linux updater checks
  have six original failures and pass after on current LuaJIT, stock Lua 5.4 and
  signed Ubuntu 22.04 dependencies. Retain ordinary older/equal/newer notices,
  same-channel up-to-date, typed refusal, exact complete response/callback/native
  settlement and cache controls; no artifact is fetched or installed. Twenty
  shared Lua vectors plus one typed/single-return case retain all earlier
  assertions: 115 focused checks have eleven original failures and pass after.
  All six other parser helpers remain byte-identical. Register both native
  interpreters for future Linux CI without launching it. macOS production checks
  use the corrected shared classification helper; Windows has the same raw-regex
  issue by source, with a bounded proposal but no foreign implementation change.
  Foreign runtime gates remain deferred. Depends on L104's shared tag decoding;
  no timestamp policy, transport, frontend or reserved surface is changed.

- [~] **L108.** Shared release prerelease metadata: decode the selected object's
  own Boolean through the existing JSON owner. Escaped keys previously lost true;
  nested true fields could override an own false or populate absent/null/string
  metadata. Return true exclusively for an own Boolean true, preserving existing
  false refusals and tag-registry channel/badge policies. Eight real verified
  TLS/public Linux updater checks have five original failures and pass after on
  current LuaJIT, stock Lua 5.4 and signed Ubuntu 22.04 dependencies; complete
  responses, callback settlement and offered/cache identity are retained. No
  artifact is fetched or installed. Sixteen additive shared Lua vectors and one
  typed/single-return case preserve all earlier 115 contracts: 132 focused checks
  have ten original failures and pass after. All six other parser helpers remain
  byte-identical. Register both native interpreters for future Linux CI without
  launching it. Windows reads the first raw true/false token, with related key and
  boundary flaws by source; the bounded proposal uses existing root-member spans
  to distinguish Boolean true from numeric one. macOS shares the Lua corpus; no
  additional live flag consumer or foreign runtime validation is claimed. Foreign
  runtime gates remain deferred. Depends on L107's parser-contract stack; no
  visible channel/badge correction, draft policy, transport or reserved change.

- [~] **L109.** Linux native periodic-duration admission: apply L105's shared
  finite-number policy to resolved seconds and converted milliseconds before
  clamping or allocating `EventLoop.run` resources. NaN/infinities and conversion
  overflow could create a dormant huge timer or unintended 1 ms repetition;
  refuse them through existing run cleanup. Preserve numeric strings, default and
  nonnumeric-default periods, finite negative/zero/fraction clamps, large finite
  durations and idle-only calls with unused invalid periods. Sixteen actual
  libuv cases have five original failures on current LuaJIT and signed Ubuntu
  22.04 dependencies, three on stock Lua 5.4, and pass after. Real finite foreign
  watchdogs bound observations; exact foreign ownership and healthy same-instance
  restart survive every refusal. Seventeen registered cases have six original
  failures and pass under LuaJIT and Lua 5.4; allocation/conversion seams are
  explicitly simulated, with a separate real native child. Retain all earlier
  assertions and reentry/stop ownership. Register future Linux CI without
  launching it. Windows/macOS have different timer-owner APIs by source; no
  foreign runtime validation is claimed. No maximum/native-width policy, callback
  type, pump/clock, sleep-completion or reserved change.

- [~] **L110.** Shared release-array admission: keep exact raw object spans and
  publication order while refusing non-object root elements. The old brace-only
  scan treated nested-array objects as releases; its entry count could still
  match the decoded root count, admitting an unintended higher version. Reuse
  the existing JSON decoder for whole-document admission and fence spans to
  direct root-array objects, retaining existing decoder semantics and selected
  release/version/channel policies. Eleven actual verified TLS/public Linux
  updater checks have three original failures and pass after on current LuaJIT,
  stock Lua 5.4 and signed Ubuntu 22.04 dependencies. Incomplete/trailing/mixed
  payloads already refused by Linux remain healthy controls; do not count them
  as new native regressions. Complete response/callback/handle/cache receipts,
  ordinary releases, nested metadata, quoted delimiters and highest-version
  selection survive. No artifact is fetched or installed. Sixteen additive
  raw-span/shape vectors plus one typed/single-result case preserve all earlier
  132 contracts: 149 focused checks have nine original failures and pass after.
  All six other helpers remain byte-identical. Register future Linux CI without
  launching it. macOS already validates decoded entry tags before this helper;
  Windows's brace scanner has a related source-only gap and a bounded proposal.
  Foreign runtime gates remain deferred. Depends on L108's parser-contract stack;
  no JSON reencoding, new grammar, transport, frontend or reserved change.

- [~] **L111.** Linux SQLite filesystem identity: represent every admitted
  relative database filename with an explicit `./` prefix at the CLI argument
  boundary. A bare `file:` path could open or mutate another database through URI
  interpretation even though filesystem admission selected the literal file;
  percent/query/fragment spellings, `:memory:` and leading dashes also changed
  its meaning. Preserve absolute argument bytes, public diagnostic spellings,
  shared SQL encoding, flags, scripts, schema and exit receipts. Thirty-five real
  filesystem/SQLite/public Reader/Writer/Keylogger checks have 23 original
  failures and pass after under current LuaJIT, stock Lua 5.4 and signed Ubuntu
  22.04 luv/libuv dependencies. SQLite itself remains the container's binary in
  that dependency mix; this is not a full Jammy SQLite/OS validation. Intended
  files gain exact expected counters/raw software-event bytes while URI-decoy
  files remain byte-identical; corrupt/missing/creation and ordinary/UTF-8/quote
  controls survive. Four additive registered cases have three original failures
  and pass; all 65 earlier command-owner cases remain, with 69 checks passing
  under LuaJIT and Lua 5.4. Register future Linux CI without launching it. This
  native filename representation has no dependency on queued SQL projection
  fixes. Windows/macOS use native open APIs without CLI option parsing; their
  compiled URI configuration is not validated, and explicit memory APIs must
  not inherit this filesystem-only encoding. No physical input, foreign runtime,
  TOML/configuration or reserved change.

- [~] **L112.** Linux timer callback error isolation: use one pure shared error
  description owner at the six callback reporting boundaries. Unprotected
  `tostring` of an error table with a throwing formatter escaped `pcall` and
  libuv's callback guard, terminating the interpreter with exit 255. Preserve
  primitive diagnostic text and describe object types without running foreign
  formatting code; no logger, callback execution or lifecycle refactor. Twelve
  genuine native cases have six fatal object failures before and pass after on
  current LuaJIT, stock Lua 5.4 and signed Ubuntu 22.04 luv/libuv dependencies.
  Each after/every/idle/periodic/registered-idle/deferred path retains an ordinary
  string control, real 5 ms successor and 30 ms foreign watchdog; after correction
  the formatter is never called, the watchdog survives owner cleanup and no
  native handles remain. Fatal baseline processes never reach cleanup assertions;
  do not certify their post-exit resources. Twenty-three registered tests have
  six native failures and pass under LuaJIT and Lua 5.4; eleven pure helper cases
  already pass before caller integration. Register the exact manual test manifest
  and future native Linux CI without launching it. Existing finite/periodic,
  reentry/stop and every other adapter body remain byte-identical. macOS has a
  similar source-only error-formatting gap; Windows uses a different exception
  reporting contract. Foreign runtime gates remain deferred, and no reserved
  dynamic-hotstring owner, physical input or foreign source is changed.

- [~] **L113.** Linux bracketed IPv6 provider ports: split the already admitted
  bracketed host before its numeric port, retaining DNS/IPv4 parsing and all
  existing guards and reason strings. Valid local IPv6 inference endpoints
  previously failed host admission before native dispatch. Eight public provider
  checks have four original failures and pass after on current LuaJIT, stock
  Lua 5.4 and signed Ubuntu 22.04 luv/libuv dependencies. Four independent real
  IPv6 curl controls verify owned TLS; eight public IPv4/IPv6 requests then
  retain exact model, authentication, Unicode prompt and generation fields,
  terminal callbacks, child exits and zero remaining native handles. Forty
  registered cases pass on both runtimes; the seven baseline failures comprise
  five valid-address cases and two invalid-port diagnostic-routing checks.
  Invalid ports remain refused. Preserve every earlier provider assertion and
  callback manifest entry; register future Linux CI without launching it.
  macOS already splits bracketed hosts explicitly, and Windows has no matching
  DNS-only splitter by source inspection; foreign native behavior is untested.
  No persistence, transport, menu, general URL grammar or physical input change.

- [~] **L114.** Linux SQLite metadata scalar fidelity: quote the selected value
  with native `json_quote` and decode it through the existing shared JSON owner
  after the unchanged checked scalar receipt. Raw CLI text stopped at NUL, and
  first-line framing stopped at LF although SQLite stored the complete value.
  Twenty genuine filesystem/SQLite/public metadata checks have eleven original
  failures and pass after under current LuaJIT, stock Lua 5.4 and signed Ubuntu
  22.04 luv/libuv dependencies. Independent `hex(value)` verifies complete stored
  bytes, including NUL suffixes; missing/empty, Unicode, quotes, compact cursor,
  actual CLI refusal and same-owner retry controls remain. SQLite remains the
  container binary in the Jammy dependency mix. Twenty additive registered cases
  pass on both runtimes; fourteen baseline failures cover seven framing vectors
  and seven malformed/non-string adapter responses. Preserve every earlier
  writer assertion and all other writer bodies. Register future native Linux CI
  without launching it. This repairs supported metadata API fidelity, without
  claiming corruption of ordinary compact production migration cursors. macOS
  avoids CLI line framing through native rows; its NUL binding is untested.
  Windows has a possible source-only zero-terminated TEXT analogue that requires
  its native owner's diagnosis. No foreign, physical input, TOML, schema, generic
  query, migration, cache or flush change.

- [~] **L115.** Linux provider-error completion admission: use one pure shared
  predicate to refuse any own root `error` field before extracting chat text,
  including explicit null or false. Canonical decoy completion fields previously
  escaped that error envelope. Preserve nested/inherited metadata, first-part
  selection, the existing empty-reply outcome and every original parser vector.
  Twenty-three genuine verified TLS/public provider calls have twelve original
  failures and pass on current LuaJIT, stock Lua 5.4 and signed Ubuntu 22.04
  curl/luv/libuv dependencies. Complete independent response bytes, child exit,
  one terminal callback, successful chunks or absent error chunks and zero native
  handles remain checked. Forty-one registered provider tests pass on both
  runtimes; introducing the pure helper before caller integration reproduces
  twelve actual extraction failures while the earlier seventeen tests stay green.
  Register future Linux CI without launching it. Windows already checks root
  error-field presence by source; macOS needs a classifier guard and native
  nested-null retention validation before claiming equivalent coverage. An
  earlier unprinted callback recorder failure in the unchanged HTTP fixture
  remains unresolved; passing original-source replays do not prove its cause.
  No foreign native gate, transport, Backboard/decisions, menu, persistence,
  multipart-policy or physical input change.

- [~] **L116.** Linux structured completion syntax admission: use the existing
  canonical strict JSON decoder at this response boundary instead of the legacy
  decoder that normalizes malformed escapes and accepts invalid number grammar.
  Preserve the preceding own-error guard, first-part/candidate selection, typed
  refusals, Unicode bytes and the existing empty-reply result. Fifty-four actual
  verified TLS/public provider requests have thirty original failures and pass
  after under current LuaJIT, stock Lua 5.4 and signed Ubuntu 22.04 curl/luv/libuv
  dependencies. Eighteen vectors have independently rejected JSON grammar;
  twelve are existing strict-owner refusals for duplicate keys, lone surrogates
  and non-finite decoded numbers, and twenty-four are healthy controls. They do
  not represent thirty separate bugs. Exact wire bodies, curl exit, terminal
  callback, chunk policy, retries and zero native handles remain asserted. All
  ninety-five provider unit cases pass on both runtimes, retaining the preceding
  forty-one and the unchanged universal forty-seven-vector corpus. Register future
  Linux CI without launching it. Windows has source-level grammar/finite/surrogate
  guards but currently permits duplicate keys; macOS native decoder behavior must
  be measured independently before changing its owner. No shared decoder policy,
  legacy caller, foreign native gate, transport, Backboard/decisions, menu,
  persistence, multipart policy or physical input change.

- [~] **L117.** Linux provider error-message UTF-8 boundaries: use one shared
  byte-prefix helper at the existing selected diagnostic field. Retain the
  200-byte ceiling and longest complete prefix of valid source text instead of
  cutting a multibyte scalar in half. Preserve field priority, empty explanations
  and pre-existing malformed-source raw-prefix behavior; this does not repair or
  newly admit malformed provider strings. Forty-five actual verified TLS/public
  provider HTTP 401 calls have twenty-four original boundary failures and pass
  after on current LuaJIT, stock Lua 5.4 and signed Ubuntu 22.04 curl/luv/libuv
  dependencies. Independent Python prefixes, complete `error_body`, empty success
  body, curl exit 22/signal zero, one callback, no chunks and zero native handles
  remain checked. Six shared-helper cases and forty-seven provider cases pass
  on both runtimes, covering scalar splits, byte budgets, invalid arguments,
  ordinary controls and explicit unchanged malformed-source behavior. Preserve
  earlier helpers, provider owners and manual callback/IPv6 manifest entries;
  register future Linux CI without launching it. macOS has the same source byte
  cut and can adopt the shared helper after native validation. Windows has a
  different UTF-16 unit ceiling and ellipsis; supplementary-pair safety needs
  its own native proof. No foreign source/runtime, decoder policy, transport,
  menu, persistence, physical input or character-budget expansion.

- [~] **L118.** Linux XKB outer-block quoted metadata: locate block keywords and
  structural openers outside quoted strings, then balance only unquoted braces.
  Quoted type/level names could select a false symbols block, and group metadata
  braces truncated its body. Preserve exact raw body bytes and refuse unfinished
  strings; no comment/angle grammar, normalization, group or shortcut policy.
  Sixty-four native checks over eight genuinely compiled and canonically retained
  maps have twenty-five original failures and pass after under current libraries
  and signed Ubuntu 22.04 luv/libuv dependencies. libxkbcommon remains the
  container library in that mix. Native a/q/2 oracles, checked files, complete
  entry floors and public layout refresh/base labels remain checked. Twenty-five
  additive pure cases have twelve original failures and pass under LuaJIT and
  Lua 5.4, including escaped-byte parity and unfinished input. Preserve all
  earlier assertions and helpers after the block reader; register future Linux
  CI without launching it. Native fixtures require LuaJIT FFI, so stock Lua 5.4
  validates only the pure matrix. Initial dispatcher setup failures are retained
  separately; corrected native baseline loads the exact saved HEAD parser source
  without replacing production files. Windows/macOS use different native layout
  owners, with no equivalent text parser by source inspection; foreign native
  behavior is untested. Per-key definitions, symbols-looking quoted lists and
  angle-name lexical gaps remain separate. No display, device, physical magic
  selection, repeat, recovery or reserved shortcut change.

- [~] **L119.** Linux XKB quoted key definitions: iterate real declarations
  outside quoted metadata and reuse the existing quote-aware block owner to
  return exact complete definitions. Per-key type names containing braces could
  truncate definitions; quoted phantom declarations also created false parser
  entries. Preserve every earlier scanner, list/group/keycode/keysym expression
  and fallback priority. Seventy-two native checks over eight genuinely compiled
  canonical maps have nine original failures and pass under current libraries
  and signed Ubuntu 22.04 luv/libuv dependencies; native libxkbcommon remains the
  container library in that mix. Retained hostile literals, independent native
  a/q/2, public checked-file refresh/base labels and phantom-entry refusal remain
  checked. The phantom-only case repairs a parser contract, without claiming a
  previously wrong public label. Sixteen additive pure cases have eight original
  failures and pass under LuaJIT and Lua 5.4; all preceding fifty-two assertions
  and the earlier sixty-four native checks remain green. Register future Linux CI
  without launching it. Stock Lua 5.4 native FFI is unexecuted; Windows/macOS have
  different native layout owners and foreign runtime behavior is untested. Quoted
  symbols-looking lists and angle-name lexical gaps remain separate. No display,
  physical device, magic selection/repeat/recovery, reserved shortcut, comment
  grammar, normalization or group policy change.

- [~] **L120.** Linux XKB quoted symbol-list metadata: match the existing
  explicit Group1 and fallback list patterns only outside quoted metadata.
  A symbols-looking type name produced a wrong public base label (`z` instead
  of native `a`). Reuse the unchanged quote skipper and preserve exact captured
  bytes, explicit priority, fallback/index/group behavior and keysym spelling.
  Sixty-four real native checks over eight compiled canonical maps reproduce
  ten failed observations of this single defect and pass under current native
  libraries and signed Ubuntu 22.04 luv/libuv dependencies; native XKB remains
  the container library. Independent native a/q/2, exact hostile literals/raw
  bodies, checked file publication and actual public refresh remain required.
  Twenty additive pure cases reproduce ten failures and pass under LuaJIT and
  Lua 5.4; all preceding sixty-eight assertions stay unchanged. Earlier native
  block64/key72 regressions replay green under both mixes. Stock Lua 5.4 native
  FFI and foreign runtime behavior are unexecuted. Windows/macOS use different
  native layout APIs, with no equivalent text parser by source inspection.
  Register future Linux CI without launching it. Angle-name lexical gaps and
  wider raw-input grammar remain separate. No physical magic, reserved shortcut,
  display/device, normalization, comment grammar or group policy change.

- [~] **L121.** Linux native application category/score edit: publish the
  existing category UPDATE and score INSERT in one checked SQLite transaction.
  Previously a score-write refusal could leave the category changed and report
  success. Native statement errors now stop before COMMIT; closing the native
  connection rolls back the unfinished edit, including AFTER trigger FAIL
  effects. Fifteen genuine Bridge/Keylogger/Writer/SQLite checks reproduce
  three failures and pass under current LuaJIT, signed Ubuntu 22.04 luv/libuv
  dependencies and Lua 5.4; SQLite/kernel/libc stay current in the mixed profile.
  Retain unchanged category/score/cache on ABORT and FAIL, truthful saved replies,
  healthy retries, existing defaults/floors/filtering/escaping and CRLF/Unicode
  controls. Writer-only NUL hex/value fidelity is checked separately; the older
  fourteen-case diagnostic retains its unresolved Reader NUL projection and
  is not claimed green. Six additive command-adapter unit cases reproduce two
  failures and pass on both Lua runtimes, with every previous assertion intact;
  prior native metadata20 remains green on all three profiles. Register future
  Linux CI without launching it. This proves statement-error rollback; a lost
  receipt after successful COMMIT remains outside this guarantee. macOS uses
  one categories-object publication; Windows has a different category-only
  sidecar and no equivalent two-statement SQL action by source inspection.
  Foreign native behavior is untested. No Reader/schema/cache/flush/TOML,
  physical input or reserved title/shortcut change.

- [~] **L122.** Linux update release-page admission: use the existing shared
  strict JSON decoder at the completed-page boundary. Legacy decoding could
  offer a release from malformed grammar, duplicate keys, lone surrogates or
  nonfinite metadata; duplicate selected tags could change the offered version.
  Change one decoder call while keeping the legacy API, shared release parser,
  tag/assets/notes/publication/prerelease selectors, channels, transport and
  caching byte-identical. Thirty-four real verified-TLS/public updater checks
  reproduce twenty-two wrong offers (eight grammar cases plus fourteen existing
  strict-policy controls) and pass on current LuaJIT, signed Ubuntu 22.04
  curl/luv/libuv dependencies and Lua 5.4. The mixed profile retains current
  kernel/Lua/libc. Twelve native healthy controls retain tag, canonical download
  and checksum URLs and cache identity; thirty-four scripted unit cases retain
  those fields plus notes/time/prerelease and pass on both Lua runtimes. Every
  prior parser assertion stays intact. Six unchanged native updater fixtures
  totaling sixty-one checks remain green under all three configurations.
  Native curl exits/status/full bytes, one callback and zero handles are required.
  Register future Linux CI without launching it. macOS uses native hs.json
  admission whose strict-policy details are unmeasured; Windows uses nonempty
  payload/span parsing by source inspection. Keep foreign diagnoses separate
  and leave their native gates to the principal agent. No release publication,
  website, transport, persistence, physical input or reserved policy change.

- [~] **L123.** Linux modifier-hold statistics projection: publish the existing
  shared `s/n/m/tap/hold` record names instead of leaking native SQL column names.
  SQLite stored correct sums/counts/maxima, but Apps displayed zero duration and
  event counts and Typing displayed an em dash. Change exactly five keys in three
  Reader lines; keep SQL SUM/MAX, defaults, numeric values/rounding, filters,
  Writer/schema, shared contract and consumers identical. Twelve real public
  Writer/SQLite/Reader checks reproduce eight failures and pass under current
  LuaJIT, signed Ubuntu 22.04 luv/libuv dependencies and Lua 5.4; SQLite/kernel/
  libc remain current in the mixed profile. Independent SQL establishes totals,
  maximum across devices, legitimate zero and existing fraction-floor controls.
  Separately run five actual Apps/Typing consumer checks on each native manifest:
  four fail before and all pass after, restoring 1570 ms/seven samples and the
  300 ms/600 ms Typing figures. Node VM supplies explicitly simulated DOM/state;
  this is software integration, without a browser session or physical tap-hold
  validation. Eight new registered unit cases fail before and pass on both Lua
  runtimes, preserving every previous owner assertion. The final CJS refuses a
  failed native child before consumer checks; its after run validates both layers.
  Register future Linux CI without launching it. Windows already emits canonical
  fields; macOS emits sum/count/max/tap/hold by source inspection, retaining a
  separate duration/count/maximum diagnosis without a native run or foreign edit.
  No alias policy, SQL/schema/cache/flush, physical hook/remap, magic/shortcut,
  persistence, brightness or title change.

- [~] **L124.** Linux supplied burst histogram keys: encode complete JSON keys
  with the existing shared codec instead of escaping only quotes. Backslash-b
  changed the stored key bytes; backslash-l and literal controls produced invalid
  JSON and refused the next merge. Normal collection uses numeric and `500+`
  labels and stays unchanged. Eighteen real public Writer/SQLite checks reproduce
  five failures and pass under current LuaJIT, signed Ubuntu 22.04 luv/libuv
  dependencies and Lua 5.4; SQLite/kernel/libc remain current in the mixed profile.
  Independent native `json_valid` and `json_each`/`hex(key)` assertions cover
  supplied key bytes, repeated writes, filtering, floors, empty defaults and a
  genuine SQLite statement refusal/retry. Eight registered scripted unit cases
  reproduce three failures and pass on both Lua runtimes; every prior owner
  assertion stays intact. Existing category and metadata native regressions
  remain green under all three configurations. Reuse the already imported shared
  JSON encoder, retaining caller data, counts, SQL/schema and all other Writer
  paths. Register future Linux CI without launching it. Check Windows and macOS
  histogram serialization by source inspection; leave their native gates to the
  principal agent. NUL-key projection is a separate diagnosis outside this fix.
  No collection policy, cache/flush, persistence, reserved surface or physical
  keyboard validation change.

- [~] **L125.** Linux fractional WPM persistence: serialize the admitted rate
  as a double instead of an integer. A real two-character collector flush with
  1300 ms elapsed stored 18 instead of 240/13 WPM under LuaJIT; Lua 5.4 threw
  before writing the raw batch. Keep the shared formula, caller data, ID cursor,
  dates, other SQL columns and all prior category/metadata/histogram fixes intact.
  Thirteen real collector/Writer/SQLite checks reproduce nine LuaJIT failures
  and the Lua 5.4 production exception, then pass under current LuaJIT, signed
  Ubuntu 22.04 luv/libuv dependencies and Lua 5.4. SQLite/kernel/libc stay current
  in the mixed profile. Seven independently specified native scalar controls
  cover fractions, numeric text, integers, zero and existing invalid-text fallback;
  the first collector check also retains the shared computation assertion.
  Nonfinite serialization now receives a genuine SQLite refusal instead of an
  acknowledged coerced integer; unchanged accepted rows and healthy retry are
  checked, without claiming ID rollback or whole-flush atomicity. Six registered
  unit cases reproduce three failures and pass on both runtimes. Every original
  assertion remains intact; existing histogram/category/metadata native fixtures
  also pass under all three configurations. Register future Linux CI without
  launching it. macOS and Windows retain their existing one-decimal WPM policy
  and numeric SQL serialization by source inspection; their native checks remain
  with the principal agent. Software collector calls are synthetic input and do
  not validate physical keyboards. No formula, schema, collection, persistence,
  reserved policy or foreign driver change.

- [~] **L126.** Linux remote terminal callback diagnostics: describe caught
  errors with the existing shared ErrorDescription policy. Calling tostring on
  an error object invoked caller formatting again and could throw during failure
  reporting. Reuse the shared helper through one import and one formatter call;
  keep owner clearing before the caller, callback arguments/count/order, retries,
  successors, decoders and HTTP transport identical. Per native configuration,
  sixty-three public Chat/Models/Test and ordinary-string Vision scenarios issue
  145 genuine verified-TLS requests: thirty-two formatter-policy failures before,
  none after under current LuaJIT, signed Ubuntu 22.04 curl/luv/libuv dependencies
  and Lua 5.4. The mixed profile retains host kernel/Lua/libc and recorded OpenSSL;
  current and stock Lua use curl 8.14/libuv 1.50, the mixed profile 7.81/1.43.
  All native primary/successor/retry tuples, arity, model IDs and captured ownership
  are asserted outside protected callbacks after settlement, alongside exact wire
  inventory, one terminal callback and zero retained handles. Preserve every
  original assertion: five deliberate software tuple mutations demonstrate that
  the former protected assertions could falsely pass and that outside oracles
  refuse them. Forty-seven independent software sensitivity controls cover the
  new oracles on both Lua runtimes; these are not native or physical validation.
  Seventy-eight registered unit cases reproduce fifty-three failures and pass
  after. Preserve the four original pcall-status assertions and additionally
  assert the genuinely returned caller-delivery records outside protection;
  four software mutation pairs on both runtimes prove these unit oracles can
  fail. The unchanged complete-tree JS false-green ratchet stays at zero.
  Existing API admission/UTF8/IPv6 regressions remain byte-identical.
  Register future Linux CI without launching it. macOS callback traceback/object
  formatting remains a source-only analogue; Windows uses native protected
  callbacks whose error getters need separate native evidence. Leave their gates
  to the principal agent. Vision object diagnostics and outer HTTP diagnostics
  remain separate, unmeasured scopes. No menu, magic, transport, persistence,
  physical hardware or foreign driver change.

- [~] **L127.** Linux raw event calendar days: use the local day for hotstring
  and shortcut collection and the four raw Writer defaults, matching existing
  typing and daily aggregates. Keep UTC timestamps and caller-supplied dates
  unchanged. Genuine public software events, Writer, Reader and dashboard APIs
  with real SQLite reproduce six mismatches in thirteen checks before and pass
  after on current LuaJIT, Lua 5.4 and the signed Jammy luv/libuv mixed profile.
  The genuine-clock fixture starts only its process with POSIX TZ=OWN-24, an
  artificial UTC+24 offset that guarantees distinct real local/UTC days. It
  replaces no clock or adapter, verifies clock identity and UTC bounds, rejects
  calendar crossing during setup, and checks repeat flushes and durable IDs.
  This does not represent a geographic timezone or physical keyboard input.
  Nineteen additional checks with explicitly simulated Lua clock inputs and real
  libc/SQLite cover east/west/UTC and midnight boundaries: nine failures before,
  none after under current and mixed-profile LuaJIT. Their FFI requirement leaves
  this fixture unexecuted under Lua 5.4. Ten registered unit cases reproduce six
  failures and pass after on all three profiles. Native fixtures assert their
  exact check floors; preserve every original test and assertion. Windows
  KL_Today and macOS aggregator.today already use local calendar days in source;
  foreign native validation remains with the principal agent. Register future
  Linux CI without launching it. No migration of historical events, formula,
  schema, shared policy, physical-input, menu or reserved configuration change.

- [~] **L128.** Linux n-gram text projection: preserve embedded NUL and distinct
  admitted UTF-8 tokens through the SQLite CLI. Raw TEXT in its JSON mode truncates
  at NUL, losing tokens or merging them with a prefix. Project json_quote(token)
  and decode its string with the existing shared JSON codec at the native adapter
  boundary; retain grouping, counts, delays, error/source totals and malformed
  numeric fallback. Twenty-nine native checks across all nine character/word
  families reproduce nineteen failures and pass after on current LuaJIT, Lua 5.4
  and the signed Jammy luv/libuv mixed profile, all with actual SQLite 3.46.
  Public synthetic output, flush, range and historical/today split APIs retain
  exact NUL, quotes, whitespace and accented text. Independent durable hex(token)
  and seven distinct token identities verify the original bytes and counters.
  Empty-range and ordinary-text controls remain healthy. Use a fixed historical
  fixture day with a distinct-day precondition rather than subtracting 24 hours,
  which can still be today on a 25-hour calendar day. Preserve all original native
  assertions and add an exact twenty-nine-check floor. The registered regression
  fails before and passes after on all three profiles; forty-four Reader owner
  checks, including canonical modifier-hold data, pass after. Their CLI adapters
  are explicitly simulated; the native fixture runs real software/database paths
  and does not validate physical input. macOS uses native binding rows in source;
  Windows has a separate source analogue in SQLite_Utf8ToStr, which calls StrGet
  without a byte length. Its direct text queries need native evidence and a
  length-aware or JSON-framed read strategy from the principal agent. No foreign
  driver changes or native gates here. Register future Linux CI without launching
  it. No NULL policy, completion cache, schema, Writer, menu or reserved change.

- [~] **L129.** Linux SQLite NULL boundary: use the existing shared lossless JSON
  decoder for native result rows and remove only top-level tagged NULL scalars.
  Legacy empty-table sentinels defeated numeric zero defaults and published absent
  optional extrema or first/last minutes as objects. Keep arrays, ordinary objects,
  nested tagged NULL and embedded JSON text unchanged; do not change the shared
  decoder contract or SQL queries. Eight genuine public Writer/Reader checks with
  native SQLite reproduce three failures and pass after under current LuaJIT,
  Lua 5.4 and the signed Jammy luv/libuv mixed profile. Optional manifest fields
  reach the runtime projection; read_system_days is a public API with no current
  Linux runtime caller. Native tests assert their exact eight-check floor and all
  original assertions remain unchanged. Three registered CLI-response unit cases
  reproduce three failures and pass after on all three profiles. Forty-seven
  complete Reader owner checks, including n-gram byte identity and canonical
  modifier-hold fields, pass after; replay all twenty-nine native n-gram checks
  on each profile. Windows already uses COALESCE for system totals and removes
  absent battery extrema represented by empty strings in source; macOS uses
  binding-native nullable values. Foreign binding and driver execution remains
  untested here and belongs to the principal agent. Register future Linux CI
  without launching it. Preserve both PulseAudio language packs and principal
  notification/HTTP fixtures from dev. No global codec, query, numeric policy,
  schema, cache, configuration, menu, physical-input or foreign driver change.

- [~] **L130.** Linux raw-event batches: wrap each typing, hotstring, shortcut
  and app-switch script in a checked SQLite transaction. An INSERT trigger using
  RAISE(FAIL) previously left earlier rows or trigger effects committed while the
  public caller retained the entire refused batch; its retry then duplicated
  events and diverged from derived totals. Roll back the refused script when the
  checked CLI exits before COMMIT. Keep separately acknowledged event-ID
  reservations and their gaps; this does not promise whole-flush atomicity,
  ID rollback, COMMIT-refusal handling or exactly-once delivery after a lost
  post-COMMIT acknowledgement. Twelve genuine native checks reproduce ten
  failures and pass after on current LuaJIT, Lua 5.4 and the signed Jammy luv/libuv
  mixed profile. A separate actual-clock public Keylogger producer and independent
  Python SQLite oracle reproduce five failures among twelve checks and pass after
  on each profile. Producer exit zero before and after only means its snapshots
  were collected: the oracle supplies the failing or passing verdict. Refused,
  accepted and repeated-flush snapshots independently verify IDs, pending events,
  raw/derived conservation, exact fractional WPM, local days and UTC timestamps.
  Both native fixtures enforce their exact twelve-check floors. Eight registered
  CLI-script unit assertions fail before and pass after on all three profiles.
  Preserve every existing assertion and the unchanged Keylogger implementation.
  macOS already checks its ingest transaction and rolls back failures in
  log_manager; Windows journals transaction-delimited ingest scripts for its
  detached replay worker. Those different native paths need their own runtime
  validation and remain with the principal agent. No shared policy change is
  required: transaction ownership belongs to each native SQLite adapter. Register
  future Linux CI without launching it. These are real Linux software/database
  executions with software-supplied input, not physical keyboard validation.
  Preserve both PulseAudio language packs and principal notification/HTTP fixtures.
  No schema, Reader, menu, configuration, foreign driver or reserved change.

- [~] **L131.** Linux native manifest completion: retain the useful partial first
  result after a refused SQLite query, but cache a revision only when every
  projection query completed. Otherwise a temporary failure in the base, error
  or session query remained cached after native recovery at the same revision.
  Preserve successful empty reads, accepted cache reuse and explicit cache clear;
  malformed native JSON and invalid paths refuse completion. Ten actual public
  collector/SQLite/Reader checks reproduce seven failures and pass after on
  current LuaJIT, Lua 5.4 and the signed Jammy luv/libuv mixed profile. A separate
  three-check public cache regression independently reproduces three failures
  and passes after on each profile: literal native SQL proves accepted chars3,
  errors7 and sessions2 while the recovered public payload previously retained
  an omitted field. This supplemental oracle does not depend on the new completion
  flag; preserve its entire original body and exact three-check floor. The primary
  fixture enforces ten checks. Eight registered CLI-response unit cases reproduce
  eight failures and pass after on all three profiles; all fifty-five checks in
  the three existing Reader owners remain green, with every old assertion and
  complete unit prefix preserved. Select only the first return in the existing
  NULL and two filesystem fixture calls to next, preserving their assertions and
  eight/thirty-five floors. The two additional calls failed with invalid keys
  after the API change; all thirty-five native path checks pass after the caller
  adaptation on each profile. macOS source likewise has no manifest completion
  result, but this alone does not reproduce a macOS revision-cache defect.
  Windows has separate candidate/last-good refresh guards; neither foreign
  runtime is executed or modified here. Completion acceptance belongs to the
  native Reader/cache adapter, with no shared SQL or numeric policy change.
  Register future Linux CI without launching it. Software events and schema
  obstructions exercise real native software/database paths, not physical input.
  Preserve both language packs and principal notification/HTTP fixtures. No
  Writer, schema, menus, configuration, foreign driver or reserved change.

- [~] **L132.** Linux layout-count projection: publish persisted counts as the
  canonical layouts_seen map consumed by the shared Apps/Typing dashboard.
  Linux previously emitted layouts, leaving healthy native metadata invisible
  to that consumer. Change only the two field statements; preserve SQL grouping,
  filters, optional absence, numeric zero, revision-cache completion and stored
  event/aggregate bytes. Ten genuine public collector/SQLite/Reader/dashboard
  checks reproduce seven failures and pass after on current LuaJIT, Lua 5.4 and
  the signed Jammy luv/libuv mixed profile. The actual keyboard module supplies
  its default qwerty label without hook initialization; two software key calls
  produce a durable count2 independently observed in native SQL. Explicit metadata
  covers multiple devices, quoted UTF-8 labels, date/app filters and recovery.
  This proves software metadata persistence/projection, not physical input,
  desktop-layout discovery or an initialized XKB/Wayland keyboard hook. Preserve
  all fifty-one original native assertion lines and enforce the exact ten-check
  floor. Four registered CLI-response unit cases reproduce one failure and pass
  after on all three profiles. All fifty-nine checks from the existing Reader
  owners remain green; retain the entire old unit prefix and every assertion.
  Replay native NULL8, completion10 and independent public-cache3 on each profile.
  macOS and Windows already publish layouts_seen in source, and shared consumers
  already read it; no shared policy or UI change is required. Their native gates
  remain with the principal agent. Register future Linux CI without launching
  it. Preserve both language packs and principal notification/HTTP fixtures.
  No Writer, Keylogger, SQL, schema, UI labels, menu, configuration, physical-input,
  foreign driver or reserved change.

- [~] **L133.** Linux directed application transitions: project persisted
  agg_app_day_switches_to rows into the canonical switches_to map. Sum device
  contributions by date, source and destination; reuse inclusive date and source
  application filters while retaining destinations outside that selection.
  Preserve optional absence, typed zero, quoted UTF-8 names, aggregate/raw bytes
  and native completion-cache refusal/recovery. Thirteen real public software
  collector/SQLite/Reader/dashboard controls reproduce nine failures and pass
  after on current LuaJIT, Lua 5.4 and the signed Jammy luv/libuv mixed profile.
  Five independent native SQL controls reproduce three failures and pass after
  on each profile, including literal directed 6|2, reverse 1|1 and zero integer
  0|1|integer oracles. Both fixtures enforce their exact thirteen/five floors.
  Four registered CLI-response unit cases reproduce three failures and pass
  after; all sixty-three existing Reader owner cases and every old assertion
  remain. Replay native NULL8, completion10, public-cache3 and layouts10 on all
  three profiles. Shared consumers already use switches_to; no shared policy
  change is needed. macOS/Windows source also produces transitions but their
  Reader manifests omit this field; this is a source diagnosis, with native
  foreign validation and corresponding fixes left to the principal agent.
  Register future Linux CI without launching it. Explicit software focus calls
  exercise native databases, not physical input or foreground-window discovery.
  Preserve both language packs and principal notification/HTTP assertions.
  No Writer, Keylogger, schema, UI, configuration or reserved change.

- [~] **L134.** Linux hourly manual corrections: credit the existing software
  [BS] protocol to local hourly/min5 error counters and cumulative delay bins,
  while preserving typed-character totals and synthetic exclusion. Persist
  numeric histogram deltas through the existing native SQLite merge policy;
  extract the existing burst expression without changing its behavior.
  Twelve genuine public collector/SQLite/Reader/dashboard checks reproduce
  eight failures and pass after on current LuaJIT, Lua 5.4 and the signed Jammy
  luv/libuv mixed profile. Enforce the exact twelve-check floor and preserve
  every original assertion. Literal SQL controls cover raw bytes, daily errors,
  cumulative thresholds, multiple flushes/devices, repeated direct deltas,
  caller preservation, filters and RAISE(ABORT) statement refusal/recovery.
  This proves that tested statement rollback, not general transaction recovery
  or automatic retry durability. Four registered Walker cases reproduce three
  failures and pass after; all forty-five Walker owner cases remain green with
  the entire old unit prefix preserved. Replay native burst18, WPM13, raw-batch12
  and completion10 on each profile. macOS/Windows already count manual corrections
  in hour/min5 bins and persist their histograms in source; native foreign gates
  remain with the principal agent. Reuse shared bucket thresholds/helpers and
  the canonical schema, with no new policy or shared-data change. Register future
  Linux CI without launching it. Real clocks/native processes/databases with
  explicit software event timestamps do not validate physical Backspace capture,
  which currently does not supply this marker. Preserve both language packs and
  principal notification/HTTP assertions. No input hook, Reader, Keylogger, schema,
  configuration, menu, foreign driver or reserved change.

- [~] **L135.** Linux canonical manual-character count: exclude the exact
  software correction marker [BS] from the per-app character accumulator.
  Preserve its raw event/bytes, correction counters, elapsed-time admission,
  global/live/raw-event WPM, ngrams and exact-marker distinction. The software
  a/[BS]/b stream previously exposed live/durable chars3 while class/hour totals
  correctly remained2; correction-only input incorrectly contributed a character.
  Nine real public collector/SQLite/Reader/dashboard controls reproduce five
  failures and pass after on current LuaJIT, Lua 5.4 and the signed Jammy luv/libuv
  mixed profile. Keep the existing exact nine-check floor. Literal SQL independently
  requires daily2, classes2, hourly2, raw hex615B42535D62 with three input events,
  and backspaces1. A second c/[BS] flush adds one character for cumulative3;
  an empty flush preserves all raw ID/text/event bytes and the ASCII control2.
  Four registered unit cases reproduce three failures and pass after, including
  Unicode/whitespace, marker-only and [BS]x controls. All forty-five old/new owner
  cases pass; preserve the entire 28658-byte old unit prefix and all ninety-eight
  assertion lines. The frozen author README undercounts those lines as97; keep
  that receipt unchanged and use the measured count here. Shared Apps/Typing,
  macOS/Windows source already separate manual chars from corrections; no new
  policy or foreign-native claim. Native foreign gates remain principal-owned.
  Register future Linux CI without launching it. This software protocol does not
  validate physical Backspace collection, which currently does not feed this
  marker. Preserve both language packs and principal notification/HTTP assertions.
  No physical hook, timing policy, Writer, Reader, Walker, schema, configuration,
  window-title logic, menu, foreign driver or reserved change.

- [~] **L136.** Linux fallback wait completion: accept the interpreter-native
  os.execute success receipts true/0 and propagate refusal instead of reporting
  a completed wait after an ignored command failure. Preserve duration conversion,
  native nanosleep/EINTR behavior, luv pump/clock/reentry and existing shared timing
  helpers. Eight actual native controls reproduce four failures and pass after
  on current LuaJIT, Lua 5.4 and the signed Jammy luv/libuv mixed profile, with
  the original exact eight-check floor. A private executable returns exit7;
  genuine sleep recovery completes at least25ms with exact0.020/0.025 arguments.
  Stock Lua naturally lacks FFI; LuaJIT FFI absence and cdef refusal are explicitly
  simulated selection seams around real commands. Thirteen registered controls
  reproduce nine failures and pass after on all three profiles while loading
  all382 modules without errors. Twelve model CLI/FFI receipts; the thirteenth
  executes the real native child fixture. Preserve the entire old unit by the
  remove-only inverse of the unchanged2567-byte internal insertion before the
  unique backend-isolation block; this is not an appended-prefix claim. macOS
  uses hs.timer.usleep with a void adapter contract, Windows native timer methods
  use SetTimer; neither supplies this Linux boolean external-command wait path.
  The macOS exception suppression is a separate source observation, not foreign
  native validation or proof of an equivalent completion defect. Shared policies
  remain unchanged; foreign native gates stay principal-owned. Register future
  Linux CI without launching it. Real software waits/processes do not validate
  physical input or new signal/lifecycle behavior. Preserve both language packs
  and principal notification/HTTP assertions. No shared helper, foreign driver,
  input hook, configuration, menu or reserved change.

- [~] **L137.** Linux Unicode character classes: replace the private multibyte
  shortcut with the existing shared coarse classifier, preserving codepoint
  lengths, source counters and manual/synthetic separation. Actual public
  software ingestion and native SQLite reproduce three failures among fourteen
  independent Python-oracle controls before and pass after on current LuaJIT,
  Lua 5.4 and the signed Jammy luv/libuv mixed profile. Han and emoji belong to
  other; NBSP and NNBSP belong to space. ASCII, accented letters, combining
  codepoints and synthetic output retain their literal counts. This existing
  coarse policy does not implement Unicode general categories or graphemes.
  Nine registered unit controls reproduce four failures and pass after on all
  three profiles; the supplemental CR/VT/FF control checks other while tab/LF
  stay space. That supplemental control is a Walker unit, not native hardware
  coverage; the fourteen native controls remain unchanged. Preserve the entire
  original eight-case unit prefix and all forty-five previous Walker controls.
  macOS already delegates to the same shared classifier. Windows agrees on the
  concrete Han, emoji, NBSP/NNBSP and accent cases; broader letter ranges and
  combining behavior differ, so this is not full foreign taxonomy parity.
  Foreign native validation remains principal-owned. Register future Linux CI
  without launching it. Preserve both language packs and principal notification
  and HTTP assertions. No input hook, shared policy, schema, source counters,
  normalization, menu, configuration or reserved change.

- [~] **L138.** Linux stored ngram source projection: retain all admitted string
  source labels except hotstring, llm and none in the canonical other bucket.
  A shared Utils predicate owns that membership; Linux retains native JSON
  projection and its existing tonumber scalar admission/fallback. Actual SQLite
  Writer/Reader controls reproduce one failure among six, scalar/shape controls
  one among seven, and public software collector/flush/SQLite/Reader/dashboard
  five among nine before, then pass after on current LuaJIT, Lua 5.4 and the
  signed Jammy luv/libuv mixed profile. Independent read-only Python SQLite
  verifies literal c11/hs1/llm2/o6; producer exit0 means collection, not success
  of the independent oracle. The word-family check is an explicit Writer seam,
  separate from the collector's synthetic-word exclusion. Ten original unit
  controls reproduce three source failures; an additional pure membership case
  covers twelve literal labels/types and adds a separate pre-fix API absence.
  All eleven pass after, along with all seventy-four current Reader controls.
  Preserve the complete old34969-byte unit and its110 assertions, the entire
  frozen ten-case prefix, native6/7/9 floors and all older ngram/NULL/completion/
  cache/layout/switch/Unicode regressions. macOS/Windows already project extra
  string labels into other; source inspection establishes that supported
  taxonomy, not full scalar/fallback parity or foreign native execution.
  This slice covers stored reads. The live unflushed projection and Writer
  conflict merge have separately reproduced omissions and remain queued; do
  not claim complete source accounting. Register future Linux CI without
  launching it. Preserve both language packs and principal notification/HTTP
  assertions. No Writer, live delta, input hook, shared admission change, schema,
  configuration, menu, normalization, foreign driver or reserved change.

- [~] **L139.** Shared typing metrics NONE selection: use one selection policy
  for historical dictionaries, live known/Unknown applications and per-app KPIs.
  Explicit NONE excludes all input while retaining existing ALL, uninitialized,
  explicit selection, Unknown inclusion, discovery and cache ownership outside
  NONE. Twelve registered JS controls cover all ngram families and actual raw/
  hotstring SFB computations; all pass after the fix. Fifteen existing request
  ownership controls remain green. Real Linux WebKit 2.54 under virtual X11 and
  private D-Bus reproduces two failures among nine before, then nine pass after:
  a mandatory visible owned h/count7 row is cleared, leaving zero data rows and
  the genuine translated colspan8 no-data placeholder. The production manager,
  keylogger, native SQLite and actual picker open/select/close transaction run;
  literal SQL historical and flushed software counts remain healthy. Preserve
  all eight original GUI checks, the ninth rendered-row assertion and subject
  floor. Register the exact future CI command without launching GitHub CI.
  The UI policy is shared by Windows/macOS/Linux; backend empty-array semantics
  differ and are unchanged. Foreign native WebViews, Ubuntu 22.04 WebKit and
  physical input are unexecuted. Preserve both PulseAudio language packs and
  principal notification/HTTP assertions. No bridge, backend, input hook, menu,
  configuration, source-admission, translation or reserved implementation change.

- [~] **L140.** Linux ngram source conflicts: reuse the existing numeric-map
  SQL accumulator so successive flushes retain every admitted literal source key.
  Preserve existing string/positive-number admission, floors, scalar counters,
  schema and generic helper. Actual public software output and native SQLite
  reproduce four failures among twelve before, then pass after, on current
  LuaJIT, Lua 5.4 and the signed Jammy luv/libuv mixed profile. An independent
  read-only Python connection verifies the same twelve outcomes from native
  snapshots. Eight healthy controls retain known-source addition, manual absence,
  raw tagged events, exact c/td/cd/e, device/date isolation and numeric admission.
  Quoted Unicode/dotted keys and persisted numeric-string counts accumulate.
  Four additive registered units pass; all104 Writer controls remain green.
  Strengthen only three old source-shape assertions into captured public Writer
  SQL, decoded known/extra input maps, cumulative literal-key inputs and scalar
  bindings; preserve every other old byte and assertion. All six focused faulty
  mutations are caught by the original strengthened subject and native fixture.
  Register future native/Python CI pairs without launching workflows. Windows
  already enumerates literal source keys; macOS uses generic JSON-path merging,
  supporting conventional labels by source inspection, without establishing
  dotted/quoted/empty literal-key parity. Foreign native runtimes and physical
  input are unexecuted. This conflict slice does not fix control-character key
  encoding, pending live-source projection or cross-flush session accounting.
  Preserve both language packs and principal notification/HTTP assertions. No
  collector, Reader, shared helper, raw event, timing, schema, configuration,
  menu, reserved implementation or foreign driver change.

- [~] **L141.** Linux live ngram source projection: use the delivered shared
  source-membership predicate and subtract each source's own flushed snapshot
  before summing its positive pending contribution into the other bucket.
  Preserve logical, hotstring and LLM deltas, raw events, flush receipts, timing,
  producer admission and persistence. Public software output, real private
  SQLite and range/dashboard requests reproduce seven failures among fifteen
  before, then all pass after on LuaJIT, Lua 5.4 and the signed Jammy luv/libuv
  mixed profile. Known-source/manual controls remain healthy; repeated reads
  retain exact pending counts without flushing the durable database. Twelve
  additive registered units reproduce seven failures before and pass after;
  preserve the complete old31208-byte owner and all45 old subjects. The root
  complete owner explicitly requires57 subjects and passes on all three
  profiles. Caller-supplied API timestamps are software inputs; no mocked clock
  or physical clipboard/input validation is claimed. The shared predicate owns
  label membership; native source maps/deltas remain the Linux implementation.
  Foreign source inspection establishes supported string taxonomy only, without
  native Windows/macOS validation. The separate delivered Writer conflict fix
  retains persisted labels; this slice covers pending projection. Register the
  future CI commands without launching workflows. Preserve both language packs
  and principal notification/HTTP assertions. No Writer, Reader, input hook,
  schema, source-count admission, session cursor, configuration, menu, foreign
  driver or reserved implementation change.

- [~] **L142.** Linux literal ngram source keys: use the existing shared JSON
  encoder for each admitted source label instead of escaping quotation marks
  alone. Preserve count admission, flooring, SQL escaping, the delivered numeric
  map conflict accumulator and every scalar. Actual public synthetic output and
  native SQLite reproduce five failures among fifteen independent readonly
  Python checks before, then all pass after on LuaJIT, Lua 5.4 and the signed
  Jammy luv/libuv mixed profile. Each profile runs one actual native producer
  successfully and one fifteen-subject oracle; these are not two test suites.
  Backslash, newline, tab and carriage-return labels remain literal; quoted
  Unicode, ordinary labels, raw tagged events, manual attribution and character
  totals provide healthy controls. Production SQLite3.46.1 writes the database;
  Python SQLite3.53.1 validates it independently. Eight additive registered units
  reproduce five failures before and pass after; preserve the complete old
  41826-byte Writer owner and its104 subjects. The complete112-subject owner
  passes on all three profiles. Unit SQL receipts are modeled, while the public
  producer uses real native libraries and storage; no physical input validation
  is claimed. Windows/macOS source inspection finds existing full JSON encoders
  on insertion, without native validation or a claim about macOS conflict-key
  parity. Register both future Linux CI commands without launching workflows.
  Preserve both language packs and principal notification/HTTP assertions. No
  collector, Reader, count policy, schema, raw timing, session cursor, menu,
  configuration, foreign driver or reserved implementation change.

- [~] **L143.** Linux canonical backspace unigrams: retain each correction
  marker through the existing Walker accumulator, with its actual delay and
  manual, hotstring or LLM source. The common metrics UI and both foreign
  drivers already retain this token; this slice covers unigrams only. Preserve
  correction errors, cascades, recovery, sequence breaks, raw events and scalar
  character totals. Actual public software events, native clocks and SQLite
  reproduce five failures among fourteen checks before, then all pass after on
  LuaJIT, Lua 5.4 and the signed Jammy luv/libuv mixed profile. Independent
  readonly Python checks reproduce two failures among eight, then all pass.
  Four additive registered units reproduce three failures before and pass
  after; preserve the complete old Walker owner and its45 subjects. All49 owner
  subjects pass on every profile. Controls cover source attribution, an actual
  forty-millisecond manual delay, literal four-codepoint "[BS]" text, dashboard
  and filtered Reader projection, unchanged scalar counts and idempotent flush.
  Unit events are modeled; production collector, clocks and storage are native.
  No physical keyboard or foreign native runtime validation is claimed. Broader
  backspace bigrams/trigrams and existing corpus differences remain outside this
  slice. Register future Linux CI commands without launching workflows. Preserve
  both language packs and principal notification/HTTP assertions. No input hook,
  schema, source-count policy, configuration, menu or reserved implementation
  change.

- [~] **L144.** Linux system-day restart retention: hydrate the sampler's
  cumulative row for its exact database, device and calendar day before the
  first sample. Preserve replacement/idempotence semantics and reset previous
  process clocks and sensor transitions. A checked Writer read distinguishes
  accepted absence from refusal; failed reads publish no writable zero day and
  remain retryable. Rebinding the same database preserves the live day, while
  changed database/device/day identities load their own row. Actual public
  collector and SQLite in two separate native processes reproduce three
  history-loss failures; a genuine thirty-second monotonic interval is retained
  after restart on LuaJIT, Lua 5.4 and the signed Jammy mixed profile. Each profile
  preserves two first-process controls and changes twelve restart checks from
  ten failures to zero; seven baseline failures cover the newly introduced
  checked-loader API, not seven further old data-loss bugs. Complete sampler25
  and Writer122 owners change ten failures each to zero, retaining all old
  assertions. The truthful in-memory Writer model and its23-case protocol owner
  remain explicit software tests, with detached rows and owned identity checks.
  Supplied sensor history, reset seams and the next-date adapter are modeled;
  clocks, native processes, library calls and SQLite refusal/recovery are real.
  No physical sensor, keyboard, systemd or foreign runtime claim. Foreign source
  inspection finds additive system deltas on macOS and additive/SQL-rebuilt
  system fields on Windows, rather than this Linux cumulative zero overwrite.
  Register future native Linux CI commands without launching workflows. Preserve
  both language packs and principal notification/HTTP assertions. No schema,
  raw-event, menu, title, configuration or reserved implementation change.

- [~] **L145.** Linux ngram group refusal atomicity: reuse the existing checked
  batch transaction for the single multirow upsert. Actual SQLite RAISE(FAIL)
  previously retained earlier additive token updates and trigger effects despite
  a false receipt; a later retry duplicated those earlier contributions. Preserve
  the native bail/connection settlement and helper body, literal source encoder,
  source-map merging, count admission and scalar fields. Each LuaJIT, Lua 5.4 and
  signed Jammy mixed profile runs one successful native Writer producer and one
  independent readonly Python oracle: eight checks with four failures before,
  then eight passes after. These are not two eight-subject suites. Refusal at the
  first token preserves counts but leaves a trigger effect; refusal at the last
  token additionally retains an earlier update. Both become unchanged rows and
  zero effects, followed by exactly-once healthy retry. ABORT and untriggered
  controls retain all scalar and known/arbitrary source values. Two registered
  units reproduce one failure before and pass after; the entire old122-subject
  Writer prefix and assertions remain intact, and all124 subjects pass on every
  profile. Unit CLI receipts are simulated; native processes, triggers, files and
  SQLite reads/writes are real. No physical input or foreign native validation.
  Foreign source inspection finds outer aggregate transactions/rollback paths,
  without claiming every foreign caller's FAIL behavior. This slice does not
  implement a collector derived retry queue, raw replay, session cursor changes,
  whole-flush atomicity or post-COMMIT lost-receipt recovery. Register future
  Linux CI commands without launching workflows. Preserve both language packs
  and principal notification/HTTP assertions. No schema, configuration, menu,
  foreign source or reserved implementation change.

- [~] **5.** Complete W1 neutral configuration and recommended/clear scopes.
  Qualify the implemented macOS/Linux Hotstrings and TapHold owners and the
  global composition, including its Script participant. Keep unknown fields,
  verified backups, exact runtime
  acknowledgement, external-write conflict detection and retryable rollback.
  Recommended delay values must match effective runtime inheritance for the
  currently published feature catalogue. The retired `autocorrection.caps`
  namespace is obsolete source data, preserved until explicit cleanup; it is
  not a current recommendation target. Do not assume deletion implements the
  recommendation.

  The Windows cold-start fixture includes the genuine parameter-status loader
  before feature state, matching the real entry-point dependency order. The
  original late Script publication assertion is retained. Terminal manual run
  37573751428 qualifies published source `7596cf86` on CI `0ab3d7e3`, with the
  same complete tree `3a9baf94` and no diagnostic overlay: native units execute
  all 10,100 planned assertions with zero failures, including the original
  Script case and include-order regression. Engine E2E, packaging, fresh-clone
  and compiled startup, compiled programmable admission, install/launch and
  mandatory verdicts pass. Release is skipped; macOS/Linux are unselected.
  Separate version-to-version compiled upgrade and physical acceptance remain
  unqualified. This current Windows receipt does not complete item 5 or replace
  the source-specific older failures below.
  At published `409b8ee0`, manual all-OS run 37476981548 is still in progress:
  Windows lifecycle capture fails with ENOBUFS before the full native suite;
  its engine E2E/package/install are skipped. macOS packaging has actual Sparkle
  server-retirement, Homebrew owned AppleEvent receiver and global-switcher
  failures. They require source/runner follow-up, not invented device-only
  closure; physical acceptance is unexecuted. Keep exact dated CI receipts.

  The three Linux scope fixtures now require raw object identity for the native
  luv issuer: five custody assertions use `rawequal` and each fixture rejects
  the actual native table's detached clone. All registered cases, timer/GC/close
  assertions and restoration remain unchanged; focused native tests pass 108/0
  on both LuaJIT and Lua 5.4. The current four distribution artifacts stopped
  at the same first-module custody assertion (22/1); actual Alpine constants
  include NaN, so the old recursive comparison can reject even the same table.
  This is not evidence of the earlier baseline's missing-luv cause. The
  local checkpoint for published source `30500346` passes selected
  verification with exit0: Linux 10,133/0 and JavaScript 363/0, using the
  admitted private writable temporary directory. The later terminal S1
  manual run 37491143093 tests `6bf86bfc` from source `aa70bebf`, same tree
  `135f3667`. Arch, Fedora and openSUSE each execute 433 modules with
  10,133/0; Alpine executes 433 modules with 10,120/13. Actual Alpine native
  diagnosis reproduces all 13 signed-zero fixture failures: the numeric
  request literal normalizes to positive zero before the writer. Genuine
  runtime negative-zero requests retain their sign through the unchanged
  parser/writer (13/0 independent native controls); this evidence does not
  justify a production correction. Debian executes no native suite: compiler
  linking fails on missing `Scrt1.o`/`crti.o` from the libc6 development
  prerequisite. S1 Windows units give 10,033/2, with two unsettled native
  screen-brightness worker cases. S1 excludes the later Extension/db31 tree;
  it does not qualify those changes, all distributions or complete TODO5.
  The earlier `409b8ee0` observation above was recorded before run 37476981548
  completed: its terminal result is failure, with Release / Publish skipped.
  Main Linux unit/E2E gates passed, while Arch/Fedora/openSUSE/Alpine stopped at
  that custody assertion; macOS native packaging failures remain recorded.
  The published Windows capture successor `109736e5` is now qualified by
  terminal successful manual run 37482352928, tested `458e9cb1` on the same
  source tree `61bf069d`: Windows units 10,032/0, engine E2E, package and
  install/launch pass. Release / Publish is skipped; physical acceptance is
  unexecuted. This dated Windows receipt does not qualify other OS lanes or
  complete TODO5.

  Hotstrings: Linux
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

  2026-10-04 candidate: the Linux Tap-Hold scope retains refused compensation
  for the navigation layer it imported, including strict native removal and
  parameter-fence release receipts. Its primary runtime/file inverse settles
  before layer removal; later requests cannot replace the indebted owner, and
  valid external edits survive exact-source cleanup. The shared layer helper
  refuses unreadable sources instead of treating them as foreign edits.
  All 14 original registered
  cases remain unchanged; 34 added real-file cases give original 15/33 and
  corrected 48/0 on LuaJIT and Lua5.4, including shared-participant global
  recommendation/clear refusal and rejected apply-time fence release before
  advancing to another category. Selected local verification passed 356 JS
  checks, 13,886 portable macOS and 6,554 Linux unit cases, plus both driver E2E
  suites. Hosted native and physical-device qualification remain pending.

  The macOS recommended Tap-Hold scope now retains its exact layers.toml
  import in the remap bulk journal: backup precedes import, inverse cleanup must
  be acknowledged before regeneration, and failed cleanup remains retryable.
  The global participant retains the successful scope receipt and restores that
  sibling on a later category refusal; a failed parent inverse restores its own
  removed import before compiling the pre-inverse settings. Observed source changes
  refuse cleanup; conditional unlink now shares the native cooperative lease.
  Native recovery alone cannot acknowledge the parent's
  still-owed inverse. Portable actual-owner tests control filesystem, Karabiner
  and later-category boundaries; they do not qualify physical macOS input.
  Full native units, E2E, packaging, installation and real-device validation
  remain required with the final shared layer-removal prerequisite.

  Conditional macOS removal now rechecks exact source bytes and the resolved
  route while holding the canonical writer lease. A refused unlock or close
  retains its exact cleanup capability in the layer, generic scope transaction
  and remap cohort; neither absence nor a no-effect inverse can acknowledge
  release debt. Existing assertions remain intact, and real-file cooperating
  writer, refusal and final-parent regressions fail against the original owners.
  An editor ignoring the advisory lease can still replace a path between source
  comparison and unlink. Full selected and hosted native qualification remain
  required; this bounded correction does not complete item 5.

The macOS bulk remap journal now owns the exact private Config publication
receipt, including a published write whose native cleanup refused. Forward
cleanup must settle before any file/runtime inverse, and refused inverse
publication or layer-removal cleanup retains its original capability. A
completed removal cannot remove a successor again; the private bulk Config
inverse additionally verifies current absence before acknowledging restoration.
Shared scope transactions preserve their existing generic removal contract and
settle exact forward/inverse cleanup before releasing verified backups. Explicit
whole-file reset can restore its original malformed source bytes without
granting ordinary malformed-file write authority. Independent actual-file
boundary controls reproduce the old false acknowledgement and preserve all
original assertions. The reset fixture now observes the actual conditional
publisher and additionally requires the exact malformed-source precondition;
all its prior assertion predicates remain intact. A wrong-source mutant fails
the new independent fence check. Selected local gates pass formatting, 357 JS
checks, 14,226 portable macOS and 6,760 Linux unit cases, plus 101 macOS E2E
checks with one host-specific skip and 188 Linux E2E checks. Hosted native
qualification remains pending. The separately reviewed lifecycle consumers
are applied below; detached semantic-source admission remains separate. TODO5
is partial.

The macOS scalar setters and detached recommendation saves now retain the actual
private file receipt when a refused save published or still owes cleanup. Retry
settles that exact owner before another mutation or initialization, without
regenerating a detached runtime. Activation and deactivation retain file debt
inside their existing native transitions: STOPPED must be proven before an
aborted enable restores its source, while a refused disable inverse must settle
before READY restoration. The existing two-return ports retain their previous
contracts. Startup captures migration/default-publication cleanup before native
lease/runtime construction, preserving both phase-specific save calls and all
seven existing literal-false init exits. Pending startup cleanup blocks another
init; settled retry rereads current source. These capabilities are process-local,
not a journal surviving VM exit. Independent controls pass 170 setter cases,
13 enabled cases and 211 composed startup cases; original owners fail the new
native-file boundaries. Selected local gates pass formatting, 357 JS checks,
14,253 portable macOS unit cases and 101 macOS E2E checks with one host-specific
skip. Hosted native/package/install and physical/global acceptance remain
required. TODO5 stays partial.

The native Linux metrics prerequisite now decodes the existing SQLite exit
receipt before its instrumentation counts JSON rows, then returns the complete
original output to production admission. It retains every old assertion and
adds missing/failed/malformed receipt and malformed JSON controls plus an actual
failed native SELECT. The untouched dev fixture fails before this correction;
independent real SQLite replays pass with 648 grouped versus 2,808 raw rows.
This restores validation coverage, not a new metrics feature or TODO5 completion.

The Linux public Tap-Hold scope regression now records and strictly removes only
its own acknowledged backup publications, without an undeclared LuaFileSystem
dependency. The unchanged functional assertions passed before the CI fixture's
cleanup failed: the original case gives 47/1 without lfs, while the corrected
module passes 48/0 both with and without lfs and with the real libuv adapter.
Runtime scope ownership and cleanup requirements are unchanged.

Linux native CI prerequisites now give the disposable SQLite account an owned
home beneath /tmp, rather than an inaccessible runner-private parent; a refused
chdir also stops before executing from the caller's checkout. CI installs the
required xdotool before the AT-SPI interpreter fixture. The upstream diagnostic
run37243988109 reproduces existing native E2E failures, including the inaccessible
SQLite profile. Other hosted native failures remain under investigation with
their Linux owners; local native replays do not replace the failed hosted verdict.

Windows workstation handoff (maintainer instruction, 2026-10-04):

- [ ] On Windows, replay the registered neutral/recommended/clear scope and global composition cases with the pinned native runtime. Check verified backups, exact runtime acknowledgement, stale-source refusal and retryable rollback.
- [ ] On a disposable Windows profile, exercise category/global Clear and Restore, restart, preserve unknown/outdated entries and verify the effective recommended delays. Record physical keyboard results separately from unit/E2E results.

Partial dev handoff (2026-10-05): complete the remaining global cohort and
publication/rollback owners in code before device acceptance. On Windows,
replay fresh/existing/moved folder recommendation and clear with exact backups,
strict external-write refusal, restart and actual input; retain items 16/38.

Current global composition now retains its exact admitted participant cohort,
including refused finalization. Linux Shortcuts, Hotstrings, Metrics and AI
scope owners keep the actual file/runtime claims through compensation; an
acknowledged sibling release is reacquired before a retained rollback may run.
Retry settles only the outstanding phase and does not repeat accepted inverses
or overwrite successor runtime owners. Independent focused contracts pass;
current full selected and hosted qualification are recorded separately. Direct
Script participation is now implemented on Linux/macOS through the shared
planner, live logger/locale/error owners and acknowledged native settings
receipts. Initial same-threshold successor defects refuse through raw parent
identity fences. Final composed, installed and device acceptance remain open.

The current macOS/Linux Script settings cohort owns only declared string and
Boolean aliases. Linux source-span publication preserves unowned future JSON
numeric tokens through apply, clear, ordinary foreign updates, exact backup
and inverse; it does not require whole-document re-encoding. Private actual
Linux owner replay passes seven selected cases on each of Lua 5.4 and LuaJIT,
with four independent complete Decimal/TOML image checks. This is bounded
source evidence, not a full unit/native-suite completion claim. Unsafe numeric
values captured into the generic owned settings inverse still refuse strictly;
future numeric-owned aliases need an explicit snapshot contract. Portable
replay does not prove actual Hammerspoon SDK/storage or atomic cross-process
publication. TODO5 remains partial.

The Linux formatting corpus now owns a private instance of the actual shared logger. The existing native shutdown owner retains its live suppression debt; every corpus assertion remains strict. Current and incoming-dev causal cohorts reproduce the old fixture failure, and isolated replay preserves the live singleton and its pending lines. This is validation isolation, not a global-reset behavior change.

The existing installed-Hammerspoon supplementary owner now requires a complete actual Script participant publication and inverse after an otherwise successful Karabiner launch scenario. The smoke measures native void set, exact readback and Boolean clear through nonce-only aliases and a private TOML source; runtime locale, logger and error-dialog views must restore. Original launch failures and strict retirement remain authoritative. Portable bootstrap and receipt tests cannot qualify actual SDK execution; final macOS CI is required.

The existing before-package native Canvas gate now requires the same actual Hammerspoon Script SDK and inverse measurement through a private diagnostic source layout. It starts only after the original Canvas process owner settles and reuses the strict native bootstrap, source hashes and retirement receipts. All original Canvas assertions remain. This makes actual SDK execution possible despite independent Sparkle/Brew package failures, but cannot qualify an installed release application; manual macOS CI remains required.

Actual Windows CI exposed two fixture premises in the new semantic snapshot controls: a stale caps raw-row lookup despite a names source, and an applied-record count omitting the independently supplied trigger. The successor retains all other assertions, checks the real trigger positively and expects both valid records. Native Windows execution remains required; no production loader or retirement policy changes.

The canonical JSON codec now offers private strict root-object source receipts and explicit root-member splicing. It retains unowned numeric/container tokens, escaped identities and source trivia without whole-document encoding, and reparses the complete candidate. All122 prior corpus behaviors and registered test prefixes remain unchanged; independent Linux33/0 and macOS25/0 pass on both runtimes, while actual whole-encode controls fail12 cases. This is a pure source primitive: it grants no file liveness or publication authority, and native owned/ordinary Storage adoption remains necessary before the conservative numeric boundary can be lifted.

Windows semantic publication meta controls now follow the actual strict full-save and claimed cleanup gateways. The historical29 callers are independently audited:27 unchanged, two migrated. Coverage expands to28 public plus8 private gateways, retaining the separate private8 guard and distinguishing Map preparation receipts from Boolean publication. Exact binding/order/Integer acknowledgement and causal suffix-renaming controls preserve prior safety predicates. Portable63 source predicates pass; native AHK rerun remains required.

The Windows semantic configuration builder now prunes only empty implicit ancestors of explicit deletions, while retaining source-owned explicit headers, sealed inline containers, populated siblings and update-owned Maps. The generic setter, physical renderer, strict whole-document readback, source fences and backup/publication owners remain unchanged. Fourteen handwritten registered builder/writer subjects retain the entire earlier test prefix; independent tomllib57/0 reproduces eight old expected-model mismatches. Actual AHK and old-native inverse execution remain required; this does not yet attribute the previously observed native cleanup failures.

Linux storage now publishes held projections and ordinary set/set_many/delete/clear requests through authentic shared JSON source spans, preserving unowned raw numeric tokens, order and container kinds. The actual native writer remains the owner; stale terminal/cleanup debt cannot acknowledge a foreign successor. Read recovery is fenced throughout active claims and initialization reentry, while ordinary unclaimed recovery remains available. Independent focused suites pass136/0 on Lua5.4 and LuaJIT, including actual native fault and foreign-source probes. Unsafe values inside captured owned projections still refuse conservatively; no exact floating-point cache or cross-process atomic-CAS guarantee is claimed. Final selected container/native CI and installed acceptance remain separately required.

The Windows semantic builder now retains unowned inline member order, raw tokens and trivia while changing or deleting only owned descendants. This addresses the exact source-image discrepancy observed in native diagnostic failure2; whole-cell explicit updates keep canonical serialization. The strict canonical lexical owner also supplies semantic inline splitting, including the independently authored triple-literal case. Final whole-document typed readback, source/publication fences and backup owners are unchanged. Independent109 plus20 portable/source predicates and the unchanged canonical syntax/loop guards pass; all28 new AHK cases and two original-production-route causal controls remain pending actual native CI.

Root dotted scalar settings now retain their exact requested finite value through the actual shared writer and native preference publication. Independent full-image and restart checks cover precision and source preservation. Header numeric publication is covered by the later finite-scalar corrective slice; broader scope/catalogue and installed-device acceptance are still open.

The first owned Linux storage publication now prepares the configuration directory through the existing quoted shell owner. Fresh user homes reproduce and fix the two actual configuration restore failures. Directory acknowledgement, source bytes and producer/file callbacks are revalidated before spending the write receipt or staging a backup; reread-time callback withdrawals refuse without publication and remain retryable. Native real-file regressions pass on LuaJIT and Lua 5.4. Packaging, installation and installed-device acceptance remain separate checks.

The Windows fresh-bootstrap control now reads the real autocorrection names record at its parent section and asserts its complete three-child shape, refusing the unrelated flattened-section lookup. Float timing, obsolete scalar, future data and read-only assertions are retained. This repairs the fixture consumer; native snapshot publication and fresh process qualification still require Windows CI.

Shared shortcut scope planning now filters only proved neutral deletions beneath an obsolete scalar/array parent. Requested nondelete, ancestor and whole-parent replacements refuse before native IO or runtime changes. Ordinary saves keep obsolete source values until explicit cleanup. Portable current-owner controls preserve all original ordinary-save assertions; physical device and native runner acceptance remain pending.

Windows scopes classify a freshly captured strict source through the existing canonical decoder and obsolete-key owner, then admit only neutral deletion intents beneath proved obsolete scalar/array parents. Nonneutral or ancestor collisions refuse before backup/runtime publication. The candidate is built from the same captured source through existing build-only admission, drift and late session fences. Eighteen registered native controls retain the original full test prefix; native execution is pending.

- [~] **7.** Complete W2: seven-page first-run opt-in wizard, per-category
  recommended choices, consistent WebView behavior and genuine translations in
  21 locales. Current source implements the seven-page declaration, native
  chosen-folder writers and rerun preservation. Remaining acceptance includes
  the installed fresh/existing/moved-folder wizard and actual trigger/runtime
  restart on each OS; portable or historical CI alone does not complete it.
  The tap-holds page lists each engine's recommended keys from the
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
  re-run of the wizard on each OS (Windows was verified by CI only), and final
  qualification of Linux trigger selection. The shared declaration now filters
  common-character presets to Windows/macOS; Linux offers its accepted ★ preset
  and custom symbols through the existing rare-symbol validator. The answer
  planner refuses unsafe or malformed values with existing translated reasons
  before language/folder preferences, destination preparation or configuration
  writes, retaining the wizard for retry. Handwritten page/projection checks and
  twenty real Linux bridge cases cover refusal, retry, sparse saves, future
  neighbors, fresh runtime reads and wizard re-run. Existing outdated trigger
  records are preserved without an explicit trigger choice; touching the
  Hotstrings question or receiving an old-folder callback grants no replacement
  intent. A changed folder retires prior values and choices immediately; feature
  navigation and Finish wait for an exact successful read response, while Back
  and same-folder retry stay available. Handwritten page cases prove missing,
  stale, malformed and duplicate replies cannot reuse old-folder intent. The
  macOS publication uses the shared JSON codec to preserve empty value maps as
  objects at the native LuaSkin boundary, including initial and changed folders.
  The original source fails all twenty new native cases. Selected local gates
  passed 356 JS checks, 13,958 portable macOS and 6,586 Linux unit cases,
  101 macOS E2E checks (one host-specific scenario skipped) and 188 Linux E2E
  checks. Actual X11 GTK/WebKit2GTK probes passed the seven-page round trip,
  delayed folder response, refused concurrent-source save with retry, and
  untouched obsolete-trigger preservation (24/28/29/33 checks). These probes
  use real DOM, native bridge and file publication; the restart port is an
  observer, not a restarted daemon. Hosted native qualification, physical input,
  Wayland and physical-device wizard re-runs remain pending.

The detached macOS recommendation owner now binds its candidate to optional raw
path/status/bytes returned by the same Config read that admitted the model.
A personalized source replacing neutral admitted bytes before backup refuses
without publishing over the successor. Backup/publication retain their existing
classified source and exact conditional-writer fences; no disconnected reread
manufactures model authority. Existing return values and custom two-return
producers retain their prior contracts. Independent controls pass 266 composed
owner cases; the same nine new cases give original 5/4 and corrected 9/0.
An independent real-file A/B source race gives original 54/1 and corrected 55/0.
The evidence covers path/raw bytes, not cross-read inode/symlink ABA identity.
Selected final-source local gates pass formatting, 357 JS checks, 14,262
portable macOS unit cases and 101 macOS E2E checks with one host-specific skip.
Hosted native/package/install qualification and physical wizard re-runs remain
open. TODO7 stays partial.

Windows workstation handoff (maintainer instruction, 2026-10-04):

- [ ] On Windows, exercise all seven wizard pages, cancellation, Finish/restart/rerun, changed-folder reads, delayed/stale responses and explicit trigger choices on a disposable profile. Preserve untouched obsolete trigger values.
- [ ] Check actual WebView/native bridge rendering and persistence; report the exact tested SHA and pass/fail/not-executed cases. Native CI alone does not complete physical acceptance.

Partial dev handoff (2026-10-05): actual virtual X11 wizard probes are
qualified separately. Installed Windows and macOS wizard reruns, restart and
physical input remain device acceptance; work-machine logs/screenshots need
not be exported. Follow PARTIAL-DELIVERY.md and record the exact artifact.

The shared Lua wizard planner now uses the canonical strict UTF-8 owner for
single-character answers. Overlong encodings, surrogate values and values above
U+10FFFF refuse before writes on macOS, while valid BMP/non-BMP symbols and the
existing Linux rare-symbol policy retain their previous behavior. Independent
actual-catalogue controls pass on both Lua runtimes; this source qualification
does not establish native WebView transport or installed-device acceptance.

The wizard WAL control now observes the current terminal-bundle token that owns the actual candidate path during hand-off, with exact token identity and unrelated-path refusal checks. It retains the ordinary Busy=false contract for an active terminal bundle and all original wizard assertions. Native Windows execution and real first-run device acceptance remain pending.

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

Windows PC acceptance, delegated to the maintainer:

1. Record the tested commit, Windows 10/11 build, monitor scale and layout.
2. Open prediction and hotstring tooltips, then close/reopen and move them
   near each screen edge. Verify the pooled border remains above the content,
   corners have no white pixels, and redraw/reuse does not leave stale rings.
3. Repeat at the available DPI scales on both Windows versions. Keep screenshots
   and exact reproduction steps for any deviation; remove item 19 only after
   visual acceptance. The integrated rendering fix must not be repeated without
   a demonstrated regression.

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
  listed; see `docs/memory/text-input-and-config.md`. Current source already
  admits known expert `[script]`/`[features]` values through their published
  owners, preserves obsolete scalar user-model and section-order rows, and
  checks gesture action-parameter bindings against each driver's complete
  native gesture inventory. The Lua keyboard owners now publish both logical
  identities and the complete 1,536 physical identities from the actual private
  registry, with current source and owner checks. Cold or partial publication
  remains unjudged; Windows keyboard and other binding owners remain pending.
  Plain-string
  remap bindings are warned, read as neutral and preserved during unrelated
  saves; requested replacement still requires explicit source repair. Linux
  layers.toml boot isolation and obsolete installed-layout entry partitioning
  are implemented. Remaining software includes complete Windows keyboard
  parameter-binding publication from its actual input owner (coordinate groups
  3/7), macOS aggregate Hotstrings category/section/order authority (group 2),
  Linux dynamic model publication (group 4), and other unfinished binding owners.
  API-provider publication is implemented. The historical review sites
  14/93, 19, 24, 26, 28 and Windows 32, 34, 36, 37-60 still require exact current
  owner audits before their closure can be claimed. Native Windows execution,
  Linux layers.toml startup, Hammerspoon and installed three-OS qualification
  remain separate acceptance work. The macOS unread-entry scan is deferred
  off the boot critical path; its native main-thread cost still needs measurement.
  The Lua configuration lifecycle now admits ordinary writes, onboarding,
  scope operations, removals and hydration through its private source/schema
  journal and the genuine initializer-issued native port identities. Future
  or invalid schema metadata refuses before registry reads, backup and runtime
  effects; source classification remains available for strict initial boot.
  Withdrawn, copied or replaced native ports cannot borrow configuration
  authority. Registered causal controls preserve all original assertions;
  Windows, native Hammerspoon and final installed qualification remain separate.
  Maintainer decisions are resolved: invalid schema stamps retain strict boot
  and session-write refusal (site 108); retired keys reported for explicit
  cleanup are exempt from automatic deletion migrations and remain on disk
  until that cleanup (site 112).

  Linux and macOS filesystem modules now expose their genuine initializer
  identity and seven original function or nil identities through a pure tuple.
  Existing I/O, acknowledgement and lock bodies remain byte-exact. The consuming
  closed schema/session fences and native qualification remain pending.

  Carried Script action parameters are now judged again by the existing genuine
  publication on every late read on Windows, macOS and Linux. A proved retired
  value is neutral and reported once; the raw source and inverse snapshot remain.
  The macOS ordinary save preserves unchanged Script fragments, including an
  obsolete inline neighbor, and refuses changed retired values or publication
  withdrawal before native replacement or unchanged acknowledgement. Actual
  supported portable owning cases pass 184/0 on macOS and 190/0 on both Linux
  runtimes; genuine old getter and save implementations reproduce the failures.
  The registered Windows compiled-owner case, actual Hammerspoon and final
  three-OS installed qualification remain pending. This is a bounded Script
  completion; the other publication authorities listed above remain software work.

  The integration with current physical shortcuts preserves obsolete parents
  and releases or reacquires only the exact retained writer cohort. Independent
  unchanged physical scope cases pass 27/0 on macOS Lua 5.4 and 35/0 on both
  Linux runtimes, against original failures of 25/2 and 23/12 respectively.
  Final composed-source CI and native installed acceptance remain pending.

  Windows tap_hold.toml now reports each obsolete entry once per exact file,
  rendered path and reason during the process, through the shared warning
  owner. Repeated real reads retain valid bindings and preserve unknown
  scalars, arrays and inline tables byte-for-byte. Known-field ERROR/refusal
  behavior is unchanged. An independent twelve-observation corpus runs on
  all three drivers; portable unit/E2E checks pass. Logger callbacks retain
  their caller's Critical state and reentry observes the claimed report.
  Native Windows and complete three-OS acceptance remain pending.

Native Linux qualification fixtures now observe real Notify wire byte hints
and exact owned service identities, preserving the text/history assertions on
Dunst 1.9 and newer versions. The failed HTTP 503 unchanged-validator control
explicitly returns the previous ETag, retaining every corrupt-body/follow-up
assertion across curl versions. Independent old/new native replays pass; hosted
final-source qualification remains pending. These are fixture prerequisites,
not completion of the remaining configuration policy or physical acceptance.

Linux native fixture prerequisites now qualify the real GTK launcher in the
same private X11/D-Bus session before starting each unchanged application-action
deadline. Application-catalogue isolation retains actual compiled GSettings
schemas; setup and functional receipts have distinct identities. Independent
actual launches pass 4/4; a simulated native cold-start delay is explicitly
separate from the unproven hosted timeout cause. The failed-HTTP ETag control
now compares exact bytes from an independent direct same-binary curl oracle,
retaining all seven functional cache/conditional-request/recovery cases across
curl versions. Hosted Linux E2E, packaging and installation must still finish.

The macOS qualification fixtures now restore the transitive strict UTF-8 owner
and decode the standard JSON backspace/form-feed escapes in their independent
Hammerspoon stub. The original twelve hosted failures are reproduced and
corrected without changing production, corpus expectations or assertions.
Full selected verification and hosted qualification are recorded separately;
these fixture repairs do not complete TODO33 or device acceptance.

The Hammerspoon JSON fixture now admits LuaJIT's single numeric model without
calling absent Lua 5.3 numeric-kind APIs. Independent number, exponent and
array/object interning controls retain the native LuaSkin value contract and
all prior assertions. Both focused runtimes pass; the complete portable macOS
suite passes 14,667 cases. This is test-runtime qualification; actual hosted
Hammerspoon and installed-device behavior remain separately required.

Windows configuration qualification now seeds the four actual section metadata
values before testing their preservation, refusing missing seed anchors. The
semantic snapshot loader no longer incidentally primes the separate raw cache;
the dynamic publication fixture now establishes that cache precondition
explicitly. All 151/203 original assertions remain, including pending source,
refusal, pause and master-state checks. Both are fixture-only changes; native
Windows CI and conflict-preserving composition with current Hotstrings remain
required, without expanding group1 into Hotstrings feature implementation.

Linux ordinary TapHold saves and recommended imports now use the existing shared classified reader: only native ENOENT permits an absent document; access, other open, read and close failures refuse before mutation, backup/staging/publication or reload. Malformed-source behavior and unknown fields remain unchanged. The registered real-writer module retains all 26 original cases and adds 13 controls: the original writer gives 28 passes / 11 failures, the corrected writer 39 / 0. macOS and Windows already refuse classified unreadable sources through their existing owners. Full selected verification and hosted native CI remain pending; TODO33 stays partial.

The Linux TapHold owner now ignores and reports obsolete scalar/array parents and
known bindings once, preserving their values during unrelated saves and scope
clear. Colliding setters and recommendation imports refuse before publication
until explicit source repair. Optional canonical parser receipts retain array
shapes and unchanged numeric tokens without changing default codec APIs or
independent corpus expectations. Reload success requires explicit true; refused
or raised acknowledgements report saved-but-not-in-force rather than inventing
an inverse of the published preferences. The reviewed shared scope additions are
composed with the existing publication-recovery owners. The explicit Linux
runner manifest retains every prior module and registers all three new modules.
Selected local gates pass formatting, 357 JS checks, 14,226 portable macOS and
6,853 Linux unit cases, macOS E2E101 with one host-specific skip and Linux
E2E188. Hosted native/package/install and physical qualification remain
required; TODO33 stays partial.

The Linux daemon now isolates only the existing shared loader’s classified whole-file layers.toml refusals during its initial tap-hold engine load. It logs the refused navigation file, leaves its bytes untouched and installs the independently valid tap-holds with an empty navigation layer, matching the existing Windows and macOS boot policy. Shared registry and native compilation failures still raise; every subsequent reload and scope candidate remains strict and retains the acknowledged engine on refusal. The registered real-manager regressions fail five cases against the original owner and pass all ten after the fix; all 29 existing hook/manager/writer integration cases pass with LuaJIT. This is bounded portable owner evidence, not physical Linux startup or complete three-OS acceptance. Full selected verification and hosted native qualification remain required, and TODO33 stays partial.

After the classified-read prerequisite, Linux TapHold ordinary setters and recommended imports now require an acknowledged temporary-file write and close before rename or reload. Genuine LuaJIT/Lua5.1 Boolean true and Lua5.4 same-file write receipts are both accepted; nil, false, wrong objects/strings and exceptions refuse. Refused candidates are cleaned only at the owned temporary path; cleanup refusal still leaves the original source and runtime untouched. Unknown fields and existing post-publication reload semantics are preserved. All 39 prior registered cases remain exact; 13 added controls give old 40 passes / 12 failures and corrected 52 / 0 on both Lua runtimes. Windows and macOS already require their native staging writer acknowledgements. Full selected/hosted native qualification remains pending; TODO33 stays partial.

The Linux hotstring editor now reads one classified save-time source snapshot, validates those exact bytes with the canonical TOML codec, and requires the hotstring projection’s explicit commit receipt before preserving tuning and replacing its owned model. Publication carries the existing exact-source precondition; malformed/unreadable sources and observed concurrent replacements refuse without reloading or reporting saved. The five old persistence cases, ten existing editor cases, twenty native-file admission cases, five deployed TOML dialects, and three causal mutations were checked privately. The independent 140-rule corpus is unchanged. This is a TODO33 preservation prerequisite; opening-time stale-page ownership, unknown fields/comments, other data-file writers, TODO104 fanout migration, and complete native/root CI remain open.

Shipped retirement-only migrations now advance the schema stamp without deleting
gestures.space_wrap, any retired AI trigger-shortcut spelling, or
shortcuts.keys.layer_scroll. Independent expected models retain each value and
its siblings, including a false shortcut, on all named drivers; the generic
delete interpreter contract is unchanged. ADR-009 records the explicit-cleanup
exception. Focused JS replay passes 72 cases / 174 driver replays and 37
registry defects; isolated shared Lua contracts pass 81 Linux-ID cases on
LuaJIT and 85 macOS-ID cases on Lua 5.4. The original registry fails five
macOS preservation vectors. Real-file shared boot, exact backup, restart and
ordinary-save preservation controls pass on both runtimes. Complete selected
verification, native Windows and native three-OS qualification remain required;
TODO33 stays partial.

The macOS config_karabiner.toml owner now preserves obsolete timing leaves and
an obsolete combination switch when an ordinary full-state save carries their
neutral runtime read results. Load and save classify them through the shared
warning owner, once per file/path/reason; unrelated binding edits keep the old
leaf models and foreign neighbors. A carried non-neutral value is not proof of
an explicit repair: that candidate still refuses with its exact file/path,
without publication. Manual repair permits a later retry; explicit leaf-intent
plumbing remains open. All 22 prior selected cases remain unchanged; fourteen
new real-file controls give original 24/12 and corrected 36/0 on Lua5.4,
including stale external edits, the existing source fence and malformed-file
refusal. Portable LuaJIT execution is unavailable because the existing macOS
harness requires table.pack; no shim was added. Selected root gates passed
356 JS checks, 13,972 portable macOS unit cases and 101 macOS E2E checks
(one host-specific scenario skipped). Hosted native macOS E2E/package/install
qualification and the separate scalar-binding parent refusal remain pending.
This bounded preservation change does not complete 33.

The macOS remap owner preserves a known unusable tap-hold scalar when an
unrelated full-state save carries only its neutral slots. Load and save share
one precise per-file warning identity; non-neutral binding or timeout candidates
still refuse with their exact path before publication, until explicit file
repair. Supported legacy combo strings and all existing typed-parent refusal
assertions remain unchanged. Nine new real-file controls give the composed
predecessor 1/8 and corrected 9/0 on Lua5.4; forty-one unchanged focused cases
also pass. This slice preserves scalar models and foreign fields through the
existing whole-document serializer, not arbitrary lexical formatting/comments.
Selected local gates passed 356 JS checks, 13,981 portable macOS unit cases
and 101 macOS E2E checks (one host-specific scenario skipped). Hosted native
qualification and broader binding-parent/repair-intent work remain pending;
TODO33 is not complete.

The macOS ordinary remap saver now preserves unchanged source numeric kinds,
precision, signed zero, temporal values and complete arrays through optional
canonical full-document receipts. Default codec APIs and independent corpora
remain unchanged. Same-read array identities also distinguish obsolete arrays
at native tap-hold/combination dictionaries and known bindings: runtime reads
are neutral with one precise warning, unrelated saves retain their complete
original values, and colliding candidates refuse before publication until
explicit source repair. Unsafe Karabiner array parents retain the existing
strict consent refusal. Historical scalar-parent refusals and every corruption
fixture predicate remain intact. Independently reviewed real-file and Python
typed-model controls reproduce predecessor loss and pass on the candidate;
selected root verification passes 14,339 portable macOS and 6,878 Linux unit
cases, plus 101 macOS and 188 Linux E2E checks with one macOS host-specific
skip. The shared test helper retains every predicate while using the codec's
existing optional math subtype alias; 25 focused cases pass on each Lua runtime,
and its covering JS repair passes all 357 checks.
Hosted native/package/install qualification remains pending. This bounded
correction does not complete TODO33 or explicit cleanup and repair-intent
ownership.

Two independent actual-file diagnostics still fail on Linux's retired API
provider reader and ordinary selection publisher: a removed provider remains
active, and its complete old row gains defaults during a successful neighbor
selection. Current native source hashes match the saved preparation. Coordinate
explicit published cloud/local catalogue receipts with group4 before changing
those native seams; empty or unavailable catalogue data cannot prove retirement.
The frozen probe and exact dependency evidence are in the group1 handoff's
`prepared/retired-api-provider-dependency.zip`. No source correction or native
qualification is claimed for this open domain; TODO33 stays partial.

The shared Lua installed-layout record owner now preserves omitted unowned
members during verified same-id updates while removing omitted publisher-owned
metadata, including an old extension replaced by a base layout. Verified
incoming fields take precedence; obsolete predecessors contribute no ignored
data. Invalid optional extensions are classified before root discovery through
the existing published validator, with lossless object/array/null admission.
Their complete rows remain on disk beside usable neighbors, and ordinary
install/remove operations do not grant native deletion authority over them.
Independent full-model vectors and real-file manager controls pass 98 macOS
and 88 Linux focused cases on each available Lua runtime. All previous
registered cases and corpus expectations remain intact. Selected executable
local gates pass formatting, 357 JS checks, 14,202 portable macOS and 6,758
Linux unit cases, plus 101 macOS and 188 Linux E2E checks; one macOS
host-specific scenario is skipped. The selected AHK unit gate is not executed
on this Linux host and remains a Windows workstation step. Hosted
native/package/install qualification remains pending; TODO33 stays partial.

The macOS remap owner now ignores and warns once about the retired
`[karabiner] enabled` entry while preserving its complete original value in
ordinary saves and explicit integration-consent changes. Only
`integration_enabled` grants consent; explicit whole-file reset retains its
existing authority. Independent real-file controls cover Boolean, numeric,
string, array and nested-table values, stale sources, invalid consent and
publication refusal. The old deletion expectation conflicted with the
maintainer's explicit preservation policy: its replacement requires the exact
original false value and an additional complete handwritten source model;
every other old assertion remains intact. Focused portable checks pass 32 new
cases and 31 existing owner cases. Selected local gates pass formatting, 357
JS checks, 14,149 portable macOS unit cases and 101 macOS E2E checks with one
host-specific skip. Hosted native/package/install checks remain pending;
TODO33 stays partial.

A bounded Windows installed-layout record candidate partitions obsolete entries
from usable neighbors and routes process-lifetime warnings through the shared
file-entry reporter. A narrow native JSON member-span owner preserves obsolete
Boolean/null/number spellings, future record members and unchanged valid entry
values while install/uninstall retain their current native owners. Original
syntax/header refusal assertions remain; independent native source/receipt,
warning-once, install/uninstall and public span regressions are registered but
not executed in this Linux container. Case-sensitive record-member exclusions
preserve future `Layouts`/`SCHEMA_VERSION` siblings; handwritten native controls
cover ordinary save, in-place updates and explicit obsolete-id replacement.
Programmatic NUL-containing path segments refuse before native Map lookup,
without borrowing a truncated prefix or exposing source data. Eight new native
cases retain all earlier assertions and corpus bytes. The new refusal-loop
callbacks bind each source explicitly so unrelated unset-variable errors cannot
satisfy their assertions. Selected local verification passed formatting, 1,814
AHK BOM/LF files, all 356 JS checks, 13,981 portable macOS unit cases and
6,586 Linux unit cases. Windows native unit, compile and E2E were not executed
on this Linux host; native CI and packaging/installation remain required. Shared Lua
record writes still need qualification of top-level future fields and
default-decoder null/array identity; this prerequisite does not complete TODO33.

The frozen macOS Boolean-leaf packet is now applied to the current feature
source. Unusable tap_holds.enabled and mod_combos.symmetric values retain their
complete scalar, array or inline-table models during unrelated saves, with one
warning per file/path/reason. An implicit non-neutral replacement refuses before
publication until explicit source repair. All 28 independent real-file controls
pass; the exact source preimage matches the reviewed packet. Selected formatting,
356 JS checks, 14,030 portable macOS unit cases and macOS E2E (101 passed, one
host-specific skip) pass. Hosted native qualification remains required. This is
a bounded TODO33 correction, not completion of its remaining domains or physical
checks.

The frozen shared Lua installed-record packet is now applied after exact source
and test preimage checks. Installed-only lossless decoding preserves unknown root
members and obsolete rows, including JSON null, empty arrays, false and a source
member named outdated. Detached private source identity survives chained builders;
verified same-id replacement does not resurrect an ignored row on later removal.
Generic JSON decoding, Windows owners, syntax/header/schema refusals and native
artifact publication policies are unchanged. Current focused Mac catalogue and
manager cases and the Linux installed-record controls pass. Selected formatting,
356 JS checks, 14,044 portable macOS unit cases, 6,627 Linux unit cases and both
portable E2E suites pass. The corpus guard includes their actual shared replay
helpers; its assertions and every corpus expectation remain intact. The AHK
unit gate was not executed on this Linux host; hosted native qualification is
still required. Preserved future members on updates of already usable entries
and invalid extension classification are separate follow-ups. TODO33 remains
partial.

Windows workstation handoff (maintainer instruction, 2026-10-04):

- [ ] Run the native installed-record/member-span cases in test_layout_catalogue.ahk and test_json_object_key_nul.ahk: usable neighbors, warning-once, exact obsolete/future preservation, case identity, native NUL-path refusal, stale-source refusal and install/uninstall.
- [ ] Replay retired-key and invalid-schema cases in test_config_migrate.ahk and boot/write-fence tests; retain retired keys until explicit cleanup and keep invalid-stamp session refusal strict.
- [ ] Audit the remaining Windows configuration-reader domains already listed above; add causal regressions before changing them. Do not repeat completed features without evidence.

Completion continuation (2026-10-05): the reviewed retired API-provider
publication candidate is applied after all five source preimages match current
dev. Its single Linux test registration preserves every newer inventory entry.
Stored provider rows consume detached cloud/local publication receipts; missing,
empty or unacknowledged catalogues cannot prove retirement. Ordinary neighbor
writes preserve obsolete rows and future values, while explicit candidate
authentication retains its existing owner. Independent current-source focused
checks pass 168 LuaJIT and 140 Lua 5.4 cases, including 36 new cases per runtime
and both catalogue/store initialization orders. Selected local gates pass:
format, 359 JS checks, portable macOS unit/E2E, Linux E2E and actual Linux
HTTP-stream receipts. The first Linux unit run exposed two incomplete provider
receipt stubs; their assertions remain unchanged and the corrected unit rerun
passes all 7,841 tests. Native runner packaging/installation qualification remains
pending. Windows sites and remaining catalogues above still need implementation
and qualification, not only device UI; TODO33 remains partial.

Final partial integration `c8e4434a0` is tested by manual Windows run37287365425:
9,218 passed and 50 failed; incoming dev's native run37283538700 has 9,213/55
on the same 9,268-case census. Both failure sets include the six configuration
snapshot subjects and legacy Boolean admission. On Windows capture the complete
native result/execution manifest, reproduce these subjects with the explicit
personal-file activation owner, and coordinate the configuration/hotstrings
fixture and production boundaries with group2. Keep strict source fences and
obsolete-value preservation; do not remove assertions. Full failure annotations
are truncated; the exact known subjects and limits are in the current partial
delivery evidence. E2E/package/install remain skipped, not passed.

Additional native macOS source-policy controls preserve carried nonstring
combination leaves on unrelated saves and refuse requested replacement until
explicit repair. Known expert script logger thresholds and manifest-declared
feature values are admitted through their actual published catalogues; invalid
values remain unread, warned and byte-preserved. Metadata inspection is pure and
does not resolve a hardware backend. Deliberate arbitrary expert scalar fields
retain their existing API. These bounded slices do not complete the catalogue,
whole-file refusal, persisted-legacy-settings or native acceptance requirements.

The 2026-10-05 continuation preserves malformed shortcut-order source rows and source-proven empty arrays instead of treating them as valid maps. Requested replacement refuses until explicit repair; valid reorders and resets retain unrelated source kinds. The Windows known-feature fixtures now target the currently published `names` owner, keeping the removed `caps` namespace as a source-preservation/explicit-cleanup control. The changed-publication/restart timing remains an explicit nondefault Float (0.75), with the separate 0.5 default test retained. Focused portable checks and independent source review pass; final composed and hosted Windows qualification remain pending.

The declared macOS-only optional user-model list now reports obsolete scalar source once, keeps it outside runtime and unmarked for explicit cleanup, and preserves it during unrelated default-carried saves and published scope clear. A nonneutral replacement refuses before publication until explicit source repair. All original assertions remain; real typed-file oracles retain signed integers, precise floats, offset dates, literal dots and nested arrays. Linux has no supported owner for this leaf and preserves it; native Windows was inspected only. This bounded correction does not finish the remaining configuration catalogue.

Persisted macOS llm.enabled now uses the actual published feature value validator before cleanup and bootstrap. Obsolete native text/numbers/containers warn once and cannot supply consent; values and TOML remain untouched until explicit cleanup. Valid true/false precedence, independently valid canonical fallback and logger ERROR are preserved. Independent actual-owner/compiled-init controls pass67/0 versus exact predecessor44/23; all44 prior cases and their assertions remain byte-exact. Equivalent typed Windows/Linux seams were inspected without duplicate changes. Actual Hammerspoon and final source/installed qualification remain required.

Parameter-bearing gesture bindings now use a shared current/retired/unjudged identity policy against each actual complete native gesture catalogue. Windows, macOS and Linux loaders preserve but do not activate proven retired entries, warn once, and ordinary setters refuse them before publication; explicit cleanup remains the removal owner. Windows keeps case-distinct parameter Maps, including unjudged qualified identities. The independent29-case corpus and registered native regressions are retained; Windows native execution is still pending. Other keyboard, tap-hold, script and combination identity owners remain unjudged by this bounded cohort, so site76 and the whole item stay open. The actual gesture fixture now restores its new shared dependency through the existing exact owner scope. All old isolation assertions remain; original2/9 and corrected11/0 independently reproduce the prerequisite, including absent/false/existing owners and construction/callback failure.

The Windows finite-number gate now delegates its unchanged CRT ABI to a native adapter. The existing OS-call purity bound remains 252; the actual source census returns to 252 without raising it. The architecture graph was regenerated through its owner. AHK encoding and private-source JS checks pass; native Windows execution remains pending.

The Windows legacy gesture-snapshot fixture explicitly establishes its case-insensitive map before population and verifies that precondition. Its original final source-policy assertion and all independent case-twin/clone checks remain intact. No native gesture implementation or parameter retirement policy changes; native fixture execution remains pending.

Manual source54 CI exposed four genuine ordinary JSON Storage regressions on links to regular files. The released ordinary writer now uses its established qualified descriptor policy and replaces only the link inode, retaining exact target bytes. Private owned cohorts still refuse links. Each journal pins its own readback route; SourceV2 callback/source, reentry and pending-settlement fences remain intact. The unchanged native special-source fixture passes28/0 on both Lua engines, while the registered adapter module passes160/0 and independent read/close/rename refusal controls pass9/0. Actual final manual Linux CI and installed qualification remain separate; this correction does not close the remaining catalogue domains.

The script-chord parameter domain now consumes each native owner's complete published catalogue through the shared identity policy, alongside the previously qualified gesture domain. Read/close and current registered-owner receipts fence publication; Mac same-API replacements and equality spoofing cannot lend authority. Retired bindings warn once, stay neutral in runtime and remain source data until explicit cleanup; writes refuse before native IO or dispatch. Other/unpublished/missing catalogue domains remain unjudged. Registered source cohorts pass104/0 portable macOS and120/0 on both Linux engines, with genuine old-public-API causal failures and read/close refusal controls. All previous assertions and450 parent corpus files remain unchanged. Native Windows, final packaging/installation and the remaining dynamic parameter/provider/order domains remain separate. Four old Linux positive script subjects now use actual current script_altgr_enter rather than retired reload, preserving every prior predicate/value/full-source/report/mark/refusal/inverse assertion; genuine actual-publisher warm/cold controls and a current-versus-retired native case prove the corrected subject.

The failed native modifier-hold dashboard qualifier now loads canonical actual selection state and helper functions, preserving its editor subset and all original Writer/SQLite/Reader and displayed mean/maximum assertions. The unchanged old harness fails with a missing real helper after12 native and4 Apps checks; the corrected fixture passes all17 on LuaJIT and Lua5.4 against real private SQLite files. No dashboard/runtime/SQLite policy or original expected values change. This is software consumer qualification; physical typing, GUI and final CI remain separate.

macOS provider identities now require a complete same-read native publication and checked close/JSON shape. Malformed, unavailable, partial or changed sources stay unjudged; valid empty local publications remain distinct from unavailable providers. Existing cloud refusal and custom names retain their contracts. The final AI branch is already integrated; complete model-row/order ownership and installed Hammerspoon acceptance remain open.

Tap binding identities now come from complete actual native producer publications on all three drivers, retaining detached identity sets and unchanged boot ordering. Changed or withdrawn owners stay unjudged, retired getters read neutral, unrelated source bytes remain, and replacement refuses before native effects. Existing native callbacks and hotkey activation are preserved. Final AHK/native acceptance is still required.

One shared fixed-domain constructor registry pins the actual native Tap and Script publication accessors. Replaced, withdrawn, fake or re-registered producers return unjudged without invoking replacement getters. Genuine old-accessor controls fail the new public consumer assertions. Complete remaining domain publication and native installation qualification remain open.

macOS/Linux keyboard bindings now publish their actual complete contextual native inventory through the same authentic fixed-domain authority owner as Tap/Script. Unknown future data remain unjudged and source-preserved; obsolete known bindings read neutral and reject replacement before effects. Both Lua engines and genuine old-producer controls qualify the portable ownership contract. Windows keyboard catalogue publication remains explicit software work because its native four-group producer does not yet own the expanded chord domain.

The existing real Storage GC fixture now returns its allocation frame before the original two collections. A receipt remains rooted while the first collection must release its weak owner, then the original token retirement assertions run. The genuine strong-owner-box mutation fails on both Lua engines. No extra collection, timing waiver or production change is added; full final-source Linux qualification remains separate.

Archive-distro unit validation now provisions only measured LuaJIT/Python/curl requirements and verifies real luv/lfs ABI5.1 loading with candidates obtained from the canonical installer function. The unchanged full unit command runs as the ordinary CI user in an owned writable checkout copy. Actual Debian13 Docker execution passes9184/0 with the reviewed GC fixture; Fedora, Arch, Alpine and openSUSE remain unexecuted until manual CI. Existing --no-deps installation, release conditions and all other workflow fields remain unchanged. The earlier Arch first-install exit2 is still unclassified.

The current Windows native read/write-exclusion and foreign TOML record-parent fixes are composed with the configuration document owner. Canonical source-span arguments keep their original positions; the native container-stop argument is appended, with a registered fourteen-assert combined lexer regression. Native-reader child fixtures discover and copy complete genuine modules through canonical source ownership; all original sixty-nine assertions and child effects remain. Local selected encoding and361 JS checks pass; native Windows execution remains required.

The actual macOS saved-model reader admits only intrinsically valid nonempty string backend/name records. Ordinary edits, removal, clear and immediate inverse preserve invalid physical members and surviving unknown fields. Explicit cleanup uses source/file/ordinal-bound native receipts with raw token identity; custom names and backend identifiers remain valid. Independent owning84/0 and shared55/0 on both Lua engines pass, including genuine original producer failures and two physical forged-token refusals. Full final-source native qualification and the remaining configuration inventories remain separate.

The native callback error regression fixture now arms its same 5 ms continuation only after the first actual bad callback, preserving the original 30 ms watchdog and all nine assertions. A real 10 ms startup delay reproduces the original failure on Lua 5.4 and LuaJIT and passes the candidate. The full local Linux suite passes 9537/0; hosted packaging and installation still require the next exact-source manual CI.

Seven Windows failures exposed a typo in four new fixture subjects: the manifest owns layout.ergopti_alt_gr, not ergopti_altgr. The corrected subjects retain every original predicate and add an actual manifest assertion plus a native unknown-neighbor preservation case. Independent exact-source review passes; the 19 registered obsolete-scope cases require Windows CI before native qualification.

The Windows persistence census now audits the actual added scope build-only consumer, retaining the previous 36 consumers and requiring its captured-source, typed finalizer and status-before-target chain. The new closed census is 37 total / 9 internal, with executable-code offsets and genuine quoted-data counterexamples; no publisher assertion is relaxed. Actual Windows qualification remains pending.

The exact personal snapshot regression now selects its handwritten semantic fixture identity among the real initialized defaults. All original name/type/value/two-row assertions remain; genuine sibling, case-twin, descendant and literal-dot decoys are rejected. Actual Windows execution remains pending.

The Windows global-clear source comparison now reports both complete physical images with the existing canonical JSON encoder. Its equality predicate and all other assertions remain unchanged. Manual run37438495454 passed9949 Windows unit/meta cases and failed2, including this comparison; the precise source difference still requires the next native receipt. This diagnostic does not repair or close the remaining global transaction work.

The Windows whole-state save now captures and classifies its exact physical source before the collector runs. It uses the existing shared obsolete-parent policy for each ordered snapshot occurrence, preserving obsolete scalar/array parents and neutral descendants while allowing unrelated accepted changes. Every nonneutral collision refuses the entire request, including one followed by a neutral duplicate. Present invalid, Boolean, fractional, newer or explicitly older schema stamps refuse before collection; ordinary saving performs no migration, and genuinely unstamped sources retain the existing first-save contract. Exact source/presence CAS, strict Integer-1 acknowledgement, generation retry and the injected two-argument writer contract remain owned by their existing native boundaries. Nineteen appended registered native cases and the original-production inverse await Windows execution. Independent V2 source review passes; its complete publisher census remains37 with the single real full-save site moving from public to private (internal9→10). Scope duplicate rejection remains unchanged. All remaining global reset/runtime acknowledgement and complete binding-inventory requirements remain open.

Linux distribution qualification now retains the exact nonroot LuaJIT suite log and annotates the actual native summary and failures without deriving expected results. Both pipeline statuses are captured before reporting; a refused native suite remains failed even if diagnostics or artifact delivery also fail. The new install upload still runs after a failed suite and stops on cancellation, using !cancelled() explicitly in the existing conditional-step guard with seven added negative controls; mandatory success certificates remain separate. Fourteen independent parser controls and six real Bash status controls pass. Prior manual run37438495454 passed16/17 Linux installation scenarios, including Arch and Alpine first-install; the Alpine full native unit scenario failed with only a generic exit annotation. Its precise hosted cause and delivery of the new diagnostic artifact still require a subsequent run. Local signed official Alpine package requests are deniedHTTP403, a separate environment limitation.

The personal-editor source guard now reads the complete actual keymap module through the strict canonical recursive helper, retaining the existing absence and behavior assertions and rejecting empty or unreadable source. Fifteen actual source files participate instead of a location-pinned layout file. The unchanged owning ratchet independently refuses381 paths before this migration and accepts380 afterward against the same380 bound. No native runtime policy, foreign Windows implementation or ratchet assertion is changed. Native Windows execution remains required.

The actual Windows global-clear image from manual run37451318736 contains the five explicit off assignments required by shared policy, while retaining every obsolete/private source byte. Its handwritten full-image expectation now includes those assignments. All188 existing assertions, exact backup and inverse checks remain unchanged. Manual diagnostic run37456524038 passes this corrected native transaction and its retained subsequent assertions; final-source native qualification remains pending.

Manual run37451318736 reports9974 successful and16 failed Windows cases, including nine actual full-snapshot cases whose ordinary saves refuse. A fixture-only diagnostic now retains the genuine ConfigIO/TomlWrite logger, collector count and complete expected/actual physical images in the first annotation line. All574 measured textual assertions and expected outcomes remain unchanged; the exact prior logger sink is restored even on exceptions. Manual diagnostic run37456524038 locates all9 remaining errors inside the actual collector at an unassigned global. The subsequent genuine keyboard-default fixture prerequisite is recorded separately and must receive its own native qualification. No production guard or schema refusal is weakened.

The five Windows source guards still naming the former public two-argument full-save gateway now follow the actual captured-source native publisher. They retain path-bound ownership, source capture and classification before collection, exact physical content/presence arguments, no pre-write deletion and strict Integer-1 acknowledgement. Independently reproduced quoted/comment-only source-receipt and ACK mutants are rejected by executable-token checks;158 portable source predicates pass. These structural repairs preserve the safety assertions and do not identify or repair the separate actual ordinary-save refusal. Native AHK execution remains pending.

Successful native Script-storage finalization now detaches the owner from the retired Linux/macOS journal after all refusals and successful weak-tombstone construction. A real retained native journal and an observed publication closure expose the previous strong-owner edge. Exact source/backup, refused ownership, pending callbacks, allocation refusal, idempotence and old-token rejection remain covered. New authentic-journal cases fail against original production on both Lua runtimes; owning probes pass Linux161/0 and macOS models29/0. The entire old fixtures, including both GC calls, remain byte-identical prefixes. Quiet old and corrected hot runs can both pass; controlled instrumented trace observations are distinguished from hosted reproduction. Manual run37451318736 failed the owner-cycle case, and a new full native receipt is still required to prove this correction resolves its exact assertion.

Windows diagnostic run37456524038 resolves the five publisher source guards, global-clear expectation and native profile frame, with9982 passed and9 remaining full-snapshot failures. The genuine logger locates those failures inside the real collector with an unassigned global. The runner omits FeatureState initialization; the fixture now constructs the mandatory keyboard defaults from the exact native manifest projection and restores its prior value or unset state. All574 existing textual assertions and19 registrations are preserved, with one new real-default prerequisite assertion. Source review is clear; exact native replay remains pending and no production persistence guard is relaxed.

The shared AutoHotkey keyboard identity rule now matches the existing Lua policy and replays17 additive independent handwritten vectors. Native source admission rejects sparse arrays, named metadata and derived prototypes before accessors run; five registered Windows cases cover retirement, omission and callback-free refusal. Independent pure Lua replay passes83/0 on each runtime. This is preparatory policy only: no complete Windows catalogue, loader publication or late parameter getter is changed or claimed implemented. Actual native AHK qualification and coordinated action-owner integration remain required.

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
  the macOS clean-launch gate. Both Lua drivers now admit handwritten
  `[[hotstrings.terminators]]` records and expose Add/Delete/toggle through
  their source-fenced whole-list persistence owners. Restart, refusal and
  unowned-neighbor preservation have callable regression coverage. Changed
  lists normalize to inline TOML; standalone comments remain preserved.
  Windows currently consumes native delimiter strings rather than custom
  record lists; the missing record consumer/editor is an explicit PC
  implementation step below, alongside native qualification.

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

Windows-dependent acceptance is explicitly deferred to the maintainer PC. Complete the [Group 2 Windows continuation](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo34-delays-and-handwritten-delimiters) for this item; prepared sources and portable checks do not establish Windows runtime success.

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

Manual macOS run37604627108 at35ef2db8fb6d6b920d51ce6ec692e7f124ffe9e7
passes the real Sparkle cohort with exact XCTest completion: admitted resource
reads, independently valid foreign-key refusal, installed-key retry,
installation/relaunch and physical retirement. The original Sparkle-domain
assertion now requires exactly SUError.validationError3002. Core JS/properties,
macOS unit/stub E2E and native Canvas pass; overall package/verdict fail because
Brew remains blocked, installation is skipped, and Release / Publish is skipped.

Brew's deny-removal positive still fails at exit66, reply-10004 and missing
second marker. Its nonprompt permission query returns-1744,
errAEEventWouldRequireUserConsent. This proves a consent prerequisite for that
attempt, not the sole failure cause or successful automation. The current
fixture generates fresh signed sender/receiver identities and sends without
prompting; it supplies no demonstrated consent-grant path. Establish a supported
admission path for those exact owned identities before promising a personal-Mac
Automation grant. Terminal consent is not a proved remedy. Preserve both
positives, full-policy denial, all six Brew cases, original deadlines and
physical closure. Package/install and transversal16/38 remain pending;
item36 stays open.

Manual macOS run37588921661 at89085c46707aa9972c787affb0f4102a5c8fff68
confirms the fixture-key repair: four admitted resource reads, genuine
foreign-key refusal, and installed-key retry through installation/relaunch.
The exact wrong-key signature-code assertion still fails; actual bound callback
identities are not yet observed. A bounded diagnostic now projects only the
original refusal receipt into closed domain labels and signed codes, preserving
all138 original assertions and adding five direct Swift assertions.

Brew retains its original failed positive sender, exit66 and physical owner.
A nonprompt AppleEvent permission query now adds only a canonical signed status
to that failure. All67 original portable cases remain; five additive controls
pass in the72-case candidate and expose the unchanged predecessor. This does
not establish a permission cause or grant consent. Real native diagnostic
execution, full-policy denial, all six Brew cases and package/install remain
required; item36 stays open.

Manual macOS run 37581581322 tested exact candidate
6072016f31f78ab517c31ab4d5c00a6cdf865d42 and failed native archive acceptance.
Sparkle's original startup catch reports stage=native-start, domain=sparkle,
code=1 (the pinned Sparkle 2.9.2 missing-public-key error), with zero admitted
resource reads. The signed fixture used SUEdPublicKey; Sparkle reads
SUPublicEDKey. The one-key correction retains the original publicKey
expression, every native assertion, independent Ed25519 checks, typed failure
frame and physical retirement rules. Its additive normal source guard rejects
missing, legacy-spelled and null-valued fixture keys; qualification and the
corrected real native archive run remain pending.

Six native AppKit registration controls and unconfined AppleEvent delivery
completed before Brew's deny-removal positive failed with reply error -10004,
missing nonce reply -1701 and absent second marker. This does not establish TCC
or another permission cause. Full-policy denial and all six Brew archive
scenarios remain unrun. Package creation and installed launch checks were
skipped. Item 36 stays partial until the existing real archive, Brew and
package/install acceptance completes; no policy, deadline or ownership gate
is relaxed.

Native run 37525448527 on ad95a2693 confirms independent signature validity but
refuses Sparkle application retirement with exit 78. The added diagnostic reads
only the original cached capture and projects six closed refusal categories.
All original failure and retirement assertions remain; actual cause and the
corrected AppKit/Brew native acceptance require the next exact-source macOS CI.

The latest origin/dev AppKit receiver registration is merged with the retained
post-failure WNOWAIT observation and original typed GetCurrentProcess refusal.
Source controls preserve both histories; native acceptance remains pending.

The portable replacement-script fixture now retains its real shell parent
while that parent waits for its own unchanged sleeper. This avoids abandoning
a zombie beneath the actual validation subreaper. The exact producer is closed
before the four original result assertions; no production swap or signalling
policy changes. The complete focused installer module passes 20 tests with
zero failures. Full portable and native final-source qualification remain
separate requirements; item 36 stays open.

Brew sender refusal -600 remains unexplained; it identifies failed native
AppleEvent port discovery and does not establish target death or a permission
cause. One exact owned WNOWAIT observation after the failed sender is reused
without reaping, signalling or changing its original exception. Its fixed
notice reports only an observation state. All 53 original portable controls
remain and six new controls pass (59 total); the Homebrew source gate passes.
Actual positive delivery, sandbox denial, upgrade/install and native closure
still require successful macOS observations; item 36 stays partial.

Exact macOS run 37511777225 on fd107685ae2ff2cedbe8edb559a54b4886d0954b
observes matching-key cryptographic validity and identical copied payloads,
but independently generated signature bytes differ. The corrected oracle
requires actual matching-key validity, opposite-key refusal and rejection of
a one-bit payload change by both authentic signatures. Every remaining native
archive and installation assertion is preserved. The Sparkle source gate
passes; actual corrected macOS compilation/acceptance remains required.
Item 36 and transversal validation 16/38 remain open.

Exact macOS run 37494074376 on a96b224a676b8267e072069ed57c556a99623327
compiles the corrected imported Sparkle delegate. Core JavaScript/properties,
portable Hammerspoon unit/E2E and tooltip checks pass, but native packaging
fails: the official foreign-signature equality and application lifecycle
controls refuse, and Brew's unconfined positive sender reports -600/exit66.
Installation is skipped; publication is skipped. Added fixed signature and
cached application-exit facts preserve all original assertions and deadlines;
the guarded diagnostics expose only fixed cryptographic/payload booleans and
an already cached exit acknowledgement. Their source controls pass, but the
native observations still require actual macOS execution. The latest complete
Linux-host JavaScript gate passes 375 checks. Physical Sparkle/Brew acceptance
and transversal requirements 16/38 remain open; item 36 stays partial.

The private Sparkle fixture now binds its real numeric loopback socket without
the HTTP server's unrelated reverse-DNS lookup. Actual bind, assigned port,
listen refusal, cancellation and physical socket retirement remain required.
All 34 existing portable controls are retained; the five new actual-socket
controls bring the CPython 3.13/Linux result to 39 passed with no platform skips.
The hosted startup trace stopped before constructor completion; it does not
prove a DNS cause. Native Sparkle acceptance and Homebrew's AppleEvent boundary
still require successful macOS qualification, so item 36 stays partial.

Current-dev integration preserves both receiver-registration diagnostics and
the incoming native AppleEvent terminal receipt, from the same reserved
WNOWAIT observation. Both retain exact ownership and refusal; diagnostic
publication does not reap or signal the receiver. The merged portable fixture
contains 48 original controls; native Homebrew containment and Sparkle
acceptance still require successful macOS execution.

The Sparkle fixture now retains fixed, bounded startup milestones after the
exact server child has retired, before its capture descriptors close. Diagnostic
failure preserves the original operation or cancellation exception; deadlines,
native signals and archive assertions stay unchanged. The exact portable helper
and 34 controls passed on CPython 3.13/Linux; causal replay retained two failures
and two errors. These observations do not identify the native startup cause
or qualify Sparkle update acceptance; hosted macOS verification remains pending.

The Homebrew sender diagnostic now snapshots its private nonce-bound marker
through a retained descriptor at the existing reply-read refusal. The parent
admits this bounded observation only after exact sender retirement; unchanged
AppleEvent and containment controls still determine acceptance. Twelve actual
Linux filesystem cases and two close-refusal injections passed for the exact
native marker function. All 48 merged portable controls are preserved, with
four marker controls added. Darwin compilation, native AppleEvents and the
Homebrew archive lifecycle remain pending; no TCC cause is inferred.

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

The recovered public-archive cohort now signs and verifies both declared archives,
binds the preferred tar.xz appcast and Homebrew cask to retained exact bytes,
and verifies published assets through their REST digest. The CI-only bundle
snapshot remains separate from public release inputs. The pinned Sparkle tools
are available to native XCTest without exposing product signing keys on manual
runs. TIS diagnostic transport preserves the raw XCTest verdict and retains
its separately acknowledged session; both failures remain blocking.

Appcast publication dates now come from the acknowledged explicit source
revision rather than the clock. Five causal controls fail against the saved
candidate and pass with the repair; 26 callable publication cases pass. The
strict signing-step ownership and both XCTest/TIS status-order guards are
adapted without dropping key-exposure or failure-retention assertions. The
19 recovered preimages and candidate hashes match the historical review.
The recovered cohort passes 13879 portable Lua cases in 1483 modules; these
are driver tests on Linux, not native macOS archive acceptance. Formatting and
encoding gates pass, and all 356 JavaScript checks pass after repairing the
new Windows tests' loop capture and reserved parameter name. Actual Sparkle
update plus Homebrew ZIP-install/XZ-upgrade acceptance remain pending. Native
AHK and Swift gates are explicitly deferred to their respective runners.
Item 36 remains partial.

The registered native acceptance cohort now invokes the actual Sparkle updater
with a signed preferred archive, preserves the old bundle after a wrong-key
refusal and retries through its real installer/relaunch path. A separate native
fixture invokes the generated Homebrew cask for ZIP installation, XZ upgrade,
checksum/artifact refusal and recovery in an owned write sandbox. Two positive
AppleEvent controls must establish that the sandbox actually prevents foreign
application control before Brew is admitted.

The shared fixture process owner reserves a nonreaped leader through native
group census and retirement; cancellation keeps the ledger alive until cleanup
is acknowledged. Swift invokers retain failed fixtures and never destroy a live
ownership ledger. macOS Package now explicitly admits CPython 3.13 and the
actual waitid/WNOWAIT APIs before XCTest. Native runtime observations still
establish the physical behavior; API presence alone is not acceptance.

Twenty Brew and fifteen process-owner portable controls pass without skips,
along with four prerequisite controls, seven POSIX transport controls and the
26 publication cases. Actual Ruby parses both generated casks in this container.
Native Swift/C compilation, Sparkle installation/relaunch, AppleEvent sandbox
containment, real Brew lifecycle and the final packaging/install matrix remain
pending. These authored native tests do not close item 36.

Archive acceptance now exports bounded typed checkpoints before prerequisite
admission and during native cleanup, into one fresh CI-owned session. An
independent always-upload step retains only those JSON facts, including an
unclosed phase after interruption. Diagnostic refusal retains the private
fixture instead of deleting evidence. Seven additive Python controls and three
native Swift filesystem controls preserve all existing lifecycle assertions.
The Sparkle fixture consumes byte-identical appcasts from the real publication
CLI and official foreign/correct-key signing receipts; only its private signed
application routes the exact admitted enclosure to its owned local server.
Production TLS policy is unchanged. Final native compilation, generated-feed
delivery, archive lifecycles and the complete packaging/install verdict remain
required before removing item 36.

Actual macOS CI run 37242083827 refused the Brew sandbox profile before
containment: Seatbelt accepts the network address host `localhost` or `*`,
not the numeric host in `127.0.0.1:*`. The fixture now declares only
`localhost:*`; outbound denial, the native EPERM probe, write/symlink
containment, AppleEvent controls and ownership retirement remain unchanged.
The portable policy guard requires exactly one loopback outbound allowance
and rejects the unrestricted host. This grammar correction still requires
actual macOS requalification; the failed run does not qualify Brew install,
upgrade, refusal/retry or the final packaging/install matrix. Item 36 remains
partial.

Native Sparkle command refusals now retain fixed operation phases and a
bounded helper-PID/errno census diagnostic. No private child stream, signing
key, path or URL is published by this diagnostic. Census admission and every
existing native assertion and cleanup requirement are unchanged. The first
failed native operation and its actual cause still require the next macOS run.

Native run 37245029288 passes shared checks, macOS Lua units and stubbed E2E,
then refuses the actual Sparkle process census. Archive signing is not that
failed operation. The helper now adds bounded BSD snapshot facts using the
existing exact native layout; schema, byte count, PID/UID identity and errno
are checked before naming a state. A zombie snapshot is not retirement proof.
The validated summary reaches XCTest annotations instead of plain print-only
logs. All earlier controls and native ownership assertions remain intact;
actual Darwin ABI/permission observations and the update lifecycle remain
unqualified. Seventeen portable helper controls and six evidence-owner
assertions pass; they are not native Sparkle acceptance.

The same run passes Brew sandbox grammar, then refuses the AppleEvent probe's
compilation: RunApplicationEventLoop is a 32-bit-only Carbon API, and xcrun
attempts writes outside the already private TMPDIR. The C probe now uses the
documented 64-bit ReceiveNextEvent/AEProcessEvent/ReleaseEvent dispatch. Brew
selects the actual compiler, adjacent linker and macOS SDK read-only, with an
owned module-cache directory; sandbox allowances and the sender/nonce/reply
oracle are unchanged. All 122 previous Python assertion lines remain intact;
the original 27 controls and 30 candidate controls pass without skips. Actual
compiler/linker confinement, both positive AppleEvent sends, the denied send
and Brew install/upgrade/refusal/recovery still require macOS qualification.

Integrated manual run 37248612190 builds the release launcher and passes
macOS stubbed units/E2E, but refuses the actual Sparkle census and native
AppleEvent receiver liveness. The prior compiler boundary is passed; this
is not proof of successful AppleEvent containment or archive lifecycle.
No bounded census detail reaches the failure annotations in this run.
Swift failure evidence is retained; archive packaging and installation are
skipped, and publication is skipped. Keep item 36 open and preserve all
physical ownership and independent positive/negative assertions.

The AppleEvent liveness refusal now retains its existing exact nonreaping
observation: five fixed checkpoints, the acquired receiver PID, native
termination kind and numeric status. No new observation, polling, reaping,
signal, raw stream or allowance is added. All thirty previous test methods
and their 139 assertion calls remain byte-identical; thirty-one portable
controls pass, and the old generic helper fails all fifteen new numeric-fact
profiles. These diagnostic controls do not identify the native cause or
qualify AppleEvent delivery, Brew lifecycle or item 36.

Sparkle census failures before path observation now project only four fixed
stages through a strict schema: private-root, library, inventory or unexpected.
The original exception, native predicates and physical refusal are preserved;
unknown or malformed output emits a fixed diagnostic-unavailable XCTest failure.
No raw exception, process path, argv or key is exported. All seventeen prior
Python controls and existing Swift assertion lines are retained. Twenty
portable helper controls and ten focused evidence-owner assertions pass;
these diagnostics do not prove a native cause or qualify the archive lifecycle.

Manual macOS run 37252222886 tests 94924d9e8c7539944d6838da2306b21cf622eeca
and identifies the Sparkle census refusal at private-root admission. It does
not identify the rejected predicate or prove an archive/update lifecycle.
A bounded directory diagnostic now names only the first original metadata,
missing, absolute-path, directory-kind, mode, owner or canonical-path boundary.
The same single metadata snapshot and short-circuit predicates preserve their
order, original exception and refusal. No permission repair, PID exception or
raw metadata/path is added. All twenty prior Python controls and fifty-five
Swift assertion lines remain intact; twenty-three portable controls and twelve
annotation-owner checks pass. Native macOS directory facts and the full
Sparkle/Brew packaging/install cohort remain pending; item 36 stays open.

The same native run observes the exact AppleEvent receiver as CLD_EXITED,
status 65, at readiness before either positive delivery. Registration diagnostics
now distinguish only GetCurrentProcess from TransformProcessType and retain
its nonzero signed-int32 OSStatus. They read only the ledger-owned, bounded,
no-follow regular capture after that existing termination observation; unknown,
foreign or unsafe bytes omit facts. Both native status guards and exit 65,
all thirty-one previous test methods and 150 assertions remain unchanged.
Thirty-five portable controls pass without skips; the old helper fails the new
projection control. Native C registration, positive AppleEvent delivery,
sandbox containment and Brew install/upgrade remain pending; no runtime fix
or full item-36 qualification is claimed.

Native run 37259548678 confirms GetCurrentProcess succeeds and the disposable
receiver's UIElement transformation refuses with OSStatus -50 at readiness.
The receiver now requests the documented self UIElement/background-to-foreground
transition, without front activation or a window request. It may have a private
Dock presence; no invisible-registration claim is made. Both noErr/exit-65 guards,
the existing event loop/handlers, sandbox policy and two-positive/one-deny
requirements stay intact. All thirty-five Python controls and 175 assertion
calls remain byte-identical and pass; the source guard rejects the old target
and an independently injected front-activation call. Native registration,
delivery, containment, physical retirement and Brew lifecycle remain pending.

The same native run refuses the Sparkle census at its unchanged canonical
directory boundary; it does not identify the root/cache argument or prove a
permission failure. The fixture now retains POSIX directory spellings and
device/inode identity at acquisition, rechecks them before census, and refuses
replacement directories or final-component symlinks. It passes the retained
String without a Foundation URL round-trip. An independent native parent-alias
control requires the old argument to fail and the retained argument to pass the
unchanged Python admission, then requires replacements to fail. All existing
Swift assertions and executable-path comparisons remain intact. Swift
compilation, real census and complete update/install acceptance remain pending.

Native run 37263453529 passes shared checks and the macOS unit/stubbed E2E
prerequisites but fails Swift acceptance. Brew reaches the deny-removal positive
control: send status is zero but the unchanged reply oracle fails; the reply
read/length/nonce cause remains unknown. Sparkle reports server retirement
refusals; the runner's accepted-socket state and functional receipt are unknown.
The server now applies its existing five-second I/O timeout before the first
request/header read. Two independent real idle/partial-header cases exceed the
old seven-second retirement budget and pass with exact terminal/exit/socket
receipts after correction. All twenty-three original Python tests remain intact;
the candidate passes twenty-five with no skips. This proves the source bug, not
the unseen runner socket state. Complete native acceptance and downstream
packaging/install remain pending; no item is closed.

The native Brew sender now exposes only closed failure-phase, send/read status,
bounded reply length/match and an independently observed standard SInt32 target
error. Unavailable data remains unavailable; nonce, reply bytes and raw paths are
never projected. The unchanged nonce/denial predicates, sandbox and physical
retirement remain required. Independent source review approves the bounded
diagnostic; all thirty-five original Python cases and six new controls pass
without skips. The unchanged new failure-fact control fails on the original
generic helper. These facts do not correct or qualify the unseen native reply
failure; C compilation and complete native acceptance remain pending.

Manual macOS run [37267530410](https://github.com/adrienm7/ergopti/actions/runs/37267530410)
tests exact candidate `4d026ba9abbc8449d68f8be932f21a7e9cac6c0b` and finishes
with five successful jobs, three failed verdict/package jobs and four skipped
jobs. Shared checks and macOS stubbed units/E2E pass. The native Brew sender
compiles and reports send status zero, missing nonce reply (-1701), and the
independently read standard target error -10004 (errAEPrivilegeError) at the
deny-removal positive control. This does not establish TCC or Seatbelt as its
cause; full-policy denial and install/upgrade remain unqualified. Native keyboard
restore assertions also fail outside this group's scope. Sparkle's verdict is
unknown from the available annotations: the typed artifact download is refused,
and absence of an annotation cannot prove success. macOS install/launch and
Release are skipped. Item 36 and transversal requirements 16/38 remain open.

Versions installation now captures its original native recipient before
admission. macOS reads the actual script pause and pending-transition owners
again before installation or retry; a reentrant probe cannot borrow a successor.
Accepted installation still completes after later pause or window retirement.
Phase reports retain their original private recipient through JSON encoding and
queued publication. Twenty-one controlled native-port regressions pass while
the unchanged predecessor fails nineteen; all thirty-six original install,
delivery and retirement controls pass. The complete Linux-hosted Hammerspoon
suite passes 14,129 tests in 1,487 modules, and its E2E suite passes. These
controlled ports do not qualify physical macOS installation or close item 36.

Manual run 37309897244 at 055afc3f94377f119c8c1b589ef590b6d0295e11
finishes with six successful, five failed and five skipped jobs. Native Brew
still refuses its positive AppleEvent control with target error -10004;
Sparkle explicitly fails server retirement. Neither cause is proved, and
macOS packaging/install acceptance remains incomplete. The XCTest reporter
now emits closed per-case archive outcomes only from an authentic complete
transcript, independently of another test's failure. Its original suite
verdict and process exit remain unchanged. All 125 original reporter
assertions and 48 additional controls pass; the unchanged reporter fails
the new causal control. Actual native annotation transport remains pending.

Sparkle server-exit failures now report only fixed failure classes and native
termination facts already acknowledged by the process owner. The transparent
diagnostic rethrows the original error; all waits, signals, retirement checks
and original assertions remain intact. Fifty-three portable source/reporter
assertions pass, while the original source and four independent mutations
refuse. Manual macOS run37324525938 on c622e45d builds the release launcher,
while the complete Swift suite and both closed archive XCTest outcomes fail.
The server owner acknowledges a normal native exit with status1; Brew
receives target error -10004 through its acknowledged AppleEvent sender.
Packaging and installation are skipped after the test failure. These facts
do not establish the server exception or the AppleEvent policy cause.

The final reviewed diagnostic cohort passes all 379 JavaScript controls,
15,154 Hammerspoon stub units in 1,529 modules and 10,142 Linux units in
496 modules. Original59/current63 portable AppKit reader controls pass;
the new enum test against the original reader fails all three expected
subcases. These are receiving/source qualifications. Swift compilation, real
AppKit readiness and complete Sparkle/Brew native acceptance remain pending.

The existing Homebrew receiver readiness refusal now projects only the exact
AppKit producer enum1/2/3 from its bounded owned capture, separately from
Carbon OSStatus. Native run37540551778 at a5a07 observes CLD_EXITED/code1,
status65 before the sender; its AppKit reason remains unknown until the new
diagnostic is executed on macOS. All 59 portable control bodies remain intact
and four closed enum/refusal controls are added. This does not admit AppleEvent
delivery or qualify the native Brew archive lifecycle. Item36 remains open.

The Sparkle child target-root guard now uses native POSIX realpath strings
on both signed fixture admission and actual bundle comparison. Foundation URL
projection no longer supplies the identity string. Strict root equality,
private directory ownership, all 117 native assertion/failure lines and
resource retirement remain unchanged. Manual run37540551778 at a5a07
identified target-root/exit78; the reviewed correction still requires actual
macOS compilation and archive acceptance. Item36 stays partial.

The Sparkle server now receives the same retained physical directory path
as its census. Swift previously admitted a Foundation parent alias that
the unchanged Python canonical-path guard refused. All 25 original Python
control bodies remain intact; the additional actual alias-refusal and
physical-path serving/retirement control passes with the 26-case portable
transport suite. This corrects a proved composition gap without claiming
it caused the hosted exit. Native macOS compilation and complete archive
acceptance on this functional correction remain required.

Manual run 37430974838 tests exact candidate 54493dc2a on macOS and Linux.
Both closed native archive outcomes remain FAIL: Sparkle reaches server
retirement with deadline/terminal debt and acknowledged signal 15; Brew still
refuses the deny-removal positive control with target error -10004. These
facts do not prove their causes. Native archive packaging and installation
are skipped, and Release / Publish is skipped. Item 36 remains partial.

Portable Linux package sources now stage the genuine LuaJIT/luv, curl, GIO
proxy backends, compiled schemas and recursive ELF dependency closure.
Recipient certificate trust remains external. Flatpak builds six native
dependencies from independently pinned official sources inside its existing
SDK, without expanding its permissions. The qualified private source cohort
passes 70 portable controls, two actual kernel ownership controls and all
seven original staged AppDir native groups, including component refusal and
escaped-descendant timeout retirement. All seven projections are regenerated
with their canonical owner and match the qualified output hashes. The original
missing-kernel-children failure is retained; complete namespace-fenced PPID
census fixes that proved setup boundary without weakening retirement guards.
Normal JS and a mandatory separate native planner/CI gate are registered;
missing or duplicated native receipts cannot qualify a zero-exit producer.
Actual full-format AppImage/Flatpak builds, installation and PAC/session/TLS
delivery remain required. Staged AppDir acceptance does not complete item 36.

Retained archive descriptors now have a reviewed sealing and native SHA-256
prerequisite, with the original producer identity preserved through read,
context and timer retirement. An independent immutable source cohort passes
125 literal model controls on each Lua ABI and twelve actual Linux
LuaJIT/libuv/OpenSSL controls, including two independent NIST vectors over
unlinked files. This receipt does not prove archive publication, tar install,
rollback or installed package delivery; their original requirements remain.

Reviewed group6 sources, exact preimages and scoped qualifications are preserved
in the [restored-container checkpoint](handovers/2026-10-06-group6-recovery/README.md).
The ordinary Linux HTTP correction captures header metadata once before native
replacement, retains live boolean predecessors until physical retirement, and
preserves typed descriptor cancellation debt without altering failed-signal
behavior. Six new normal modules retain 48 independent controls; GET198 and all
existing fixture assertions remain intact. Final current-source verification
and hosted HTTP replays are required. Pending output-hop, fixture335 and four
body-pipe failures remain implementation work. The installed native archive/
update chain remains required; saved patches do not close this item.

Current native qualification on f346157c726b96e36f12701ea61b60be76e9e3e9
(run 37546410275) reports AppKit policy-refused before any sender and Sparkle
deadline(refused-1) after accepted startup/census. The corrected POSIX root
admission progressed; final Sparkle cleanup reported ownership_closed=true.
Neither result qualifies signature refusal, successful upgrade, or Homebrew.
An additive bounded AppKit diagnostic observes only fixed initial/after-NO
policy labels without relaxing admission. Portable receiving controls pass
all 63 original and all 67 current tests; the new positive projection against
the original helper fails its 16 subcases. Genuine policy-state observation
and the remaining native lifecycle/install scenarios are still required.

A reviewed additive Sparkle progress diagnostic uses only the existing
physically closed direct-child capture and authenticated server-retired
receipt. Fixed PID-bound milestones and the actual admitted resource-read
counter can locate the original refused-1 deadline without claiming response
delivery or update success. All 117 original Swift assertion/failure lines
remain exact and ordered; two new Swift receiving controls still require
genuine macOS compilation/execution. No deadline, signature expectation,
readiness predicate, installer authorization or cleanup law is relaxed.

Manual run 37551458196 on 67d563584b05426f2e2564b61cbbc1ddd61d6eb0
passes macOS portable unit/E2E/tooltip lanes but refuses native Sparkle test
compilation: the added progress enum used commas before subsequent case
declarations. The syntax-only correction removes 13 separators, retains all 42
event identifiers/values/order and every current Swift assertion, and adds
an independent source grammar guard. Actual corrected compilation and complete
AppKit/Sparkle/Homebrew acceptance remain required; this failed run supplied
no new policy-state or progress runtime observation.

Manual run 37556022981 at ece8de48 observes actual AppKit initial=accessory
and after-NO=accessory, yet refuses the unnecessary modifying setter. The
receiver now skips that setter only for an initially observed Accessory state
and requires a second fresh Accessory confirmation. Other initial states still
require a successful setter; nil and changed policy remain refused. The four
original native result controls remain and two same-state/change controls are
added with a strict six-control receipt. Native compilation, both positive
AppleEvent deliveries, full-policy denial and six Brew archive scenarios remain
required on these sources; the portable fixture is not real AppKit acceptance.

Corrected native Sparkle compilation in run 37556022981 reaches the actual
archive case but observes start-refused, zero admitted resource reads and the
original refused-1 deadline. Neither the missing unchecked progress marker nor
the plist proves whether native start or immediate policy validation failed.
The existing catch now emits only a fixed PID-bound stage and typed NSError
category/code into its original capture. The diagnostic reads that capture only
after physical retirement; all original admission, signature, update and cleanup
assertions remain mandatory. Its native compilation/receiving controls and the
actual refusal identity remain unexecuted until the next macOS validation.

Group 6 end-of-slice checklist, 2026-10-07. Item36 remains open. Source
checkpoint `e25d938f9c77f49295741b0ba2eb9d5988a965e9` preserves the delivered
archive, signature, native AppKit and bounded diagnostic changes. Historical
component receipts do not qualify the final integrated package/install matrix.
The [partial delivery handover](handovers/2026-10-04-parallel-containers/GROUP6-RELEASE-NETWORK-2026-10-07.md)
retains exact runs, source SHAs and continuation requirements.

- [x] Retain the delivered XZ/ZIP admission, wrong-key refusal/retry, signing
      identity, native ownership and physical-retirement assertions.
- [ ] Qualify the complete native macOS Package job on the final source:
      Sparkle install/refusal/retry/relaunch, both Brew positives, full-policy
      denial and all six Brew archive cases. Filtered Sparkle success does not
      qualify Brew or the complete package verdict.
- [ ] Establish any required Automation prerequisite for the same actual owned
      sender/receiver identities. Query -1744 proves a consent requirement for
      that query, not the sole cause of reply -10004 or a demonstrated grant.
- [ ] Complete all eleven CI installation legs on the same final source and
      retain exact passed/failed/skipped receipts. Keep independent items16/38
      and genuine device validation open.

The new group6 native-receiving source archive preserves the six exact Brew
preimages and public SDK contract audit. The unconfined positive already passes;
the sandboxed reply-10004 and separate query-1744 still need causal native
evidence. An interactive same-executable prerequisite is remaining CODE, with
real responsible identity/prompt/grant and its effect unmeasured. A public
permission call can block arbitrarily; the hosted runner cannot supply human
consent. The original positives, full denial, six Brew cases, clocks and physical
closure remain mandatory. This source audit does not close36 or16/38.

- [~] **37.** Always show the shipped Ergopti hotstring pack, including when
  its keyboard layout is not installed. Move French `suffixes_a` and magic-key
  `replace` into that extension without a beta compatibility layer. The runtime
  relocation and packaging inventories are prepared: all 24 French suffix
  rules and the existing 21 replacement descriptions remain unchanged.
  Actual metadata-only replacement remains selectable through its declared
  native feature owner. Shared bound-section policy owns extension bulk
  commands and preserves unrelated choices; native menus and preferences
  consume that policy. The old layout-menu replacement row and retired French source are removed.
  Mac portable units (13,891) and E2E (101), Linux E2E (188), shared JS
  checks (356), and focused selection/registry/menu tests pass. Linux units (6,505) also pass
  with real GUI dependencies and explicit negative GTK premises. Hosted macOS
  packaging/installation and deferred Windows acceptance remain required before removing this item. Preserve the real-device
  acceptance in item 38.
  The Linux native metrics prerequisite now counts only the JSON body after
  validating the terminal SQLite receipt. Real SQLite equivalence preserves
  nonempty projections and transports 648 grouped versus 2,808 raw rows;
  missing and nonzero native receipts are independently refused.
  Windows continuation is explicitly deferred to the maintainer's PC:
  - [ ] Run the actual AHK unit/meta and engine E2E suites on the integrated SHA,
        including extension, language-pack and category-scope cases; retain complete
        passed/failed/skipped results.
  - [ ] With no installed Ergopti layout, verify the shipped pack, all 24 suffix
        rules, metadata-only replacement and physical magic-key repeat/retirement.
        Check native bulk enable/disable, preserved unrelated choices, refusal and
        pause recovery, persistence and all 21 translated menu descriptions.
  - [ ] Build/install/upgrade/uninstall that same Windows source SHA without a
        release; verify both required extension TOML files, no retired French source
        fallback, no duplicate Layout row and preserved personal files/preferences.

Windows-dependent acceptance is explicitly deferred to the maintainer PC. Complete the [Group 2 Windows continuation](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo37-shipped-ergopti-sections) for this item; prepared sources and portable checks do not establish Windows runtime success.

The Linux E2E job now installs native LuaFileSystem before the unchanged scripted
keyboard harness. Manual run 37265099229 at CI head 0b8a57021 (the exact source
of feature c04072754) passed JS 358/0 and Linux units 6,892/0 but reproduced
22 magic-source failures in 188 E2E assertions. Its separate initial job had
neither LuaFileSystem nor libuv, so the shipped file could not establish native
identity and the bound replacement section stayed unavailable. An unchanged
physical-module control reproduces exactly 166/188 with neither provider and
passes 188/188 with actual LuaFileSystem alone; native libuv alone is also a
sufficient alternative. All 22 failure labels and expected/actual receipts
match hosted CI. Source bytes, admission policy and every assertion are unchanged.
The corrected hosted E2E job passes all 188 assertions in manual run
37266856722 at b85d3f6ad (tree-identical to feature 0649967ea). Core JS 358/0
and Linux units 6,892/0 also pass. This scripted replay does not establish
physical input, packaging, installation or deferred Windows acceptance. Native updater validator, audio-locale and notification failures,
and the macOS Homebrew/Sparkle archive acceptance failures, remain separately
owned blockers; their assertions and package/install requirements are retained.

Native Linux prerequisite follow-up: the unchanged audio fixture reproduces
six checks/four failures without actual PulseAudio gettext catalogs and six/zero
with the signed package's French/German catalogs. The Ubuntu runner now installs
both language packs. Dunst 1.9 history lacks urgency; fixture-owned native urgency
rules must provide a classified category receipt for every original notification
case, and a deliberately wrong native rule must be rejected. Neither product
adapters nor the existing literal-text/options assertions are weakened. Hosted
confirmation remains pending until the next exact-source manual run.

The E2E job also declares the existing driver/shared Lua namespace for native
Python children. Terminal manual run37274473330 proves seven newly adopted
controls otherwise fail at real app_dirs/json/logger imports; three more lack
xkbcli. Audio gives6/0 on each interpreter, notifications13/0 and unchanged
GTK4/4 on that runner. Source module imports and native compiler readiness are
runner prerequisites; those import/compiler assertions remain unchanged.
The distinct POST NUL-body failure is an obsolete fixture dispatch premise:
the published production owner already refuses these bytes synchronously. The
fixture now requires exact false, an immediate single failure callback and no
active/native request, keeping all seven cases and socket/cleanup assertions.
Actual Lua5.4 and LuaJIT each reproduce6/1 before correction and pass7/0 after.
The separate HTTP503 ETag control remains with the HTTP owner.

The subsequent native XKB controls adopted from dev now receive the actual
xkbcli compiler before their first execution. Their unchanged symbol-list,
key-definition and block fixtures pass64/0,72/0 and64/0 with the signed native
compiler; absence refuses the original admission. Manual run37274473330 confirms
the audio and notification corrections on Ubuntu while its remaining verdict
is still tracked separately. All three XKB fixture sources remain unchanged.

Composition with the partial configuration/menu delivery preserves both native
publication protocols: private hotstring receipts retain exact source identity
and native debt, while ordinary configuration inverses receive their exact
cleanup callback. Dynamic rollback also checks retained secondary-file debt.
The stronger typed D-Bus byte notification control keeps the independent wrong
urgency-rule negative. The new version-neutral HTTP503 E1 control is retained,
and the original changed-error ETag E2 stimulus is restored as a seventh case;
its canonical E1 assertion remains mandatory. Final composed gates and native
qualification are tracked separately; no lost stimulus is called unchanged.

The latest dev composition at a550193 preserves the configuration inverse and
private hotstring receipt protocols. Its selected local Linux suite passes7,805/0;
the twelve macOS portable failures reproduce the dev baseline. Three scenario
fixtures now explicitly own the strict UTF-8 shim they transitively import, and
the native JSON stub decodes standard backspace/form-feed escapes as bytes08/0C.
The production decoder, frozen corpus and every original cache-residue assertion
remain unchanged. Independent byte and literal-backslash controls distinguish the
old stub before correction; final full-suite and hosted receipts are separate.

The maintainer now explicitly requests delivery into dev after feasible container
and CI work, with genuine remaining native/device failures documented rather than
holding the feature indefinitely. Follow the [device/native continuation](handovers/2026-10-04-parallel-containers/GROUP2-DEVICE-TODO.md)
and the Windows checklist. Keep all five parent items partial; mandatory native
assertions and cross-cutting item38 remain required.

The [Group 2 integration checkpoint](handovers/2026-10-04-parallel-containers/GROUP2-INTEGRATION-STATUS.md)
records exact candidate/CI SHAs, passed/failed/skipped results and the remaining
native and Windows continuation. Final integration uses the owned empty-commit
lock and shared validation branch. The maintainer explicitly authorizes partial
delivery and feature deletion after the terminal integrated CI result, with
remaining failures and device acceptance preserved as concrete TODO steps.

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
  macOS conditional writes, unchanged acknowledgements and removals now
  support a captured strict final logical admission. The new APIs detach
  classified source scalars before native callbacks; refused operations
  preserve external successor bytes and existing release-only cleanup.
  The Lua closed-schema writer and scope consumers now use the private
  source/schema journal and initializer-issued native identities before
  acquired-source readers and native mutation. An initial invalid or newer
  schema remains readable only through its captured native source image; it
  grants no write, migration or scope-effect admission. Constructor source
  identity accepts genuine relative and absolute loader spellings while
  retaining the original native-owner checks. Retired-Script consumers and
  final-source native/installed qualification remain separate follow-ups.

  Current source implements the Windows typed dotted/inline document reader,
  targeted saves and full-state publication. The nineteen FullSnapshot cases
  passed natively in diagnostic run 37466163822 (feature `682d373e` plus one
  test); that historical tree does not qualify the published `409b8ee0` source.
  Final composed native/E2E/package/install/restart qualification remains open.
  Preserve obsolete scalars until explicit cleanup and strict invalid-schema
  and requested colliding-subtree refusals. Earlier reader/full-state status
  below is historical, superseded by current source implementation.

  an old build's scalar where a table is now expected (`magickey = true` under
  `[hotstrings.modules]`, `groups = "x"`) still makes a menu save fail with «
  the batch cannot address the destination without ambiguous TOML keys » —
  maintainer decision: preserve outdated scalars until explicit cleanup; an
  ordinary save must refuse a colliding new subtree without replacing them.
  The shared macOS/Linux decoder now resolves hand-written dotted assignments
  (`a.b = 1`) as semantic nested keys while quoted dots remain literal keys.
  Windows now reads typed document dotted keys and supports targeted semantic
  configuration saves; full-state publication was then a separate follow-up.
  Its inline-table reader also replays the common corpus.
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
  preservation policy is settled; at that historical checkpoint the Windows
  document dotted-key reader was still open.

The Windows configuration gateway and detached scope builder now use the
configuration-only semantic document transformation through the existing atomic
writer. Dotted/quoted paths, inline descendants, typed Boolean intent, array
owner generations and no-op comments retain their semantic/source identities.
Scalar/array collisions, duplicates and changed sources refuse publication;
ordinary writes never replace an outdated scalar with a new subtree. All prior
native assertions remain, with independently authored complete-image controls.
Local format, encoding and 359 JavaScript checks pass; actual AutoHotkey unit,
compile, E2E, packaging/installation and installed restart remain pending CI.
Full-state/onboarding/LLM publication stays explicit implementation work.

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

The maintainer resolved the scalar collision policy: obsolete entries remain
until explicit cleanup. Ordinary saves cannot replace an outdated scalar with a
new subtree. This decision preserves the existing strict batch-writer refusal;
it does not qualify the remaining Windows bootstrap or physical-source gaps.

The Windows bootstrap cache and feature owner now consume a configuration-only
semantic snapshot through the existing typed document reader. Root and section
relative dotted assignments and declared inline namespaces reach the native
section/key cache and feature records from the same admitted source generation.
Owned inline feature records merge through the existing child policies onto
detached seeded records, keeping unspecified defaults and exact outdated child
identities. Root presence belongs to the admitted read, so external deletion
cannot make the two boot consumers select different generations. Quoted literal dots, Unicode
case-distinct and empty names retain exact identities; dynamic personal names
keep their Boolean and timing domains independently of static manifest identity.
Nested native values are
independent between cache, retained source rows and each feature application.
Table-array members remain outside scalar settings instead of collapsing their
owner generations. Malformed semantic boot sources publish no partial cache or
feature state and retain session write protection after a later readable repair;
invalid/newer schema-stamp refusals remain owned by migration. Generic data-file
parsing and ordinary/detached writer admission keep their existing contracts.
Registered native cases include the unchanged independent dotted corpus with
handwritten complete cache goldens, actual child bootstrap readers, ordinary and
full-save no-op preservation, native read locks, stale-source publication and
version authority. Portable encoding, source registration, closure, startup,
coercion and convention checks do not qualify those native cases. Windows unit,
compile/startup, E2E, packaging and installation validation remains required;
item 42 and physical-source preservation stay partial. Selected local
verification passed formatting, all 356 JS checks and 1,815 AHK BOM/LF files;
native Windows unit, compile and E2E were not executed on this Linux host.

Windows workstation handoff (maintainer instruction, 2026-10-04):

- [ ] Replay the 30 new native semantic-snapshot cases through the real registered runners, including the unchanged dotted corpus, typed inline/default merges, exact quoted/empty identities, bootstrap, cache generation, source locks, stale-source/full-save behavior and invalid stamps.
- [ ] Compile the complete ErgoptiPlus.ahk include graph, then run Windows E2E, packaging and installation on the exact source SHA. Check real menu/full-save comment preservation; ordinary saves must refuse obsolete-scalar/new-subtree collisions until explicit cleanup.

Partial dev handoff (2026-10-05): implement and qualify Windows
document/config dotted assignments with independent expected models. Preserve
retired scalar collisions until explicit cleanup; ordinary saves must refuse
them. Installed-driver restart and actual menu persistence remain acceptance.

Ordinary Windows full-save, onboarding and AI configuration candidates now use
the same semantic-document writer as targeted configuration updates, preserving
root-dotted, quoted and inline source identities through the existing leases,
staging and durable receipt owners. Shared Lua leaf publication and explicit
unused-key cleanup retain authenticated source array/object kinds and opaque
scalar lexemes; stale or forged shape hints refuse. Native macOS custom wrap
choices publish through their canonical typed namespace and conditional writer,
including future pair metadata. All native Windows causal fixtures and final
packaging/install acceptance remain separately required.

The 2026-10-05 continuation adds source-bound explicit Windows cleanup of retired physical sections, including empty section headers, exact case identities and verified backup bytes. Ordinary full saves preserve retired entries. New Windows namespace publication now uses an explicit native-readable header only when the semantic parser admits that declaration after explicitly owned drops; closed dotted/inline owners keep their existing legal insertion route. Complete independently written images and actual flat-reader assertions cover first publication and explicit replacement. Native qualification is still in progress; unsupported retired dotted/inline/table-array cleanup projections remain implementation work.

Ordinary macOS snapshot and scope preparation now preserve an obsolete scalar at the optional user-model list. Neutral operations cannot silently delete it; nonneutral replacement refuses before source cleanup. Existing exact-source and typed-neighbor fences stay active.

Windows explicit cleanup now offers the complete retired ahk root in dotted assignments, inline roots and table-array generations. Its private native receipt binds exact record identity, fields and complete source; cloned, forged, mutated, stale, partial and consumed records refuse before publication. Existing backup, lease, typed document writer and host action-only authority remain intact. Twenty-one native regression cases are added; native Windows qualification is pending. Lua collectors still cannot offer these root forms, and retirement policy is not yet centralized, so this slice does not complete the cross-driver item.

The trusted macOS/Linux native cleanup owners now preview and explicitly remove wholly unread dotted, inline and table-array roots through authenticated source ranges. Generic source-only cleanup and ordinary writes retain their previous contracts. Private receipts bind exact record/source/path identity and recheck the actual unread collector before backup, after verified backup and before native conditional publication. Protected or partially consumed roots remain untouched; raw selection identity and plain-array admission refuse equality proxies. Independent actual private-file Linux67/0 passes both runtimes and controlled macOS82/0 passes Lua5.4; previous producers fail22 new cases. No retired-root catalogue is inferred, and quoted root assignments containing equals remain conservatively unavailable. Actual Hammerspoon, Windows and final native/installed qualification remain separate.

Native Windows diagnostics executed the complete root cleanup subjects but three shared neighbor checks used a comma expectation for an existing pipe-delimited diagnostic joiner. The successor additionally requires Array shape, length, Integer kinds and both original ordered values before the correct pipe expectation. Production cleanup and all other asserted neighbors remain unchanged. Source review is clear; actual Windows rerun remains required.

Explicit cleanup meta controls now inspect the authenticated RootReceipt through the actual private publisher and claimed ConfigCommitBuilt chain, retaining backup, exact-current-source and strict acknowledgement gates. Anchored lexical binding controls reject renamed unresolved Publisher/Writer/Receipt aliases. Native Windows execution is still required; no production cleanup rule or assertion was disabled.

Explicit Windows namespace deletion now normalizes its semantic expectation only for emptied implicit parents. Real retained header and inline-container identities are preserved, including quoted literal dots, empty quoted segments and case twins. Two independent source reviews pass57/0 portable predicates and preserve every old assertion; no-op checks measure exact source and modification time, not inode identity. Actual Windows syntax, all14 subjects and native cleanup causality remain pending.

The shared physical record scanner now reuses the existing strict quote-aware assignment splitter instead of taking the first equals sign inside quoted keys. Actual Linux cleanup admits the proven ahk root beside an unowned quoted key containing equals, verifies the exact backup and preserves the complete independently handwritten survivor, including empty-array kind. The original valid-source limitation fixture now has stronger identity/removal/backup predicates; malformed, forged and stale refusals and447 earlier corpora remain unchanged. Independent Linux201/0 on both number models and portable macOS222/0 reproduce18 predecessor failures; actual Hammerspoon and final selected/native CI remain separately required.

Windows inline descendant updates now preserve source-owned order and trivia instead of rebuilding the complete enclosing Map. Three obsolete normalization premises have independently handwritten source-fidelity expectations; all assertions remain, with exact reverse reconstruction and unchanged independent corpora. The new optional canonical lexical splitter is used only by semantic document admission; generic APIs retain their earlier bytes and behavior. Source review and canonical guards pass, but native AHK execution and the original-route causality probes are not yet claimed.

Both Lua drivers can now replace or explicitly remove an existing root dotted scalar through the shared strict source writer, preserving untouched bytes, comments and fresh-reload semantics. Native preference tests cover 17-digit precision and signed zero; nonfinite requests and inexact owned candidates refuse. Root inline tables, section-relative dotted writes and unrelated closed-shape literal-dot destinations remain explicit implementation gaps. This slice does not relax preservation of obsolete scalar parents or alter the default document encoder.

The actual Lua preference writer now preserves requested finite numeric header leaves with the existing optional precise-literal owner and rejects inexact owned readback before native publication. Authentic source literals retain precedence; nonnumeric/container handling, the default codec, backups and source/CAS permissions are unchanged. Native-file setter, full-image and fresh-reload controls cover 17-digit values and signed zero on both Lua drivers. Root inline-table and section-relative dotted write support remain implementation work; packaging and installed-device acceptance remain separate qualifications.

Two Windows cleanup controls now compare their complete handwritten case-sensitive identity sets independently of unspecified native Map enumeration order. Exact cardinality, duplicate refusal and unique semantic section markers strengthen the checks; all original key identities, backup, unknown-data and case-twin assertions remain. Production discovery and cleanup policies are unchanged. Actual Windows execution remains pending CI.

The shared writer now resolves root and section-relative dotted/inline scalar destinations through canonical source spans, including an absent bare inline member with an existing valid parent. Whole-image, typed intent, same-source backup/readback and finite-number admission retain refusal for collisions and ambiguous namespaces. LuaJIT explicitly refuses newly requested integers outside its exact integer range. The obsolete-parent preservation decision remains unchanged. Existing valid inline scope deletion is now checked positively; the original five refusal assertions retain a genuinely malformed duplicate-key subject. Native Windows and installed qualification remain separate.

Shortcut scopes preserve source-proven obsolete scalar/array parents rather than deleting them to create a current subtree. Explicit unsafe descendant replacement raises a retained-parent collision with no native IO. This does not complete the separate Windows full-state obsolete-parent refusal or case-sensitive boot-map work.

The real Windows recursive full-state collector now renders each semantic key segment with the canonical TOML key owner. Its configuration-only sparse adapter consumes the resulting exact semantic parts, preserving literal dots, empty/non-BMP keys and supplied case-sensitive map entries. Generic sparse API semantics remain unchanged. New registered actual-collector/full-save cases are appended; native execution is pending. Simultaneous case-twin boot maps and obsolete-parent full-state safe refusal remain separate software work.

Windows scope recommendation/clear preserves source-classified obsolete values until explicit cleanup, including new external-source and late schema-session refusals. This covers the detached scope owner, not the still-open whole-state obsolete-parent refusal or unclassified table-array boundaries.

Saved-model scalar edits and explicit intrinsic obsolete-record cleanup now use authenticated canonical inline-array/table-array physical row spans. Whole-source backup, native CAS, exact readback and refusal recovery remain authoritative; generic arrays do not gain record-list ownership. Ordinary saves keep opaque invalid members until explicit cleanup.

The reviewed signed-zero fixture correction (`493524db`, V2) changes only
13 request subjects in three test files. Actual Alpine LuaJIT turns the Lua
fixture literal `-0.0` into positive zero before the writer receives it;
`tonumber("-0.0")` now establishes the intended request, with numeric-type and
reciprocal-sign assertions before each producer call. All 382 original
assertions, expected source images, 465 corpora and production bytes remain
preserved; wrong positive-zero owned candidates still refuse acknowledgement.
Independent V2 focused replay passes 204/0 shared cases and 41/0 native
preference cases on each of actual Alpine LuaJIT, glibc LuaJIT and Lua 5.4;
the genuine original Alpine fixtures reproduce 195/9 and 37/4.

The author's full V1 Alpine run passes all 433 modules, 10,133/0, under the
unchanged canonical GNU prerequisite setup and pinned native luv/lfs builds,
executed as the ordinary CI user. Its earlier incomplete-prerequisite attempt
(10,123/10) remains recorded. V2 differs from that qualified V1 source only in
three comments; this is executable-body equivalence evidence, not a claimed
second full V2 run. Corrected hosted current-source, macOS SDK, Windows and
physical-device qualification are not inferred. TODO42 remains partial.

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
- [~] **46.** **Partial: local model admission and download offers.** Windows,
  macOS and Linux share model-presence policy for chat, agents and screen
  reading. Missing, removed, unavailable and malformed model lists remain
  distinct; model receipts belong to their originating endpoint and newest
  joint listing generation. Complete bounded HTTP failures and restored modal
  ownership fence download offers and request resumption. Mac endpoint/epoch
  controls and Linux loopback/source/retirement controls are qualified slices,
  not final desktop acceptance.
  Remaining: actual models/chat/download/retry on final native sources,
  consent and exact source/endpoint/model admission, held dialog and modal
  restoration, packaging, per-user installation/restart and physical desktop
  input. Windows steps 1,10,12 and Mac native Hammerspoon qualification remain
  required. Preserve one-shot/cancel timer and native curl-slot assertions.
  Direct-source manual run37306690694 attempted actual HTTPS/model validation.
  Its native child exited0 with inference6 bytes, but the supervisor rejected
  its physical-reaping counter; this remains a failed whole acceptance until
  explicit pending-zero/no-rescue proof qualifies. The corrected physical
  consumer passes35 parser controls and three refusal controls;14 durable
  diagnostics and actual native82 checks pass. Real adoption, rescue and timeout
  controls preserve their physical outcomes. Hosted direct-source run37314770405 passes the actual official HTTPS installation,
  model pull/chat and strict pending-zero/no-rescue acceptance step. The whole
  Linux lane fails separate updater and negative-publication fixture steps;
  packaging/install are skipped. Its public artifact bytes remain unavailable.
  Items16/38 remain.

- [~] **47.** **Partial: authenticated local-server discovery and menus.** The
  shared catalogue owns optional empty authentication only for declared local
  providers; cloud/generic/unknown providers retain typed key requirements.
  Exact configured HTTP(S) endpoints and secret bytes remain authoritative,
  with no empty Authorization header. Private source order, unknown values,
  classified reads, DPAPI/0600 publication and existing writer admission remain
  required. Mac joint discovery and Linux four-owned-GET menus preserve ordered
  generations, typed models, held-dialog freshness and saved-but-not-selected
  refusal; neither permits a logical ticket to acknowledge native cleanup.
  Linux owned HTTP retains creator, detached group, body descriptors, native
  close ACKs and literal source authority until physical settlement. The final
  POST source 4171a254 qualifies 424+17 cases on LuaJIT and 421+17 on Lua 5.4,
  actual POST 4 and descendant 5 per ABI. Its final 82-check native gate passes on both ABIs, including physical
  process/file/POST teardown; the earlier 64 checks remain intact. New fixture loaders
  restore their exact ShellRunner/monotonic dependencies without changing old
  assertions: original prefix 159/0 per ABI, 24 cache controls and 6 causal REDs.
  Final daemon consumers pass 162/0 and actual routing 2/0 per ABI; 12 causal
  variants reject 30 named assertions per ABI. The manual-page-close
  bridge passes all 13 original/new controls per ABI. Synchronous cancellation
  retains its own UI completion before retirement: faithful composed controls
  pass180/0 plus daemon routing2/0 per ABI; the original fails two behaviors.
  Windows14 source paths include panel/lifecycle and timer relocation. Direct-source
  run37316704100 passes panel20, timers4, logical39, models20, private42, JOIN9
  and all six succession controls. Its whole unit suite reports9303 passed/44
  failed; downstream E2E/package/install are skipped. Nine shared
  renderer/declaration/test paths use canonical inert fallback rows; generated
  artifacts were regenerated through their owner. Final
  driver qualification remains required. Historical diagnostic
  run 37285932690 source 6e7363b247 tested 3857b87767 passed the Group4 join,
  orchestration/models/private/tooltip cohorts but finished 9278 passed/43 failed
  using eight fixture variants; E2E/package/install skipped. It does not qualify
  new unmodified sources. Remaining: final unchanged-source Windows/Mac/native HTTP/UI discovery,
  cache/source/credential/model/menu supersession, pause/resume/shutdown and
  page-close cleanup, exact private writes and restart, renderer duplicate-row
  identity, actual model/chat/consent, packaging/install and physical input.
  Preserve C1/full cloud endpoint semantics, timer inventory, original corpus
  and existing private-file/DPAPI/WAL assertions. Lua 5.4 authenticated private
  file fixture's17 baseline FFI failures are unresolved qualification, not green.
  Corrected root Linux passes8302/0 and E2E189/0. JS361/0, portable macOS
  unit14665/0 and E2E101/0 plus one driver-specific skip qualify their selected
  sources. Hosted Linux8337/1 exposed a cache-only fixture admitting an extra runtime
  offer on trusted-root hosts. Explicit unavailable-runtime isolation preserves
  every old assertion and passes all58 admission controls per ABI. The final
  local Linux suite passes8338/0 across406 modules after current dev integration. Six Windows
  retained writer/JOIN failures are traced to the scope fixture retaining its
  recovered barrier. Exact-owner fixture restoration and six original native
  refusal sequences are adopted. Native37313187012 passes panel20/20, timers4/4
  and logical controller39/39, but still exposes two subsequent recovered G2
  fixture markers. Their coordinated exact-owner finally restoration preserves
  all139 original assertions. Direct-source run37316704100 closes all twelve
  earlier marker failures; its remaining44 failures retain their prior names.
  The Linux no-clobber negative fixture now checks exact GNU version-specific
  exit receipts without normalizing production outcomes. All34 original
  assertions remain; native44 cases and the complete82 gate pass on both GNU9.4
  and9.7 (164 final checks), with unchanged1164 source hashes and physical
  pending-zero/no-rescue cleanup. Earlier read-only/incomplete scratch setup
  attempts failed and did not qualify POST. Complete native three-OS
  qualification remains; items16/38 stay.

- [~] **48.** **Partial: owned local-runtime repair and enable admission.** All
  three drivers require a fresh configured /api/version receipt before the
  existing preference writer can publish AI enable. Redirect, malformed or
  incomplete response, stale backend/model/source, pause and scoped-writer
  refusal keep AI off. Retry needs fresh source/native restoration; API mode
  remains independent of a local model/server. Start/install/replacement and
  model actions retain separate explicit consent and originating authority.
  Canonical Ollama 0.24 archive pins cover five OS/architecture assets without
  rewriting the independent expectations. Linux user-only installation uses
  one 30-minute bootstrap budget, a complete executable/library tree and exact
  physical process/file cleanup. Actual official cached archive install and
  CLI startup, and owned engine/version/preference handoff, are qualified slices;
  they do not prove HTTPS transfer, model inference or physical UI acceptance.
  The daemon consumer 162/0 and actual routing 2/0 per ABI are fresh focused
  results;12 variants reject 30 named assertions per ABI. Manual-page-close13
  passes per ABI; corrected root Linux8302/0 and E2E189/0 complete locally.
  The Linux cancellation fence and faithful managed fixture retain all original
  assertions; current native three-OS CI and physical acceptance remain pending.
  The earlier manual HTTPS/model CI failed its outer physical receipt after
  native child exit0. Corrected direct-source run37314770405 passes actual
  official HTTPS install/model/chat and strict pending-zero/no-rescue acceptance
  without relaxing archive/model/chat/source assertions. Whole-lane updater
  and negative-publication fixture failures skip package/install. The corrected
  negative fixture passes44 native controls and complete82 checks on GNU9.4
  and9.7; final local Linux8338/0 and E2E189/0 remain qualified slices.
  Actual local official HTTPS installation reached typed readiness and durable
  enable, then failed the model pull with exact child cleanup. Registry CONNECT403
  persists in this container; saved network configuration is not applied.
  Remaining: genuine archive/model HTTPS under system proxy/TLS, cancellation,
  timeout/size/digest/redirect errors, native model/chat and fresh enable,
  app-owned shutdown/pause/manual-close handoff, packaging, per-user install,
  restart and physical desktop acceptance on final sources.
  Windows PC steps 6-10,12 retain DACL/handle/reparse/ancestor/namespace proof,
  construction receipts, finite downloader, architecture resolver/version lease
  and exact foreground Job/service readiness. No extra producer argument,
  empty task state, accepted signal or cache-copy success proves settlement.
  Never kill an external server, run an administrator/system installer or
  overwrite foreign configuration. Saved Windows v3/file-port sources remain
  proposals until review and native 25-case qualification. Items 16/38 remain.

- [~] **49.** Windows keyboard-hook order audit: AutoHotkey removes and
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

Delivered prerequisite: terminal replay has one exclusive native release owner
across the unlocked SendInput boundary. Reentrant and concurrent attempts retain
the FIFO; final acknowledgement and ownership retirement are atomic. Overflow
preserves its original fault/error while consuming only the accepted prefix.
All 929 original assertion expressions remain byte-identical. The official
MSVC generator refreshed the DLL/manifest; source/recipe, x64 PE, ASLR, DEP,
CFG, 24 exports and absence of a dynamic compiler runtime are verified.
Native run 37237868670 (source 2d31eee37) passes all 33 C cases. Run
37232550379 also demonstrates both expected original-production failures at
the independently specified first assertions.

Windows PC implementation and acceptance, delegated to the maintainer:

1. Record the actual installed-hook order before and after a real SendInput
   rehook. Exercise native-first and AHK-first orders with physical input;
   hook-free C events and injected keys do not establish physical provenance.
2. Audit terminal capture against KLE/layout/dead-key consumers, digit/profile
   routes, tap-holds, key combinations and script shortcuts. Include down,
   repeat and up, owner changes while held, and pause/reload transitions.
3. Implement the remaining event-specific capture/replay and effective-modifier
   ownership protocol. AutoHotkey criteria do not expose low-level flags or
   extra-info for each event: a blanket capture guard or replay exemption cannot
   distinguish simultaneous physical input from native replay. Retain exact
   FIFO-prefix acknowledgement, partial-send retry and overflow debt.
4. Verify captured layout/dead-key state, modifier transformations, balanced
   releases and menu masking in both orders, including physical typing during
   paced expansion, failure/retry and secure-desktop transitions.
5. Add registered regressions for the observed routes, regenerate native
   artifacts through their owner, then run the full Windows unit, E2E, startup,
   packaging and installation gates. Keep this item open until the complete
   hook-order audit and physical acceptance pass.

- [ ] **50.** Measure SendEvent against SendInput on Windows. While the native
      arbiter's low-level hook is installed, SendInput is interruptible anyway,
      which is the only reason AutoHotkey removes its own hook, so SendInput now
      only costs the rehook of item 49. `ErgoptiPlus.ahk` sets `SendMode("Event")`,
      yet `hotstring_send.ahk`, `hotstring_dispatch.ahk`, `text_sender.ahk` and
      `config_io.ahk` still call SendInput. Measure long expansions, pastes and
      accepted predictions (latency, dropped or interleaved keys) before switching;
      not before the demo.

Windows PC measurement steps, delegated to the maintainer:

1. Record the commit, Windows build, app, layout/emulation state, arbiter state,
   payload length and configured send delays for every measurement.
2. Compare SendEvent and SendInput on identical long expansions, pastes and
   accepted predictions, with the native arbiter actually installed. Retain
   exact expected output and repeated elapsed-time samples for each mode.
3. Repeat with simultaneous physical typing and modifier presses. Count
   missing, duplicated and interleaved characters/edges; record the actual
   rehook/order behavior from item 49 rather than inferring it from timings.
4. Report latency distributions and correctness together. Change send policy
   only when the measurements justify it, then add regressions and complete
   the native pipeline. No send-mode change is included in this cloud slice.

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

Windows PC execution steps, delegated to the maintainer:

1. Record the tested commit, Windows build, installation/source mode and layout.
   Run every behavior listed above after a cold start and again after reload.
2. Repeat navigation with both Shift keys, ctrl navigation modifiers and
   Shift plus a tap-hold Tab. Record slot indices, wrap, caret position and the
   inserted result; verify each physical press produces exactly one action.
3. Repeat expansion, prediction insertion and clipboard checks with emulation
   disabled and enabled. Check the AltGr action switch in both positions.
4. Check versions, AI menus, layer legends, rollback backup and source-run
   uninstall availability. Record each case as passed, failed or not executed,
   with diagnostics and reproduction steps for failures.
5. Remove item 51 only after the entire matrix passes. Automated unit results
   do not substitute for these real-machine observations.

## Maintainer requests on the evening of 2026-09-30

Each item is removed once it is integrated and pushed; what must still be
checked on a real machine moves to item 51 (Windows) or its macOS twin.
Releases: push to `dev` without a release until every item below is
integrated, then publish one grouped release.

- [~] **54.** Every menu is declared in the shared menu manifest, never in
  driver code. The ratchet `npm run test:native-menu-rows` counts the rows
  drivers still build (current baseline: Windows 28, macOS 32, Linux 31, each
  site listed in tools/test/native-menu-rows-baseline.json); migrate them to
  zero. Each OS-limited row declares `unavailable = "hide"` (not
  applicable) or `"grey"` (not yet ported, with its reason); classify the
  existing rows during the migration (proposal in the menu-first-group
  report: most hide; greyed: Linux edit_shortcuts, Linux key
  combinations, Linux metrics shortcut rows, Windows preview_bubbles).
  The complete MagicKey source frame now consumes the canonical capture,
  automatic choice, candidate list and separators on all three drivers. Native
  selection, readiness and publication callbacks remain unchanged. Both owners
  regenerate byte-exact artifacts; the census retires five Windows sites,
  establishing 48/86/61. Independent source and portable controls pass; final
  integrated native and installed qualification remain required.

  Corrective Windows CI `37621118292` completes 10166/1: the earlier menu
  regressions and native cleanup controls pass. The sole remaining OS-call
  purity failure is addressed by moving exact captured-handle probes into
  the existing native tray adapter, without raising its baseline. Follow-up
  Windows CI `37625043296` completes 10166/1: the purity and menu controls now
  pass; the sole failure is the actual Python program-provider argv receipt,
  routed to its Group 3 owner without changing its assertions. Windows E2E,
  package and installation stay skipped; this item remains partial.

  Current Group 1 software and device boundaries are recorded in the
  [2026-10-07 checkpoint](handovers/2026-10-04-parallel-containers/GROUP1-CURRENT-CHECKPOINT.md).
  The selected local gates pass on published `fad59c821`; exact-source native
  CI reported Windows menu/fixture failures and retained macOS packaging
  failures. The Windows follow-up preserves foreign detached owners and
  original assertions; final native qualification remains required. All six
  Group 1 items and requirements 16/38 stay open.

  Shared dynamic captions now validate the actual English format before any
  lazy native getter runs. Literal captions, escaped percent signs and user
  data retain their original rendering; malformed or withdrawn declarations
  refuse before getters and native allocation. Independent corpus and causal
  controls cover all three renderers. This API prerequisite retires no native
  sites: the census remains 48/86/61. The compiler-boundary fixture now
  parses actual nonempty top-level functions instead of truncating nested
  blocks; original assertions and new missing/data/comment/empty controls
  remain mandatory. Final composed native, installed and
  physical-device qualification remain separate; items 54 and 81 stay partial.

  The complete WordExpander parameter, delay-color, Agent, extension,
  shortcut, internal LLM, personal-file, Language, Debug, Configuration,
  Apps and Metrics frames now consume shared declarations on all drivers.
  Native callbacks and the existing WPM lifecycle remain owned by their
  original drivers. Child scopes, false check states, literal caption affixes
  and command prefixes retain their original behavior. Both actual generators
  reproduce the union's 28/33/33 source census. Independent source reviews and
  focused causal controls pass; final composed local and native gates remain
  required. Remaining native construction and Windows append placement are
  software work; installed and physical-device acceptance remain separate.

  The complete Magic trigger-character frame now consumes the shared main
  command and the Linux-only customized reset fragment. Genuine Windows,
  macOS and Linux getter/setter/reset bodies, macOS paused presentation and
  Linux indentation remain unchanged. Source withdrawal, late metatables and
  malformed declarations refuse before publishing the parent. Independent
  causal controls pass; the two actual generators retire exactly zero Windows,
  one macOS and two Linux sites, giving 28/32/31. Native Windows, final composed
  gates, packaging/install and physical-device acceptance remain required.

  Published `409b8ee0` includes the shared model-readout migration and its two
  owner-generated artifacts; the remaining sites are software migration work.
  Native allocators and computed user-data captions alone do not prove missing
  shared policy. Final native binding/order/caption and installed acceptance
  remain required; source review and the local portable gates are insufficient.

  Integrated partial-delivery checkpoint: published Dev8cba7a0c/treec0a8c809
  includes117 feature commits and the actual create-only lease receipt.
  Final exact-source CI37547053814 is terminal failed:37jobs,32pass/3fail/2skip.
  Windows native10089/0/startup/fresh-clone/E2E/package/compiled-install/
  programmable/evidence/verdict and the entire Linux chain with17 acceptance
  variants pass. Mac stubbed units/E2E and native canvas12 pass; Package fails
  on named Sparkle/AppleEvent/GlobalSwitcher receipts, causing Mac Install skip;
  no precise cause or TCC grant is claimed. Release is skipped. The77-path
  source equality proof does not establish runtime equivalence or exoneration;
  changed supplemental macOS launch-gate inverse remains unexecuted there.
  All six items remain partial:53/86/61 retains200 software sites plus genuine
  item33 producer gaps and separate installed/device requirements.

  Current qualification checkpoint: own all-OS CI37541202298 tested exact
  published cee55e1a/treea17350f2: native AHK10089/0, macOS canvas12 and the
  entire Linux chain with17 install/launch variants pass, but Windows fresh-clone
  startup fails with downstream phases skipped, and macOS package fails.
  Corrected Windows CI37543830928 on exact20352/tree6641 is terminal successful:
  native10089/0, full/fresh-clone startup, E2E, package, installed compiled
  admission, programmable qualification, mandatory evidence and verdicts pass;
  Release is skipped. Both new personal-shortcut cases belong to the actual
  native runner; only aggregate proof is available (earlier individual manifest
  download403, current individual/artifact fields not downloaded). All six items
  remain partial:53/86/61 retains200 software construction sites plus separate
  final integrated-source and installed/device qualification requirements.

  The current Windows fixture cohort checks the genuine shared-renderer
  toggle route, captures and restores absent or present dependency state, and
  loads the real English translation owner while restoring all eleven prior
  locale references and flags. All 156 existing model/label assertions remain
  intact; production menus, corpus expectations and locale sources are not
  regenerated or changed. The component fixes are independently source-reviewed;
  actual AHK/Win32 execution remains unrun locally and requires fresh Windows
  CI. These fixture corrections leave all six group items partial.

  The Windows personal-shortcuts separator and fixed submenu caption now
  consume one shared frame. Its genuine ordered runtime registry remains
  Windows-only; macOS keeps its arbitrary personal script and Linux its
  existing shortcut controls, with this frame explicitly not applicable.
  Registry predicates, descriptions, child order, switch callbacks and
  native menu lifetimes remain unchanged. The unchanged owner scanner
  measures 55/86/61 to 53/86/61. Shared renderer controls pass 12/0 on
  Lua5.4 and LuaJIT; the two registered Windows native cases remain locally
  unexecuted. Current hosted-native and installed qualification remain
  required. All six group items stay partial.

  The Windows hardware-boundary fixture now uses the existing typed recursive
  \_LVS_DeepEqual comparator through AssertEqual with an empty mismatch result,
  replacing two calls to the undefined AssertDeepEqual helper. Both independent
  expected hardware Maps and both actual operands remain exact; all other
  assertions, the strict comparator and its registered negative controls are
  preserved. The canonical runner includes the owning fixture and comparator
  before registered callbacks execute. Reversing those two calls recovers the
  complete published fixture, and the repair commutes exactly with the appended
  model-header tests. Production, framework, corpus, locales, menu declarations
  and the 55/86/61 census remain unchanged. Early native CI 37519571990 on
  source47dec reports Windows 10038 passed/1 failed at the first undefined call;
  the second defective call was not reached. That run is terminal failed and
  Release is skipped. Detached source checks pass; local AHK/Win32 execution
  and the actual Windows retry remain pending. This fixture repair is not a
  current union/native or installed qualification result. All six group items
  stay partial.

  The model-picker header boundary now consumes one canonical inert separator
  on Windows and macOS; Linux retains its genuine flat model-list presentation
  and hides this fragment, not the model feature. The unchanged owner scanner
  retires two genuine native constructors, establishing 56/87/61 to 55/86/61.
  Selectable NoModel/default controls, model/API/catalogue data, pause policies,
  native callbacks and preceding HF-token reads remain exact. Declaration
  refusal retains the native empty-Menu/completed-row refusal behavior; it does
  not prevent those earlier catalogue/token reads. All 472 predecessor corpora
  and 21 locale files remain exact. Actual supported portable macOS owner tests
  pass 16/0 and French-warm controls pass 3/0 on both Lua runtimes; genuine old
  native-only controls give 14/2 and 1/2 with the same tests. Unchanged Linux
  whole-menu controls pass 41/0 in English and French on both runtimes. Actual
  source withdrawal/receiver/comment controls and repeated owner generation
  protect binding and presence. Two new Windows full-picker/native Win32 cases
  remain locally unexecuted; SDK, GTK, device, installed and final current-Root
  hosted-native qualification remain pending. All six group items stay partial.

  The first full portable macOS gate of the staged LLM presentation union
  records 16530 passed and 79 failed, not a qualified union. Two existing
  fixture renderer seams omit the genuine native_child_rows contract; 77 cases
  fail on that omission and two activation_scope cases reflect the same
  boundary consequences. The repair is limited to forwarding the genuine
  helper through those same two fixture owners; prior assertions and production
  behavior stay intact. The complete corrected portable rerun and
  current hosted-native/installed qualification remain pending. The 55/86/61
  source census is unchanged; all six group items stay partial.

  The LLM Trigger, Display and Navigation parents now consume three canonical
  group declarations on all three drivers. Existing caption keys, platform
  projection, disabled/health-dot policy and native child settings, readiness,
  callbacks and choices remain authoritative. The pure native_child_rows
  adapter detaches valid completed Lua trees without IO or callback delivery;
  actual admitted/refused-input controls verify no external hooks. Proper
  empty Navigation remains valid, while malformed child trees refuse parent
  attachment. Windows uses the real shared renderer with its original staged
  Menu, child handles, cleanup/lifetimes and conditional backend warning anchor.
  The unchanged owner scanner establishes 56/90/64 to 56/87/61, retiring three
  macOS and three Linux sites with no Windows retirement. All 471 predecessor
  corpora and 21 locale files remain exact; original behavioral assertions stay
  retained and one Windows source-route premise is strengthened for genuine
  canonical renderer binding and dispatch. Thirteen actual source negatives,
  21 lexical controls and 12 helper-shape controls protect real parent binding.
  Supported macOS Lua5.4 owning, pure-renderer and layout controls record
  175/0, 106/0 and 8/0, inherited through exact native/API/test-byte equality.
  Final Linux owning and adapter/menu controls pass 90/0 and 41/0 freshly on
  both Lua runtimes. Genuine original native routes with their original dynamic
  declarations and current APIs give 166/9 on macOS and 84/6 on Linux. The
  repaired Linux fixture prefix and its unchanged topology registration are
  exact; separate cumulative fixture-chain qualification remains required.
  Five actual registered Windows native cases remain locally unexecuted; SDK,
  GTK, hardware, final Root/full hosted-native and installed qualification
  remain pending. All six group items stay partial.

  The existing Windows/Linux empty-API status and macOS empty server-model
  status now consume two shared inert label fragments. Three genuine native
  leaves migrate, but only the Windows and macOS leaves were counted: the
  unchanged owner scanner establishes 57/91/64 to 56/90/64. Linux's actual API
  status remains available; only genuinely absent presentation roles hide.
  Native empty predicates, retained selected models, selectable NoModel
  commands, provider actions and runtime owners remain unchanged, with all
  470 predecessor corpora, 21 translated locale files and prior assertions
  preserved. Supported macOS Lua5.4 owning and French-warm controls pass 22/0
  and 3/0; genuine old native source gives 20/2 and 1/2. Linux LuaJIT owning
  controls pass 50/0, and four new controls pass 4/0 in English and French on
  Lua5.4 and LuaJIT versus old-native 2/2. The Linux full Lua5.4 fixture remains
  48/2 versus original 44/2 from its inherited private-write/FFI limits; raw
  macOS LuaJIT warm controls remain 1/2 on current and old native source from
  the inherited table.pack formatting limit. No shim or unsupported green
  result is claimed. Windows native cases and Win32 acceptance, actual
  Hammerspoon/SDK, GTK, physical devices and final Root/hosted-native
  qualification remain unexecuted or pending; all six group items stay partial.

  Linux's two existing selection boundaries now consume shared inert
  fragments between CapsWord, the case-transform trio and the selection-helper
  trio. Existing native actions, callbacks, readiness and order stay unchanged;
  Windows and macOS have no corresponding provider boundaries and explicitly
  hide them. The unchanged owner scanner establishes 57/91/66 to 57/91/64,
  preserving all 469 predecessor corpora, 21 locale files and prior assertions.
  Actual Linux case-transform and whole-tray controls pass 72/0 and 22/0 in
  English and French on Lua5.4 and LuaJIT; the genuine old native producer
  gives 70/2 and 21/1 with the same tests. Neighbour controls pass 311/0, and
  eighteen negative source/declaration controls remain red. These portable
  source receipts do not qualify native GTK, SDK, physical devices, the final
  Root source or hosted CI. Final composed native and installed acceptance
  remain pending; all six group items stay partial.

  The existing trigger, display and live-mode control boundaries now consume
  three shared inert fragments at their genuine Windows, macOS and Linux
  provider sites. Each original platform-specific presence and placement
  remains exact; native settings, prompts, pause/source checks, callbacks,
  catalogues and acknowledgement policies are unchanged. The unchanged owner
  scanner retires four sites, establishing 59/92/67 to 57/91/66, with all 468
  predecessor corpora and 21 locale files exact. Supported portable macOS
  Lua5.4 owning and French-warm controls pass 14/0 and 3/0; the genuine old
  native producer gives 13/1 and 2/1. Linux whole-tray controls pass 20/0 in
  English and French on Lua5.4 and LuaJIT, while original native source gives
  19/1. macOS LuaJIT preparation fails on the inherited raw bitwise operator
  in key_state.lua before behavioral assertions; original native source and
  original fixtures reproduce that preparation failure, so no LuaJIT behavior
  is qualified and no shim is used. Two new Windows Win32 cases, actual
  Hammerspoon/SDK, final composed hosted-native and installed acceptance remain
  unexecuted or pending. All six group items stay partial.

  The Windows/macOS separator before per-model hardware details now consumes
  one shared inert fragment; Linux has no corresponding hardware block and
  explicitly hides this boundary. Each native availability predicate remains
  exact: Windows still shows its hardware heading for an empty Ollama Map,
  while macOS requires download, disk or RAM values. Bare Windows Ollama and
  decorated macOS Ollama headers, all values, order and native callbacks
  remain unchanged. The unchanged scanner and two owner-generator fixed-point
  runs establish 60/93/67 to 59/92/67, with all 467 predecessor corpora and 21
  locale files exact. Actual portable macOS owning and French-warm controls
  pass 13/0 and 2/0 on both Lua runtimes; genuine old native source gives 12/1
  and 1/1. Unchanged Linux whole-tray controls pass 17/0 in English and French
  on both runtimes. The new real Map/Win32 case is locally unexecuted; final
  composed native CI, actual Hammerspoon/SDK and installed acceptance remain
  pending. This source-qualified boundary does not complete either menu item
  or any of the six group items.

  Linux's six existing absent-module status children now consume five shared
  inert fragments for Hotstrings, LLM, Metrics, Shortcuts and Gestures. The
  exact native absence predicates and outer captions remain unchanged; all
  statuses stay disabled with no action, and all unrelated data, callbacks and
  IO retain their native owners. Windows and macOS have no such child
  presentation and explicitly hide these Linux-only fragments. The unchanged
  owner scanner establishes 60/93/73 to 60/93/67; all 466 predecessor corpora
  and 21 locale files remain exact. Actual registered Linux whole-tray controls
  pass 17/0 in English and French on Lua5.4 and LuaJIT, while the genuine old
  native producer gives 12/5 with the same tests. This is portable source
  qualification, not a GTK, SDK, Windows or physical-device result. Final
  composed hosted-native and installed acceptance remain pending; all six
  group items stay partial.

  The curated model family and per-model origin boundaries now consume two
  shared inert fragments on Windows and macOS; Linux's installed-model list
  has no corresponding boundaries and explicitly hides them. Native populated
  family predicates, catalogue order, selection, download, deletion, readout
  and hardware callbacks remain unchanged. The unchanged owner scanner retires
  exactly four sites, establishing 62/95/73 to 60/93/73. All 465 predecessor
  corpora and 21 locale files remain exact. Independently reviewed portable
  macOS owning and genuine French-warm controls pass 11/0 and 3/0 on both Lua
  runtimes; original native producers give 9/2 and 1/2. Unchanged Linux
  whole-tray controls pass 9/0 in English and French on both runtimes. Two new
  Windows Win32 cases remain locally unexecuted; final composed native CI,
  actual Hammerspoon/SDK and installed acceptance remain pending. This bounded
  source migration does not close either menu item or any group item.

  Generation numeric boundaries now consume three shared inert fragments,
  retiring the three actual Windows separators and one macOS separator. Later
  macOS numeric boundaries and all Linux generation boundaries retain genuine
  absence
  through explicit `unavailable = "hide"`; no native callback, numeric/reset
  selection, prompt, state or existing acknowledgement policy changes. The
  canonical generators establish 66/98/73 to 63/97/73, with all 463 predecessor
  corpora and 21 locale files byte-identical. Actual macOS owning tests pass
  10/0 and French warm-owner controls 3/0 on both runtimes; genuine old native
  source alone gives 8/2 and 1/2 respectively. Unchanged Linux whole-tray tests
  pass 9/0 in English and French on both runtimes. Three new Windows Win32
  cases, final composed native CI and installed-device acceptance remain open.

  The nonempty shortcut-extension boundary now consumes one shared separator
  and decorated disabled heading on Windows and macOS. Linux retains its
  extension entries without this presentation boundary. All extension scans,
  builders/fallbacks, sandbox loads, child ordering and callbacks remain
  byte-identical outside the four genuine constructor replacements. The
  unchanged owner scanner counts three retired sites, establishing 63/97/73
  to 62/95/73: the Windows decorated heading was originally uncounted.
  Independent portable macOS owning and genuine French-warm controls pass
  5/0 on both Lua runtimes; the genuine old native producer gives 3/2 in both
  contexts. All 464 predecessor corpora and 21 locale files remain exact.
  On macOS, missing/unbound presentation refuses after the existing sandbox chunk loads;
  it does not prevent those earlier loads. The new registered Windows native
  fixture is unexecuted locally. Current parent-tree CI run 37491143093 tests
  the aa70/6bf86bfc tree without this extension slice, so it cannot qualify the
  new family. Composed native CI and installed-device acceptance remain open;
  all six group items stay partial.

Linux Metrics unavailable/idle migration readouts now consume shared inert label
templates. Running progress and cancellation retain their native owners. The
composition graph credits executable template publication per platform and keeps
clicked-submenu action requirements intact; independent malformed-row and native
state cases retain the original assertions. The census retires exactly two Linux
fixed-caption sites. Source-selected local gates pass 359 JavaScript checks,
14,667 portable macOS and 7,860 Linux unit cases, plus 101/189 portable E2E
checks (one macOS host-specific skip). Items 54/81 stay partial; native Windows,
three-OS packaging/installation and installed-device acceptance remain required.

The fixed per-key native/no-action command now consumes one shared command
declaration on all three drivers, with the existing Windows/Linux and macOS
caption variants and their original native persistence owners. Tap/hold pickers
and the native separator remain driver-owned. The existing scanner retires one
fixed caption source per driver: Windows/macOS/Linux 97/154/98 to 96/153/97.
Independent caption/state/platform corpus and actual menu callback regressions
cover the bounded slice; hosted Windows execution, physical native validation
and the final complete three-OS gate remain required. This item stays partial.

The per-key Tap-Hold head now uses one shared ordered child template on all
three drivers, including the original platform captions and declared separator.
Native picker, acknowledged writer and refusal owners remain authoritative.
Independent handwritten order/caption tests and original-provider inversions
cover this slice. The reader guard follows includes only from actual native
read roots and rejects missing, cyclic and disconnected consumers. Both owner
generators reproduce the artifacts; the census falls from 96/153/97 to 95/152/96.
Items 54/81 remain partial for delay, picker children and other menu families.
Full selected verification and three-OS native CI are tracked separately;
physical tray and input acceptance remain required on installed devices.

Windows fixture qualification preserves the sparse disabled-field contract and
the renderer receipt for three labelled rows, while independently requiring
four actual Win32 menu positions and their original captions/separator. The
HIGH07 dispatch guard follows the real shared template/action/registration
chain and now uses effective regex word boundaries. Every behavioral predicate
remains; hosted Windows execution is required before native acceptance.

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

Linux's Select Word, Select Line and Paste Plain helpers now consume shared
command declarations for captions, order, readiness and platform presence.
Windows and macOS retain their existing binding placement. Retained callbacks
re-read the current native method and configuration admission, require an exact
Boolean acknowledgement, and preserve native refusal and retry behavior. The
independent helper corpus and 24 registered cases cover actual effect ports,
reservation, withdrawn capabilities, declaration mutation, composed order and
all 21 locale captions; the original 21 cases fail 19 times against the old
provider and pass after migration. The original registered module remains an
exact prefix. The native census stays at 97/154/98: its scanner excluded the
computed helper captions already, and separator migration remains separate.
Selected and hosted native qualification are pending; items 54 and 81 remain
partial.

Windows workstation handoff (maintainer instruction, 2026-10-04):

- [ ] Execute the existing native per-key command/caption/state/refusal cases and review the still-native Windows menu sites against the actual census (currently 82). Move remaining fixed policy/data to shared declarations without hiding rows or weakening the scanner.
- [ ] Prepared shared menu packets in docs/handovers/2026-10-04-config-menus are unapplied. Verify their recorded dependencies/preimages, regenerate owner artifacts and qualify all affected drivers after any shared change.

Partial dev handoff (2026-10-05): Metrics V3 is reviewed but unapplied.
The Windows timing prompt and macOS Wrap refusal transaction are implemented
by 9bae9a340, with subsequent arity and finite-writer refinements. Their native
and installed-device acceptance remains separate. Guidance is reviewed but
blocked by those predecessors; Gesture mode has no complete test/generation
qualification. Continue remaining families to the actual zero-site ratchet.
These are implementation tasks; separate installed tray/input acceptance.

Further fixed Wrap, Gesture mode/sensitivity/action and Tap-Hold duration and
Karabiner guidance controls now consume shared declarations through actual
native templates. Inert labels, named composed headers and checked templates
retain strict field and getter contracts; clicked submenus still require a
usable child. Each native composition edge carries executable source evidence,
and transparent includes retain cycle, missing-target and duplicate-identity
refusal. The Windows per-key duration path preserves physical TOML source and
requires the precise native publication witness before reload. Its current-value
prompt is genuinely translated in all 21 locales. Independent historical
corpora remain immutable. Full selected and all-OS native qualification remain
required; the remaining fixed native families and physical acceptance are open.

The 2026-10-05 Swipe continuation declares its fixed action separator, mode group and sensitivity group once in the shared manifest. Native selection, eighteen numeric sensitivity choices and acknowledged compensation remain their existing owners. Two captions use genuine translated prefixes in all 21 locales. Source/graph/callback controls and the old-producer inverse pass; final composed native and physical UI qualification remain pending. This does not complete the remaining fixed provider controls.

Native Linux metrics equivalence now retains the established JSON-quoted token column in its independent raw-row SQL transport. All twenty-one assertions, aggregation rules and date/application filters remain unchanged. Real SQLite compares 648 grouped rows with 2808 raw rows; this repairs a validation prerequisite and changes no production metrics policy.

The native Windows DelayRows provider now supplies all four required renderer arguments. The previous candidate failed loading before any native unit case; all eight production call sites retain the unchanged four-argument API. Two actual-provider regression cases cover complete physical rows, caption propagation, missing commands and withdrawn callback ownership. Native Windows qualification remains required on this successor.

The fixed separator after the native About build/version row now comes from one shared fragment on all three drivers. Existing update/channel/cadence callbacks and shared version wording remain unchanged. Independent actual rendered/provider mutation, platform-hide and missing-declaration controls preserve every original registered assertion. Focused macOS20/0 and Linux29/0 pass on both Lua5.4 and LuaJIT; identical old-source controls fail two cases per driver. The actual scanner measures83/125/93 to82/124/92 (Windows/macOS/Linux). Windows cases are registered but unexecuted locally; final native CI and installed-device acceptance remain required. Items54/81 remain partial for other fixed presentation/data families.

The packaged macOS About check row now consumes its existing shared command and readiness getter. Both manual and offered-release callbacks retain the actual shared live-admission wrapper; the original strict tag/channel consent body and every prior registered assertion remain byte-exact. Independent Lua5.4 passes36/0; original provider30/6 and the discarded direct-callback override34/2 prove the regressions. Raw LuaJIT fails at the inherited fixture table.pack boundary; explicit fixture-only compatibility replay is recorded separately. The unchanged scanner measures Windows82/macOS123/Linux92. Actual native CI, installed menu acceptance and other fixed families remain required. The registered provider dialect guard now verifies actual declared rendering, manual/offered dispatch and stale-offer refusal instead of the retired caption location. Its six other About predicates and original assertion message remain exact; independent current11/0, original/current7/1, original/old8/0 and strengthened/old8/3 distinguish the regression.

The newly registered Windows Wrap provider controls now load the actual seven-group shared catalogue, while the older two-pair transaction fixture and all its assertions remain untouched. Actual renderer acknowledgement counts labelled rows, and independent Win32 item/position/caption checks require all15 native rows including3 separators. The handwritten corpus is unchanged; source review is clear and native rerun remains required.

The Windows gesture-slot tap-group separator now belongs to its existing shared gesture_slots_ahk status fragment. Actual native rows retain all action and persistence owners; three new registered tests measure Win32 positions, declaration withdrawal and invalid effect-free status admission. Every prior test/corpus is unchanged. Owner generators reproduce the artifacts and the unchanged scanner lowers only Windows82 to81, leaving macOS123/Linux92. Available selected format, BOM/LF and361 JS gates pass; AHK unit, parse and E2E are skipped on this Linux container and require targeted native CI.

macOS missing-bundle and macOS/Linux empty installed-layout statuses now consume the existing shared status fragments. Native discovery and installation owners are preserved; independent handwritten expectations cover all21 translated captions. The owning generators reproduce the census Windows81/macOS120/Linux91. Selected container checks are recorded separately from native installed/device acceptance; remaining native row families keep this item open. The empty macOS Input Sources provider also consumes a shared Open preferences command with the unchanged native callback; retained declaration withdrawal refuses before launch, and no true launch acknowledgement is fabricated.

Custom-profile actions, saved-user-model children and Linux free-entry numeric tails now use shared ordered child declarations. Native action, prompt, save, disable and rollback owners remain in their drivers. Existing labels and handwritten caption/order corpora cover all 21 languages; the saved macOS My models capability has a truthful translated reason, while OS-specific child presentations explicitly hide. The compiler and availability report share one strict classifier; the unexplained-capability ledger preserves exactly 104 historical identities and rejects new debt even below the count ceiling. The owning scanner measures Windows81/macOS113/Linux84 remaining fixed native sites. Whole profile frames/list splicing and the other native families remain software work; native runner, packaging/install and physical menu acceptance remain separate qualifications.

Default/custom profile headings and their custom boundary now consume two shared inert fragments on all three drivers. The composition guard follows executable native publication and retains clicked-child requirements; independent source-withdrawal, malformed header, mixed/real clicked orphan and old-loop controls remain red. All old callback bodies, native registry phases, conditional custom presence and 21 caption sets retain their behavior. Canonical generators retire exactly nine genuine native allocator sites, yielding Windows78/macOS110/Linux81. Complete ordered profile frames/list splicing and other scanner families remain software work; actual Windows/Hammerspoon and installed-device acceptance stay separate.

Shared renderers now support ordered list/group child templates, direct unique row selectors and strict presence predicates. Narrow presentation-only refusal omits a wholly inert heading while retaining native data; callback, mixed, cyclic and clicked-row refusals remain strict. Category coverage follows the actual declared transitive include graph from executable native publication roots, with genuine malformed, foreign, withdrawn and clicked counterexamples. The API alone does not retire native allocator sites.

The actual Windows CI profile-heading failures were caused by an unset native LLM_PROFILE_HOTKEY_LIMIT. The existing fixture now supplies the real nine-number-row protocol and restores the exact prior unset/value state. Every original assertion and heading withdrawal case remains. This is a fixture prerequisite; corrected native execution is pending the next manual CI.

Whole profile frames now consume shared child templates on all three drivers, preserving each native registry phase, platform-specific creation order, paused macOS presentation and lazy per-application reads. Executable owner guards reject decorative/comment/qualified decoys. Canonical generators retire eleven additional allocator sites: Windows75/macOS106/Linux77 at this slice. Other native menu families and physical-device acceptance remain open. The previously recorded macOS Wrap refusal defect and Windows timing prompt are already implemented by 9bae9a340, with the later arity and finite-adapter corrections; neither is reimplemented.

The existing model-picker providers now obtain their inert tail separator from the shared provider status declaration. Native callback/browser phases and platform-specific conditional presence remain unchanged. Actual canonical generators retire exactly one more allocator per driver, giving the current baseline Windows74/macOS105/Linux76. Existing labels retain all21 translations; remaining native families and device qualification are still open.

The Windows profile uniqueness audit now follows both actual frame providers and their shared native counter. Existing duplicate-label and disambiguator assertions remain; executable-source data decoys and four genuinely colliding Win32 rows add causal controls. Static/source review passes, while the actual native menu cases require Windows CI.

The Agent per-system Model command and its preceding separator are now declared as shared two-row templates on all three drivers. macOS observed installed/missing captions use the same declared command through separate templates and existing translations. Native callbacks, dialogs, validation and transaction/refusal behavior stay unchanged. This bounded source migration lowers the actual native-row census from Windows74/macOS105/Linux76 to73/104/75. Independently frozen owning probes pass Mac19/0 and Linux23/0 on both Lua runtimes, against genuine original-producer15/4 and21/2 controls. Actual Windows/Hammerspoon execution, CI, packaging, installation and device acceptance remain separately unqualified; the other native sites and all six global TODO items remain partial. The Linux regression uses genuine runtime translation scopes and restores exact prior module identities, including a warm French backend and a raised scenario. Independent warm controls pass5/0 on both Lua runtimes; the unchanged previous fixture reproduces1/2 French-caption failures. No persisted locale choice is changed.

The direct Windows profile-frame regression now initializes its four mandatory number-row dependencies from genuine executable native declarations and restores exact prior absent/value identities in nested finally. All28 prior assertions remain in order. The preceding native run37438495454 stopped this test at an uninitialized tone dependency;19 independent portable source controls pass, while real Win32 execution and restoration still require the next Windows run.

The fixed API Add-entry affordance and its existing separator now consume canonical shared templates on all three drivers. Windows retains its dialog command; macOS/Linux retain their native provider children, callbacks, separator order and availability policy. Existing 21 translated captions are reused. Canonical generators reduce the actual remaining native-row census from73/104/75 to71/102/74. Independent owning portable probes pass Mac59/0 and Linux LuaJIT43/0; genuine French-warm controls pass3/0 on each driver and Lua runtime, while the original native producers fail1/2. Actual AutoHotkey/Hammerspoon/GTK, full final CI, packaging, installation and item38 device acceptance remain separate. Other native families and all six group items remain partial. The whole Linux tray fixture now owns the genuine API entries/backend/builder cohort and a private real JSON source. All old assertions remain; independent whole-tray replay passes9/0 on both Lua runtimes in English and French, preserves the malformed external API file byte-exact and restores module identities/private paths on success and refusal. The original incomplete fixture fails4/1; rejected V3 passes7/0 while quarantining that external file and is not adopted. Full Root and native final qualification remain pending.

The genuine complete Windows profile-frame fixture now initializes its isolated app_profile_overrides collection from the native constructor contract and requires a nonempty Array before enumeration. All35 previous assertions and exact prior-state restoration remain intact. Manual run37451318736 reached this previously missing provider dependency and failed with a non-enumerable frame; manual diagnostic run37456524038 passes the corrected genuine Win32 frame; final-source native qualification remains pending.

The existing Windows/Linux separator after backend choices now uses one canonical shared child template. Actual backend, model and port callbacks and native ordering are unchanged; macOS had no corresponding separator and remains explicitly hidden and byte-exact. Independent handwritten platform/order tests, actual native producer inversions and both owning generators retain all previous assertions and21 translations. The real remaining census falls from71/102/74 to70/102/73; unexplained platform debt remains104. Focused and French-warm portable controls pass3/0 per runtime versus genuine predecessor1/2. Native AHK, full composed qualification and installed-device acceptance remain separate; items54/81 remain partial.

The fixed Specifications and Capabilities frames of the Windows/macOS per-model detail sheets now consume shared child templates. Existing separators, platform decoration, capability predicates and native callbacks are preserved; Linux has no corresponding detail sheet and retains its declared absence without a native change. The owning generators lower Windows 70/macOS 102/Linux 73 to 66/98/73. Independent source review preserves every predecessor corpus file, all 21 locale files and original registered assertions. Portable Mac owning probes pass 8/0 and French-warm probes pass 5/0 in both Lua runtimes; the genuine original producer gives 6/2 and 3/2. The unchanged Linux whole-tray fixture passes 9/0 in English and French on both runtimes. Final composed native CI, Windows allocator execution and installed-device acceptance remain separate; items 54/81 remain partial.

- [ ] **62.** Downloads on managed company networks: system trust and
      system proxy for every download child (Ollama installation/server/pull,
      updater/rollback and remote AI), with translated certificate/proxy/blocked/
      offline/disk/permission causes and useful recovery actions in all21 locales.
      Committed source at `b21bea3ee3ed0f3a21b90096ab0e9607a5ac688a` includes
      Windows/Linux transport, publication and receiving repairs; those changes
      must be preserved rather than rebuilt from the old interrupted worktree.
      Complete native, package, installation and enterprise acceptance remains
      open. macOS system trust and explicit proxy relays are integrated, while
      opaque-client full-URL PAC/WPAD/fallback/redirect routing remains CODE.

Linux manual37646124429 atc18f0796b2f708a1650d4a1eb5dc316b7bf263dd
passes shared checks, Linux units, actual official Ollama installation/model
pull/inference/shutdown and every other native E2E step. Genuine Nix now passes
pinned-source metadata and revision/NAR agreement, then fails native-build
with status1, no signal/owner error and no retained physical debt. Package and
installation are skipped, strict lane verdicts fail and Release is skipped.
The native-build diagnostic now projects only closed captured stderr into
fixed lexical error-kind hints; no raw URL/path/credential or lifetime change.
The original49 runner controls remain intact with31 additive privacy/boundary
controls. The actual build cause and all seven installed-runtime cases remain
unqualified; a hinted error kind is not native acceptance.

The Windows native routing policy and request/capability workers now admit
actual decoded JSON Int32/Int64 integers within the original signed Int32
domain, preserving every semantic limit and the original 64-bit started clock.
Canonical environment inventory duplicate checks use exact ordinal spelling;
required lower/upper-case names retain order while exact duplicates still
refuse. The native route fixture selects Marshal.SizeOf(Type) explicitly and
retains all four independent ABI size expectations. Genuine PowerShell7.6.6
on Linux passes64 source-bound policy, lookup, worker-guard and CLR controls
with physical closure. Predecessor canonical admission and first-revision
case-insensitive inventory failures are preserved. This is platform/preflight
evidence; Windows PowerShell5 routing, curl, CA and updater acceptance remain
pending in the next targeted native CI. Item62 remains open.

The official Linux acceptance now builds its actual original native archive
helper under the existing930-second subreaper before running the unchanged
900-second Lua fixture. Fresh generated ELF admission preserves existing
helpers and rejects foreign bytes/symlinks; full source/tool/helper identities
are rechecked. Eight actual build-prerequisite controls pass across both Lua
ABIs with exact physical closure. The official fixture observes real retained
transport, FD digest and successful adoption; its independent1198635318-byte
archive/SHA expectations and every original assertion remain unchanged.
Current official package/model and complete lane acceptance remain pending;
tiny authored archives and build controls do not qualify those effects.

The Linux Ollama archive continuation joins pinned artifact admission to the
retained download descriptor, native SHA256, same-inode tar/zstd extraction and
owned stage publication under the original absolute bootstrap deadline.
Retained native debt blocks successors and publication. Seven additive modules
are registered after the original two priority updater fixtures; all existing
inventory entries and independent expectations remain intact. Separate private
receiving preserves44 predecessor failures and44 candidate passes on each
genuine Lua ABI. Six tiny authored TLS/archive outcomes cover successful
publication, wrong digest and missing completion across both ABIs with actual
native closure; these are not official Ollama or corporate-network acceptance.
Final composed-source, real package/server/pull and installed-format receiving
remain required before this item can close.

The exact-revision local Git flake request now explicitly admits the depth-one
CI checkout with `shallow=1`. Genuine Nix2.26.3 receiving preserves four
independent controls: full-source metadata, the original shallow refusal and
shallow/full opt-in metadata with identical revision and NAR. Both checkout
HEADs and source bytes remain clean, and native phase owners close physically.
All49 existing runner controls remain unchanged. Seven installed-runtime
product cases and the exact final hosted package result remain unqualified;
this protocol proof does not establish the hidden historical CI failure cause.

The portable MLX fingerprint mirror now explicitly owns its fake UV route and
clears inherited proxy, bypass and CA selections. The unchanged27 assertions
reproduce21 passes/six failures without the old ambient relay, then pass27/0
with the correction. Conflicting inherited proxy/CA inputs also pass27/0.
Production system-routing and opaque-download refusal guards remain unchanged;
this hermetic fixture correction does not qualify native Mac networking.

Windows receiving37641625052 at74ad5da0b passes10,257 assertions and fails11;
E2E/package/install are skipped. The repair binds both native receipt readers
to the original combined stdout, launch-failure cleanup to actual counter-owned
payload paths, and integrity/timeout guards to the selected real vendor owner.
The existing state-only Critical completion admission is isolated before
handoff with exact current/successor and prior-Critical controls. All original
assertion sites/messages remain; deadline guards require the smaller original
remaining budget. Five native route/held-response/CA/cleanup cases remain
unresolved CODE pending actual Windows replay; no physical-PC-only deferral
or full Windows acceptance is claimed. Artifact NTLM-only CODE stays open.

Manual all-driver receiving37631791924 at6855c1e6 reports10,242 Windows
AHK passes and24 failures. The receiving correction preserves all original
assertions while fixing stored UTF-16 NUL admission, ordinary recovery-target
initialization, adapter-owned locale/timers, cancellation-before-spawn return,
actual curl config indexing and both native adoption callback arities. Staging
now reconstructs bounded UTF-16 SCRIPT fragments while preserving the original
7000-character per-value limit. Additive real-cmd receiving covers three source
fragments, full production UTF-8 swap data and exact environment retirement;
the native updater fixture receives the full actual stage/swap pair. Final
Windows unit/E2E/package/install qualification and artifact NTLM-only CODE
remain required. Canonical WinHTTP Ex receiving publishes only fixed cached
stage and verified native scalar diagnostics on an already-settled failure;
all original assertions remain. These corrections do not close this item.

The Windows receiving slice adds full-URL native route observations, bounded
owned curl requests, endpoint-aware updater downloads and shared terminal
failure actions. Observer publication and refusal rollback now use separate
epochs inside a short Critical admission; network and UI work remain outside
that section. The registered original38 action vectors and eight CA vectors
remain intact, with two additive actual-AHK observer race controls. The private
composed source passes382 JS checks, encoding, formatting and real Linux HTTP
and managed-network checks. The same selected checks pass on the main receiving
sources composed with actual dev33a5227ea; its native owners close physically.
Native AHK parsing, unit, E2E, package and installed
acceptance remain UNRUN until the current-source Windows CI completes.
The actual artifact producer still lacks bare NTLM-only CONNECT support: this
is remaining CODE, not a device-only validation. Keep full corporate-network
PAC/WPAD, SSPI/domain authentication, system trust and physical UI checks open.

Actual macOS HF-download and Ollama-pull owners now refuse opaque fetches when
a verified native configuration needs unsupported PAC/WPAD or SOCKS routing.
Failed, malformed, duplicate or divergent scoped native facts remain unavailable,
never manufactured DIRECT. Explicit environment overrides preserve lowercase
precedence; supported static/no-proxy routes and cached local startup remain.
The shared classifier maps only verified unsupported resolution to the existing
proxy cause and21-language messages. Portable receiving passes29 literal route
and13 phase vectors,28 emitted owner wrappers and21 blocked HF launchers;
these are controlled shell/source observations, not native Apple/PAC acceptance.
Four fixed repeated-activation controls preserve one loopback exclusion per
token and the same UV system-trust flag. Original bootstrap/generation/readiness
fixtures retain their assertions; executed-wrapper CLI observations and nine
exceptional close/removal controls cover their new native-task premise.
Current-source validation passes382 JS checks,16688 macOS unit assertions,
101 macOS E2E assertions with one declared skip, and11245 Linux unit assertions.
Native Linux archive, HTTP and runtime checks pass after replaying the four
resource-affected gates on the owned temporary volume. Genuine Nix admission
remains unexecuted locally beyond its missing-store prerequisite and requires
hosted CI; these portable results do not establish native macOS network routing.

Full request-URL PAC/WPAD, ordered fallback/redirects for uv, HTTPX/HF/Xet and
outgoing Ollama Go requests remain CODE on their actual drivers. System-store
trust, complete loopback bypass and generic model failure/action integration
must also be qualified. A successful direct download on a personal Mac cannot
complete these unsupported routes. Native SystemConfiguration/task/trust and
installed-network CI/device acceptance remain required; item62 stays partial.

ETag validators now belong to the final admitted endpoint, with cache endpoint
and byte identity retained. Every redirect selects its own matching validator;
an untagged successful response invalidates the prior validator. Real TLS wire
receiving passes eight total outcomes: two independently authored modes in each
of the four curl8.14.1/curl7.88.1 and LuaJIT/genuineLua5.4 cohorts. The genuine
predecessor loses endpoint affinity in all four cohorts. The unchanged original
seven-mode updater corpus passes28 candidate and28 predecessor observations.
Legacy singleton cache options retain their original handling; only actual
updater cold-save admission opts into managed endpoint affinity. The original
invalid-route fixture again requires proxy-route-invalid before any native
acquisition, with every callback, status, privacy and closure assertion intact.
This is endpoint cache migration, not equivalence of curl7 and8 raw ETag files.

The native temporary runner can admit a private absolute current-user0700
clone root, independently from its unchanged canonical fixture namespace.
The actual repaired gate passes all five namespace,24 ownership and24 allocation
controls with zero skipped product checks and physical closure. Heavy clones use
the admitted private root; native namespace controls retain the canonical root.
Final ordinary Linux, packaging/install and actual company-network acceptance
remain separate requirements; item62 stays partial.

The two production-updater fixtures now restore only file-resolved repository
Lua imports reached by the scenario, including whole prior cache values. Their
seven original explicit stubs and all98 original assertions remain intact.
Native ffi/luv/lfs providers and external SDK modules retain their first loaded
identities; clearing them can reinitialize VM types or retire anchored loop
userdata. The unrestricted proposed rollback crashed the whole Linux suite and
was rejected. The unchanged fixtures with the final URL eligibility repair
complete11242 passing tests and three persistence failures. The scoped repair
passes all11245 tests across499 modules and all nine selected local gates at
072481c3a9e890d24b16bb46cc93c28d2d277344. Manual Linux run37612794362 passes
unit/shared checks but fails three native E2E steps: NUL-bearing conditional
path diagnostics, authenticated no-follow cache admission and Nix pinned-source
metadata. Packaging/install are skipped; Release is skipped. The first two
failures are reproduced locally; the Nix cause remains unproved. Historical
Ubuntu Configuration assertion432 causality also remains unproved.

NUL-bearing conditional compare/save paths now retain their original fixed
argument-refusal diagnostic before any file or child acquisition. The unchanged
native byte fixture reproduces10 passes/two failures before correction and
passes12/0 afterwards; the original native HTTP preflight also passes25/0.
Conditional URL/value/affinity and ownership laws are unchanged. Current source
passes11245 Linux assertions plus genuine native archive, managed HTTP and
runtime checks; the hosted E2E/package/install replay remains required.

The authenticated live-updater wrapper now clears only its copied hop-affinity
opt-in when it deliberately disables redirects. Conditional save/compare and
endpoint/value ownership remain intact, as do the original caller options.
Four genuine curl7.88.1/curl8.14.1 and LuaJIT/Lua5.4 cohorts preserve eight
predecessor failures and eight candidate passes for cold200/warm304 and
no-follow authenticated302 refusal. Original owners, TLS servers and accepted
connections close physically, with zero skips. These controlled wire receipts
are not official GitHub-release or company-network qualification.

Nix failures now publish one bounded annotation from the original cached phase
projection: fixed checkpoint/boundary, scalar status and closed error/signal
categories plus retained-owner state. No raw stderr, URL, path, environment or
exception text becomes public. All original phases, deadlines, predicates and
cleanup remain mandatory. The original35 controls and14 additional independent
receiving controls pass49/0. This container has neither the standard Nix store
nor its native CLI; actual derivation and installed-runtime acceptance remain
unrun here and must be replayed by the original hosted CI gate.

Manual Linux run37591679813 at9195a6419f4d36581e4404198cd152753791f2e6
failed the Configuration restore assertion at test_hotstrings_scope.lua:432:
rolls remained false. Two unrelated passing unsafe-answer fixture names contain
invalid UTF-8 bytes and made the whole-log annotation decoder refuse. The
annotation now selects complete fixed records as raw bytes before strict UTF-8
decoding; original assertion identity, footer counts, reporter, failed unit exit
and artifact remain authoritative. The authentic old CLI refuses and the new
CLI publishes the complete unchanged assertion; twelve additive controls cover
unrelated invalid bytes, selected invalid bytes and record boundaries. The
Configuration failure cause remains unproved. Exact current-dev Linux manual
run37596288622 passed unit/E2E/package/install and skipped Release; private
exact and prefix native receiving also passed, without exonerating this branch.

A failure-only Linux CI annotation now reads the completed current-run unit log
after its existing failure-artifact upload. It publishes only the fixed
Configuration restore assertion when the inline failure, terminal replay and
original reporter agree; incomplete, ambiguous or oversized evidence is refused.
The original unit status, reporter, fixture and upload remain unchanged. The
assertion behind run37563506830 is still unknown: a fresh Linux manual run must
provide authentic evidence before a product correction or qualification claim.
This diagnostic does not complete item62.

MLX downloads now refuse missing or failed system-trust activation through the
existing dependency-failure path, before importing Hugging Face or starting a
watcher/download. The actual production-emitted Python is exercised against five
independent offline vectors and its original session exit path; the unchanged
predecessor reports two passes/three failures. This does not qualify native
Keychain trust, corporate proxies or transitive Rust/Xet downloads. Item62 and
its Windows/company-network acceptance requirements remain open.

The shipped MLX dependency pair now pins truststore0.10.4 and includes it in the
canonical uv lock. The admitted uv0.12.21 generator preserves all41 previous
package versions; its offline lock check passes and both artifact digests match
independent official PyPI metadata. The ordinary dependency guard retains all
seven previous bootstrap controls and adds20 checks: the actual old pair passes
8/27, while the generated pair passes27/27. Bootstrap controls use modeled uv;
native frozen bundle sync/import and Keychain acceptance remain unqualified.

Current Linux checkpoint (2026-10-06, working sources over eeb6fd58f):
retained temporary namespace conflicts now carry an explicit, pre-destructive
retry disposition. Only the same owner can retry after the independently
identified foreign entry has gone; ambiguous close debt still refuses retry.
Incomplete native path acquisition closes its exact acquired descriptors without
claiming a completed namespace. Genuine Lua 5.4 CFFI admission exposed native
NULL representation and unsigned-byte SHA-256 input differences; the native
adapters now preserve their declared pointer types and exact input bytes.

All 63 mandatory native controls pass with physical closure: four partial-path
controls, five original namespace conflicts, three fixed SHA-256 vectors per
ABI, and the original twelve ownership plus twelve allocation controls per ABI.
No product check is skipped. The pinned CFFI provider independently reports
22 vendor passes and one originally optional union-by-value skip. The normal
Linux suite passes 10,140 tests in 496 modules; all 379 JavaScript controls pass.
Original independent expectations remain unchanged. Local window-supervisor
and Nix-store prerequisites refuse before qualification; their native acceptance
is unexecuted. Hosted E2E, packaging, installation and final integrated-source
qualification remain required. The twelve Windows continuation steps and
transversal items16/38 remain open; item62 is partial.

The original installed-updater fixture now initializes the real pause owner and
waits for the actual asynchronous installation callback. Release identity and
all original replacement, restart, stamp and rollback assertions remain fenced.
Its source/model controls pass; the complete local Linux suite above includes
the unchanged candidate. Actual installation in this non-root container refuses
at its native privilege prerequisite (exit127, no sudo/pkexec); hosted native
installation is still required and is not reported as passed.

Validation curl now prepares a private Debian archive keyring from the exact
signed-distribution package and checks its complete aggregate hash. The original
full InRelease verifier, successful gpgv command and required signer are unchanged.
All 21 receiving controls pass; genuine private preparation and strict full
signature verification pass locally. Host trust stores are untouched. Hosted
validation-tool setup and the complete company-network matrix remain required.

The latest hosted Nix refusal reaches pinned-source metadata. Four fixed
checkpoints distinguish command, decoding, routing and exact pin agreement;
all original 35 controls and seven native requirements remain. Local admission
refuses at the local-store checkpoint; the seven native checks are unexecuted
in this container. Item 62 remains partial.

The latest origin/dev authenticated Ubuntu acquisition owner now installs every
original group-6 runtime, validation-tool, portable and Nix dependency. The
workflow guard requires all 34 acquisition scopes and retains failure mutations.
Neither this merge nor portable tests close native or device acceptance.

Fresh authenticated validation-curl preparation succeeds locally after actual
signed gpgv installation. Hosted Linux run 37516058879 on
281ee9a70905d677e5a2e9d7fef8a26114d53760 still refuses preparation and Nix;
package/install are skipped and publication is skipped. Safe fixed stage/class
diagnostics preserve each primary failure and expose no private output. All
73 receiving controls and 11 independent emitter controls pass; the complete
original setup-source inverse remains pinned. Nix retains all 35 source
controls and seven mandatory native claims, with a fixed checkpoint diagnostic.
No diagnostic constitutes native acceptance or identifies the hosted cause.

The CLI orphan-retirement refusal is now reproduced and corrected without
relaxing physical closure. Actual kernel observations showed the exact adopted
child as a zombie in the retained group while curl waited for group absence.
The fixture reaps only that identity during its original settlement loop and
consumes the acknowledgement before any later numeric cleanup. Original
50 native cases now pass with zero failures; all 56 assertion sites and the
five-second settlement budget remain. This does not close item 62 or 16/38.

The reviewed redirect correction retains canonical sensitive-header no-follow
admission by default; deliberate per-hop owned GETs select
`managed_redirects=true`. Both actual Linux interpreters pass the 62 focused
production controls. Identical receiving controls against the predecessor
report 51 pass/11 fail on LuaJIT and 52 pass/10 fail on Lua 5.4; these include
new API contracts as well as reproduced regressions. Original native wire
fixtures pass: empty-header56 on each ABI, origin credentials40, TLS21 and
personal curl-config5 (with their nested native controls). The complete normal
Linux suite passes 10,121 tests in 495 modules. Final committed-source native
qualification and the Windows/device work remain required; item 62 stays open.

The current Linux working-source qualification passes 375 JavaScript checks,
all 10,106 normal Linux tests in 495 modules, 124 focused updater controls
under each Lua ABI, and the original uninstrumented 20 real body-pipe cases
with unchanged 1 ms caller budgets. Earlier failures remain recorded. Strict
native output 18/public 30 now pass with physical closure; the successful
CONNECT fixture retires its HTTP connection after tunnelling. Source controls
pass separately: metadata8, filesystem4, actual private Git snapshots5 and
modeled CONNECT5; registration89 and receipt19 also pass. Protocol models do
not qualify enterprise authentication or native transport.

A real AppImage was built (17,230,328 bytes, SHA-256
024429d3e90c3316dfd44ddf3139915e3bbd28f897ad8b0da86f8d4fcaa16c0f),
extracted without FUSE, and its real launcher and installed network-runtime
probe pass with host Lua/library overrides removed. This is the recorded
working-source test build, not final committed/package-matrix acceptance or
a physical graphical session. The original AppDir7 and actual PPID2 controls
also pass. Flatpak/Nix and final-source package qualification remain required.

The genuine updater now builds from an actual HEAD clone plus its exact
index-listed working snapshot. Private staging preserves tracked files inside
ignored parents and all original index/status/HEAD bytes. Canonical Bash,
actual generated stamp and identical complete UTF-8 inventory ordering admit
the native chain. A separately captured shared 8388608-byte listing bound
admits the real names117004/verbose229756-byte outputs while extraction and
the generic 65536-byte process bound remain unchanged. Three genuine native
cases now pass fifteen checks with zero skips and complete physical closure:
verified installation, wrong-digest refusal, and an actually executed exit42
replacement launcher followed by restoration of the complete prior inode,
path, mode and content tree. Original assertions remain intact. Fifteen new
listing-policy models pass under each actual Lua ABI, alongside their
thirty-three original controls. Archive receiving controls pass their original
19/89 floors plus four/eight rollback refusals. Final source qualification and
the package matrix remain required. The twelve Windows PC steps and
transversal requirements 16/38 remain open; item 62 stays partial.

The final scoped replay also passes 15,154 portable Hammerspoon tests. Its
stamping-mutation failure is corrected against the actual packaging owner;
the complete 375-check JavaScript gate then passes. Swift is deferred to native
macOS. The cloud window-switch supervisor prerequisite remains blocked before
child allocation. A real Nix user/mount namespace works, but the official cache
HTTPS prerequisite returns 403; genuine Nix package qualification is pending.
A reviewed hosted Nix gate now requires seven distinct installed-runtime
receipts from the actual derivation, unchanged wrapper, packaged LuaJIT/luv,
shared root, native C ABI, supported GIO/schema and independent NIST digest.
Its thirty-five source/configuration/receipt controls and the complete
376-check JavaScript suite pass; none credits a native Nix execution.
Run the new mandatory Linux gate at the committed SHA before crediting Nix.
The original native body-limit84 and literal-target55 fixtures now wait for
actual close acknowledgements and pass without changed assertions or budgets.
The CLI50 cohort still reports34 passes and16 orphan-retirement failures;
its stronger intermediate closure observation does not credit those cases.
That separate native refusal is under investigation; item62 remains open.

Windows remote API readiness and generation now reserve their actual request
owner before asynchronous system-proxy admission. Native WinHTTP resolves the
complete destination through configured PAC or WPAD, distinguishes acknowledged
DIRECT from lookup refusal, and preserves exact child retirement and the
original total admission budget. Environment selection follows the destination
scheme. Strict requests do not reuse the application's PAC cache; changed system
settings require a fresh lookup. Legacy updater behavior remains unchanged in
this prerequisite.

The registered native fixture serves controlled localhost PAC scripts and invokes
the actual private-input production worker. Nine newly registered tests cover
native receipt admission and that fixture; Windows execution, E2E, packaging and
installation remain pending. Explicit unsupported relay lists are refused rather
than silently truncated; successful WPAD, integrated authentication and enterprise
certificate acceptance are not yet qualified. Linux routing, installer/server
children, updater/rollback and usable shared failure actions remain required.
Item 62 remains open.

The shared managed-network policy now classifies only typed native receipts.
Ambiguous TLS handshakes, DNS/timeouts, origin refusals and unstructured child
stderr remain unknown. Reports expose cause, translated keys and admitted
action ids, never native URLs, paths, credentials or stderr. Independent receipt
and capability corpora preserve the same policy across the three drivers.
Four additional labels and corrected certificate, proxy and route wording are
translated in all 21 locale sources.

macOS MLX failure dialogs retain a monotonic failed-intent revision and recheck
both that owner and actual action capabilities after modal interaction. Network
Retry reuses the ordinary installation path; only explicit Repair admits runtime
rebuilding. Existing unrelated runtime diagnoses and repair controls remain.
Actual MLX children still produce unstructured stderr, so these consumer changes
do not prove a deployed typed receipt producer or enterprise-network coverage.
Native action opening and the final three-driver qualification remain pending.

Linux progress windows now retain the actual session, failed-intent epoch and
fresh native capability predicates. Model retries fence callbacks from earlier
attempts even when they reuse the request table. Update retries retain the exact
cached release and original consent, and use authenticated download_release;
verification/install failures keep their separate existing messages. Native
failure receipts stay private while the shared page receives translated action
records. The renderer retires actions on reset, successor sessions and success,
and refuses delayed reports from older failures. Model diagnostics, proxy
settings and download-folder opening remain unavailable where no qualified
native owner exists. The production Linux proxy/receipt producer, real WebView
actions, installer/pull and updater/rollback qualification remain pending.

Native qualification now preserves SQLite's exit receipt while the observational
row-count fixture decodes only its acknowledged payload. The same stale fixture
failed on dev before this tranche; independent workload/equality assertions are
unchanged. Gated-model retry records its error kind before retiring old managed
controls, preserving the existing macOS wiring check. Shared CI failures expose
only check names in GitHub annotations when archived logs cannot be retrieved.

The current-dev merge preserves strict native window acknowledgements and
revokes managed-document consent before cleanup. Its timer retires only after
native destruction and input-release acknowledgements, preventing reentrant
cleanup from clearing a successor window. The original regression and ten new
controls pass; the full Linux suite passes 9,875 checks in 477 modules, Linux
E2E passes 189 scenarios, JavaScript passes 369 checks, and actual network
runtime passes four native groups. These results do not qualify enterprise
authentication, installed update/rollback or native Windows/macOS acceptance.

Windows continuation is explicitly deferred to the maintainer's PC. The portable
[Windows handover](handovers/2026-10-04-group6-windows/README.md) preserves exact
patches, source/preimage hashes, dependency order and unexecuted/WIP status.
Its twelve numbered Windows TODO steps cover composition, actual AHK/WebView
controls, WinHTTP/PAC/WPAD ownership, enterprise CA/SSPI, redirect/failover,
installer/serve/pull, installed packaging and update/rollback. Verify each
packet's preimages before applying it; preserve newer owners and independent
assertions. Native Windows tests and release/install acceptance remain unrun.
These Windows steps no longer block the requested group-6 merge; item 62 and
transversal items 16/38 stay open for their remaining validation scope.

The existing actual GTK/WebKit model-pull fixture now sends the progress
bridge's session/failed-presentation epoch protocol. Its successful retry uses
that actual owner, and its post-success stale retry reuses the same failed
token. Every original assertion, native loop deadline and retirement check is
unchanged. Actual Linux CI run 37243798345 on 846eb713514b3921b35594dbca92cc3cb5525aef
passes this native GTK/WebKit/luv/curl scenario. The shared JS and Linux unit
jobs also pass. Six other native E2E steps fail with unknown first assertions;
Linux packaging and installation are consequently skipped. The available
earlier reference run skips E2E after its unit failure and cannot prove these causes
are historical. Preserve the focused follow-up steps in the Linux handover;
this successful scenario does not qualify the whole lane or close item 62.

New reference run 37245806103 executes the exact tree of dev b9a43969b9ac8917f32bf4af0d19b6f77a31668e.
GTK application operands, updater ETag associations, virtual-audio locales and
notifications fail there as executed scenarios. Their exact first assertions
and causes remain unknown; matching source bytes are not causal diagnosis.
SQLite profile and AT-SPI interpreter-option scenarios now pass after upstream
fixture provisioning, which this branch preserves. The reference's older model
protocol also passes; do not claim a baseline failure-to-success for that case.
Final candidate and integrated native qualification remain required.

The bounded group-6 slices are integrated without squash in dev
02ad69e06ecea424de11facf3dced404a6fdd602. Manual run 37248612190 tests
d993de4fc26d8febceac685a334246bb9bdce998, whose complete source tree
is identical to that integrated commit. Shared checks and Linux units pass;
the four executed reference E2E scenarios above still fail, leaving Linux
packaging and installation skipped. The managed model retry scenario passes.
The macOS native archive cohort also refuses; release publication is skipped.
Windows remains the twelve-step PC continuation. Items 36 and 62 are partial;
no completion or native enterprise-network qualification is inferred.

The unintegrated Linux HTTP producer is preserved in the
[Linux continuation](handovers/2026-10-04-group6-linux/README.md), with exact
sources, preimages, independent controls and patches. Actual diagnostic privacy
controls pass 12/12 after six causal failures, with eight bounded-diagnostic
controls passing. Independent review identified defects in public owned
cancellation/activity, admission behind cleanup debt, supported resolver failure
fallback and total-deadline publication/admission. A separate corrected
six-blocker continuation now preserves these corrections and four additional
timer/reentrancy review controls without weakening original assertions.
Its 101 model/native-port controls and four actual LuaJIT/luv timer controls
pass without skips; the unchanged producer fails eleven of thirteen public
cases. The native timer cases restore their initial handle inventory and spawn
no child. These results do not qualify the final GIO/curl/PAC/CONNECT producer.
The generated archive binds exact sources, preimages, review and typed receipts;
its older extracted engine is retained only for causal replay and must never
replace the newer fix/linux core. Native-owner composition, final network and
privacy controls, E2E, packaging and installation remain unexecuted for this
packet. Per-hop PAC, retry leases, installer/pull and enterprise CA/auth/WPAD
remain pending. Refresh ownership and qualify the final composition before
delivery; item 62 and transversal requirements 16/38 stay open.

Linux remote API callbacks now preserve an actual failed transport's private
receipt through chat, decisions, both Backboard hops, model discovery and Test.
Existing positional results, formats, authentication, cancellation and identity
fences remain intact. Successful/malformed application replies and error strings
cannot create transport evidence. Fifteen independently authored caller controls
pass; the untouched producer fails eight of those same controls, and 129 original
remote/provider/auth assertions pass in isolation. The registered control module
keeps those expectations unchanged. This receipt is not a page-safe report and
does not itself implement failure actions. Final managed transport composition,
native network/UI behavior, full Linux and packaging/install remain pending.

Actual isolated Linux GIO/curl composition executes eighteen independent cases:
fifteen pass, two fail functionality and one refuses its prerequisite. Both
functional refusals admit the actual executable but reject its inode above the
Lua safe-integer range. An unchanged replay with a byte-identical curl copy at
an owned representable inode passes seventeen cases; the old-curl negative
case still refuses because the required version below 8.7 is absent. No case
is skipped, and both runs exit nonzero. This diagnoses the representability
boundary; copying curl is not a production fix. The composition remains an
unintegrated preparation. Exact descriptor identity, installed dependency
closure, native document actions, per-hop PAC, updater retry ownership,
installer/server/pull and enterprise CA/auth/WPAD still require qualification.
The twelve Windows PC steps remain deferred; item 62 stays open.

Linux Versions and download actions now require the original native view,
document generation, independent page nonce and acknowledged initialization.
Retired API fetches cannot admit a successor Atom transport, and managed retry
recaptures actual capabilities without borrowing the reopened window. Failed
initialization uses the existing translated native error presentation. Shared
failure reports expose translated actions and operation epochs, while private
transport receipts remain native. Ninety-one focused shared/JS/Linux document
controls pass; causal predecessors remain retained. The complete Linux suite
passes 6,781 tests in 365 modules, and its E2E suite passes. Existing fixture
assertions retain genuine managed initialization and protected module cleanup.
The mandatory Versions browser scenario passes on Chromium and WebKit in
manual run 37309897244 at 055afc3f94377f119c8c1b589ef590b6d0295e11.
That run exposes a native WebKit admission defect: LGI supplies is_loading as
a Boolean property, while the new port called it as a method. The corrected
port and property-shaped fixture pass eighteen independent admission controls;
the old port fails twelve of those controls. Both native window fixtures now
use the actual pause controller; model retries traverse the actual admitted
page bridge and decode native responses. Original assertions and deadlines
remain intact. Selected verification passes formatting, 361 JavaScript checks,
Linux E2E and 7,934 Linux tests in 384 modules. Actual GTK/WebKit model retry and
Versions listing both pass in manual run 37315291545 at
5ce6bc2c9ac682f0764d8f204ef8ca271de18947. Shared checks and Linux units pass;
application operands and the curl-version-sensitive ETag fixture still fail,
leaving packaging and installation skipped. Those scenarios still require diagnosis or their owners' pending
corrections. Item 62 stays partial.

The Linux public HTTP adapter now delegates initial destination routing to
shared proxy policy and an owned native GIO lookup child. Ordered native relay
choices, explicit DIRECT, environment precedence and inherited bypass rules
retain the original absolute budget and physical settlement before successors.
Exact curl/helper image admission uses retained descriptors and decimal native
inode receipts, preserving large kernel identities without floating-point loss.
Runtime prerequisites and package-manager declarations come from one generated
catalogue; package success alone cannot admit missing luv, GIO or proxy schemas.

Normal qualification passes 363 JavaScript checks, 8,206 Linux tests in 403
modules, local Linux/macOS E2E, the existing actual libuv/curl streaming gate,
and four actual Linux runtime groups. The full portable macOS suite passes
14,728 tests; all twelve shared policy controls also pass after the final
normalization correction. New native CI and installed-format qualification
remain required. Per-hop redirects, retained archive-output integration and
portable package closure are separate ongoing slices; enterprise authentication
and recipient system trust acceptance are not inferred. Synchronous filesystem
metadata cannot be hard-preempted. Item 62 remains partial.

The Linux transport composition now preserves both the native AI request-owner
contract and managed proxy admission. Public source consent is reserved before
metadata or proxy probes; physical child/group/handle settlement remains
independent of logical cancellation. Models acknowledge exact process-group
absence separately from leader exit. Fresh window presentation can clean up
only its original native operation and exact pause-state owner; it cannot
refresh download consent. All 76 focused document/presentation controls and
the complete 8,750-test Linux suite in 430 modules pass on the joined sources.
Selected qualification also passes 365 JavaScript checks, 14,731 portable
Hammerspoon tests, both local E2E suites, 48 pure canvas controls, 28 actual
X11/Xvfb checks, 262 streaming HTTP and 48 API authentication observations,
four actual GIO runtime groups and 82 native runtime checks on both Linux ABIs.
The first selected run retains its missing-Pillow failure; the exact failed
48-case gate passes after installing the pinned prerequisite. Windows native
checks and macOS Swift are explicitly deferred to their real hosts. Final
hosted/package qualification, per-hop GET, retained archive output and
installed-format closure remain required; item62 stays partial.

Joining current dev 71ec4563f exposed forty-six callback tuple regressions:
appending absent private evidence added a nil argument to existing callers.
The transport now preserves the original two/three-value tuples whenever
there is no actual failure receipt, and retains optional native evidence
when present. All original callback/sibling assertions remain unchanged.
Exact upstream and corrected composition each pass the 78 focused controls;
the original joined failure is retained. The complete corrected Linux suite
passes 8,969 tests in 433 modules. Actual verified-TLS replay also passes
33 provider scenarios with 75 requests and 30 sibling scenarios with 70
requests, preserving callback counts, ownership and healthy retries. The
first provider attempt retains its missing shared Lua-path failure; the
unchanged fixture passes after activating its documented search path.
Hosted/package qualification and the HTTP fixture corrections remain
required. Item 62 stays partial.

The Linux buffered GET owner now follows explicit per-hop redirect policy,
re-resolves native proxy policy at each hop, strips cross-origin credentials,
and retains the original operation deadline. Independent literal vectors cover
loops, HTTPS downgrade refusal, origin changes and native cleanup receipts.
Archive output has an opaque retained descriptor owner; archive transfer,
digest sealing and installed artifact delivery are still separate pending work.
The final local selected gate passes 365 JavaScript checks, macOS stub E2E
101/101 (one driver-specific vector skipped), macOS stub units 14,731/0,
Linux E2E 189/189, actual HTTP streaming/API checks, native runtime 82 checks,
and Linux units 9,167/0 in 441 modules. AutoHotkey is unavailable and its gate
is skipped. The first local attempt retains actual formatting/source-contract
failures and canonical temporary-directory permission failures; the corrected
sources pass after enabling writes to the existing canonical test directory.
The 198 added normal Linux cases are registered; final-source replay of the
30 actual managed GET and 18 actual output controls, hosted qualification and
installed-format closure are still required. No physical enterprise-network,
macOS installation or Windows acceptance is inferred from these local results.

Hosted run 37430974838 tested the preceding 54493 source cohort and failed:
macOS Sparkle/Brew native lifecycle controls and Linux E2E did not complete
successfully; packaging/install and publication were skipped. Retrieved Linux
logs additionally expose public owned-request predecessor replacement,
preflight cleanup and fixture retirement failures. Their source corrections
and causal native replays remain required Linux work, rather than Windows or
macOS device-only follow-up. Item 62 and transversal items 16/38 remain open.

Final reviewed local sources retain the unchanged nine actual relative-clock
cases:9/0, with first/second loopback HTTP56.24/52.00ms and acknowledged
physical closure. The change-scoped gates pass format, JS379/0, stub macOS
15154/0 and Linux 10142/0. The earlier complete a5a07 range additionally passes
all63 mandatory genuine temporary-native controls and installed archive 3/15;
its window-supervisor and Nix local-store prerequisites refuse, so that full
range remains FAIL and the seven native Nix cases remain unexecuted. Final
hosted E2E, package/install and enterprise-session qualification remain required.

Native Linux CI run37540551778 at a5a07 retains one first-request timeout
(208.57ms/status0) and a successful second request (55.91ms/status200);
10,141 units pass and one fails, with packaging/install skipped. The relative
HTTP fixture now records bounded passive actual spawn/timer/server/callback
times after its original verdict. All nine cases, assertions, 100ms timeout,
40ms server delay and native retirement remain unchanged. On matched genuine
local runtimes, old origin/dev7a75 and current a5a07 each pass9/0 once without
and once with this diagnostic, with physical owner closure. The first old
replay HTTP403 is retained separately; only the common child loopback bypass
prerequisite was corrected. These local passes do not establish the CI timeout
cause or qualify the entire managed-network/package matrix. Item62 stays open.

The portable Linux network closure described in item 36 is also a managed
network prerequisite. Its installed ABI/schema/backend refusal and recovery
controls pass on genuine host components; they do not prove an enterprise
session, authentication or certificate deployment. Package CI now declares
the native development/runtime prerequisites for the stage owner. Installed
AppImage/Flatpak network replay and archive delivery remain required.

Shared archive transfer budgets capture the canonical checksum, archive and
hash caps once, deriving the original total deadline from those caps. Redirects
and relay retries cannot renew a phase. The descriptor-sealing and digest
prerequisite has the bounded qualification recorded in item 36. Mandatory
native runner, planner and CI evidence registrations are added; final-source
validation and the full updater composition remain required.

The ordinary Linux HTTP owner now snapshots prepared headers once, queues a
replacement only behind its exact physically retained live predecessor, and
retains typed descriptor-cancellation debt. Seven additive normal modules cover
55 independent controls; GET198 and existing forwarding assertions remain
unchanged. Selected local gates pass format220, JS368, stub Hammerspoon101/14731,
Linux189/9296, actual HTTP streaming262/API48 and native runtime82 on both ABIs.
The Hammerspoon E2E profile skips one driver-specific vector. Native preflight25
and body-cleanup14 pass with actual child reaping and no pending/rescue debt.
A cold fake-backend fixture leak caused two first-run Linux failures; all seven
new receiving controls fail before and pass after on both ABIs, and both
original native assertions pass in the final full normal suite. Exact finite
results are in the restored-container checkpoint. Native GET30/output18,
cancelled-BOOLEAN successor/body-pipe, fixture335, archive-output/updater,
hosted final-source and installed-format qualification remain required.
Item62 stays partial; no Windows/macOS or enterprise-session acceptance is inferred.

Reviewed pending group6 sources, exact preimages and scoped qualifications are
preserved in the [restored-container checkpoint](handovers/2026-10-06-group6-recovery/README.md).
The installed native archive/update chain remains required; saved patches do
not close this item.

Manual run 37546410275 on f346157c726b96e36f12701ea61b60be76e9e3e9
passes Linux 10142/0, genuine relative-clock 9/0, mandatory temporary updater
63 unique controls, managed output 18/public 30, and installed archive 3/15,
with no product skips in those native receipts. The live update instead
fails before installer acquisition: its first download request was not
dispatched. Genuine Nix fails at pinned-source-metadata before its native
build/runtime cases. Additive fixed owned-phase diagnostics preserve the
original physical owner, clocks, pins and predicates; actual command/fence
refusal remains to be observed. This is diagnostic work, not a Nix fix or
native packaging credit. The previously recorded company-network implementation
remains unfinished.

The Linux release-check owner now waits for its original child and deadline
retirement before parsing, caching, pagination or publishing a check result.
Its final receipt is source-bound and detached from consumer mutation;
cancellation retains pending check ownership until the same physical ACK.
The existing GET Boolean remains first in the return tuple, followed by the
exact original operation. Controlled receiving passes 25 new cases on each
actual Lua ABI, retaining all 134 historical cases across five complete modules
(Manager 73, changelog 13, feedback 8, JSON admission 34, channel 6). The
original producer fails 22 of the same 25 cases, including the early-download
callback. All 34 independent JSON vectors and every old assertion remain exact;
three additional Boolean-only fixtures now declare their explicit modeled
no-resource settlement without a production Boolean fallback.
The required archive port fixture is explicit and throws on unexpected use;
no archive success or physical IO is modeled as native acceptance. The composed
local change-scoped verification passes all 11 selected gates: 379 JavaScript,
16,675 portable macOS and 11,225 Linux unit tests, plus genuine Linux archive,
HTTP, temporary-allocation and runtime controls. Native Swift compilation is
explicitly deferred. Genuine installed live-download CI on these sources remains
required; TODO 62 and transversal 16/38 stay open.

The hosted Configuration restore failure remains red despite an unchanged
local CI-command replay passing all 11,225 tests. A targeted Linux unit-step
capture preserves the original reporter command and nonzero exit, and uploads
only that public log after an actual non-cancelled unit failure. The current
group1 branch's unit step is unchanged; the patch is isolated on group6 and
preserves all other workflow spans, including the French/German audio packages.
This diagnostic supplies no successful unit, native packaging or cause credit.

Current Windows native run37651111440 at `0b0be55e` reports 10,265 passes
and five failures, with E2E, package and installation skipped. The previously
failing integer, ordinal-inventory, CLR layout and held-response paths now pass;
this does not qualify the full Windows lane. Source-reviewed diagnostics retain
all original assertions, native calls, 8-second capability budget, 10-second
receiver budget, cleanup and ephemeral certificate ownership. The canonical
route fixture now emits only bounded returned shape/Boolean/count/limit facts;
30 source-bound receiving model controls and 12 genuine portable PowerShell
routing/projection controls pass, without AHK or WinHTTP native credit. The
remote TLS service exposes only the first fixed stage/exception family/signed
HRESULT; the fixture-only curl capability receipt exposes only a cached phase.
Their actual native receiving is still unrun. None of the five native failures
is relabelled or waived. Diagnose the next original Windows run before claiming
a cause or a successful fix; item62 remains open.

Group 6 end-of-slice checklist, 2026-10-07. Item62 remains open. Delivered
source includes the Linux retained transport/archive chain, the Windows e25
receiving repairs and committed `0b0be55e` integer/ordinal-inventory/CLR fixes.
The [partial delivery handover](handovers/2026-10-04-parallel-containers/GROUP6-RELEASE-NETWORK-2026-10-07.md)
keeps historical failures and separates CODE, native and device requirements.

- [x] Retain Linux per-hop transport, endpoint-owned ETags, same-FD digest,
      archive publication/install/rollback, original pins/clocks and physical
      cleanup. Current official runtime/model receiving passes; full lane and
      final-source package acceptance remain separate.
- [x] Record native Windows37651111440 at0b0be55e:10,265 passes/five failures.
      Integer/inventory/CLR and held HTTP response paths now pass. Subsequent
      diagnostics are committed in b21bea3ee; manual37657524885 reports10,268
      passes/four failures. Package/install remain skipped, without waiver.
- [x] Native Windows1 — original System32 curl capability completion passes in
      manual37657524885 at b21bea3ee under unchanged request/receiving clocks.
      This component pass does not qualify the complete Windows lane.
- [ ] Native Windows2 — receive canonical WinHTTP vector1's exact shape/order/
      limit facts, fix the demonstrated mismatch and replay the full URL/PAC
      vector with original native ownership. Portable PowerShell is not WinHTTP.
- [ ] Native Windows3 — receive the TLS fixture's service failure stage, fix
      its demonstrated cause and preserve the original failure-count expectation,
      ephemeral key ownership and actual server retirement.
- [ ] Native Windows4 — receive actual updater route/trust failure and correct
      classification only with causal evidence. Preserve the original TLS
      expectation, system trust, proxy refusal and provenance; no TLS bypass.
- [ ] Native Windows5 — receive updater service/child/Job cleanup ACK, fix its
      demonstrated join/receiving defect and replay the original failure count.
      Namespace removal cannot replace physical closure or release retained debt.
- [ ] Native/hosted — replay the complete Windows lane on the final SHA. Obtain
      complete Linux E2E/package/install and the original seven-case Nix runner.
      c18's lane failed only Nix native-build; manual37657530026@b21 confirms
      that current failure, with every other E2E step passing. The runner now
      prepares the separate standard build-log directory; independent genuine
      Nix reproduces its missing permission and passes after preparation.
      Complete hosted receiving remains required. Genuine Ubuntu OCI build,
      help and five runtime observations pass, without full seven-case credit.
- [ ] CODE — complete Windows packaged artifact/request owned-curl SSPI/NTLM
      join and causal fallback after exact first-child/pipe closure. Preserve
      full-URL routing, absolute clocks, Schannel trust/revocation, exclusive
      staging/integrity and Job retirement; request SSPI does not prove artifact.
- [ ] CODE — implement macOS full-request-URL PAC/WPAD, ordered fallback and
      redirect routing for uv, HTTPX/HF/Xet and outgoing Ollama Go requests.
      Preserve verified unsupported-route refusal until those paths exist.
- [ ] Device — exercise corporate PAC/WPAD/static proxy, CA/revocation and
      authentication, actual child/redirect failures and useful cause/actions
      on every OS. Check native UI cancellation/successor windows/retry and
      installed upgrade/rollback. Keep transversal16/38 and item36 open.

Prepared Windows routing/TLS diagnostics, curl-engine extraction and macOS
opaque-client continuation are saved in the handover's source-packet archive.
They remain inactive and unexecuted. The macOS audit also finds missing native
PAC evaluation in initial stock-curl installer downloads; that is remaining
CODE. Schannel's documented ephemeral-key constraint needs genuine native
qualification, preserving the original key ownership and TLS assertions.

Manual37670051601 at1b0b3be0a passes shared and Linux unit/official-runtime
checks, but its early GTK dependency/receiving step exceeds the one-minute
boundary and subsequent native cases fail before the Nix step. Terminal raw
logs cannot currently be retrieved; the full failure cause is unproved. Native
GTK and process-group dependencies now also acquire in the existing preparation
step, before either unchanged one-minute native receiving clock. The original
in-case signed dependency checks, package lists, actual providers and every
fixture assertion remain byte-exact. Preparation requires real luv before the
first native case. The first local JS run correctly refuses removing those
original checks; they are retained, and the corrected receiving must rerun.
Two additional signed acquisitions strengthen the independently declared
Ubuntu invocation floor from34 to36. Every original status/mutation assertion
remains unchanged; removing one of those acquisitions still refuses. This
additive prerequisite preparation remains unqualified until the new hosted run.

Manual37670051601 at1b0b3be0a now completes: its original genuine Nix
installed-runtime step passes, including the complete seven-case admission.
The run's shared/Linux unit/official-runtime checks pass, while broader E2E
fails and package/install remain skipped. Release is skipped. The Nix log-root
repair is natively qualified; this does not close62 or qualify the full lane.

Commit9d7b838d570004ba66d974a12410d7032df8eb83 preserves every original
workflow byte while adding early signed dependencies. Local formatting262,
JS382 and original runtime/temporary-registration controls pass, status0 with
no signal/error or retained phase. The failed earlier source-registration
receipts remain; no original assertion is removed or relaxed. Linux-only
manual37677432702 tests exactly9d7b838d5 and remains in progress at this
checkpoint. Native E2E/package/install qualification and dev integration remain
pending. Items36/62 and transversal16/38 stay open.

The closed Windows route diagnostic now records only the single-route source
and kind from the already-returned receipt. All original native PAC bytes,
providers, ordering assertions, clocks and cleanup remain byte-exact. Actual
portable PowerShell AST/helper controls pass74 cases; the source-bound AHK
receiver model passes61 cases. Both close under the original command owner,
status0 without signal/error or retained phase. These are passive projection
controls, not WinHTTP, AutoHotkey or Windows native qualification. A subsequent
native observation must distinguish native DIRECT from static/environment
admission before claiming why vector1 returns one route. Item62 stays open.

Linux manual37677432702 at9d7b838d5 records11,643 unit passes and one genuine
relative-clock failure. Its native trace shows a refreshed clock, request arrival
at79.959ms, the unchanged40ms response delay and callback at100.670ms under the
original100ms budget. This failed receipt remains; neither assertions nor
deadlines are changed. One fresh-run diagnostic is requested at ef67fa390,
whose only delta is the qualification documentation. Complete Linux acceptance
and the early E2E prerequisite receiving remain pending.

The Windows fixture server now uses actual native OpenSSL3 memory BIOs over its
original TcpClient streams. Production Schannel/.NET clients, system-root/CRL
admission, PAC/CONNECT, payloads, counters and original native clocks remain.
Both original RSACng keys stay ephemeral; Framework-compatible PKCS8 export is
pinned only in memory, imported and cleared. Native provider PE/import/path/
hash/version/export fences and exact stream/context/DLL retirement must admit
before the strengthened ready/graceful receipts. All108 original AHK assertions
remain byte-exact;11 provider/closure assertion call sites are added. The updater
receiving source is unchanged. Genuine portable PowerShell parsing and whole
CSharp compilation pass;29 independently specified pure-helper controls pass,
status0 without signal/error or retained phase. No native Windows DLL or TLS
call ran in this container. Native trust/refusal, full updater staging/cleanup
and complete Windows E2E/package/install receiving remain pending;62 stays open.

Windows-only manual37682193508 tests exactly6695173f80e1560aca298ce6cab5252019529e6d
and remains in progress. Linux-only manual37679343730 passes the unchanged unit
suite and official runtime/model acceptance, then fails its combined dependency
preparation after ten minutes and subsequent E2E cases. Its terminal result and
setup log remain pending. No full-lane success is claimed.
The [native-receiving source archive](handovers/2026-10-04-parallel-containers/GROUP6-NATIVE-RECEIVING-PACKETS-2026-10-07.tar.gz)
preserves82 exact source/manifest records with separate portable receiving
summaries, SHA256 d9d2ef1ffb91a82ead067a060d6f9619009d1692276c5ab0afa826dd5baa7903.
Original source-only packet statuses remain distinct from subsequent execution;
no raw private captures, signed redirect URLs or private keys are included.

Windows manual37682193508 at6695173f80e1560aca298ce6cab5252019529e6d
subsequently completes with10,268 passes/four failures. The unchanged canonical
route expectation receives one native_bypass/direct entry; this proves origin,
not why the full-URL PAC selection bypassed. Managed-remote graceful cleanup,
updater TLS versus connect classification and updater deadline/cancellation
cleanup still fail. E2E/package/install and Release are skipped. Raw job logs
are refused; API annotations retain the exact failures. No full Windows
qualification or native TLS repair success is claimed.

Linux preparation now separates core LuaJIT/luv, GTK and compiler acquisitions.
Each dependency role retains its own bounded setup attempt; a prior failed role
cannot prevent a later role's signed acquisition. Real luv is mandatory in the
first bootstrap. All original in-case signed checks, package lists and native
receiving clocks/assertions remain unchanged. The independent acquisition floor
stays36. This fixes the combined setup's failure propagation; actual complete
Linux qualification must still rerun. Items36/62 and transversal16/38 stay open.

Windows service diagnostics now use the existing native TAP receipt writer.
The CI-owned AHK process has no reliable console handle; console-only optional
output can disappear before the retained transcript is printed. The same closed
stage/kind/HRESULT projection now reaches that transcript and its GitHub notice.
This changes observation only: every original native assertion, receiving clock,
retirement requirement and privacy admission stays intact. Genuine receiving
of this channel remains pending; no native failure is counted as repaired.

Integrated manual37688807101 at091743921 completes with shared checks passing,
Linux11,644 unit passes/zero failures and all157 E2E steps passing with none
skipped. The Linux package fails in Flatpak curl configuration because no GSS
implementation is available in the24.08 SDK. Windows retains its four native
failures; Mac Sparkle passes, Brew's deny-removal AppleEvent positive fails, and
the separate native global-switcher/Shortcuts package probes fail. All installed
runtime lanes and Release are skipped. No complete packaging claim is made.

The Flatpak source inventory now adds MIT Kerberos1.22.2 at the exact upstream
commit8570e77819563e036027e1da789d08ec9333ed4d before curl. Its native GSS library
and krb5-config must exist under/app; curl retains mandatory GSSAPI and explicitly
finds that prefix. The regression fails against the old missing dependency;
all original source pins, requirements and assertions stay intact. Actual
Flatpak build/package/installation receiving is pending. This Linux-only
catalogue/generator region is owned by group6; other fields remain unchanged.

Manual37695878081 at2cbcea144 passes shared checks, Linux11,644 unit assertions
and all157 E2E steps, including genuine Nix. Package refuses before the Kerberos
build because Flatpak's implicit Autotools bootstrap requires an autogen script
that the pinned upstream does not provide. Installation and Release are skipped.
The generator now declares explicit SDK commands for autoreconf, configuration,
build and installation under/app; the original source pin, disabled static/rpath
and bundled-verto choices, GSSAPI requirement and installed-library checks remain.
Actual host-source compilation/install passes with physical closure; it does not
qualify the Flatpak SDK. The independent recipe regression fails before this
repair. Native package/installation receiving on the repaired source is pending.

Windows manual37690927221 atc00cec629 remains terminal FAIL. Restored raw-log
and execution-manifest downloads confirm10,272 executed/timed cases,
10,268 passes/four failures and no manifest errors. The canonical route remains
one native-bypass/direct result; no service-stage notice is admitted. Artifact
access does not repair WinHTTP, TLS classification or graceful cleanup. The
handover now lists exactly four current native fixes; the historical System32
curl capability case passes and must not be rebuilt without a regression.

Manual Linux package receiving now continues after a failed E2E job, retaining
successful unit admission through the unchanged E2E dependency. Automatic runs
still require E2E success; cancelled or skipped E2E does not admit packaging.
The final native verdict still rejects any failed mandatory job or absent
subject, and Release remains push-only. This allows item62's real Flatpak SDK
build to be tested while another group's native E2E repair is pending. The
regression fails against the previous workflow and preserves every existing
assertion, original receiving clock and package/install requirement. New native
receiving is pending; this diagnostic admission does not close36/62 or16/38.

Manual37709350150 at3161aada9 passes shared checks, all11,644 Linux unit
assertions and all157 E2E steps without failures or skips. The Flatpak SDK now
builds and installs MIT Kerberos1.22.2 and curl with GSS-API/SPNEGO enabled.
Package then fails at network-gio-proxy because the pinned glib-networking
source has no Meson tests option. Its declared installed_tests=false replaces
that unknown flag; GnuTLS and every proxy-provider choice remain unchanged.
An independent complete option-vector regression fails against the old recipe.
Source pins, all other modules, native assertions/clocks and installation legs
remain intact. New native package/install qualification is still required;
installed GSS libraries do not establish authenticated enterprise traffic.

The SDK log also places libproxy in/app/lib64, outside the existing package
environment's/app/lib lookup. The pinned GIO source derives its module directory
from the selected libdir. Both native Meson providers now explicitly select
libdir=lib; independent full option vectors fail before this correction and
retain every prior provider flag. Other modules, source pins, runtime lookup,
native assertions and installed-format requirements remain unchanged. SDK
compilation and actual installed closure still need final-source receiving.

Manual37713678709 at acb14576c passes shared checks,11,644 unit assertions and
all157 E2E steps. GIO configuration now succeeds, but executable linking exposes
unresolved Duktape math symbols. The pinned upstream shared-library Makefile
does not consume LDLIBS and places LDFLAGS before its source. Its generated
build/install commands now retain libm explicitly while preserving SDK flags
and restoring as-needed for later inputs. A genuine checksum-verified host
source build/install reproduces refused original consumer linking, then passes
corrected linking and Math.sqrt evaluation with libm, RELRO and BIND_NOW.
Both source identities and every GIO/native assertion remain intact. The
preceding native run skips installation/Release; final SDK/package/install
receiving on the new source remains required before any completion claim.

Linux manual37714714116 at9d26b947e passes11,644 unit assertions, all157 E2E
steps and the complete package job, including actual Flatpak build/install/run
and tarball installation. Three binary installation variants pass;14 source
variants fail: five lack a caller-supplied compiler under--no-deps, seven omit
the canonical builder from the first-install checkout, and two Fedora variants
refuse because no verified LuaJIT networking provider is declared. Compiler
and libc-header packages now have a separate shared catalogue projection;
source installs provision them, binary installs do not, and--no-deps preserves
caller ownership. CI retains every original installation assertion and supplies
the missing source prerequisites. Local regression and selected gates pass;
native receiving of this repair and the separate Fedora provider work remain.

The Fedora source-install bootstrap now uses the same immutable luv commit and
CMake options as Flatpak, compiling against the recipient's actual LuaJIT and
retaining its Git/build evidence. GIO, schema and compiler prerequisites come
from a separate shared package map; the absent distribution LuaJIT package
remains explicitly absent. The generated module is atomically installed under
the private driver namespace, recorded in uninstall ownership and selected by
the standalone launcher. Source/native directory aliases and malformed recipes
are refused. Genuine host compilation and C-entry loading pass, including a
foreign inherited Git-namespace control. Full selected gates and hosted Fedora
first-install receiving remain pending; this does not close item62.

Manual37747891785 atb4ef975f1 passes all shared checks, Linux units/E2E,
the complete package job and13/17 installation variants. Release is skipped.
The remaining four failures are the two Fedora provider refusals and two
Alpine source compilations missinglinux/magic.h. The source-build catalogue
and the unchanged--no-deps caller now also provisionlinux-headers on Alpine;
no binary runtime dependency or native assertion is removed. The independent
header-package regression fails before this correction. Final native receiving
of the combined Fedora/Alpine repairs is still required.

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

Group3 qualification checkpoint, 2026-10-06: run 37451229133 is terminal
FAILED. Windows passes 9,693 cases with nine program/decoder EOF failures;
brightness and shutdown pass. Linux units pass 9,126/0, and GTK operand,
hold-consumer and native window gates succeed; Linux E2E fails only the
separately owned updater ETag assertion. Windows downstream E2E/package/install,
Linux package/install, unselected macOS and Release are skipped. The earlier
GTK/brightness failure causes remain unknown; a successful later component
run does not establish their cause.

The basic-15 diagnostic run 37454415583 is terminal FAILED on CI commit
17c2d4e0e526c97e6a33fdb30d63032873dc064b, feature
9fcef640b8e55e96d645f6ab756f0e21e8f0448b and tree
5870b02163302d71d7cde21687ff11bf20a8df79 records Windows 9,700 passes and two
BOM-fixture failures. Linux E2E fails the GTK operand receipt (closed facts:
stage=receipt, case=0, exit=1) and the separately owned updater ETag assertion.
The GTK refusal remains unexplained; local four-case successes do not qualify
that failed hosted boundary. The reviewed atomic pending-file rename and
UTF-8-RAW fixture repairs now preserve the original assertions but still require
fresh hosted execution. Core JS/properties, Linux units, hold-consumer and
native cursor-window gates succeed. Windows downstream E2E/package/install,
Linux package/install, unselected macOS and Release are skipped. Linux mandatory
E2E evidence recording/upload are skipped; complete installed qualification is
not claimed.

The separate Windows-only private 27-case constructor run 37454501003 on CI
commit 10882b95122a691f62bf9bf4633ccb2739aab044 and candidate
43d8026cf97c9077c77762f9eb6b5f1f844ca86f, tree
ae799563db349f7df9f8b1e93f96e12e8201f106 records 9,709 passes and five failures:
two BOM-fixture and three brightness five-second failures. Its 12 native
constructor cases pass, but the whole run fails and the constructor remains
inactive/unadmitted to Root. Do not infer a brightness cause or whole product
qualification from those partial results. Core JS/properties pass; Windows
downstream E2E/package/install, unselected Linux/macOS and Release are skipped.

Fresh qualification of the current EOF decoder and BOM/GTK fixture repairs is
in progress on committed feature 089008a19f1aff8b63e8beb832fbae037f5311c5.
Minimal run 37458316115 selects Windows/Linux on CI commit
54b02cdb5bab61ec746fdf49bb87a63358314a80, tree
87eba1ed8af60a07ecfe95dea57bc2ef293adbb3. The separate Windows-only private
constructor run 37458344080 tests CI commit
78781632bf098fb7c19ceaec35d29e12b61219b4, candidate
9fa92730dba206e1e9bd97b7a5f61d8a9b0defd2 and tree
81405a1af10e61234f94c24ff7086438e01ee9c0. Both runs are PENDING at this
checkpoint; no successful or failed final result is claimed. The private
constructor remains unadmitted, and no TODO item is completed by starting CI.

Root merged dev b6fa826fb639f7f1a81cee5ebb99a3f1f5853fa5 while retaining both
independent SQLite transport oracles. Actual LuaJIT fixed/restored projections
pass 1,026 grouped/3,402 raw rows; both legacy column omissions are refused.
The earlier smaller fixture passes 648/2,808. Lua 5.4 retains the unchanged
numeric-comparison failure on previous, incoming and composed sources, with
later alias checks unexecuted; it is not green. Root formatting, 362 JS checks
and 1,855 encoding checks pass before these doc changes. All 13 items remain
open. Complete feasible software/native unit/E2E/package/install work in CI;
real-device tasks are separate. Older receipts remain historical evidence
rather than qualification of final sources.

Fresh minimal run37458316115 records9,700 Windows passes and two brightness
worker five-second failures, with the owned root still running. All15 program
cases now pass. The private constructor run37458344080 succeeds completely:
9,714 Windows unit passes, E2E, compiled packaging, installation and startup;
Release is skipped. This does not establish why the minimal brightness worker
stalled. Its fixture now writes only eight closed phase markers, observed via
a capped64-byte native reader at the unchanged failure deadline. All121
existing assertions, five provider cases, actual WMI doubles, polling and
exact tree termination remain unchanged. Marker cleanup requires termination
acknowledgement; the shipped worker is untouched. Native marker/reader
qualification and final integrated-source acceptance remain required.

Remaining work for item63 (CI-feasible software first):

- [ ] Software implementation/repair: Preserve the Windows brightness worker/provider and suspend owner; characterize the three private-run five-second failures, repair only demonstrated regressions and requalify final sources; preserve nested LASTEXITCODE, complete WMI readback, unavailable providers and exact Job/process retirement.
- [ ] Hosted native qualification: Run real Windows worker/provider and ownership regressions, then all affected OS unit/E2E, compiled packaging, installation and isolated startup gates. Provider doubles do not measure light.
- [ ] Separate device/evidence boundary: Measure physical display luminance on supported backlight hardware and confirm honest refusal on hardware without a provider.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 63, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Preserve the qualified brightness owner and finish required native package/install acceptance; investigate only demonstrated timeout regressions. Separate device/evidence boundary: Actual display luminance and retained evidence for historical timeouts.

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

The exact composed source retirement passes 13,281 macOS unit cases, 4,960 Linux cases and E2E suites of 101 and 154 checks. Four comment-banner widths caused the initial JS parent failure; the exact comment-only correction range and complete 353-check JS rerun pass, with the original failed receipt retained. Both canonical generators produced the owned artifacts. Exactly two save calls disappeared with the retired binding methods; every one of the remaining 57 calls and strict acknowledgement predicates is unchanged, and independent missing-call and unguarded-call mutations are rejected. Fresh integration retains the existing native Metrics consent and compensation owners, general action catalogue and exact historical unknown-source preservation. Native Windows and complete packaging/installation qualification were pending at this historical source checkpoint; the later actual receipts below supersede that status.

Native Windows checkpoint 37107656277 retains 7,958 passing unit cases but exposes two genuine source-preservation failures: the real full save retains the retired Metrics values while its canonical serializer discards their unowned comments. Ordinary candidate composition now retains unmatched physical records and comments around explicitly owned canonical rows, checks the complete requested semantic model, and keeps source, lease, staging and publication refusals unchanged. Independent handwritten byte vectors run through both shared Lua ports and the actual Windows builder/publication owner; the original collector assertions and namespace no-op controls remain intact. The shared corpus also qualifies header-only comments and fully owned scalar records; a changed quoted literal-dot assignment stays explicitly refused before IO on the Lua ports, while Windows keeps its existing writable canonical contract. Portable full qualification passed 13,289 macOS units, 4,989 Linux units and 101/176 E2E checks; the final formatting/comment delta reruns the required static gates. Keep item 71 partial until a non-release native Windows checkpoint qualifies this repair and the complete three-OS package/install/launch gate finishes.

Checkpoint 37116696443 no longer reports the two real full-save retired-Metrics comment failures. Its remaining two Windows assertions concern obsolete comment-removal expectations, which are aligned separately with the approved source-preservation contract using complete-image and typed-value assertions. Linux unit, E2E, package and all 17 installation/run variants passed; macOS unit, E2E, package and nine installation profiles passed, while clean and Karabiner AppleEvent probes remain blocked. Windows downstream package/install gates were skipped after the unit failure; Release/Publish was skipped. Item 71 remains partial pending a complete native three-OS checkpoint.

The maintained AHK and Hammerspoon configuration-schema draft examples no longer recommend the retired dedicated Metrics-window shortcut table. The existing CJS retirement gate checks their actual semantic table headers, including quoted and array-table aliases, while literal-dot foreign table names remain distinct. All other draft consent, color and privacy records remain byte-identical, and the generator registry confirms the examples are separate from generated runtime templates. Whole-document draft schema validation remains separate; item71 still requires a complete native three-OS package/install/launch checkpoint.

Remaining work for item71 (CI-feasible software first):

Integrated checkpoint `7a75da439` ran manual CI `37539552261` on its exact
tree through `codex/ci-validation` SHA `532aad27`. All Linux unit, E2E,
package and seventeen installation/run scenarios passed; Core JS/properties
passed. Windows retained 9,734 passing AHK records and ten native observer
ownership scenarios, but the fresh-clone fixture failed at Git checkout on
the newly archived evidence's long paths, before application startup. The
fixture now configures `core.longpaths=true` only in its new private clone,
before checkout, and verifies the local setting. The complete clone, exact
HEAD, tracked driver projection and all native boot/retirement assertions
remain mandatory. Separate
macOS TIS, Brew receiver, switcher and Shortcuts failures remain explicit;
downstream Windows/macOS delivery was skipped and Release/Publish skipped.

The integrated clone correction `5d1d06854` was replayed by Windows-only
manual run `37542732140`, exact CI SHA `6c9d575ce`. All 9,734 AHK records,
70 E2E cases, complete source boot, fresh clone/reload/warm startup and
packaging passed. Installation admission then refused the actual Python
catalogue reader before compiled boot; the original assertion retained no
child error/status, so its cause is unknown. The downstream 23 programmable
cases were unexecuted, not failed test cases. Release/Publish was skipped.
At that historical checkpoint both manual runs were terminal, the owned
integration lock was released and the feature remained for isolated
preparation and qualification.
The reviewed diagnostic successor keeps the exact original execution,
predicate, 5-second deadline, buffer and all earlier assertions, exposing
only closed result/status/error/signal facts without streams or private
values. Independent controls retain 55 assertions: fourteen observability
failures on the old helper, none on the successor. The later successful
native replay below does not diagnose the original refusal cause.
Published diagnostic successor `0ce682b1f` preserves those boundaries. The
Windows launch job now selects the repository Node version and Python 3.12
using the existing packaging setup policy, after bounded ownership
coordination. The observed unpinned Node version is corrected; the native
Python refusal cause remains unknown. Manual Windows run37546977032
on CI `f3473b8b0fa29ac20032fbd2dc01908ffac5e458`, exact candidate
`92ae2ba0af9f3bc57789d0786c61f4b944ba4564`, completes successfully:
9,734 units, 70 E2E cases, complete source/fresh-clone/warm startup,
package/install and 23 compiled programmable cases. Native install admission
uses actual Node22.22.2 and CPython3.12.10; no original assertion or
deadline changed. Integrated configuration run37547053814 on dev8cba7a0c
also passes the complete Windows chain (10,089 units) and all17 Linux
installation scenarios. Its complete CI fails native macOS packaging;
macOS installation and release are skipped. Item71 remains partial for
final-source full-save/upgrade and complete three-OS qualification.

- [ ] Software implementation/repair: Keep the completed dedicated Metrics-shortcut retirement and ordinary Metrics actions; repair only demonstrated regressions in unknown retired values/comments, consent or compensation.
- [ ] Hosted native qualification: Requalify native full-save, installed upgrade/startup and complete three-OS unit/E2E/package/install/launch gates on final sources.
- [ ] Separate device/evidence boundary: No new device-only task is established for this retirement; item38 retains its independent physical requirements.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group3 qualification checkpoint (item71, 2026-10-07): [Group3 continuation](handovers/2026-10-04-parallel-containers/GROUP3-2026-10-06-CONTINUATION.md). Preserve the completed Metrics retirement, unknown-source comments and successful native Windows runtime/startup/package/install qualification37546977032. Integrated configuration run37547053814 passes Windows and Linux delivery; native macOS packaging fails and installation is skipped. Keep final-source full-save/upgrade and complete three-OS acceptance open. No new device-only task is established; item38 retains its independent physical requirements.

Final partial integration `70fda177fd4c1411197aec908aadb954f01c8ca1` is qualified by Windows-only
manual CI 37555144797 on exact validation SHA `dd194edaa4c6e2c7bd42e621bd8d38f4d84e92fe` and tree
`d3bcec2d598c56404f7b8952e11a8e2b2128c759`. All 10,097 units, 70 E2E cases, native startup,
package/install and 23 compiled acceptance cases pass; nine jobs pass and
three are skipped, including Release/Publish. The final documentation receipt
changes no native inputs. Complete final-source three-OS save/upgrade and
macOS package/install acceptance remain open; this is not item 71 completion.

- [ ] **73.** Partial: Windows combination families and pairs already use
      the canonical translated tap-hold key labels; macOS now resolves both
      physical keys through the same catalogue and invalidates its picker
      cache when the locale changes. The complete 182-entry native matrix,
      action IDs, press order and setter refusal boundaries stay unchanged;
      the three script-management pairs remain hidden. Linux now provides
      shared labelled ordered tap/hold pairs; simultaneous chords remain
      unavailable under the existing translated platform reason. The
      real macOS provider regression covers all 21 locales; shared contracts
      also replay each driver's physical catalogue. Native CI qualification
      remains pending. Find which action left the French magic-key category
      off in the maintainer's config.toml on 2026-09-30 (a
      restore, a clear or the wizard), since « ct★ » did nothing only because
      `category_enabled.french_magickey` was false; no historical attribution
      is established yet.

Historical notes in commits `accf53c7f` and `6145b014f` record
`french_magickey = false` in the September 30 18:06 backup while
`magic_key`, `french_autocorrection` and `french_distancesreduction` were enabled. The boot message counted three
disabled feature sections under that one gate, not three disabled categories.
The parallel-container handover retains no original before/after configuration,
log or backup for attribution, and the maintainer cannot recall the preceding
operation. Source review found intentional clear, explicit-disable and wizard
writers, but no independently demonstrated writer regression; keep this
historical attribution requirement partial.

The physical-label contract is independent of the native matrix and stored action
IDs. Original provider cases fail before the fix; the qualified component suites
pass with all 21 locale catalogues. Full native CI remains required.

Remaining work for item73 (CI-feasible software first):

- [ ] Software implementation/repair: Qualify the actual translated physical-key labels, complete 182-entry matrix, unchanged action IDs, hidden script-management pairs and all 21 locale menus. Change a writer only after a reproducible regression proves its cause.
- [ ] Hosted native qualification: Run native provider/menu, unit/E2E/package/install cases on affected hosted OS runners; retain the independent physical-label contract.
- [ ] Separate device/evidence boundary: September30 attribution still lacks contemporaneous before/after configuration/logs, and the maintainer cannot recall the operation. Clear, explicit disable and wizard writers are possibilities, not a proved cause; never force-enable the category or invent attribution.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 73, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Preserve translated labels and the 182-entry matrix; qualify actual providers without guessing a configuration writer regression. Separate device/evidence boundary: Historical writer attribution requires retained evidence; one disabled gate and three boot sections do not prove three disabled categories.

- [~] **81.** The maintainer asks to treat item 54 now (every menu row is
  declared in the shared manifest, none built in a driver's folder):
  Windows 28, macOS 32 and Linux 31 rows are still built by the
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
  Dynamic caption admission now validates the genuine English formatter
  before lazy getters, with literal and escaped-percent controls. It is a
  renderer prerequisite and does not retire native sites or close this item.

  Corrective Windows CI `37621118292` completes 10166/1: the earlier menu
  regressions and native cleanup controls pass. The sole remaining OS-call
  purity failure is addressed by moving exact captured-handle probes into
  the existing native tray adapter, without raising its baseline. Follow-up
  Windows CI `37625043296` completes 10166/1: the purity and menu controls now
  pass; the sole failure is the actual Python program-provider argv receipt,
  routed to its Group 3 owner without changing its assertions. Windows E2E,
  package and installation stay skipped; this item remains partial.

  Current Group 1 software and device boundaries are recorded in the
  [2026-10-07 checkpoint](handovers/2026-10-04-parallel-containers/GROUP1-CURRENT-CHECKPOINT.md).
  The selected local gates pass on published `fad59c821`; exact-source native
  CI reported Windows menu/fixture failures and retained macOS packaging
  failures. The Windows follow-up preserves foreign detached owners and
  original assertions; final native qualification remains required. All six
  Group 1 items and requirements 16/38 stay open.

  Current shared child-template, native-list/lazy-group, presence and inert
  presentation-refusal APIs are implemented. The historical classification
  above does not mean these APIs are absent; remaining provider families still
  need genuine shared data/order/policy consumption on the applicable drivers.

  Integrated partial-delivery checkpoint: Dev8cba7a0c/treec0a8c809 contains
  all117 feature commits. Final CI37547053814 is failed only at macOS Package
  and its verdicts; Windows10089/0/full installed chain and Linux17 acceptance
  variants pass, while Mac stubbed units/E2E/native canvas12 pass and Mac
  Install/Release skip.53/86/61 retains200 software sites. All six items stay
  partial; items16/38 and source-specific historical receipts remain intact.

  Current qualification checkpoint: exact cee55e1a/treea17350f2 CI37541202298
  has native AHK10089/0, macOS canvas12 and the entire Linux chain with17
  install/launch variants passing; Windows fresh-clone and macOS package still
  fail on that source. Corrected Windows CI37543830928 on exact20352/tree6641
  is terminal successful across native10089/0, startup/fresh clone, E2E,
  package, installed compiled/programmable admission and mandatory verdicts;
  Release is skipped. The two personal-shortcut cases belong to that native
  runner: aggregate proof only, no individual manifest or artifact fields
  inferred.53/86/61 retains200 software sites; all six items remain partial.

  The generation numeric-boundary family consumes actual shared fragments at
  its four former native constructor sites, preserving cross-driver order and
  genuine hidden absence. Counts above are the owner-generated result, not a
  raised ratchet or a claim that remaining provider families are complete.
  Original corpus, locale, native callbacks and prior assertions stay intact;
  final native three-OS qualification remains required.

  The shortcut-extension presentation family now shares the actual Windows
  and macOS boundary while preserving Linux's boundary absence and extension
  functionality. Four true native constructors migrate; three were counted
  by the unchanged scanner, including no previously counted Windows heading.
  Item 54 records the exact 62/95/73 census, callback/sandbox preservation,
  qualified portable controls and remaining native/installed acceptance.
  No item is removed, and all six group items remain partial.

  The Windows qualification successor for the shared Tap-Hold head retains its
  real four-row Win32 and refusal assertions; item 54 records the precise
  sparse-field/renderer/dispatch contract corrections. Native CI is pending.

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

The fixed Linux selection helper trio is now declared; see item 54 for its
independent regression evidence and remaining separator/native qualification.

The per-key native/no-action command uses the shared declaration on all three
drivers, retaining each platform's established caption and native callback.
Only this fixed command source is retired; tap/hold pickers, separators and
remaining provider rows keep items 54 and 81 partial. Final native qualification
is still required.

Windows workstation handoff (maintainer instruction, 2026-10-04):

- [ ] Continue the remaining Windows menu families using shared templates and the item54 census. canonicalHoldOptions is already shared; do not cosmetically reimplement it.
- [ ] After every Windows push, cancel automatic runs on its exact SHA. Use manual ci.yml with windows for Windows-only changes, or all affected OS lanes for shared changes; let manual runs finish and record native/E2E/package/install outcomes independently.

Partial dev handoff (2026-10-05): use the immutable resumed menu archive
and its independent reviews; no saved packet qualifies an integrated feature.
Complete the source steps under item 54, then native E2E/package/install and
real-device menu acceptance. The Windows timing UI and macOS Wrap refusal
transaction are already implemented; retain their native acceptance steps.

The composed 2026-10-05 source census is Windows 83, macOS 126 and Linux 93 after the additional three macOS Swipe sites are migrated. The canonical generator owns the 76 menu sections and the baseline generator owns this lower ceiling. Clicked mode children and the composed sensitivity heading are distinct proof edges; the latter does not claim the eighteen numeric native choices. Other fixed/native provider controls remain source work, so this item stays partial.

The About build/version separator now consumes the same shared fragment on all three drivers. Independent actual provider and mutation controls retain all earlier assertions; the unchanged source scanner measures Windows82/macOS124/Linux92 fixed sites. Native Windows and final three-OS qualification remain required. Other fixed provider families stay open.

The packaged macOS About check uses the existing shared command for both native callbacks, preserving offered-release consent and declaration withdrawal refusal. Its actual owning scanner lowers only macOS124 to123 fixed sites; Windows82 and Linux92 remain. Final native qualification and the remaining fixed families stay open.

Windows Wrap validation now observes its actual shared catalogue and separately checks labelled acknowledgement and all15 Win32 rows with3 separators. Production rendering and independent catalogue expectations remain unchanged; this fixture correction needs actual Windows rerun and does not complete the remaining menu families.

The declared Windows gesture tap boundary retires one more fixed native separator site. The canonical census is Windows81/macOS123/Linux92, reproduced by its owning scanner. Actual Win32 and fail-closed behavioral assertions are registered but not executed locally; remaining families and installed/native acceptance keep this item open.

The missing layout-bundle status and empty installed-layout status rows have moved to their existing shared declarations. The unchanged owning scanner now counts Windows81/macOS120/Linux91 remaining fixed native sites. Earlier corpora and native selection/installation behavior are retained; this is a bounded software slice, not complete menu migration. The empty macOS Input Sources provider also consumes a shared Open preferences command with the unchanged native callback; retained declaration withdrawal refuses before launch, and no true launch acknowledgement is fabricated.

The custom-profile, saved-model and numeric-tail slices retire seven macOS and seven Linux fixed native sites from the preceding 81/120/91 census, yielding 81/113/84. This is a bounded migration using existing child-template APIs, not the complete ordered profile parent frame. The remaining scanner sites, native qualification and item38 device acceptance keep this item open.

The shared profile heading fragments retire three genuine allocator sites per driver, from81/113/84 to78/110/81. Portable actual provider cases and all original assertions/corpora are retained. This bounded source migration does not close the remaining full profile frame, other menu families or item38 device validation.

The ordered profile frame retires three Windows, four macOS and four Linux native allocator sites through the actual shared renderer. All old provider callbacks, main/close/lifecycle boundaries and prior independent corpus files remain. This slice baseline is75/106/77; whole remaining families and item38 acceptance are not completed.

The fixed model-picker tail presentation is shared on all three drivers, retiring one authentic native allocator per platform. Current remaining baseline: Windows74/macOS105/Linux76. This does not classify remaining dynamic native builders as shared or close item38.

The Agent per-system Model command and its preceding separator are now declared as shared two-row templates on all three drivers. macOS observed installed/missing captions use the same declared command through separate templates and existing translations. Native callbacks, dialogs, validation and transaction/refusal behavior stay unchanged. This bounded source migration lowers the actual native-row census from Windows74/macOS105/Linux76 to73/104/75. Independently frozen owning probes pass Mac19/0 and Linux23/0 on both Lua runtimes, against genuine original-producer15/4 and21/2 controls. Actual Windows/Hammerspoon execution, CI, packaging, installation and device acceptance remain separately unqualified; the other native sites and all six global TODO items remain partial. The Linux regression uses genuine runtime translation scopes and restores exact prior module identities, including a warm French backend and a raised scenario. Independent warm controls pass5/0 on both Lua runtimes; the unchanged previous fixture reproduces1/2 French-caption failures. No persisted locale choice is changed.

The fixed API Add-entry affordance and its existing separator now consume canonical shared templates on all three drivers. Windows retains its dialog command; macOS/Linux retain their native provider children, callbacks, separator order and availability policy. Existing 21 translated captions are reused. Canonical generators reduce the actual remaining native-row census from73/104/75 to71/102/74. Independent owning portable probes pass Mac59/0 and Linux LuaJIT43/0; genuine French-warm controls pass3/0 on each driver and Lua runtime, while the original native producers fail1/2. Actual AutoHotkey/Hammerspoon/GTK, full final CI, packaging, installation and item38 device acceptance remain separate. Other native families and all six group items remain partial. The whole Linux tray fixture now owns the genuine API entries/backend/builder cohort and a private real JSON source. All old assertions remain; independent whole-tray replay passes9/0 on both Lua runtimes in English and French, preserves the malformed external API file byte-exact and restores module identities/private paths on success and refusal. The original incomplete fixture fails4/1; rejected V3 passes7/0 while quarantining that external file and is not adopted. Full Root and native final qualification remain pending.

The existing Windows/Linux separator after backend choices now uses one canonical shared child template. Actual backend, model and port callbacks and native ordering are unchanged; macOS had no corresponding separator and remains explicitly hidden and byte-exact. Independent handwritten platform/order tests, actual native producer inversions and both owning generators retain all previous assertions and21 translations. The real remaining census falls from71/102/74 to70/102/73; unexplained platform debt remains104. Focused and French-warm portable controls pass3/0 per runtime versus genuine predecessor1/2. Native AHK, full composed qualification and installed-device acceptance remain separate; items54/81 remain partial.

The shared per-model Specifications and Capabilities frames retire four genuine Windows and four genuine macOS allocator sites, reducing 70/102/73 to 66/98/73. Linux's actual absence is declared; native callbacks and dynamic detail rows retain their existing owners. Independent source, locale, corpus and original-producer controls are qualified. Final composed native CI, the registered Windows cases and item 38 device acceptance remain open; the remaining 66/98/73 sites keep items 54/81 partial.

- [~] **88.** **Partial: native prediction tooltip appearance.** Shared
  llm-line-style policy and the unchanged independent line corpus retain grey
  typed, green corrected, orange next, inactive emphasis, both selections and
  indentation 0,+2,-1,-3. Windows uses actual font/weight measurements and owned
  GDI deletion debt; diagnostic run 37285932690 passed28 native GDI/line-layout
  controls, without qualifying later unmodified source or whole delivery.
  Linux production GTK/cairo/Pango has12 untouched headless X11 captures on
  ea6e849df82f2a67e321b1ca7aa885f145101b93, with real glyph pixels, alignment,
  bold/regular ink and mapped/focus-free flags. This is not physical input or
  native Wayland acceptance. Source/screenshot hashes remain in the handover.
  Mac production formatter/styledtext/canvas diagnostics and independent pixel
  observer are adopted. Mandatory pure/native registration is committed;
  the hosted three-OS manual run will qualify the exact composed tree. The original38 pure observer/supervisor controls and ten added controls
  pass48/0. Replaying all12 unchanged signed-Hammerspoon screenshots passes12/0.
  The canonically formatted final observer also passes48/0 and12/0 replay.
  These image replays do not replace fresh native creator and source-freeze
  qualification; missing GUI/trust/capture/cleanup must fail, not skip.
  Direct-source manual run37306690694 produced all12 Mac native captures with
  exact child retirement, but failed its independent typed-text locator on
  antialiased marker pixels. The corrected locator and neutral-contrast weight observer preserve unchanged
  screenshots, independent prefix/font/color/geometry assertions and the1.03
  bold threshold. Original-source and removal-only controls fail as expected;
  Fresh native run37314015214 passes all12 signed-Hammerspoon captures and48
  pure controls, with3082 exact source/probe hashes, all PNG hashes and actual
  creator PID/PGID1767 physically retired. Its whole macOS package lane fails
  five Swift cases (303 passed/5 failed), leaving install/launch skipped.
  Direct-source Windows37316704100 passes all28 tooltip/GDI controls.
  Remaining: real-device typography/geometry/retirement, Linux/Mac physical appearance/input,
  packaging/install and desktop acceptance. Preserve Windows PC steps 11,12 and
  all resource/line-corpus assertions. Transversal 16/38 remain required.

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
  Remaining work for item91 (CI-feasible software first):

- [ ] Software implementation/repair: Implement symmetric simultaneous chords, delay and tap-to-chord copying through the actual hook owner. Resolve key-down hold arbitration and synthetic AltGr LCtrl ordering; preserve recommendations, clear and unrelated/future parameters.
- [ ] Hosted native qualification: Run native Windows hook/unit/E2E cases for both orders, delay boundaries and fake-LCtrl refusal, then compile/package/install/startup. Shared changes require all affected OS lanes.
- [ ] Separate device/evidence boundary: Verify real keyboard ordering when a key held alone is joined and actual AltGr generation; injected events do not prove physical hook ordering.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 91, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Complete Windows simultaneous chords, delay/copy, hold arbitration and fake-AltGr-LCtrl hook ownership, then native hook/compiled acceptance on the maintainer Windows workstation. Separate device/evidence boundary: Real key ordering and actual AltGr generation.

- [~] **93.** Linux: the key combinations of item 91. The shared ordered-pair
  model now runs through the actual tap-hold engine, keyboard hook and
  native configuration owner, using the same pair IDs, slots and sections.
  Controlled fixtures pass 43 new cases and 99 unchanged engine/hook cases
  on both Lua ABIs; eight independent behavioral omissions turn controls
  red. Eight added terminal route/pause reentry controls fail on the old
  owner and pass after final private currency checks. This first tranche supports ordered tap and hold pairs on one exact
  keyboard, with modifier restoration and source/retirement fences.
  Simultaneous chords, cross-device pairs, native-only caps_word and
  one_shot_shift actions remain unavailable. The ordered-pair menu and
  generated manifest now admit the reviewed Linux configuration scope.
  Its staged delivery fence prevents native output while any participant
  can still refuse publication or retain inverse debt. Final route currency
  is checked after pause observations. Reviewed controlled scope/owner
  fixtures pass 50 scope and 49 pair-owner cases per Lua ABI; six actual
  menu controls preserve the full 182-pair matrix through a bounded native
  hold picker. The unchanged whole-tray ceiling is respected: 2,291 rows
  instead of 8,297. Linux onboarding No explicitly disables its independent
  pair owner even on a first run or while ordinary shortcuts are off;
  existing tray choices survive Yes without a new import. Formatting and
  all 360 JavaScript checks pass, portable macOS units pass 14,895/0 and
  Linux E2E passes 189/0. The normal-JIT, uninstrumented composed Linux
  suite passes 8,156/0 across 393 registered modules. Fixture-owned native
  library caches survive suite restoration, and actual window-action tests
  use scoped SDK admission rather than accidentally opening GTK headlessly.
  Portable macOS E2E passes 101 cases with one native-host skip.
  The admitted physical scope tranche now composes global clear/recommended
  with the ordered pair owner. Pair delivery remains fenced through program
  retirement, native installation, canonical publication, parameter release
  and inverse recovery; refused terminal receipts retain exact cleanup debt.
  The shared physical editor/model and read-only XKB additions do not add
  simultaneous chords or qualify physical pair input. Native hosted input,
  packaging, installation and physical acceptance remain unqualified.
  The current composed Linux suite passes 9,126/0 across 433 modules. Its
  paired-scope compensation retains the exact delivery fence while paused;
  normal edit and delivery admission still refuse. Native Luv fixture cache
  custody and current canonical Ctrl+G fixture owners preserve every previous
  assertion. Final integrated CI and physical input acceptance remain open.
  A baseline CI prerequisite also required a fixture-only raw SQL token
  transport repair: the independent aggregation oracle now returns the
  reader's byte-preserving token_json field while retaining all 21 assertions.
  Actual SQLite on the declared LuaJIT target passes; independent embedded-NUL
  and Unicode byte controls pass on both ABIs. The extra full Lua 5.4 run still
  fails its existing extreme-number comparison and is not claimed green.

Remaining work for item93 (CI-feasible software first):

- [ ] Software implementation/repair: Preserve the admitted ordered Linux engine/delivery fence. Implement remaining simultaneous chords, cross-device ownership and native caps_word/one_shot_shift where supported, with explicit unavailable reasons and source/modifier/retirement currency.
- [ ] Hosted native qualification: Qualify native Linux ownership and Windows/macOS parity, unit/E2E/package/install/startup. Requalify the reviewed GTK receipt-publication fixture repair without inventing its historical hosted failure cause; the separately owned updater ETag gate remains failed. Preserve closed evidence and explicit-none, duplicate-source, held-input and independent SQLite oracles.
- [ ] Separate device/evidence boundary: Qualify genuine evdev grabs, supported X11/Wayland seats and multi-keyboard pairs. Xvfb and controlled hooks do not prove physical input delivery.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

The native modifier-hold consumer fixture now loads its actual shared Typing
selection helpers and production selection constants. The missing dependency
reproduces on both current sources and dev13 after12 successful SQLite checks
and four Apps checks. The reviewed fixture-only repair retains every original
assertion, SQL query and independent expected number; actual LuaJIT and Lua5.4
replays pass12/0 SQLite and5/0 consumers, with four omission controls rejected.
Production readers, writers, schemas and consumers are unchanged. Hosted
revalidation remains pending; these checks do not qualify physical input.

Current Group 3 source checkpoint (item 93, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Preserve ordered Linux pairs and historical fifth GTK 4/4; diagnose the current delayed-identity poll miss, then complete simultaneous chords, cross-device ownership, remaining native actions and physical-host/input/distribution acceptance. Separate device/evidence boundary: Genuine evdev/device/seat delivery and multi-keyboard acceptance.

The existing GTK wrapper now retains its after-spawn timestamp and samples one
additional timestamp after durable start-receipt publication. The terminal
observation exposes only nonnegative signed-64-bit integer phase values or
unknown, so hosted evidence can separate process creation, receipt publication
and native wait. All 17 original diagnostic tests and their 71 assertions,
native commands, ownership, polling and deadlines remain intact. Six new
portable controls fail before the addition; the candidate passes all 23.
This is diagnostic instrumentation, not a repair or native qualification; the
observed hosted delay's cause and the original failed verdict remain unresolved.

- [ ] **96.** Remove the separate Ergopti+ AltGr-adjustments option from the
      Layout menu. Selecting the Ergopti+ keylayout in the emulation picker must
      suffice. Verify that the layout supplies every intended change, retire
      redundant feature gates and settings through their migration owner, and
      add native regressions for the selected layout without an extra switch.

Added a test-only characterization prerequisite for the legacy Windows Ergopti+ switch: all six historical AltGr descriptors are compared with independently frozen selected-layout neutral outputs, and eight SC012 roll cases execute exact production helper definitions in an owned native child. The reviewed TODO107 test prefix and historical golden remain byte-exact. Shift percent/ligature and whitespace deviations, wrapping requests, and configurable word spacing are recorded without claiming equivalence. Portable source/corpus contracts and scoped convention/encoding/loop checks passed; native AHK interpretation, owned child retirement, physical hotkey precedence, recent-chevron timing and final root verification remain pending. The switch, defaults, settings, migrations and all production/layout data are unchanged; TODO96 remains partial.

Current-owner inspection distinguishes the raw KLE characterization from actual
picker selection: `LayoutManager_Select` still selects the built-in Ergopti+
through `ergopti_base`/`ergopti_plus` and an empty `emulated_layout`.
Removing its separate option therefore also requires a proved picker handoff.
The frozen matrix records wrapping, configurable word spacing and shifted
ligature/percent/whitespace differences; these effects are not established as
redundant. A legacy true value with the base/AltGr gates false can affect only
three keys, so migrating it blindly to a complete layout would change unrelated
keys. Occupied layout selections and absent, false or malformed values need
independent migration vectors. No production switch or migration is retired
until the actual selected-layout contract is qualified.

Remaining work for item96 (CI-feasible software first):

- [ ] Software implementation/repair: Prove the actual empty-emulated-layout picker handoff and selected Ergopti+ behavior across drivers. Resolve or retain wrap/spacing/shift-percent/ligature differences, then retire only proven redundant switch/settings through acknowledged migration; preserve occupied and absent/false/malformed legacy records.
- [ ] Hosted native qualification: Run six frozen historical AltGr descriptors and eight independent SC012 roll cases on native Windows, selected-layout parity and migration/unit/E2E/package/install gates. Never regenerate historical expectations from the new implementation.
- [ ] Separate device/evidence boundary: Check real hotkey precedence, recent-chevron timing and emitted layout/dead-key behavior after software qualification.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 96, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Prove picker handoff and layout equivalence, resolve wrap/spacing/shift differences and acknowledge migration before retiring the separate switch. Separate device/evidence boundary: Real precedence, recent-chevron timing and layout/dead-key delivery.

- [~] **97.** Replace the fixed accent/direct-symbol shortcut submenu with
  user-owned entries, empty by default and offering "+ Add". Let a user on
  any keyboard layout choose an action from the shared catalogue or enter
  a character, then assign a physical key or modifier chord. Include é, à,
  è, ç, ù, circumflex/diaeresis dead keys and arbitrary punctuation (comma,
  period, colon, etc.). Ergopti emulation/keylayouts already supply their
  symbol mappings, so do not duplicate them as default shortcuts. Share the
  entry model, picker and persistence contract across drivers; test capture,
  custom Unicode output, dead-key composition, neutral defaults and refusal
  behavior through automated native and parity suites.

  Partial source admission: the shared empty-by-default physical slot/entry
  model, Add/Edit/Remove editor, Linux/macOS host lifecycle and acknowledged
  publication scopes are present. The 79-source slice preserves unknown and
  legacy records, owns fresh operation backups and retains inverse/resource
  debt. Caller update rows are detached before any admission callback;
  callbacks cannot turn an allowed None/Delete into an active mapping write.
  Linux/macOS native physical delivery capability is explicitly false.
  Missing source, all-owner collision or output-provenance authority must
  refuse active assignments at scope, setter, intake and deferred dispatch,
  independently of GUI readiness. None/Delete and established logical owners
  keep their existing contracts; the new editor remains unavailable with a
  translated reason. Nine read-only Linux XKB/source/test files and four
  test registrations supply opaque source/chord observations, numeric symbol
  and modifier-state inspection. They do not emit user mappings or dead keys.
  Collision, output-provenance and native GUI work remains unintegrated.
  Preparations stored only in /tmp before the cloud restart are unavailable
  and must be reconstructed and reviewed against current sources. No fixed accent menu/default is retired.
  Real physical capture, Unicode/dead-key delivery, collision refusal, native
  GUI lifecycle, installation and Windows native acceptance remain open.
  The editor row retains an all-platform separator before the legacy modifier
  shortcut groups, preserving the existing native Windows menu assertion.

Remaining work for item97 (CI-feasible software first):

- [ ] Software implementation/repair: Complete the admitted empty-by-default editor with native capture, all-owner collision and joint input/source/modifier/output provenance on supported drivers. Implement genuine Unicode/dead-key delivery; reconstruct/review lost unintegrated preparations and qualify legacy accent migration before menu/default retirement.
- [ ] Hosted native qualification: Run genuine GUI/bridge lifecycle, native assignment/delivery/refusal, renderer-only browser, unknown-source and unit/E2E/package/install cases. Linux/macOS delivery stays false until native authority is proved; GUI readiness cannot enable it.
- [ ] Separate device/evidence boundary: Qualify actual keyboard positions/modifiers, arbitrary Unicode and dead-key composition across real layouts/devices; keep fixed menus reachable until the replacement is qualified.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 97, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Complete native capture, all-owner collisions, joint source/modifier/output custody, Unicode/dead-key delivery and accent migration; qualify actual GUI/bridge and retain legacy menus. Separate device/evidence boundary: Real physical positions/modifiers and output across layouts/devices.

The frozen [modifier-consumer inventory](handovers/2026-10-04-parallel-containers/group3-2026-10-06-modifier-consumer-inventory/README.md)
preserves the original fourteen watchdog cases and overlap assertion. Actual
controlled consumers record 17 PASS / 8 FAIL on each Lua ABI. In addition to
the two-source Shift overlap, withdrawing a Caps remapper can swallow the
remaining physical Shift release as an orphan and leave the Writer held roster
set. A skip-only-UP change remains red (19/6), weakened temporary restoration
regresses further (16/9), and blanket reentry refusal breaks an original
TapHold retirement assertion (25/1 versus unchanged 26/0). Independent review
is CLEAR for the inventory only. Implement a coherent single-channel owner
broker across Hook, Reader, Writer, TapHold, Injector, ComboEmitter,
OutputTransaction and daemon; coordinate source ownership before admission.
No production repair, native capability, kernel output or physical qualification
is claimed. This remains software work, not a device-only check.

- [~] **98.** Replace the fixed "make J the star key" setting with a physical
  key and output chosen by the user: any keyboard position and arbitrary
  character, including choosing no star at all. Integrate with item 97's
  shared user-owned shortcut model rather than another fixed-layout switch.

  The admitted shared model can represent an arbitrary physical entry and
  explicit None without introducing a fixed J/star default. Its Linux/macOS
  native delivery remains unavailable, so no active star mapping is accepted
  or consumed through this new model. Existing records remain intact. The
  Windows legacy logical magic-source character is not proof of a physical
  J position; no layout-dependent migration or legacy-setting retirement is
  claimed. Qualify genuine physical source/output and acknowledged migration
  before replacing the old setting. See the item97 partial handover.

Remaining work for item98 (CI-feasible software first):

- [ ] Software implementation/repair: Complete item 97 native source/output ownership for arbitrary physical key/output and explicit None. Prove star-setting migration without treating a logical character as physical J; preserve occupied/unknown records before retiring the old setting/default.
- [ ] Hosted native qualification: Run shared model/native setter, collision, migration, persistence and delivery/refusal cases plus affected OS unit/E2E/package/install gates. Arbitrary text emission is not dead-key composition.
- [ ] Separate device/evidence boundary: Verify real positions and chosen star/other output across layout changes, modifiers and repeats; None must produce no mapping.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 98, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Complete the same arbitrary physical key/output or None owner and star migration, preserving occupied/unknown records without inferring physical J from a logical character. Separate device/evidence boundary: Chosen output across actual layout changes, modifiers and repeats.

- [~] **101.** Investigate the supplied Windows diagnostic's retained keylogger
  shutdown debt (watchers=0). Keep privacy filtering fail-closed;
  distinguish measured stalls from causes before changing tooltip/hook code.

Delivered prerequisite: Windows closing records retain an exact accepted
interval owner through producer teardown. Only content-free `idle_end` and
`session_end` records can use that authority; ordinary telemetry still uses
the current fail-closed privacy predicate. Non-variadic frozen getters preserve
scalar and indexed access. Queue/commit identity, generation and lifecycle are
rechecked after yielding preparation, and refusal retains the original close.
The registered native child exercises the production focus-stop, privacy and
queue chain through controlled native ports, including replacement, mutation
and receipt-retirement scenarios.

Standard non-release run 37237868670 tested the exact source tree of
`2d31eee374353823032e4f231b98f4f08655a2b0` at CI commit
`2fc31dc9ff1eff3ea9b52783364c6c3bc5dd7652`: all 9038 AHK cases executed
and were timed, with 9037 passes and the pre-existing item 102 failure. The
owned shutdown-close child, 33 native C cases, 356 JS checks, 27 property
checks and 72 browser checks passed. E2E, isolated LLM suites, startup,
packaging and installation were skipped after the item 102 failure. The Core
runner now installs lua-luv so Lua 5.4 can use the actual Linux regular-file
reader; its fail-closed reader and existing assertions remain intact.

Windows PC follow-up, delegated to the maintainer:

1. The original diagnostic has been lost, as confirmed by the maintainer.
   Capture a new diagnostic and reproducible steps on the current integrated
   build if shutdown debt recurs; record Windows/build version, configuration,
   foreground application, privacy context and the complete watcher/debt state.
   Do not attribute the old `watchers=0` report to a historical cause without
   new evidence.
2. With real UIA and foreground transitions, exercise focus loss, session stop,
   reload and shutdown after an accepted interval. Check that certified
   content-free closes are recorded once, that refusal retains retryable debt,
   and that ordinary telemetry stays refused in excluded or secure contexts.
3. Check replacement/reload during a pending close and repeated teardown on
   the real app: stale owners must not authorize records, retries must not
   duplicate accepted closes, and pending watcher retirement must remain
   observable until acknowledgement.
4. Measure any stall separately from its cause. Collect timings and relevant
   diagnostic evidence before proposing tooltip or keyboard-hook changes;
   controlled native ports do not prove physical/UIA responsiveness.
5. After the item 102 owner fixes the unrelated native unit failure, complete
   the standard Windows unit, E2E, startup, packaging and installation gates.
   Keep this item open until the live investigation and its acceptance steps
   are complete; retain the independent cross-cutting requirements of items
   16 and 38.

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

Windows run 37223727872 at `2476b0b2a` completed with 9,036 passed and one
failed native case; E2E, packaging and installation were skipped. The remaining
opening-source metadata fixture attempted to replace a section-override header
that the neutral seed writer correctly omitted. Its seed now inserts that table
before the first actual alpha entry, verifies both insertion counts, and checks
all eight metadata values before opening the editor. Every existing final-save,
source-consent, transaction and metadata assertion remains intact. This is a
fixture correction, not additional personal-file gate completion. Native
execution and complete qualification of the corrected fixture remain pending.

Controlled macOS personal-source tests pass 30/0 and native registry ownership tests pass 10/0; focused Linux controls pass 20/0. The actual producer is composed, but its staging-only cleanup receipt omission and final regular-file identity boundary remain unqualified producer follow-ups. Pending recovery closes normal reload/quit admission before the watchdog; physical native qualification is still required.

Windows-dependent acceptance is explicitly deferred to the maintainer PC. Complete the [Group 2 Windows continuation](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo102-personal-files-and-source-controls) for this item; prepared sources and portable checks do not establish Windows runtime success.

- [~] **104.** Split common autocorrections into meaningful selectable sections.
  The runtime source now contains 34 names, 95 abbreviations and 11 technical
  terms, with genuinely translated labels in all 21 languages. The independent
  pre-split corpus still freezes all 140 rules, flags, metadata, delays,
  historical order and common priority; never regenerate those expectations
  from the split implementation. French contextual packs retain their own
  existing identities, choices and registration order.
  Schema version 11 conditionally fans out stored common choices through
  `copy_if_absent`, preserving explicit destinations, including false and
  occupied ancestor or descendant namespaces. Override migration copies only
  recognized delay/color/show_tooltip/priority leaves into unoccupied family
  destinations, then removes only the recognized old leaves. Unknown records,
  global preferences, comments and unrelated sources remain preserved. Strict
  source classification and compare-and-swap ownership fence preparation,
  publication and inverse restoration; malformed owned state cannot be
  advertised as successfully migrated or admitted.
  Cold startup reports a partial receipt when common admission is refused:
  unrelated categories may still load, while unavailable common sources are
  omitted before parsing and registration. Ordinary live reload retains its
  complete-image refusal policy and prior committed image. Desired choices
  remain unchanged. Registered regressions cover occupied destinations,
  repeated migrations, invalid sources, historical case/order arbitration,
  native cache identities and default/live refusal after partial cold startup.
  The actual Linux common suite passes 19 cases; portable macOS cold-start
  ownership checks and the independent migration/reference checks pass.
  Native post-publication refusal and retained lock-release debt remain
  unqualified. The common migration must retain that invocation's physical
  receipt and exact forward/inverse ownership; observing converted bytes on
  a later reload cannot acknowledge the original failed write or clear debt.
  Full selected verification, native Windows/macOS qualification, per-section
  E2E, packaging and installation remain required before removing this item.
  Portable Lua and source checks do not qualify physical native input.

Focused recovery passes 14/0, including five terminal-admission cases. The composed producer now retains staging-only receipts, pins regular-file and staging-directory identities, and preserves ordinary release-only cleanup alongside guarded private inverses through one native removal implementation. Serial portable Mac-target conditional-removal, cooperative configuration, Writer and staging controls pass 178/0, retaining the original refusal assertions. Native release debt remains owned across forward and inverse publication. This is cooperative pathname ownership; portable controls do not establish hosted macOS locking, physical input, packaging or installation.

Windows-dependent acceptance is explicitly deferred to the maintainer PC. Complete the [Group 2 Windows continuation](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo104-common-autocorrection-families) for this item; prepared sources and portable checks do not establish Windows runtime success.

The hotstring formatter now supports an explicit preamble directive for sources whose physical registration order is intentional. Marked files retain interleaved array boundaries and rule order while canonical rule layout and syntax admission remain mandatory; unmarked files keep the existing sorter. The independent 140-rule corpus remains unchanged. This is a tooling prerequisite for the prepared family split; runtime migration and native acceptance remain separate.

Native-source fixture prerequisites explicitly provision LuaFileSystem for the
macOS E2E interpreter and the Linux unit interpreter. Real link, directory and
device/inode controls remain mandatory; this dependency does not replace native
packaging, installation or physical acceptance.

- [~] **105.** Let users define programmable dynamic hotstrings on Windows,
  macOS and Linux, separately from the ordinary hotstrings editor. Provide
  a documented user-code entry point under "Dynamic hotstrings", examples
  and a callback API that lets users compute any replacement/action rather
  than limiting them to the editor's fields. Share the trigger, callback,
  enable/disable and lifecycle contracts; isolate native implementations.
  Preserve user source files, report load/execution errors visibly, and
  cover real callback execution, live enable/disable, cancellation and
  suspended/privacy-filtered input with automated cross-driver tests.
  Prepared shared trigger/source/lifecycle policy and native facades now
  cover opt-in loading, callback execution, private destination admission,
  cancellation debt and source-preserving menu commands. Configuration
  inverses must retain admitted callbacks without evaluating the factory
  again, require the same native owner and operation-assigned revision,
  and refuse foreign mutations or unsettled cancellation. Missing sources
  may support an acknowledged closed-only inverse, never active admission.
  Portable and real Linux GTK/AT-SPI checks have executed; reopened scope
  regressions are still being qualified. The compiled Windows worker probe
  is prepared and independently reviewed, but has not executed natively.
  Full final-source verification, Windows/macOS execution, E2E, packaging
  and installation remain required. These checks do not replace items 16
  and 38 or establish physical X11/Wayland keyboard behavior.

Final focused Lua validation passes macOS runtime53/scope30/shared40/transport86 and Linux runtime49/shared40/transport31, with no failures or skips in those selections. Deferred output retains the actual native publication receipt after callback completion; source/lifecycle fences and strict cleanup acknowledgement remain required. Foreign clipboard ownership leaves honest unsettled debt. Hosted native/installation and physical input remain unqualified.

Windows-dependent acceptance is explicitly deferred to the maintainer PC. Complete the [Group 2 Windows continuation](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo105-programmable-hotstrings) for this item; prepared sources and portable checks do not establish Windows runtime success.

Hosted Linux qualification of candidate `caa1ef045` exposed a real startup
regression: the new file-scope programmable-runtime import raised `main()` to
61 captured variables, above the runner LuaJIT limit of 60. Both main-only hotstring imports
remain mandatory inside the startup function before argument parsing, leaving
59 LuaJIT captures and 60 in the unchanged PUC compiler gate. The budget guard
now inspects actual nested LuaJIT prototypes as well as the existing PUC compiler
listing, so a newer local LuaJIT cannot conceal this portability ceiling. The
existing syntax and CLI help assertions remain mandatory and unchanged. Native
CI qualification and the explicit Windows continuation remain separate gates.
The same completed run also refuses native macOS packaging in the two existing
Homebrew/Sparkle archive acceptance methods; those owned item36 prerequisites
and installation qualification are still required.

- [~] **106.** Expand the shared gesture/keyboard action catalogue for user
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

The original executable/argument tranche is integrated in `origin/dev`; the
broader automation-provider scope remains partial. A saved patch or incomplete
review receipt is not integration evidence. Independent regressions exposed
refused macOS parameter
transactions, overly broad source admission, Windows shutdown cancellation
ordering and Linux descendants surviving their original process leader. Their
bounded fixes retain source/privacy and strict ownership requirements.
The Windows provider tranche now uses the canonical shared command metadata
and one native inventory adapter. Discovery performs bounded regular-file and
PATH metadata checks without launching programs or reading user scripts;
interpreter prefixes and literal arguments use the existing owned execution
path. Refused native cleanup remains reserved before assignment or confirmation
callbacks. The shared reader preserves POSIX prefixes and rejects mismatched
Windows provider metadata. Independent source review covers the native consumer,
assignment/confirmation paths and retained-handle cleanup; all 27 previous
program cases remain intact, with 34 composed registered cases. Exact-source
manual run 37523199350 on CI `3cb5ff1f` / feature `7d305622` passes all 34
program/provider records within 9,722 native units, 70 E2E cases, compilation,
packaging, installation and launch. This includes actual AutoHotkey, Python
and PowerShell script arguments and native retained-handle retirement. The run
is globally FAILED: Core, Linux and the Ubuntu-hosted macOS portable job stop
at `Ubuntu archive authority ownership refused`; Release is SKIPPED. The shared
metadata required Linux/macOS qualification at that historical checkpoint.
Later integrated run37539552261 passes the complete Linux chain and all17
installation scenarios, plus the actual signed Hammerspoon inventory16full
and5shim cases, including interpreter symlinks and owned retirement.
Preserve those qualified component scopes; complete macOS package/install
remains failed or skipped. Real interpreter invocation does not
qualify broader automation inventory, Apple Shortcuts or physical keyboard
acceptance, and this tranche does not complete item 106.

The earlier retained native macOS inventory baseline is run 37494746572 on
CI `ad22d308` / dev `4dfbb9a5`: all 16 inventory and five shim cases PASS,
including `real_interpreter_symlink`. The current native adapter, directory
owner, full/shim fixtures and controller are byte-identical to that qualified
baseline. Older 15/16 notes below are historical failures, not a demonstrated
current symlink regression. The Windows additions changed shared provider
policy/data while preserving the macOS projection, so the current complete
source was subsequently replayed in integrated run37539552261 with all21
native inventory cases passing. Preserve those21 cases; Apple Shortcuts,
broader inventory and full macOS package/install remain open.

Complete selected gates, hosted native execution, packaging and installation
remain required. Automation-provider discovery and Apple Shortcuts are still
outside this executable slice; item106 remains partial.

The actual Linux runner now passes an independent binary argv fixture with
Unicode executable/script paths, empty arguments, decomposed Unicode, percent
text, quotes, shell-like literals and newlines. Native stdout/stderr are
discarded, exit status 37 is observed, and the original process group and
handles retire completely. This does not qualify Windows or macOS execution.
Actual private macOS assignment/full-save probes reproduced a pre-existing
post-rename lock recovery gap. Prepared guarded publication receipts now pass94
focused composed cases with independent review. Real macOS interprocess locks,
physical symlinks and complete product qualification remain pending.

The Linux action-catalogue fixture reloads its captured workspace dependencies.
A deliberate earlier tool provider reproduces the missing-wmctrl assertion
failure before the repair; all ten catalogue cases pass afterward without
weakening absent-tool or availability assertions. This fixture correction does
not integrate or qualify the pending executable/provider feature.

The shared Core CI preparation reuses the independently released Group4
`lua-luv` provisioning fix so stock Lua 5.4 can run native descriptor-admission
checks. Preparatory native checks may use the owned `codex/ci-actions` branch
without the integration lock. Final integrated qualification still owns
`codex/ci-lock` and uses only `codex/ci-validation`; this prerequisite does not
qualify native program execution.

The bounded publisher correction now retains prepublication staging debt and
pins physical published/staged identities before use. Retrying cleanup cannot
unlink a replaced directory or payload, relearn unknown allocation identity,
or turn a refused publication into success. Independent temporary-I/O controls
pass108/0 on target Lua5.4 with CI umask022;19 conditional cases pass on both Lua
ABIs. The metadata-copy fixture now performs the real acknowledged copy and
proves each intended post-rename premise. The prior no-op copy reproduces the
five hosted failures; it is not evidence of native publication. These checks
retain the cooperative pathname boundary and do not claim atomic fd-relative
CAS, restrictive staging permissions or actual Hammerspoon/fcntl validation.

The inactive three-source native publisher handoff is pinned under
`docs/handovers/2026-10-04-parallel-containers/group3-native-publisher/` for
separately owned hotstring consumers. Its receipt API and 94 focused composed
cases have independent source review; real macOS locking/symlinks and full
product qualification remain pending. Saving this patch does not integrate
or finish the executable/provider feature.

Current-dev composition preserves one native conditional remover with two
explicit contracts: ordinary scope/layer inverses retain an exact release-only
closure, while private program compensation keeps its source-guarded receipt.
A recreated foreign source may allow physical lock release but cannot authorize
private logical compensation. Stale cleanup closures cannot retire a successor.
Independent source review and 296 targeted Lua5.4 cases cover both participants;
this is portable qualification, without native Hammerspoon or packaged approval.

The macOS stubbed E2E lane now installs LuaFileSystem for real directory and
payload identity observations. Removing that prerequisite reproduces the exact
34 hosted failures; restoring it passes101 cases with one existing skip.
Manual run37259060275 at78c33cd851be187221dcd6ab5f2b2668928b0dc8 confirms
stubbed units and E2E pass. That run's native Swift compilation fails because
the owned-program C header is absent from the umbrella export. The umbrella
now includes that header, preserving the existing POSIX declarations. An
independent declaration/signature probe fails against the original umbrella
and passes against the corrected source; this is portable C evidence, without
macOS SDK qualification from that probe alone. Manual run37262044694 at
3efd4eb8c87758f540b064b78f2563ded42a724e now passes the release build and all14
owned-program native XCTest cases:14 started/completed/passed, zero skipped,
failed, duplicated or unexecuted. Its native launcher target tree is identical
to feature commit e9c9f240201e13a5022423da4b7487fcbbf351fb. The mandatory receipt
guard preserves the complete XCTest verdict: the root suite still fails the
Homebrew and Sparkle archive acceptance cases, so package completion and
installation remain unexecuted. Native Hammerspoon publication, provider
discovery and physical acceptance are still separate unfinished scope.

The shared picker now inventories explicit `config_dir/scripts` on Linux and
macOS through bounded native adapters, with opaque session choices and the
existing literal executable/argv persistence. Selection rechecks script,
interpreter, configured route and captured identity before assignment; manual
entry remains available. Windows discovery was unavailable at this historical
checkpoint; the exact-source Windows provider results above supersede that status.
Seven new labels are translated in all21 locales. Real Linux child fixtures
cover discovered shell, Python and executable scripts, literal Unicode/empty
arguments, refused starts, exit37 and cancellation with closed process groups.
The registered macOS controlled fixtures cover exact native64-bit integers,
stale identities, source privacy and retained cleanup debt. A signed official
Hammerspoon native inventory fixture is registered in macOS CI; its portable
parser controls are not native qualification. Later integrated run37539552261
qualifies all21 actual native inventory cases, and the Windows34-case
provider tranche passes its separate native qualification above. Apple
Shortcuts, installed automation/application providers, complete cross-consumer
parity and full macOS packaging/installation remain unfinished.

A separately owned read-only Apple Shortcuts observer is registered after the
native Hammerspoon inventory in hosted macOS CI. It calls the actual structured
native catalogue API and records typed refusal, CLI identifier-help and exact
owned query retirement without storing names or identifiers. Twelve independent
JXA API controls and eight parser/cleanup controls remain portable evidence.
Native catalogue retrieval itself is unbounded; empty discovery does not qualify
invocation. No automation is imported or executed, and service cancellation,
chosen-ID revalidation and a safe native invocation fixture remain unfinished.

Hosted native run 37288850992 retains 14 passing owned-program Swift XCTest
cases, but its complete native suite fails and packaging/installation do not
execute. The signed Hammerspoon provider inventory records 14/16 passes; both
`actual_native_runtime` and `real_interpreter_symlink` fail and the five shim
cases do not execute. Artifact retention now whitelists closed receipts rather
than recursively collecting the deliberately newline-named private scripts.
Closed diagnostics preserve every case and verdict. Official Hammerspoon 1.1.1
implements public `symlinkAttributes` as a Lua wrapper: its incorrect public-C
premise is replaced by stricter verified script/native bytes, wrapper bytecode,
captured C upvalue, loader identities and real lstat/stat witness checks. All
other original conditions and the primary receipt schema remain unchanged.
Portable Python diagnostics pass 17/0, and nine controlled origin cases plus
four independent omission controls pass; final native macOS qualification is
still required. The independent interpreter-equality failure remains unresolved.
Read-only Apple Shortcuts catalogue retrieval timed out after 20 seconds; CLI
identifier help passed, permission was not determined, and invocation was not
qualified. The Windows handoff now records nine actual program-action failures,
two missing lifecycle/timer inventories and two unchanged OS-purity ratchets.
These are CI-feasible software repair steps, not completed scope.

The Linux runner now admits each native close callback only after the same
protected close attempt acknowledges submission. A rejected or raised attempt
cannot borrow a callback from itself or a replacement attempt to retire the
handle. All 36 prior lifecycle cases remain; 14 causal close-attempt controls
pass on both Lua ABIs. Two actual POSIX/luv cases per ABI retain exit status 37,
private discarded output, cancellation, absent original process group and exact
callback/handle retirement. These controls qualify the Linux runner boundary,
not automation discovery, native Windows behavior or installed application input.

Native macOS run 37304571728 tests CI commit 9d89453278dd9455fd4cc3ddebbc732b988a029e
and the exact feature tree at 7ae2f6e251d7cdadbdfc8ca1575c54e2a8f6395f.
Owned-program Swift cases pass 14/0; signed Hammerspoon inventory passes 15/16,
including actual_native_runtime. real_interpreter_symlink remains failed and
the five shim cases remain unexecuted. A strict primary-receipt validator now
prints only a closed six-field diagnostic summary before preserving each
original verdict. Its Python controls pass 20/0; dependent notification and
global-switcher controller controls pass 13/0 and 27/0. No source identity,
private stream, fixture pathname or signed download URL is logged. The native
interpreter cause is still unobserved until the next source-identical CI run.
The complete Swift suite retains the two Brew/Sparkle failures; packaging and
installation are unqualified. Apple Shortcuts still times out in catalogue
retrieval and has no qualified invocation; item106 remains partial.

Latest dev25b879aa is composed without losing the retained app-runtime or
user-program shutdown barriers. Observer callbacks and polling acknowledgments
share one immutable owner census; input retirement and registration completion
both precede event-loop stop. Every original test body from both branches is
retained, with two joint-debt controls. Composed gates pass formatting,362 JS
checks, Linux8,860/0, macOS14,898/0 and E2E189/0 plus101/0 with one Mac host skip.
Actual X11 source28, native HTTP48, Linux runtime82 and canvas pure48 controls
pass. The cursor-window native supervisor refuses this container before any
child/namespace allocation; mandatory hosted native qualification remains open.

Remaining work for item106 (CI-feasible software first):

- [ ] Software implementation/repair: Requalify the EOF-first Windows descriptor and UTF-8-RAW BOM fixture repairs with retained shutdown/HANDLE/Job ownership; fix only demonstrated failures. The reviewed constructor failure carrier has native basic/constructor qualification; preserve its lifecycle guards and requalify final integrated sources. Complete Windows discovery, installed automation/application providers and bounded Apple Shortcuts chosen-ID/invocation ownership; preserve literal argv, privacy and consumer concurrency.
- [ ] Hosted native qualification: Run the actual basic 15 program cases, genuine script/Python/executable and lifecycle controls on affected hosted OS lanes; retain the admitted constructor's 12 native HANDLE/Job fault cases and their private Windows qualification; final integrated-source acceptance remains required. Requalify signed Hammerspoon provider/shim cases after scalar-arity fixture repair, native locking/symlinks and 14 owned-program XCTest cases; complete E2E/package/install/launch. Saved, unintegrated or lost preparations require preimage review/reconstruction, not a completion claim.
- [ ] Separate device/evidence boundary: Only hardware/peripheral-dependent automation or actual user workflows require a device; basic execution, discovery, cancellation and packaging remain software work.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Native provider CI fixture correction on 2026-10-06: the real Hammerspoon
JSON decoder accepts exactly one argument, while the shared resolver returns
value and reason. Capture its scalar before decoding instead of forwarding
both through assert. The regression fails before and passes after on Lua 5.4
and LuaJIT; the complete Lua 5.4 provider module passes 21/0. All 57 original
native checks, 16 full-provider and 5 shim cases remain unchanged. This corrects
the case raised in macOS run 37329111337; actual hosted revalidation remains
required, and no production interpreter/provider behavior was changed.

The Windows tree completion owner now claims finalization before diagnostic
logging or capture I/O can yield. Ordinary callbacks use the adapter logger;
private program claims retain the unchanged central redactor. Both existing
native guards remain byte-exact. Ten independent causal source controls and
the complete 362-check JS gate pass; actual native AHK revalidation is pending.
This repair does not admit the inactive Job-constructor packet or finish106.

The Windows basic program owner now uses an exact, acknowledged one-shot
callback and keeps cleanup polling while physical program debt remains. Its
suspend/resume owner is registered, and the fixture preserves an initially
unset keyboard map. The canonical JSON string lexer replaces the duplicated
lexical path, with an independent native stage/cursor control before the
unchanged corpus. All11 original tests and91 assertions remain, with three
new controls. Source review is clear and the unchanged601 native-call budget
is met; native parser success, all14 tests and packaging remain unexecuted
until the next hosted CI. The lexer change is an unproven diagnosis hypothesis.

Native run37446596183 records9,690 Windows passes and11 failures. The original
menu, logger, lifecycle and timer guards now pass, but valid program descriptors
remain refused after successful string/cursor decoding. Fixed private parser
stages and independent delimiter, numeric and empty-string controls now localize
that refusal without changing its guards or logging input/exception messages.
The isolated shutdown fixture loads the actual polling dependency graph and
captured timing values, with strict per-mode callback and handle cleanup. All
145 existing assertions remain; the candidate15 methods require native CI.
The Linux GTK operand fixture adds only closed stage/case/exit annotations on
its original failure branch. Actual unchanged current/dev13 and the candidate
each pass4/4 locally, with12 descendants reaped and no pending debt. Its remote
failure remains unexplained. Existing invocation/assertion/cleanup budgets are
unchanged; this diagnostic slice does not qualify either refused boundary.

Native run37451229133 passes the isolated shutdown envelope and brightness
worker, but9 program cases still fail. Its closed decoder receipt localizes the
valid descriptor refusal to object-trailing:ValueError: the whitespace owner
called native InStr with an empty EOF needle before checking the cursor bound.
The bound now short-circuits first. Independent actual native EOF/cursor,
complete/trailing-whitespace, empty-argv and invalid-tail controls preserve all
156 earlier assertions and15 methods. These corrected sources require fresh
Windows CI; the previous brightness failure cause remains unknown.

Native run37454415583 passes the Linux units and hold/window native gates,
but the GTK operand fixture fails at receipt/case0 and the foreign ETag gate
also fails. A controlled real shell/file barrier reproduces the fixture's
publication race: all four original consumers see an empty public file. The
producer now writes a private pending file and renames it only after writing
the full receipt; all four unchanged identity assertions then pass. Independent
review preserves all native commands, cleanup and time budgets. Actual local
GTK passes4/4 with12 descendants reaped, none pending or rescued. The precise
historical hosted receipt failure remains unknown; fresh hosted qualification
is required. Package and installation were skipped in that failed run.

Native run37454415583 now records9,700 Windows passes and only two program
fixture failures; the private constructor run37454501003 records9,709 passes
and five failures, including three native PowerShell5s timeouts of unknown
cause. All12 appended constructor controls pass, but that private suite fails
and its constructor remains outside the product. Exact source reads retain
the physical UTF-8 BOM: the fixture added one to a BOM-less foreign image and
duplicated it when restoring an already-BOM-bearing captured source. Only
those two fixture writers now use UTF-8-RAW. All165 earlier assertions and
15 methods remain;13 additive actual FileAppend/RAW-byte controls require
fresh Windows execution. Production source admission and the independent
corpus are unchanged. The native brightness budget and assertions remain
unchanged; downstream E2E/package/install were skipped in both failed runs.

The hosted successor run37458316115 passes Linux units and the native hold
and cursor-window gates, but GTK operands and the separately owned ETag gate
fail again. Atomic publication has not qualified the remote GTK boundary.
The unchanged worker now reports only not_observed or identity_mismatch at
its existing failure sites; all100 read/sleep attempts, exact identity
assertions and native/cleanup deadlines remain unchanged. Independent
portable controls preserve earlier-stage annotations and reject payload
values. Actual local GTK still passes4/4 with12 reaped descendants and no
pending/rescue debt; the diagnostic successor requires hosted execution.

This slice admits the reviewed call-scoped native constructor failure carrier
and all12 unchanged HANDLE/Job fault cases after private Windows run37458344080
completed SUCCESS:9,714 unit passes, zero failures, E2E, compiled packaging,
installation and startup successful; Release skipped. The complete15-method
BOM-corrected prefix remains byte-exact, with all178 assertion lines retained.
Native partial acquisitions are taken and zeroed before publication, adopted
through the same exact retirement claim, and cancelled starts retain their
pre-bind disposition. Legacy anonymous cleanup and completion policies remain
unchanged. The old archived constructor preparation remains inactive and
native-unexecuted; it is separate historical evidence. No raw per-method
artifact-row or E2E case count is claimed. Final integrated three-OS
qualification, discovery/automation completion and device acceptance remain
open; this does not complete item106 or the other partial items.

Integrated run37462985994 (CI036bbff29, exact Dev2dc6f9d6b tree) passed all
9,715 Windows unit checks, E2E, packaging, compiled startup and crash smoke.
The separate23-case compiled programmable-hotstring acceptance had22 passes
and one failure before disable; its owner has the exact evidence. macOS passed
all14 native owned-program cases and21 signed Hammerspoon inventory cases;
this inventory does not prove program invocation, atomic leases or effective
ACL behavior. Native Shortcuts discovery remained refused and invocation
unqualified. Linux units passed9,126/0, while the original GTK identity cases
passed3/4: the first ordinary-app receipt was not observed, with no precise
launcher failure cause proved. Package and installation acceptance remains
incomplete across the integrated OS lanes; Release was skipped.

This slice adds a transparent observer around the actual PATH-selected GTK
command, forwarding the exact original arguments and native status. Capped,
closed command-entry, operand-boundary, terminal-status and launcher-entry
facts diagnose failure without publishing paths or receipt payloads. Failed
diagnostic writes preserve the genuine native outcome. The whole original
worker, all assertions, four identities,100 reads,20ms sleeps and10s/5s native
budgets remain unchanged. Local actual GTK passes4/4; four real marker-write
refusals and two genuine CLI diagnostic-publication refusals preserve original
receipts/status/stdout. All12 adopted descendants are physically reaped with
zero pending/rescue debt;15 closed-parser controls pass. Hosted execution of
this observer is still required, and its output cannot complete item106.

After this prepared slice was pushed, upstream2afdf3039 introduced structured
GTK command, native stderr and polling diagnostics. Its entire fixture and
new diagnostic owner are preserved during the current Dev merge; the earlier
58690cd9 observer is superseded rather than layered onto another wrapper.
The old four-case/refusal controls qualify only that historical observer.
Current GTK sources require fresh hosted qualification, with the original
identity oracle and poll window retained. Upstream ETag, typing-consumer and
macOS acceptance/diagnostic corrections are preserved; macOS also requires
qualification on these new sources. The atomic PID publication correction
remains active. No TODO item is completed by this diagnostic preparation.

Bootstrap diagnostic follow-up (2026-10-06): the provider, notification and
global-switcher probes now report closed release_metadata/archive_download
phases, closed transport families and a finite numeric HTTP status when
observed. They rethrow the identical ordinary failure; diagnostic write faults
do not turn failure into success, and genuine interruption remains visible.
No URL, headers, response body or arbitrary exception text enters these facts.
Portable controls pass29/0,15/0,29/0 with every original20/13/27 control intact;
the original metadata HTTP403 black-box control fails without these facts and
passes with them. Both callers retain the formatted inventory source pin.
Fresh native macOS qualification is pending; the prior HTTPError stage/status
remains unknown. This is diagnostic evidence, not provider invocation.

The owned GTK fixture now requires a real X11 protocol handshake before its
original four application trials. A live process and published display number
alone are insufficient: a genuine owned SIGSTOP trial passes that old predicate
but refuses the five-second xdpyinfo handshake, retires its exact client and
passes after the same server resumes. Seventeen diagnostic controls, four
proof-cleanup controls and eight actual X11 observations pass with exact child
reaping. Original workers, identities, receipt polling and observer deadlines
remain unchanged. This strengthens setup admission; it does not establish the
cause of the prior late GTK receipts or qualify physical application delivery.
Final composed and hosted qualification remains required; item 106 stays partial.

The three native Hammerspoon probes now consume the existing ephemeral CI
metadata token before any Git or native child allocation. Only the fixed
official release-metadata request receives Authorization; authenticated
redirects and supplied-credential refusals fail closed without anonymous
fallback. Archive requests, native child environments and closed diagnostics
remain credential-free. CI portable controls, Brew and the log receiver exclude
the dedicated key. Independent controls pass40/0,19/0,33/0 with every old
assertion retained and the strict parser census updated only additively.
The controlled old403/new authenticated asset result proves the request
boundary, not the cause of the earlier hosted403. Actual hosted acquisition
and native qualification remain pending; item106 stays partial.

Linux qualification prerequisite follow-up (2026-10-06): exact integrated
run37494746572 passed all four genuine GTK cases but timed out while APT
was still downloading the audio prerequisites, before either native audio
runner. The same surviving apt-get process held the dpkg frontend lock,
so later physical-source/window commands and package/install matrices did
not execute. The exact existing PulseAudio packages, both translated language
packs and locale generation now have a separate bounded prerequisite step.
The original native audio name, both interpreter commands and two-minute
budget are unchanged; fifteen additive wiring controls refuse missing
prerequisites, changed budgets and shared setup/native clocks. Fresh hosted
qualification remains required; no native assertion or item is waived.

Current Group3 qualification checkpoint (item106, 2026-10-07): [Group3 continuation](handovers/2026-10-04-parallel-containers/GROUP3-2026-10-06-CONTINUATION.md). Preserve the actual qualified Windows34-case provider, Linux process/GTK/install cohorts and signed native macOS21-case inventory. Complete broader automation/application inventory, bounded Apple Shortcuts chosen-ID discovery/revalidation/invocation/cancellation and cross-consumer behavior; ordinary program discovery/start/cancel does not depend on the modifier broker. Keep complete macOS package/install qualification open. Only actual device-dependent automation workflows require separate device acceptance.

The Ubuntu prerequisite is now separately published and integrated upstream:
`b70f98236` restores actual native acquisition; dev `a576915cf` CI
37533343559 passes the complete Windows and Linux lanes. Its non-root fixture
failure has a published thirty-case successor (`509795692`, dev `de4f253c1`).
The Group 3 test-only successor keeps all thirty methods/assertions and
constrains modeled private UID facts to captured directory/file identity,
original UID and exclusive creation. Thirty-one controls pass under UID 1000;
the same boundary corpus has eleven failing subtests against the published
pathname-only model. Production root/signature policy is unchanged. Selected
formatting and all364 JS checks pass under actual UID1000. Integrated
run37539552261 and later configuration run37547053814 pass the complete
Linux chain and all17 installation variants. These actual hosted results
supersede the earlier Ubuntu/GTK prerequisite-pending checkpoint.
The separately owned macOS package
still fails owned Brew receiver lifetime and Sparkle server retirement; its
complete native/package/install scope is unqualified. These are automated
software/ownership prerequisites, not device-only checks. Item 106 remains
partial, and items 16 and 38 retain their validation requirements.

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

Read-only Linux source admission now includes native number-row level
inspection and its registered fixture, alongside opaque chord/source currency
and numeric-symbol inspection. This supplies observations for later policy
owners; it does not acquire held output, rewrite key events or enable forced
Lua digits/symbols. The joint native input/source/modifier/output provenance
owner and physical row/repeat/Nav/AltGr/Caps/dead-key qualification remain open.
The unintegrated number-row runtime/provenance preparation stored only in
/tmp is unavailable after the cloud restart and needs reconstruction and
review. Linux/macOS forced native capabilities remain unavailable.

The reviewed Windows observation precursor now exposes native key levels and
number-row descriptors through two append-only native adapter APIs. Captured
external scalar getters are read once before validation; returned observations
never grant input, owner, forced-output or dead-state authority. The original
ToUnicodeEx reader, no-state-change flag `0x4`, independent ten-key corpus and
every old test assertion remain byte-identical. Six additional registered
cases include two genuine French/US HKL probes and four controlled native
adapter-boundary cases. Exact-source run37552051028 executes all six
successfully within 10,097 passed / zero failed AHK records; the complete
Windows E2E/package/install/compiled acceptance chain passes. Readonly
previews do not complete the forced-output policy or item107. The existing layout fixture is unchanged; no new explicit HKL unload
qualification is claimed.

Native observation checkpoint 37549417973 reached all 10,095 registered
AHK cases: 10,094 passed and one failed. Five new observation cases passed;
the actual French dead-key refusal exposed an indexed read of an absent
Action field in the shared AHK descriptor validator. The successor consistently
uses the existing empty defaults for missing Text, Action and State, preserving
the native refusal assertion and every independent expectation. Eight added
missing-field checks exercise both source positions without depending on HKL
availability. Lua already safely refuses absent fields and is unchanged.
Corrected native qualification37552051028 on exact CI
`18c69e27a753bec1816e926455e4f1e0ed944afd`, candidate
`454847c2fcd04ba0e61697412929632dec492636`, passes all10,097 units,
70 E2E cases, source/fresh-clone/reload/warm startup, package/install and
all23 compiled programmable cases with native exit0 and owned process-tree
closure. All12 jobs terminate:9 PASS / zero FAIL /3 SKIP; Linux/macOS
are intentionally unselected and Release/Publish skipped. All six new
cases pass, including the preserved actual dead-key refusal. Item107
remains partial for forced-output ownership and physical delivery.

Final integrated Windows qualification 37555144797 tests CI `dd194edaa4c6e2c7bd42e621bd8d38f4d84e92fe`,
exact dev merge `70fda177fd4c1411197aec908aadb954f01c8ca1`, tree `d3bcec2d598c56404f7b8952e11a8e2b2128c759`:
10,097 units, 70 E2E cases and all 23 compiled programmable cases pass;
all six readonly observation cases pass, including two genuine HKL probes.
All twelve jobs terminate: nine PASS / zero FAIL / three SKIP. Linux/macOS
are intentionally unselected, Release/Publish skipped and the 32-bit native
variant unrun. The forced-output software and physical acceptance below
remain open; item 107 is not removed.

Remaining work for item107 (CI-feasible software first):

- [ ] Software implementation/repair: Implement native-HKL forced-symbol and Linux/macOS forced digit/symbol owners with joint input/source/modifier/output provenance; reconstruct/review the lost number-row runtime preparation. Preserve the acknowledged three-mode policy, schema migration and independent descriptor/dead-state semantics.
- [ ] Hosted native qualification: Run native HKL/KLE/XKB source, migration and delivery/refusal cases for ten keys, Shift/AltGr/Caps/Nav/repeats and dead states, then unit/E2E/package/install. Read-only observations do not enable forced Lua output.
- [ ] Separate device/evidence boundary: Verify physical number-row/repeat/Nav/AltGr/Caps and dead-key output on real layouts after native ownership is qualified.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 107, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Implement native-HKL and Linux/macOS forced symbol/digit owners with joint provenance, preserving admitted policy/migration and independent descriptor/dead-state expectations. Separate device/evidence boundary: Actual number-row/repeat/Nav/AltGr/Caps and dead-key output.

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

The admitted generic physical editor/model preserves existing shortcut and
magic-source records; it does not qualify a new default hotstring-editor
binding. Its Linux/macOS physical delivery gate remains false even when the
native window host is ready. Read-only XKB observations cannot substitute for
acknowledged effective-source retargeting, all-owner collision checks or actual
modifier/output custody. Existing conditional/native-owner requirements above
remain open, including real layout changes, explicit-none precedence and
physical acceptance; legacy menus remain reachable.

Remaining work for item108 (CI-feasible software first):

- [ ] Software implementation/repair: Qualify existing conditional-editor policy without reimplementing completed work. Complete missing effective-source retargeting, all-owner collisions and modifier/output custody; preserve explicit None, personal overrides, migration and pause/reload fences. Keep unsupported seats honest and new physical delivery disabled until proved.
- [ ] Hosted native qualification: Run actual HKL/TIS/XKB source, registrar and scoped publication/compensation cases for direct star/ù, missing/ambiguous/dead source and conflicts, then affected OS unit/E2E/package/install/startup.
- [ ] Separate device/evidence boundary: Verify real layout changes and direct magic-key/editor delivery on supported keyboards/seats; source-only and controlled native owners do not prove physical delivery.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

Current Group 3 source checkpoint (item 108, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Complete effective-source retargeting, all-owner collisions and modifier/output transactions while preserving None, personal overrides and compensation. Separate device/evidence boundary: Actual layout changes and editor-key delivery on supported keyboards/seats.

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

Application notifications now use the same generated caption policy through a
shared wrapper and native macOS/Linux facades. Generic Notifier defaults, custom
titles and the independent port corpus retain their original contracts. Native
urgency decorations follow the product prefix; payloads, options, click handlers
and native return values retain their existing ownership. Two bare labels are
translated in all21 languages. Independent empty/custom/Unicode policy controls
pass108 assertions and reject all six generic-bypass controls. Focused macOS
fixtures pass82 cases on Lua5.4; Linux fixtures pass101 cases on each Lua ABI.
The new Linux test is explicitly registered. These are controlled fixtures,
not actual AppKit/D-Bus delivery or packaged acceptance. The Linux LLM enable
refusal caption remains deferred until the AI owner publishes its active runtime
projection; its unchanged fixture passes10 cases on each ABI. Native Windows
console identity, native delivery, packaging and installation remain unfinished.

A separate native macOS constructor-only probe is now registered in CI with
independent failure evidence. It retains genuine Hammerspoon notification
userdata, reads caption/body/options through native getters, checks the exact
callback registry and unregisters owned tags without invoking callbacks. It
never sends, schedules or withdraws a notification; the private runtime's exact
native retirement owns the final object boundary. Thirteen portable Python
controls and both Lua ABI safety profiles pass, including independent rejected
delivery-guard omissions. All nine genuine native cases still require hosted
execution on the final committed SHA. Constructor qualification does not prove
user delivery/clicks or complete the remaining native panel-title boundaries.

Native macOS run 37304571728 passes all nine actual notification-constructor
caption controls and retires the exact owned native process. Native delivery
and click callbacks remain unqualified. The source-pinned inventory now emits
only validated closed diagnostic facts; its dependent controller still passes
13 portable controls. This does not qualify the deferred Windows console
caption or the remaining application panels.

Remaining work for item109 (CI-feasible software first):

- [ ] Software implementation/repair: Complete an identity-safe Windows Variables/KeyHistory caption owner and remaining application panel/file-picker/notification boundaries. Preserve shared composition, bodies/options, focus, cancellation and returns; do not revive withdrawn A_ScriptHwnd retitling or redo qualified constructor work.
- [ ] Hosted native qualification: Run all five native Windows dialog title/filter/selection/cancel families with strict UIA, child status/stderr and HWND/Job retirement, actual Linux/macOS panel cases and unit/E2E/package/install. Preserve nine qualified Mac notification-constructor cases, which do not prove delivery/clicks.
- [ ] Separate device/evidence boundary: Check delivered notifications/click callbacks and desktop focus where hosted automation cannot observe the actual user session; caption implementation is not deferred merely to a PC.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

The constructor probe shares the closed bootstrap phase/status diagnostic
without changing the existing lowercase native reason policy, source/digest/
signature admission, nine-case contract, cleanup or failure status. Portable
15/0 controls retain all13 original cases. Native requalification remains
pending; first-checkpoint constructor successes do not replace the second
checkpoint refusal, and no notification delivery/callback is claimed.

The notification constructor probe shares the API-only metadata credential
owner and removes the dedicated key before native allocation. All19 portable
controls pass, including the15 prior controls; archive verification, the nine
native constructor cases, cancellation and physical retirement are unchanged.
Fresh hosted qualification and delivery/clicks remain separate; item109 is partial.

Current Group 3 source checkpoint (item 109, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Preserve genuine constructor captions/returns; establish supported fresh invisible Variables/KeyHistory capture before separate owned GUI/title qualification, retaining runtime HWND identity. Separate device/evidence boundary: Physical key history and notification/focus behavior outside observable hosted cases.

- [~] **111.** Provide two distinct, explicitly labelled shared window-switching
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
The prepared Linux cursor-display implementation replaces the incorrect global
Alt+Tab alias with an owned asynchronous X11 worker. Shared requirements declare
X11 and all six native tools; Wayland reports the action unavailable. Independent
source review and82 focused cases on LuaJIT/Lua5.4 pass. The actual Xvfb/Openbox
fixture passes34/0/0 against the generated final routing, including stale source,
focus, pause, transport replacement and composed publication refusal. These two
RandR monitor regions do not qualify physical evdev grabs or real dual displays.
Mandatory native CI registration, complete composed gates and physical display
acceptance remain pending. Existing distinct labels have all21 translations.

The shared native-worker owner now centralizes acquisition, admission, process,
timer and auxiliary-resource retirement through injected native ports. Strict
completion waits for physical acknowledgements; paused or revoked operations
retain their cleanup debt. This independent prerequisite does not implement
cursor-display switching or qualify the prepared native adapters. The Linux
packet, full composed gates and native display acceptance remain pending.

The Linux tap-hold route now retains the canonical source slot through immediate,
release, replay and timed dispatch. Cursor-display admission captures and rechecks
that exact source generation and configured action; a retired global alias cannot
substitute for it. Focused routing and admission controls pass172/0 on both Lua
ABIs. The actual pre-integration Linux suite passes6632/0 after its picker fixture
owns the real Magic dependency left cached by an earlier missing-default test;
the independent two-failure causal prefix remains preserved. Source-port controls
and virtual X11 checks do not establish physical tap-hold/display behavior.

Manual run37266564575 at e816189be1293cf3650c9d7c5696fd2201a6a6b6 now
qualifies all five native fixture-supervision cases, the additional external-owner
recovery case and all34 actual X11 window cases, with zero failures or skips.
The earlier run37262044694 failed paused-snapshot retirement despite a refused
Lua operation and zero handles: GNU timeout had detached its helper group.
All three native timeout calls now use `--foreground`, preserving the worker's
existing whole-group retirement authority. The actual picker requires a literal
GNU capability acknowledgement and keeps unsupported implementations greyed
with the existing translated reason. Six adapter and six actual-manager controls
preserve the original assertions and own their captured module dependencies.
The mandatory native gate retains exact READY/SETTLED, EOF, process-close and
kernel-family receipts; five supervision cases, external recovery and all34
independently authored window cases cannot be replaced by portable doubles.
The hosted source/test postimages are imported unchanged. The complete Linux
run still fails the updater validator, locale-audio and notification scenarios,
so packaging and installation remain unexecuted. Virtual RandR regions do not
qualify physical input or genuine dual displays; item111 remains partial.

A separate native macOS global-switcher probe is registered in CI. It verifies
an official signed Hammerspoon 1.1.1 instance, independently owned fixture apps,
exact tagged Command/Tab event observations and an independent frontmost change.
Hardware-only samples and posted combined-session release receipts remain
separate requirements; posting success cannot acknowledge Dock consumption or
modifier retirement. The controller retains exact process/input/tap/timer
capabilities through source revocation and cleanup refusal. It requests no TCC
grant; missing native permission is an unqualified CI failure rather than a skip.
Twenty-six portable Python controls and forty Lua 5.4 cases pass on the actual
committed-candidate sources. CI owns a fresh temporary-fixture control runner;
genuine native execution and product SyntheticInput broker integration remain
unfinished. This probe does not implement the product global action or complete
physical dual-display acceptance.

Native macOS CI 37304571728 did not execute this probe: two portable wrapper
controls expected lexical library paths, whereas the controller correctly uses
the canonical source root (`/var` resolves to `/private/var` on the runner).
The fixture now checks canonical library identities while retaining the exact
literal owned output argument; an independent source-alias case covers the
same boundary on Linux. No native permission or switch result is inferred from
this preparatory failure. Native execution and product integration remain open.

Remaining work for item111 (CI-feasible software first):

- [ ] Software implementation/repair: Integrate the macOS product SyntheticInput/global-switcher broker with retained input/tap/timer retirement and finite deadlines. Preserve distinct cursor-display behavior, Windows providers and Linux X11 source fences, unavailable reasons, no global fallback and no monitor setting.
- [ ] Hosted native qualification: Run genuine signed-Hammerspoon switcher/ownership cases, all 34 existing native X11/window cases and supervisor receipts, Windows provider/UI tests and unit/E2E/package/install. Portable controller/RandR results cannot complete product broker integration or real displays.
- [ ] Separate device/evidence boundary: Verify actual two-display cursor/active-window independence, moved cursors, spanning/negative/minimized/closed windows and activation refusal on supported OSes; retain current-pointer display and window-centre membership.

Fetch current `origin/dev`, establish the native baseline and coordinate affected
owners before source changes. Use `verify-change` on final sources; distinguish
successful, failed, skipped and
unexecuted unit, E2E, package, installation and launch gates.
[group3-windows-follow-up/README.md](handovers/2026-10-04-parallel-containers/group3-windows-follow-up/README.md)
retains historical commands and packet ownership; the earlier PC-only software
deferral is superseded. This item and items16/38 remain open.

The shared worker timer retirement now separates each native close admission
from its callback receipt. A synchronous callback waits for its own admission;
callbacks from rejected or older attempts cannot release retained debt.
Four original controls and ten independent delayed/synchronous refusal controls
pass on Lua5.4 and LuaJIT; seven of the new controls fail on the prior source.
These injected callback cases do not qualify physical timer APIs or complete
item111; finite default deadlines and the native display requirements remain.

Integrated run37462985994 at CI036bbff29 (exact Dev2dc6f9d6b tree) passed the
first five native supervision cases, then failed the external helper-loss
case before all34 cursor-window cases could execute. The failure was the
original five-unique-PID assertion, not a measured window operation failure.
Generated child and parent PID receipts could be observed before their writers
completed. This slice stages both receipts privately, closes the original
writer and atomically publishes the completed bytes. All46 original assertion
ASTs, cases, readers, native calls, cleanup and budgets remain unchanged.
Two real direct-child fork barriers expose the old incomplete publications
(expected red) and pass after the correction, with exact reaping, descriptor
and namespace acknowledgement and zero debt. This proves the publication race,
not the exact earlier hosted schedule or complete native family recovery.
The container still refuses the full /proc child-census prerequisite; the
unchanged five supervision cases, external recovery and all34 window cases
require hosted qualification. This does not complete item111 or items16/38.

Follow-up integrated run37470985920 at CIaea032f8 (exact Dev90076001 tree)
passes all five native family controls, external recovery and all34 original
cursor-window cases, with physical settlement acknowledged. GTK4/4, units9126/0,
E2E and packaging pass; nine first-install scenarios and three package-format
launches pass. Five distribution unit lanes each report8803 passes/78 failures:
their setup installs only LuaJIT, lacks native luv/lfs and Python3, and runs
permission-refusal fixtures as root. This slice supplies those test prerequisites
after the unchanged ordinary-user --no-deps installation proof. It compiles the
existing vendor versions from verified official Git commits and the pinned
compatibility submodule against each distribution's own LuaJIT headers. The
unchanged suite requires real native C entry points and a non-root UID before
execution. Local native compilation/admission and the unchanged9126/0 unit suite pass
with these pinned modules. Explicit CA bundles preserve HTTPS verification in
fresh minimal distributions. Five-distribution hosted qualification remains
pending. All original assertions, native windows and
deadlines remain unchanged; macOS broker integration and real displays remain
unfinished. The overall integrated run failed; Release was skipped.

The global-switcher bootstrap reports the same closed transport diagnostic
while retaining all source pins, native owners and retirement guards. Portable
29/0 controls retain the original27; native broker qualification remains open.
Subsequent Linux-only run37479728162 on CIa1e30e88 (exact Dev7bfd15ea tree)
passes units9126/0, native supervision5+external1 and all34 window cases. GTK
passes3/4: case0 misses its unchanged receipt poll, while real GTK exits0 after
about2.3775seconds with the exact authored identity present. No argv refusal,
specific cold-service cause or production regression is established. Package
and all distribution lanes are skipped; the new native distro bootstrap has
not executed on hosted distributions. Release is skipped. Preserve this failure
and the earlier4/4 success separately; no assertion or deadline is weakened.

The global-switcher probe consumes the metadata key at its actual same-process
entry, before Git or native allocation. Its portable suite passes33/0 and retains
all29 prior controls. Brew, independent owner controls and the log receiver
exclude the key; archive/native ownership and refusal contracts remain intact.
Fresh native acquisition, broker integration and actual switcher consumption
remain unqualified. Linux window assertions and deadlines are unchanged.
Item111 and cross-cutting requirements16/38 remain open.

Distribution prerequisite follow-up (2026-10-06): independent native run
37491630360 tested byte-identical helper sources and exposed three real
ordinary-user fixture writes denied by the root-owned checkout directories.
Alpine additionally lacked the actual curl executable; Debian could not
link its native modules without C startup objects. The preparation now
provisions curl and Debian libc6-dev, changes only the driver/tests directory
owners and adds actual ordinary-user write receipts before the unchanged
suite. The three prior preflights/suite calls, native module pins and all
assertions remain intact. Genuine UID1000 private mode-only refusal/recovery
reproduces all three failures and recoveries; the original full suite passes
9,126/0 on 433 modules with a short owned TMPDIR. Its earlier long-TMPDIR
Unix-socket harness failure is retained separately. Actual foreign-owner
chown, all five corrected distributions and integrated package/install
acceptance still require hosted qualification; item111 stays partial.

Current Group 3 source checkpoint (item 111, 2026-10-06): [Group 3 current checkpoint](handovers/2026-10-04-parallel-containers/GROUP3-CURRENT-CHECKPOINT.md). All 46 owned commits are integrated; sixth Linux-only qualification ended in failure at GTK case 0. This item remains partial. Remaining software/hosted qualification: Complete Mac broker/wiring and exact retirement qualification; preserve final Linux supervision five, external recovery one and window 34 successes without rebuilding the switcher. Separate device/evidence boundary: Genuine dual screens, independent cursor/focus and moved/closed windows.

- [ ] **112.** Accept an AI prediction immediately with its configured
      modifier-plus-digit shortcut, with matching shortcut hints on all three OSes.

  Maintainer report on Windows AHK (2026-10-06): the shortcut currently only
  highlights the corresponding prediction. Pressing the configured shortcut
  must immediately insert that prediction through the normal acceptance owner,
  including any correction of previously typed text.

  Each prediction tooltip row must show its effective shortcut in a separate
  right-aligned, muted gray column. Derive the displayed modifiers and digit
  from the same current menu configuration that owns the binding. Use one
  shared visual design on Windows, macOS and Linux, with the existing native
  modifier labels, and refresh both bindings and hints after configuration
  changes.

  Regression coverage must distinguish insertion from highlighting, verify
  every supported prediction index and modifier choice, preserve the existing
  behavior when no prediction is mapped, and check hint/binding agreement.
  Native acceptance must cover replacement/correction in Windows Notepad and
  the supported macOS/Linux editors, plus tooltip alignment and appearance on
  all three OSes. This is an unimplemented follow-up; it does not complete the
  existing prediction-input or tooltip validation items.

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

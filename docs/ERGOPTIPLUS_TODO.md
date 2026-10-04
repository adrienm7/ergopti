<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-03. Latest release: v0.0.0-dev.155 (c9e4c64ab); `dev` is
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

The current session requires one atomic commit per fix or feature, updating this
checklist in the same commit. Push each commit immediately to `dev`, then cancel
every CI run triggered by that exact push to avoid releases. Run the full CI
through `workflow_dispatch` on a temporary `codex/ci-*` branch: a non-dev ref runs
the CI profile and publishes nothing. Use its Windows and macOS runners for
native behavior and parity regression tests. Preserve unrelated changes, stage
exact paths, never force-push `dev`/`main`, and delete only the temporary CI
branches this session created after their evidence is recorded.

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
  Extension geometry and physical magic-key completion remain in L4.
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
- [~] **6.** Complete L4 extension layout geometry and physical magic-key
  behavior. Keep independent base/Shift, AltGr/ShiftAltGr and number-row
  emulation. The physical magic-key setting is item 30.
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
  still applies its hotstring sections through hotstrings_config (storage.json)
  and leaves the trigger to its tray.
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
- [ ] **22.** Delta updates: macOS Sparkle deltas are ready on
      `wip/delta-updates` (mirrored as `backup/wip/delta-updates`, not integrated:
      its CI step only runs on real releases, so it needs a dry-run CI mode first),
      then Windows and Linux per ADR 010 with an automatic full-download fallback.

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
- [~] **39.** Repository hygiene: the maintainer deleted every temporary backup
  branch on 2026-09-30; agents must not create `backup/*` branches again. The
  finished agent worktrees under `.claude/worktrees/` can be removed; the
  uncommitted test edit left in the `wip/win-tooltip-border-fix` worktree
  (tooltip DPI radius) is the only unsaved change among them.
- [ ] **40.** The packaged-launch gate never builds a Karabiner configuration:
      the CI runners have no Karabiner-Elements, so dev.148 passed every launch
      scenario while every real Mac refused the deploy (« generated rule 1
      manipulator 3 has inconsistent managed conditions », fixed with
      `json-shared-tables`). Add a launch scenario that makes the app build and
      merge its Karabiner configuration in the real Hammerspoon runtime (into the
      runner's own `~/.config/karabiner/karabiner.json`) and fails on any ERROR,
      without needing the Karabiner driver.

The packaged macOS launch matrix now contains a Karabiner configuration scenario. It uses the real Hammerspoon JSON runtime and production build, merge and conditional atomic-file owners for eight default/recommended and switch vectors in a runner-owned private destination, preserves foreign profiles and personal rules, proves independent codec trees, and restores exact original bytes. It acquires no remap lease and installs no driver. The selected local gates pass 353 JS checks and 13,074 portable macOS cases, including five registered publication/restoration lifecycle regressions; 65 Python judges pass. Actual signed native execution remains pending and the existing scripting transport deadline is blocking, so TODO40 stays partial until that proof is green.

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

- [~] **43.** A Mac upgraded from a pre-lease release could not deploy (dev.149:
  « Merge aborted: 25 ambiguous legacy ErgoptiPlus rules … matches the
  historical CapsWord anchor »): its karabiner.json keeps an untagged historical
  block the merge cannot prove. The refused deploy now offers « Retirer les
  anciennes règles » (listed, confirmed, backed up next to karabiner.json), also
  from a Tap-Hold menu row while the rules are pending
  (`karabiner-legacy-cleanup`); untested on a real Mac. Still to do: find why
  the proof fails from the backed-up file.
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
- [ ] **47.** Running local OpenAI-compatible servers (oMLX, LM Studio,
      llama-server/LocalAI, Jan; `_shared/modules/llm/local_servers.json`) are AI
      backends on macOS only (`local-openai-backends`). Windows and Linux need an
      asynchronous probe (WinHTTP, curl), keyless API entries (Linux
      `api_remote.lua` refuses an empty key) and menu rows; the Linux tray has no
      text input for an address or a key.
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

- [ ] **54.** Every menu is declared in the shared menu manifest, never in
      driver code. The ratchet `npm run test:native-menu-rows` counts the rows
      drivers still build (current baseline: Windows 105, macOS 187, Linux 115, each
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

Streaming-display parity remains a separate follow-up: canonical
`llm.display.streaming_multi = true` becomes Windows `show_all_at_once = true`,
which waits for all variants, while macOS and Linux interpret true as progressive
variant display. macOS ticks Show All At Once for false, but Linux ticks it for
true. Reconcile the native prediction owners and shared check polarity before
retiring this policy; preserve Windows' explicit refusal of unsupported token
streaming rather than infer capability from the stored setting.

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
- [ ] **63.** Layer actions: add screen brightness up and down (asked as an
      example for the wheel slots), with its key, action and label on the three
      drivers and 21 locales.

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

- [ ] **81.** The maintainer asks to treat item 54 now (every menu row is
      declared in the shared manifest, none built in a driver's folder):
      Windows 105, macOS 187 and Linux 115 rows are still built by the
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
  Windows Boolean and preserved unrelated settings. The current Boolean now
  resolves actual desired KLE base descriptors before falling back to native
  HKL probing. Already-direct Ergo-L over AZERTY retains Shift symbols; an
  emulated swap emits through the existing KLE owner rather than flattening
  actions/dead states to text. Inspection preserves Caps and pending state.
  Independent ten-key vectors and captured registered criteria/callbacks cover
  actual AZERTY/QWERTY HKLs, base/category/navigation changes, AltGr, Caps
  descriptors and dead-key composition; native CI remains pending.
  Remaining: the three-choice shared policy, persistent migration, translated
  choices and corresponding owners on supported macOS/Linux paths, with genuine
  platform limits documented. No enum or schema change occurs in this slice.
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

<!-- docs/memory/linux-web-release.md -->

# Linux, web, and release memory

## Linux input

### project-linux-grab-is-a-contract-not-a-flag

Observe mode and `EVIOCGRAB` mode have different correctness contracts. A driver
that does not grab cannot prevent a physical terminator from reaching the app;
replay logic must reflect the active mode.

### project-linux-update-restart-is-watched-until-the-daemon-reports

After an update, `modules/updater/restarter.lua` starts the new daemon under a
watcher (`WATCH_SCRIPT`), the Windows boot-ready and probation contract: the
daemon reports its pid to a one-shot token (`infra/updater_boot_ready.lua`, after
`BootProfiler.complete()`), and a daemon that does not within 60 s, reports
garbage or dies in 0.75 s is stopped, its tree moved to `<root>.failed-<pid>`,
`<root>.old` put back and the previous daemon started. The relay runs the
watcher itself; under systemd it is a `systemd-run --user --collect` transient
unit (the service's cgroup would kill it), the token goes through
`systemctl --user set-environment`, and a refused restart or a Quit
(`cancel("systemd")`) stops that unit first so it never rolls a good update
back. A tree without the reporter file is only started; the rollback start is
not watched. Moves are `mv -T -n` plus an existence check, not renameat2.

The watcher's wait is the updated daemon's boot, so a user's Quit lands in
that daemon, not the old one (a relay restart has already requested the old
one's shutdown; under the unit systemd TERMs it at once). Every user Quit
(`infra/quit_request.lua`, both degraded trays) first writes `quit` to the
token (`report_quit`), and the watcher then keeps the update and starts
nothing. macOS does the same (`infra/updater_boot_ready.lua` `report_quit`, called
by `TerminationCoordinator.request_user_exit` and the non-reload
`hs.shutdownCallback`; `release_installer.lua` keeps the build on `quit`).
Action: a new Quit path calls `report_quit`. systemd expands `$$`
(and `${NAME}`) in a unit's command line, so the transient watcher's command
goes through `systemd_watch_command`, which doubles every `$`. Action: any
new `systemd-run` command escapes `$` the same way.

A `systemctl --user --no-block restart|stop` of the daemon's own unit runs
inside that unit's cgroup, so systemd's TERM of the cgroup can kill the shell
and client before they report: the call then read as refused although the job
ran, which disarmed the update watcher (seen about one run in five under a real
user manager). Those calls carry `OWN_UNIT_JOB_PREFIX` (`trap '' TERM;`).
Action: any new command that stops or restarts the daemon's own unit takes the
prefix. `tests/hardware/desktop/run_update_restart_watcher.sh` runs a real
`systemd --user` in a container by mounting a tmpfs on `/run/systemd` and
creating `system/` there (sd_booted) in a private mount namespace.

### project-linux-the-install-path-runs-no-synchronous-child

The async installer (`Installer.install_owned`) runs on the daemon's event loop
while the keyboard is grabbed. Every child on its path is an owned ProgramRunner
child that re-admits the install deadline (`start_owned_child`): the updated
wrapper's `--help` smoke (LUR-001) and the previous tree's
`install/ownership.sh`, which hashes the whole payload (9 s natively on a real
installed tree, found by `tests/hardware/phys_live_guest.sh`). What stays
synchronous is in-process: `Ownership.verify` (about 0.25 s per call natively,
three calls per install) and the moves. A new child on this path goes through
`start_owned_child`, never `os.execute`; test it from a timer inside a running
loop, because a child run before `uv.run` hides any stall.

### project-linux-live-proof-host

The cloud sandbox kernel has no uinput, no KVM and no systemd PID 1, so a
systemd Docker container cannot host the live daemon either.
`tests/hardware/run_phys_vm.sh` boots an Ubuntu cloud VM under QEMU (TCG without
`/dev/kvm`, about 20 times slower: the first install takes about 25 minutes)
and runs `phys_live_guest.sh` there. A loopback `HTTPS_PROXY` becomes
`10.0.2.2` in the guest, and its apt sources must use https because the agent
proxy refuses plain http with 405. On a GitHub-hosted Ubuntu runner the guest
script runs directly as root.

### project-linux-device-descriptors-are-close-on-exec

`EVIOCGRAB` and a uinput device belong to the open file, not to the daemon: the
kernel drops them only when the last descriptor on that file closes. A child
the daemon starts (`xdg-open … &`, a gesture's application, the update relay)
inherits every descriptor opened without `O_CLOEXEC`. A daemon that dies while
one runs leaves the keyboard grabbed by a process that never reads it, the
restarted daemon's grab fails with EBUSY, and a forwarded key stays down on a
virtual keyboard nobody destroys. Action: open every device descriptor
`O_CLOEXEC`; `tests/hardware/run_grab_race.lua` section 7 kills a daemon that
left a child running and checks the keyboard comes back.

### project-linux-the-mouse-is-grabbed-only-for-a-wheel-binding

The hook observes the pointer and never grabs it, except while the navigation
layer is held and binds a wheel direction: then it grabs the mice (EV_REL and
no EV_ABS; a touchpad is never taken), forwards every report through the
virtual device (created with the relative axes for that reason) and turns a
bound notch into its key press and release, dropping the high-resolution twin.
The grab ends with the layer, after the last forwarded button is released, or
the desktop keeps a button down. `EVIOCGRAB` does not label reports already
queued at acquisition or release. The current grab state, event timestamps and
an `EAGAIN` read do not by themselves establish an atomic boundary with the
ioctl; changes to this handoff must account for reports on both sides.
`adapters/keyboard_hook.lua`'s main chunk is
at LuaJIT's 200-local ceiling ("main function has more than 200 local
variables" at load): new hook state goes into an existing table such as
`LayerPointer`, never into new top-level locals. The same holds for
`modules/keystats/keystats.lua` (raw-event buffers join a table such as
`_clipboard`), and `ergopti_hotstrings.lua`'s `main` is at the 60-upvalue
ceiling: a new top-level local it reads breaks the load, so `require` inside
the closure instead.

A pointer's custody in a source transaction is its descriptor's open
lifetime (the Reader's `same_open`), never its input generation: the layer's
`ungrab` and a `SYN_DROPPED` renumber the slot, and judging the mouse by the
generation once stopped the hook at the next device watchdog tick after the
first wheel or button binding (`_source_recovery.member_custody`).

### project-linux-container-proofs-model-the-kernel-at-libc

A container kernel has no uinput: `tests/hardware/run_container_proofs.sh`
runs the unchanged daemon with `virtual_kernel_preload.c` in `LD_PRELOAD`,
FIFOs as `/dev/input/eventN` and a bind-mounted `/proc/bus/input/devices` in a
private mount namespace. The model sits at libc because the hook's managed
capture admits only the Reader's production FFI backend: a Lua `_set_backend`
fake is refused ("original Reader authority is unavailable"), and swapping a
Reader export breaks the hook's cold-construction pin. The shim must also catch
libuv's `syscall(SYS_close)` and `syscall(SYS_statx)`, and drop `LD_PRELOAD`
for the daemon's children. The AT-SPI client binds to the first bus it meets,
so a multi-session proof reads AT-SPI in a child process. Locally, `python3`
may lack gi: run with `PYTHON=python3.12`.

### project-linux-x11-slave-switch-revokes-the-layout

Xorg sends an XKB new-keyboard notify each time the slave keyboard feeding the
core keyboard changes (XTEST, the daemon's virtual keyboard after a physical
one). `adapters/xkb_source_probe.lua` bumps its source generation on every such
notify and `adapters/xkb_capture.lua` renews a revoked inverse only for a group
change, so after one switch `KeyboardLayout.is_ready()` stays false and every
replacement takes the clipboard route. Xvfb fed by uinput never shows it (it
reads no evdev); the container proofs show it with XTest and warm the XTEST
slave before the daemon starts.

### project-linux-touchpad-gestures-share-the-touches-with-the-desktop

The gesture reader decodes the touchpad evdev node without a grab, so the desktop
(GNOME 47 and later) acts on the same touches: the nine two-finger slots fight
with scrolling (the decoder refuses a scrolling pair as a swipe, rule 1, and the
reader start names each bound two-finger slot), and no code here can stop the
desktop's own gesture without taking the grab. Under Wayland no external process
can move, focus or close a window, so no Linux tool can add those actions there.

### project-linux-tap-to-click-is-re-derived-from-the-touch

libinput synthesises a tap-to-click above evdev, so the kernel never reports
its button; Windows and macOS count it because their hooks see the button.
The keyboard hook forwards every touch report of a pointer source as a
`contact` and stamps each `frame` with the kernel time; `pointer_metrics`
runs `modules/gestures/tap_detector.lua` (libinput's 180 ms timer from the
last landing, 1.3 mm, at most three fingers, no landing after a lift, no
button press) and counts a left or right tap as a click only while
`adapters/tap_to_click_setting.lua` reads the desktop's setting as on. That
reader answers unknown, never off, when the desktop does not say; the Metrics
menu then names « Touchpad taps » as not measured. Palm, thumb and
disable-while-typing rejection are not reproduced: a change that needs them
must bring the keyboard stream and the hwdb quirks to the detector. The
setting is read off the input path (the tick, every 5 s while the pad is in
use) except once at a pad's first tap.

### project-linux-a-field-must-be-named-at-every-boundary

Linux input records cross evdev, resolver, injector, and Lua boundaries. Preserve
the exact canonical field names at each hop.

### project-linux-writing-a-table-nobody-reads

Persisting a mapping is not implementation if the runtime resolver never reads
it. Tests must execute selection through injection.

### project-a-computed-label-is-a-list-of-one

Provider APIs may return a single computed label wrapped as a list. Normalize at
the adapter boundary rather than spreading shape checks through the driver.

### project-linux-luaposix-stat-is-lstat

luaposix's legacy `posix.stat(path)` reports a symlink itself (`type = "link"`,
the link's own inode) and its `mtime` in whole seconds; it never follows the
link. A module that prefers `posix.stat` and falls back to `stat -L` therefore
behaves differently on a host where luaposix is installed. Action: when a path
must be judged by what it points to, use `luv.fs_stat` or `stat -L`, never
`posix.stat`; a test of that path injects a `posix` port with these semantics
so it fails on a host without luaposix too.

### project-linux-keymap-before-libxkbcommon-1-8

`xkbcli dump-keymap-{wayland,x11}` only exists from libxkbcommon 1.8; Ubuntu
24.04 ships 1.6. On X11 the keymap comes first from the source probe in
process (`xkb_source_probe.dump_keymap`, the text `xkbcli dump-keymap-x11`
prints, 0.6 ms against a 30 ms `xkbcomp` fork; `run_keymap_native_dump.lua`
proves the parser reads both alike). `adapters/keyboard_layout.lua` otherwise falls back to
XWayland's keymap (`xkbcomp -xkb $DISPLAY`, exact because XWayland receives the
compositor's keymap) and then to `xkbcli compile-keymap` from the session's
layout names (`infra/xkb_rmlvo.lua`). Action: a keymap source must be proven on
the runner's own libxkbcommon through `refresh()`, never through a fallback the
test writes itself.

### project-linux-xkb-data-tests-need-a-real-missing-include

A serialized, self-contained keymap is not a negative control for XKB data.
libxkbcommon 1.13.1 admits a context with no include paths and compiles that
input; 1.7 requires an existing path, even an empty directory. Also, on 1.13.1
an absent `XKB_CONFIG_ROOT` override does not remove the compiled system path.
Environment variables alone therefore do not prove data absence.

Action: give the native keymap a unique required include, copied from genuine
`evdev` data found through the native context's search paths. Omit that file,
then restore only it with the same argv, environment and include paths: require
exact native compiler refusal followed by successful capture. Keep the
self-contained positive and the independent Compose-table negative. Never
change production context flags or accept either capture result by version.

### project-linux-injection-table-comes-from-libxkbcommon

The char → keystroke table is probed on the validated keymap
(`XkbCapture.inverse_table()`): each chord the injector can press is applied to
a fresh XKB state. A text model that maps level N to a fixed modifier is wrong
for keypad types (NumLock) and Ergopti's `ERGOPTI_SEVEN_LEVEL` (Shift = level
3). Shortcut letters (Ctrl+V, Ctrl+W) go through
`keyboard_layout.shortcut_keycode()`. Action: never add a hardcoded evdev
letter or a level → modifier table.

### project-linux-atspi-focus-is-per-application

Every GTK application keeps STATE_FOCUSED on its last focused field; only the
window manager's STATE_ACTIVE frame says which one the user is in. A
desktop-wide search is ambiguous with two windows open, and the daemon fails
closed on ambiguity: every expansion blocked. Measured cost is ~1 ms per node
against a 1 s probe deadline. Action: keep the search scoped to the active
window and prove changes with `tests/hardware/run_atspi_focus.sh`.

### project-linux-first-install-needs-luajit-module-builds

Generic `lua-*` packages are Lua 5.4 builds on Fedora, Arch, openSUSE and
Alpine; LuaJIT needs `lua51-*` (Arch), `luajit-*` (openSUSE), `lua5.1-*`
(Alpine, Fedora). Fedora has no LuaJIT lgi, so its WebKit windows cannot open
(declared in the `first-install-distros` matrix). GNOME shows no tray icon
without an AppIndicator extension. Action: prove installer changes with
`tests/hardware/run_in_docker.sh <image>` and the first-install matrix.

### project-linux-tap-holds-run-in-the-daemon

Since 2026-09-24 the Linux tap-holds and navigation layer run in the daemon
(`platform/remap/tap_hold_engine.lua`, installed by `tap_hold_manager` through
`keyboard_hook.set_remapper`, which releases every held key on swap, pause and
stop). They replaced kanata, which needed glibc 2.39 (absent on Debian 12 and
Ubuntu 22.04), was never started by the daemon, and broke its whole config on
one free-text action. No Linux release had been installed, so nothing
migrates an old kanata unit. Action: do not reintroduce an external remapper or a `kanata.kbd` release asset; change
tap-hold behaviour in the engine and its loader/writer, with Lua tests.

### project-linux-script-chords-decide-in-the-consumption-callback

The Linux script chords (`modules/shortcuts/script_chords.lua`) decide in the
keyboard hook's consumption callback, before the tap keys: AltGr is the XKB
level-3 role the hook reports, so a layout whose right Alt is a plain Alt has
no chord. They follow no feature switch but their own, run on the next loop
tick and judge the slot again there, so a pause in between runs only a
script-management action. The Shortcuts scope owns them; its `only =
"script_chords"` narrowing leaves the other owners' rows and parameters alone.
Action: keep any new chord in that callback, never in `on_key`, where the
application already has the key.

### project-linux-ai-off-disarms-the-ai-actions

With the AI switched off nothing of it runs on Linux, as on macOS and Windows.
`modules/shortcuts/ai_actions.lua` answers `blocked(action)` for every `llm_*`
catalogue action from the prediction engine's switch, read at each press: a
modifier chord, a physical slot, a number-row tap key and a touchpad gesture
bound to one are left to the application (never claimed, then refused), and the
switch-on re-arms them with no reload. The engine's `arm_agent` and
`agent_blocked` also hold the agent's automatic mode back while it is off, and
the switch-off drops its pause and request through `cancel`. Tap-hold taps and
ordered-pair taps bound to an AI action are unarmed too: the engine asks its
`tap_blocked` port at each press and release (the key then types its own tap,
Space types a space) and the pair engine rebuilds its policies from the next
press with every key up, so no reload is needed. A tap-hold hold is a modifier
or a layer, never an action, so there is no hold to gate. Action: a new
key-claiming layer asks `AiActions.blocked` before claiming; extend
`test_ai_off_disarms_ai_actions.lua` and `test_tap_hold_ai_off.lua`. The agent's
manual actions (`llm_agent_selection`, `llm_agent_command`) refuse with the AI
off (`agent_refused`, notice `llm.manual_prediction.disabled`), and the picker
greys them through the `ai:on` requirement token of `actions.toml`, which all
three drivers understand (Linux `requirement_holds`).

### project-linux-the-ai-completes-its-own-typing-context

The prediction engine does not read the hotstring word buffer on Linux. The
Linux `modules/hotstrings/engine.lua` wrapper reports each edit the shared
engine applies (typed text, Backspace, `apply_expansion`, `reset`, a
navigation) to the AI context of `modules/llm/context.lua`, a rolling window
from `_shared/ai/engine/policy/context_buffer.lua`, which macOS shares for its
navigation rule and pins with `context_buffer_vectors.json`. A navigation key,
Escape, Enter, a click, a shortcut and a tap-hold command clear it only while
`llm.generation.reset_on_nav` is on, whatever the `hotstrings.*_resets_word`
options do to the word buffer; any other `engine:reset` (focus, pause, failed
output, undo, a word deletion) clears it, and `engine:reset(nil, nil, true)`
is the one reset that keeps it (a mirrored expansion, a click, an accepted
prediction). Paste, cut and undo chords clear it in `handle_control`, a private
expansion clears it, and the AI off keeps nothing. Action: a new site that
resets the word buffer chooses between the default (forget) and the keep flag
with an `engine:navigated()` call; the prediction engine's `main` chunk is at
LuaJIT's 200-local limit, so it keeps the context in the reused `_context`
slot.

### project-linux-uinput-drops-a-press-of-a-held-key

The kernel keeps one bit per key: a press of a key already down is dropped, and
its release lifts the key whoever held it. A chord tap written straight to
uinput therefore released a Ctrl a tap-hold was still holding. Action:
`combo_emitter` skips the chord modifiers `keyboard_hook` reports held, and the
tap-hold engine masks a lone Alt or Super release with KEY_F24.

### project-linux-coarse-clock-overstates-a-gap

When luv is unavailable while `infra/monotonic` loads, its source is
`os.time() * 1000`: two keys typed together can read 1000 ms apart across a
second boundary. Action: subtract `Monotonic.resolution_ms()` when comparing
a gap, as `within_expansion_delay` and `keyboard_hook` do. Daemon scenarios pin
that clock with `ERGOPTI_E2E_CLOCK=seconds` and `{TICK}`.

Native signal ownership still requires luv. A coarse-clock fixture hides luv
only while loading the real Monotonic module, then restores both its loaded
and preload entries before starting Main. Pump native I/O and finish any
SQLite flush before advancing virtual time; a readable rollback is not a
committed configuration snapshot. Shutdown assertions require actual native
close acknowledgments, independently of the clock being simulated.

### project-linux-capsword-locks-the-desktop-capslock

Until 2026-10-20 the Linux CapsWord only rewrote the character handed to the
hotstring engine; the key was already forwarded, so no capital reached an
application. A session of `modules/shortcuts/manager.lua` now locks CapsLock on
the desktop, as Windows (`SetCapsLockState`) and macOS (Karabiner
`caps_lock`) do: `keyboard_hook.lock_caps_for_word` first taps CapsLock in the
capture state (a keymap whose CapsLock locks nothing, `ctrl:nocaps` or
`caps:escape`, is refused before the desktop sees the key), then the session
taps KEY_CAPSLOCK on the daemon's uinput keyboard. Letters arrive as the
layout's CapsLock level types them (Ergopti's explicit Lock level keeps digits
and punctuation); the injector already unlocks around the text it types. A
CapsLock the user had is ridden and left on. The user's CapsLock press, a
stop, an emergency stop and `while_released` end the hold, unlocking while the
daemon still owns the keyboard; an LED reseed restores the session's lock,
which the grabbed keyboard's LED never shows. The `caps_word` catalogue action
(a keyboard slot, a key-combination tap such as Windows' LAlt then CapsLock, a
simultaneous chord, a tap-hold, a gesture) toggles the same session through the
executor: `tap_hold_manager._run_tap` never hands it to the hook as intent, and
the engine's former per-letter mode (`arm_caps_word`, `adapters/caps_word.lua`)
was removed on 2026-10-22. Only the one-shot Shift still arms the hook's input
owner. Action: end a session only
through `end_caps_word`, which unlocks; never type a capital of the daemon's
own; a desktop that keeps one lock state per keyboard (sway without keyboard
grouping, in `--no-grab` mode) needs a real-machine check.

### project-linux-the-menu-builder-is-pinned-token-by-token

`tools/lib/menu-native-llm-parent-binding.cjs` and the language-owner binding
read `ui/menu/builder.lua` token by token. A new top-level `local` (an
import, a helper table, a function) in that file turns `test-menu-parity` and
`test-hotstring-category-submenu-order` red. Put helpers in their own module and
call them with an inline `require(...)` at the call site, as
`ui/menu/feature_notice.lua` is. Check fast with
`declaredLinuxTopLevelPublication(source)` instead of the four-minute suite.

### project-linux-e2e-tray-clicks-need-the-idle-pump

A committed menu row asks `ui/menu/rebuild_owner.lua` for a redraw; the tray
publishes the new tree only on the event loop's idle tick, and a click on a
stale tree is held, not run. An E2E that clicks rows must click the tree the
tray was handed (the appindicator stub's `set_menu`), then run `loop.onIdle()`
before reading the menu again, as `tests/e2e/startup_child.lua` does for the
delimiter rows. A switched-off feature notice is error-level by design
(`_shared/menu/engine/feature_notice.lua`), so the start-up child's error-dialog watch
flags it unless the step names the notice it causes. A refused write through a
read-only folder needs a non-root user: report it as SKIP under root.

### project-linux-tray-submenus-fill-on-activate-not-show

`platform/tray/appindicator.lua` builds a submenu's rows only when it is
opened. libdbusmenu-gtk 0.4 turns a client's `AboutToShow` on a parent row
into that GtkMenuItem's `activate`, and rows added in the handler are in the
next `GetLayout`. The submenu GtkMenu's `show` is useless as a trigger: the
indicator shows every submenu when the menu is set; a native popup (XEmbed
fallback) maps it instead. An empty GtkMenu is published as a plain row and
`AboutToShow` on it is ignored, so an unopened submenu holds one hidden
placeholder. `gtk_widget_show_all` recurses into submenus: never call it on a
menu. `gtk_check_menu_item_set_active` emits `activate`, so a changed check on
a parent row must block that row's open handler. Action: prove tray changes
with `tests/hardware/sni_host.py` (`--expect-lazy`, `--toggle-label`), which
opens submenus as a panel does.

The daemon's idle wait polls the GLib main context's descriptors with the
input sources (`appindicator.wait_companion`: acquire, prepare, query, poll,
check, release; dispatch stays in the next tick's `pump()`). Before 2026-11-11
only evdev was polled, so every dbusmenu call waited out the 8 ms idle wait: a
submenu open cost 26 ms whatever its size. GLib's own timeout is deliberately
not adopted (an always-ready source would spin the loop). Action: a new GLib
or GTK consumer on the daemon's thread relies on this wake, and a change to
the wait keeps `run_perf_budget_container.py`'s tray budgets green.

### project-linux-file-manager-folder-needs-the-window-own-bus

The folder of a file manager window is read only where the window publishes
its own owner: Nautilus's GtkApplicationWindow sets `_GTK_UNIQUE_BUS_NAME`
and `_GTK_WINDOW_OBJECT_PATH`, and its FileManager1 `OpenWindowsWithLocations`
is keyed by that path. Query the unique name, not `org.freedesktop.FileManager1`
(Thunar or Dolphin may own it). The list holds every tab in tab order and the
active tab is not published (the `go-to-tab` action state stays 0), so tabs on
different folders are ambiguous. Thunar's D-Bus methods only take
caller-supplied folders and Dolphin's MainWindow only says whether a URL is open
in some tab. Action: keep `adapters/file_manager_folder.lua` refusing every
other owner, and prove a new file manager with
`tests/hardware/run_file_manager_folder.sh`.

### project-linux-field-report-answers-its-todo-section

`tools/dev/collect-linux-field-report.sh` runs, after the daemon's field run,
the collector-side steps of `linux/data/field_guided_steps.json` through
`tools/dev/field-guided.py`: probes (uinput, evdev, the user unit, a polkit
agent, the focus reporter's log line), observed gestures (Metrics rows by kind,
day-log line counts) and attested ones (y, n, s). It ends with
`field-todo-summary.py --os linux`: one verdict per point of TODO « To confirm
on Linux », whose open lines carry `field-point` tags
(`linux/data/field_todo_coverage.json`,
docs/tooling/linux-field-report-coverage.md). Action: a new open line needs its
tag and coverage entry, or `test_field_todo_coverage.lua` fails; a probe reads
counts or exit codes only, never a line of the log.

## Linux native boundaries

### project-linux-absence-needs-enoent

Linux native ports admit absence only on a proven ENOENT; any other open refusal
blocks the mutation (JSON store, backup chain, logger, SQLite) and never starts
an empty store. A file write counts only with write and close success. FIFOs,
sockets and directories are rejected for read, write, JSON and build-stamp reads
through a pinned `O_NONBLOCK` descriptor plus a regular-file check, never by a
blocking open. Embedded NUL is refused at every native boundary (spawn argv,
`sh -c`, curl config, file path, SQLite script) through one argv validator;
binary payloads travel as Base64 or hex.

### project-linux-curl-argument-rules

Every Linux curl call passes `--disable` first, turns URL globbing off, fences
the scheme to HTTP and HTTPS, never downgrades HTTPS, and does not follow
redirects for credentialed requests. Bodies go through `--data-raw` or an
inherited anonymous pipe, never argv; an empty header value uses curl's `Name;`
form; CR, LF or NUL in a header is refused before an incumbent request is
cancelled. The Windows and macOS adapters do not all follow these rules yet (see
the TODO parity backlog).

### project-linux-libuv-and-replacement-rules

Validate and compose a replacement request before cancelling the incumbent owner
(HTTP, owned HTTP, digest); the updater and the layout registry own separate
digest slots. Capture each libuv handle inside its protected constructor,
require start receipts rather than `pcall` success, call `update_time` before
arming a relative timer, pass durations through the shared finite-number
predicate, and describe foreign error objects with `ErrorDescription`, never
`tostring`. The event-loop reentry guard is separate from stop, and sleeps retry
`nanosleep` after EINTR. libuv reports exit status and termination signal
separately; a signal is a failure (SIGTERM is status 143), and ESRCH on a
process group means already gone.

### project-linux-webkit-takes-sigusr1

WebKitGTK's JavaScriptCore suspends threads for its collector with SIGUSR1 and
installs its handler over the daemon's ("Overriding existing handler for
signal 10"), so the reload request (SIGUSR1) killed a daemon with a WebView
open, SIGSEGV. `infra/signal_handlers.lua` `reserve_webkit_gc_signal()` sets
`JSC_SIGNAL_FOR_GC=12` (SIGUSR2) at the top of `ergopti_hotstrings.lua`, before
anything loads WebKit; verify with the process `SigCgt` mask
(`tests/hardware/run_webkit_gc_signal.lua`). JSC still prints "invalid option:
JSC*SIGNAL_FOR_GC=12": its option parser reads every `JSC*\*` variable, while
WTF honours this one. A new signal the daemon handles must not be 12.

### project-linux-a-corrupt-store-moves-aside-without-replacing

A malformed JSON store is set aside through `infra/corrupt_aside.lua`
(`<path>.corrupt`, then `.corrupt.1`, ...) with the no-replace move, never with
`os.rename`, which replaces an older set-aside or the one another process makes
at the same instant. `api_entries.lua` used `os.rename` until 2026-10-31;
`agent_learning.lua` and the storage adapter already refused to replace.

### project-linux-idle-loop-costs

An active libuv idle handle makes the loop poll with a zero timeout, so the
daemon's idle tick used to spin one whole core (measured 99.997 % of a core,
180 000 ticks a second, nothing to do). The tick now ends in
`EvdevReader.wait_any_readable` (one `poll(2)` over every open keyboard,
pointer and touchpad descriptor, at most 8 ms) supplied as `idleWait` by the
daemon, and a fixed 1 ms `nanosleep` when the wait declines (nil). The wait
answers nil, never false, when it cannot sleep, and a hook with an event read
but not yet dispatched answers true at once. A source that is open but never
drained would turn the wait into a spin: open a descriptor only for a consumer
that drains it. On X11 the focus poll (four times a second) reads the root's
`_NET_ACTIVE_WINDOW`, the title and the owner through libxcb in this process
(`adapters/x11_focus`); the xdotool route forked twice per poll and blocked the
loop for tens of milliseconds. Never use Xlib for it: a dead server makes Xlib
`exit()`. TOML decoding of the shared codec is linear in the number of
structural characters: its scanners copy runs of plain characters with one
`string.find` stop set per lexical state, the pattern `^%s*(.-)%s*$` is
quadratic on a long value, and `unescape_body` returns a body that needs no
decoding as it is. Any new scanner there is proven against the previous one
with a differential fuzz over every repository TOML file before it ships.
`infra/perf_counters` holds the permanent closed-enum counters and spans, one
evidence line per minute and one at exit (`flush_now`); measure with
`tools/bench/linux-hot-path.lua`, and the whole daemon in an X session with
`tools/bench/linux-session-bench.py` (median and p95, `--budgets`). Spans a
person waits on (`tray.fill`, `layout.switch`, `config.reload`,
`hotstring.expand`) use `trace()`/`done()`, which add a paired `[Span]` DEBUG
pair (macOS writes the same tag and names); a key's kernel stamp to its
forwarded write is `input.latency` (`record_age`). Log lines carry real
milliseconds (`logger_sink.timestamp_provider`).

### project-linux-startup-cost-is-compilation

Before the first boot stage the entry's file-scope requires load about 440
modules (6.5 MB of Lua on 2026-11-11, 4.7 MB on 2026-10-24);
`tools/bench/linux-module-graph.lua` measures them, and the boot summary now
reports the process age at `BootProfiler.begin` as `load=` (160 to 210 ms).
Most of that CPU is LuaJIT compiling source (2026-11-11: 126 of about 180 ms;
the same chunks loaded as bytecode with debug info took 8 ms). A real boot
calls none of 128 of those modules before `BootProfiler.complete`, but they
are only 21 ms of compile, some are used at the first key or tray draw on a
desktop, and the largest (the HTTP engine behind `adapters/http_client`,
`unicode_case.data`, `llm.parser`) carry identity or test-seam contracts.
Action: measure with the probe before proposing lazy requires. The lever that
moves the start is the precompiled-bytecode package, decided and implemented on
2026-11-11 (`infra/bytecode_package.lua`, `install/compile_bytecode.lua`,
maintainer-decisions): in an installed tree the load phase went 200 → 90 ms
and spawn to ready 488 → 355 ms (`tests/hardware/run_bytecode_installed_tree.py`).
A dev checkout still compiles from source.

### project-linux-layout-proof-reuses-the-keymap-between-notifications

Each injected press re-proves the layout live (`injector` admission →
`xkb_capture.inverse_current` → `xkb_source_probe.read`). The read used to
download and serialize the whole server keymap every time (48 KB, 0.6 ms on an
idle Xvfb, about 1.1 ms per typed character with the round trips). It now
reuses the text it last downloaded while no XkbNewKeyboardNotify or
XkbMapNotify has been drained on the same connection; the drains before and
after the read synchronize with `XSync`, so a change in between still refuses
the read. Action: any new keymap event kind that can change the keymap bumps
`_keymap_events`; prove changes with `tests/hardware/run_xkb_source_read_cost.lua`
(cost budget and a `setxkbmap` invalidation).

### project-linux-directory-walks-in-process

Hotstring discovery and the log retention purge walk directories through
`infra/native_directory.lua` (libuv opendir/readdir, lstat only without
d_type) with GNU `find -P` semantics kept exactly: pre-order, readdir order,
links reported and never followed, `-maxdepth`, find's path spelling for a
root with trailing slashes. It needs no logger, so the sink can use it. Action:
a new directory walk uses this module instead of forking `find` or `ls`, and
proves itself with a differential against the real find over a fixture.

### project-linux-sqlite-cli-invocation

The Linux SQLite CLI runs with `-init /dev/null` and `-bail`, `-readonly` for
dashboards, an explicit `./` prefix on relative database names, and an
exit-status receipt appended to the stdin script. Scalars are emitted with
`json_quote` and decoded by the shared lossless JSON codec; CR and NUL in SQL
literals go through the shared `sqlite.literal` `char()` concatenation.
Current-schema admission uses a shared deferred `BEGIN`; real writes keep
`BEGIN IMMEDIATE`, and metrics event IDs are acknowledged only after COMMIT.

### project-linux-sqlite-text-nul-traps

SQLite itself, not only the CLI, cuts text at NUL in `json_group_object`
(a merged `{"a\u0000b":1}` came back as a second `"a"` key) and in
`length()`/`substr()`; the CLI's `-json` mode cuts every raw TEXT column.
The Windows walker's `KLW_BucketMergeExpr` hit the same trap through the
vendored `sqlite3.dll`. Rebuild merged maps from `json_quote(key)` with
`group_concat` on every driver, and project
any text that can hold NUL through `json_quote` and decode it in Lua. The
shared `Json.decode_lossless` returns nil for malformed text instead of
raising, so a `pcall` around it validates nothing: test the result's type.

### project-linux-metrics-walk-context

The Linux flush walks each application's buffered events from a per-app walk
context (open word, sequence, correction, burst, session) taken from the last
COMMIT and adopts the new one only on COMMIT, as Windows and macOS carry
theirs. Buffered delays are capped at the pause threshold, so session gaps
come from the keystroke stamps, and `AggregateWalker.settle` credits what a
context holds once its own gap has passed (all of it at a new day or at
shutdown). Action: a new cross-keystroke metric keeps its state in that
context, never in walk locals, or every flush cuts it.

### project-linux-foreign-ledger-import

`ledger_import.lua` never executes a foreign data.sql: it re-renders only
`INSERT OR IGNORE INTO events_*` rows of literals carrying the folder's own
device_id, with columns from the shared schema. The `devices` table CHECKs
`os IN ('darwin','windows','linux')`, and `INSERT OR IGNORE` drops a row that
fails a CHECK without an error, so the following watermark UPDATE then
changes nothing and the device re-imports forever. Action: validate every
value a CHECK guards before an `OR IGNORE` insert whose row a later statement
depends on.

### project-linux-json-store-publication

The Linux JSON store requires an object root, creates its per-process stage
`storage.json.ergopti-<pid>-<start>.tmp` exclusively (a foreign file under that
name blocks the mutation and is never removed; a dead Ergopti process's stage
is reaped at start, CFD-1, `infra/stage_owner.lua`) and publishes backups by no-replace rename on LuaJIT or checked
link and unlink on stock Lua. The updater downloads into the inode reserved by
`os.tmpname`, publishes with no-replace, and reuses its cache on a 304 only
after a completed-response receipt.

### project-linux-process-and-locale-traps

Query `pactl` under the C locale (a translated "oui" or "ja" broke mute
detection). A process name in `/proc/<pid>/stat` sits between the first `(` and
the last `)` and keeps spaces and parentheses, so parse it as bytes; a zombie
(state Z) has exited, and a stat that vanished between listing and read
(ENOENT, ESRCH) is an absent process, never a failed snapshot. `notify-send` and `gtk-launch` get an option terminator before caller
text. On POSIX a backslash is filename data, the working directory comes from
native `getcwd` rather than `$PWD`, and the at-rest key falls back to
`/var/lib/dbus/machine-id`.

### project-linux-gio-hides-pac-failures

GProxyResolverGnome (glib-networking 2.80, libproxy 0.5.4) answers
`direct://` with no error for a PAC it could not download, and libproxy's
answer parser keeps only the `METHOD host` entries of a PAC answer:
`PROXY a; DIRECT` reaches GIO as `a` alone (both PROXY entries of
`PROXY a; PROXY b` survive). So GIO can never stand for a PAC on GNOME: a
caller that walks the list or must tell an unreachable PAC from DIRECT passes
`pac_check_timeout_ms` to `adapters/system_proxy.lua`, and the lookup child
skips GIO, downloads the GSettings `autoconfig-url` itself and evaluates it in
the system Duktape (`platform/network/pac_runtime.lua`, SONAME in
`linux_native_runtime.json` `network_runtime.pac_engine`) with the shared
`pac_helpers.js`. A PAC it could not download answers DIRECT with
`pac_unavailable = "native_pac_download"`; one that raises or breaks a bound is
`proxy-pac-evaluation-failed` (stage `native_pac_evaluation`). The system
engine has no execution-timeout hook: only the child's deadline bounds a
script, so never run it in the daemon. Container proofs of the managed
runtime run as a normal user; the resolver refuses root-owned trees and a
group-writable ancestor unless its group is the user's private group.

### project-linux-ci-runner-prerequisites

Linux fixtures depend on runner details: Dunst 1.9 history has no urgency field;
Ubuntu runners need the PulseAudio gettext catalogs and `xkbcli`; Unix-socket
tests fail under long `/tmp` paths, so use a short `/var/tmp` directory; E2E
must wait for an Openbox round trip after `xrandr --setmonitor` before mapping
owned X11 clients. Debian native compiles need `libc6-dev` (`Scrt1.o`,
`crti.o`); Fedora and Alpine source installs need a compiler, `linux-headers`
and a verified LuaJIT networking provider. Alpine's Lua 5.2 compatibility
`os.execute` returns `true, "exit", 0` and its constants include NaN (compare
identities with `rawequal`). LuaJIT folds the literal `-0.0` to +0 (use
`tonumber("-0.0")`) and allows 60 captured upvalues per function.

### project-linux-minimal-images-ship-few-programs

The distribution lanes run on minimal Arch, Fedora and openSUSE images that hold
coreutils, findutils, grep, sed, bash, sudo and shadow plus what
`.github/linux-install-matrix.json` and `tools/test/prepare-linux-distro-unit.sh`
install (git, a compiler, cmake, curl, python3, luajit). Anything else a driver
file, installer script or test launches passes on Debian and Ubuntu and fails
minutes into the matrix: two tests ran `hostname`, which the driver itself
replaced with `/proc/sys/kernel/hostname` (100e42bc65, 80802ed0dc). The
Unit-stage gate `tools/test/test-linux-portable-commands.cjs` (lot "Distribution
and updates") lexes the Linux tree without comments, inventories every launch
(`io.popen`, `os.execute`, the ShellRunner, ProcessRunner, ProgramRunner,
OwnedProcess and `uv.spawn` calls, Python `subprocess`, every shell script) and
checks each program against one list, `PROGRAMS`, by scope (driver, test, host).
Action: read `/proc` or `/sys` instead of running a program (the process
snapshot of `adapters/process_lifecycle.lua` reads `/proc/<pid>/stat` rather
than forking `ps`, and the local-server scan reads `/proc/<pid>/cmdline`
because Alpine's busybox `pgrep`, first on PATH even with procps-ng installed,
has no `-a` or `-i`); when one is needed, add it to `PROGRAMS` with a proof the
gate checks for every scope it is used in: a file token (installed by the prep
script or a CI job, declared in the package recipes and `install.sh`, or `sh`,
which both container entry points run in every bare image), each bound to the
scopes it covers, or a `command -v`/`has_command` probe in every launching file
of the probed scopes, host scripts included. No entry may rest on its
justification alone, and none is "tolerated". A test's refusal fixture names a
path under a root no system creates (`/nonexistent/...`), which the gate
recognises structurally and refuses in a driver file. A command stored in a table
field, built from a parameter or probed through a loop variable is invisible to
the scan, so probe it by literal name. The gate has no warn-only state: an
unbacked program fails it (`cmp` from diffutils was the first one).

### project-flatpak-sdk-build-flags

The Flatpak SDK build needs explicit commands for the MIT Kerberos build,
`libdir=lib` for glib-networking and libproxy, and an explicit `libm` link for
Duktape.

## Website and documentation

### project-site-i18n-gettext-french-key

The website's gettext source keys are French user-facing strings. Do not replace
them with English developer identifiers without a deliberate catalog migration.

### project-site-kit3-paths-and-images

SvelteKit 3 refuses `$lib` and drops `base` from `$app/paths`. Library imports
go through the `#lib/*` subpath import in package.json; static files go
through `asset('file')` and pages through `resolve('/route')`, both without
a base prefix. Helpers that are executed by tests in a `vm` realm take the
`asset` resolver as a parameter, so a test injects one per base path.
`enhanced:img` sources stay relative to the page and the benchmark image glob
stays rooted at `/src/lib/`. The vite-imagetools cache under
`node_modules/.cache/imagetools` changes the emitted image set between a warm
and a cold build. Action: delete that cache before comparing two builds'
outputs.

### project-svelte-script-comment-closing-tag

The HTML parser can terminate a Svelte `<script>` block on a closing-tag token
inside a comment. Avoid spelling that token literally in script comments.

### project-pages-deploy-branch-vs-workflow

GitHub Pages deployment source can be branch-based or workflow-based. Verify the
repository setting before changing CI; workflow files alone do not prove the
active deployment mode.

### project-deploy-site-runs-on-every-ci-completion

`deploy-site.yml` listens to `workflow_run` completions of CI on main and dev,
and GitHub labels every such run with the default branch (main) whatever the
producer's branch. A failed or cancelled dev push therefore looked like a red
"site deployment on main" at the admission step ("event must be a completed
successful push"), while the real main deployment had succeeded. The receiver
job now runs only for a manual dispatch or a successful push producer; the
admission script still refuses anything else. Action: before debugging a red
deploy, read the triggering CI run (`gh run list --workflow CI`), not the label.

### project-xkb-extensions-dir-is-the-clean-install-contract

Since libxkbcommon 1.13 + xkeyboard-config 2.45, layout packages install under
`/usr/share/xkeyboard-config.d/<package>/{symbols,types,rules}` and compose
rules through a `<ruleset>.post` file - never by patching the system
`rules/evdev`. The Ergopti clean installer relies on this contract; the sandbox
tests override the roots via `ERGOPTI_XKB_*` env vars. Two limits measured on
libxkbcommon 1.13.1: an unindexed `! layout = types` rule only matches
single-layout configurations, so the `.post` fragment must also carry
`layout[1]`..`layout[4]` or the custom type vanishes as soon as GNOME/KDE
compile a second input source (dead Shift/AltGr, issue #84); and only
libxkbcommon reads extensions directories, Xorg's `xkbcomp` never does, so the
detector routes X11 and unknown sessions to the legacy method. The repository
does not ship a separate AUR `PKGBUILD`: the former handwritten recipe
referenced an absent tag and hook and drifted from the canonical package
builder. Action: any new install target must reuse/generate from the canonical
builder, pass a real package build in CI, keep the extensions-dir contract, and
prove the type with `xkbcli compile-keymap` for `ergopti`, `ergopti,us` and
`us,ergopti`; never reintroduce an X11 symlink bridge, which cannot carry the
types rule.

### project-french-xkb-variant-must-preserve-the-system-default

A variant registered under `ergopti` is not offered by input-method pickers
that enumerate variants of `fr` (issue #84). Publishing `fr(ergopti)` requires
both an extension `symbols/fr` section and variant-specific types rules in
every group. A file containing only that section can also capture plain `fr`
when the system file has no explicit default: measured on libxkbcommon 1.13.1,
the original French keymap became Ergopti. Action: delegate the extension's
explicit default to `%S/fr`, keep other named sections resolving through the
system search path, and compare plain French, OSS and Bépo before/after install
with the real compiler. Register the variant under `fr` in libxkbregistry too;
successful compilation alone does not establish picker discoverability.

### project-legacy-xkb-types-go-inside-the-section

The legacy installer edits `types/extra`, a single
`default partial xkb_types "default" { ... };` section that `complete`
includes. A `type` block appended after the closing `};` is a syntax error:
Xorg's `xkbcomp` rejects the whole `complete` file and libxkbcommon drops the
block with no diagnostic, so "it compiles" proves nothing. Action: insert
through `insert_type_sections()` (inside the last section), then require the
type name in the compiled keymap; roll every backed-up file back otherwise.

### project-gsettings-input-sources-must-be-merged-not-set

GNOME stores the user's keyboard list in `org.gnome.desktop.input-sources
sources`; writing a single-entry list silently deletes the user's other
keyboards (reported as "my old layout disappeared"). The installer reads,
merges with the new layout first, writes, then reads the value back: dconf
reports success even when a root process wrote into root's own database.
gnome-shell activates `mru-sources[0]` at login, not `sources[0]`, so the
most-recently-used list is aligned as well. Plasma keeps `LayoutList` and
`VariantList` index-aligned and ignores both unless `Use=true`; the legacy
layout is `fr` + `Ergopti_<version>` there, never GNOME's `fr+variant`.
Action: reuse `merge_gsettings_source()` / `merge_layout_specs()` from
`layout_package.py`, run activation as the desktop user, and never hand-write
a sources value.

### project-gnome-runtime-layout-switch-goes-through-the-shell-extension

A running GNOME Shell (checked on 46) keeps its input sources in memory: it
ignores runtime writes of `current` and `mru-sources`, and a `sources` change
makes it activate its first entry, so no gsettings sequence switches it
reliably. The daemon therefore asks the `focus@ergopti.fr` extension
(`org.ergopti.InputSource1.Activate` at `/org/ergopti/InputSource` on
`org.gnome.Shell`), which calls the source's `activate(true)` as the Shell's
own switcher does. A GDBus `UnknownMethod`/`UnknownObject` answer means the
extension is not running (Flatpak, turned off, or an updated copy not loaded
before the next login): report `gnome_extension_missing`, never fall back to
rewriting `sources`. The installer (`desktop_activation.gnome_extension_activate`)
uses the same call; the Shell lists a written source in its own time, so poll
until it does, and an id its registry does not know is never listed (no "us"
fallback). Action: keep the extension's constants pinned to
`input_source_switch.lua` and `desktop_activation.py` by their tests, and prove
a change with `tests/hardware/run_input_sources_live.sh gnome` (and the
`run_user_layout_wayland_live.lua` script) and `gnome-no-extension`, as an
unprivileged user (the installer refuses root; needs gnome-shell,
python3-dbusmock, xwayland and a world-writable `/tmp/.X11-unix`).

### project-a-keymap-that-compiles-can-still-have-dead-layers

libxkbcommon and xkbcomp both accept a symbols file whose key type is
unknown: the key silently falls back to `ONE_LEVEL` (`type= "ONE_LEVEL"` on
`<AD01>` in the dump), which users experience as a dead Shift key (issue #84).
The dumps spell groups and levels differently (`type[1]=`, `map[Shift]= 3`
for libxkbcommon; `type[Group1]=`, `map[Shift]= Level3` for xkbcomp) and
neither compiler logs the fallback at warning level. Action: never accept
"it compiles" as proof; require the probe key to be bound to the custom type
in the group carrying Ergopti and the type to map/preserve Control
(`inspect_keymap()` in `desktop_activation.py`), print the compiler command
and diagnostics on failure, and make a failed verification a non-zero exit.

### project-linux-a-live-layout-is-proven-by-its-cells

A live layout replacement is acknowledged only from the keymap read back from
the session (`xkbcomp -xkb $DISPLAY -`: the X server, or XWayland, which
receives the compositor's keymap), compared key by key with the same
description compiled offline. The layout's name proves nothing: a desktop that
puts back an older same-named build keeps it (`stale_keymap`). A compositor
recompiles only when the selected id changes, so Wayland builds alternate
between `<id>` and `<id>_live`; never rewrite the selected slot and expect a
reload. The layout scope settles from that answer, which arrives after a child
process, so `infra/global_scope.lua` is asynchronous: never reintroduce the
"every participant settles synchronously" assertion.

### project-linux-install-is-proven-by-the-distribution-matrix

The maintainer has no Linux host: `linux-layout.yml` runs
`tests/e2e_distro.sh` in a container per distribution (old and new
libxkbcommon, glibc and musl, sudo and doas, Python 3.6 to 3.14) with the
distribution's own compilers, from an unprivileged user through the documented
piped command, and requires the system tree to be byte-for-byte pristine
after uninstall. The Arch entry replays the host of issue #84 (fish, wlroots
compositor, generation-2 leftovers) and a GNOME session on a private D-Bus bus
with a real dconf. Action: any installer change lands with a green matrix; a
new distribution family is added as a matrix entry, not as a manual checklist.

### project-linux-daemon-is-proven-live-through-a-real-kernel

`tests/hardware/run_daemon_live.sh` (CI step in `test-linux`) starts the real
daemon with `--tray` on a uinput keyboard, types "adn " and decodes what the
daemon's own virtual keyboard sends, while `sni_host.py` reads the tray menu.
It found three bugs that no recorder-based test could: every tray row's
`ffi.cast` callback leaked (LuaJIT never frees them, so the daemon crashed
with "too many callbacks"; one process-wide dispatcher now routes by id), a
100k-row menu that took seconds to build, and the expansion's replayed
terminator dropped because its key-down was still held on the virtual
keyboard (the kernel ignores a key-down for a key already down). Action:
inject through `injector.run_transaction`, which releases
`keyboard_hook.held_forwarded_keys()` first; never add a per-item FFI
callback; keep this live step green for any hook, injector or tray change.

### project-linux-tray-dialogs-and-windows-cross-the-grab-and-json

Two boundaries silently broke every tray UI on Linux while unit tests stayed
green. (1) A native dialog runs inside a menu callback and blocks the event
loop that forwards the grabbed keyboard, so nothing could be typed into it:
every blocking dialog must go through `ui/modal.lua`
(`keyboard_hook.while_released`). The dialog is Ergopti's own GTK 3 child
process (`ui/dialog_host.lua`, LuaJIT FFI, started by `ui/native_dialog.lua`
with the daemon's interpreter), never zenity or kdialog: its command line is
the zenity subset the sites wrote, exit 0 accepted, 1 cancelled, 69 no display
or no GTK 3 (never read as a No). It stays a separate process so the modal
release keeps owning the keyboard; `tools/test/test-linux-native-dialog-titles.py`
drives it live on Xvfb. (2) The webview manager decoded page
messages and encoded replies through `dkjson`, which is never installed: all
page objects arrived as nil. It uses the shared `json` codec now; bridge tests
that pass Lua tables to `route_message` cannot catch this, so
`tests/hardware/run_webview_roundtrip.lua` lets a real page post its own
request. Action: never add an optional JSON dependency or a dialog outside
`Modal.run`; a new window needs a round-trip check, not only a bridge test.

### project-linux-ai-is-proven-against-real-servers

The AI path is exercised end to end in CI: `run_daemon_live` accepts a
prediction from `fake_llm_server.py` (OpenAI dialect, as Cerebras) with a
bare 1 (the default chord since 2026-09-24; Alt+1 once the AI menu requires
Alt) through the real kernel, and `run_ollama_live.lua` drives the real Ollama
(model list, `/api/pull`, predictions, and the remote backend on Ollama's
`/v1` endpoint). They caught what scripted tests could not: text typed while
the accepting Alt was still held (every injection now releases Ctrl/Alt/Super
after an F24 mask tap, never restoring them), a double space from the parser
spacing against the word-rebuilt tail, and curl argv exposing keys and typed
text (headers, body and URL now go through `--config -`). Remote API keys
live in `~/.config/ergopti/api_keys.json` (`config_paths.default_config_dir()`),
mode 0600, outside a picked, possibly-synced config folder. Action: keep both live steps green for any
change to the injector, the engine, the parser or the HTTP client.

### project-xcompose-sequences-name-the-keysym-the-key-sends

Inside a dead-key state a key sends what it sends from the neutral state: a
dead key its dead keysym, any other key the keysym of what it types. Both
converters (`keylayout_to_xkb.py` and its Lua twin `layouts/xkb_converter.lua`,
`state_keysyms`) end each Compose sequence with those keysyms. Naming the
character the action is called after instead (the historical rule) made Ergopti's
`^ ^` and `^ ¨` untypable and gave Bépo's chained dead keys 62 untypable outputs
and 6 conflicting sequences (a plain `^` and the circumflex dead key sharing
`<asciicircum>`). The base keysym stays first when a key sends it, so every other
line of the shipped Ergopti files is unchanged; the Ergopti+ magic key
(`base_level_only`) also ends its action's sequences on the keysym its base
level sends (★), so ^ then ★ types j as on macOS. A text keysym with no
`<when>` in a state gets an explicit fallback line typing the terminator then
its text (macOS semantics), since native Compose would cancel; an explicit
`<when>`, even typing nothing, and a chained-dead-key prefix get none.
Action: pin a new dead-key shape with a vector in
`_shared/tests/corpus/keylayout/xkb_conversion_vectors.json` (both converters
replay it) and keep `test_registry_conversion.py`'s written-keysym check green.

## Release artifacts

### project-release-notes-are-not-joined-to-the-assets

Release notes and uploaded binaries are separate publication steps. Verify the
tag, notes, and every expected asset explicitly.

### project-packages-name-their-commit-through-a-build-stamp

An installed package has no .git, so `git rev-parse` or a HEAD read reports
"unknown" in every release. macOS and Linux package builds write
`_shared/build_stamp.txt` (`commit=<sha>`) through
`tools/build/write_build_stamp.sh` (the Linux packagers `verify` their copy);
Windows stamps `BUNDLE_COMMIT` in `infra/bundle.ahk`. Every diagnostic surface
resolves the commit through one resolver per driver
(`diagnostic_snapshot.resolve_commit` / `DiagSnapshot_ResolveCommit`): stamp,
then checkout, then a logged "unknown". Relatedly, macOS `hs.configdir` is the
script directory (inside the app bundle when packaged), never the configuration
directory; report `config_paths.get_config_dir()` for the latter. Action: a new
package format or diagnostic field goes through these owners, and
`test-package-builds-stamp-commit.cjs` must stay green.

### project-appimage-is-built-on-the-oldest-lts

The AppImage bundles LuaJIT, curl, luv and their ELF closure but uses the
recipient's glibc, and appimage.github.io tests it on the oldest Ubuntu LTS in
standard support (22.04, glibc 2.35) under firejail with no network. v1.0.1,
built on ubuntu-latest, needed GLIBC*2.38 and died before its tray appeared.
`tools/build/appimage-oldest-lts.sh` now builds it (and the archive backend
every package carries) in an `ubuntu:22.04` container, and
`check-elf-glibc-ceiling.cjs` refuses any GLIBC* need above 2.35. GLib, the
C++ runtime and libgcc are left to the recipient: the tray loads the host GTK
into the daemon, and an older bundled GLib shadowing it through
`LD_LIBRARY_PATH` breaks every host library built against GLib >= 2.80. The
launch environment reaches every host program the daemon starts, so it names no
library directory: `LD_LIBRARY_PATH` put the staged libssl, libcurl, libtinfo and
readline in front of the host's (readline 8.1 killed bash 5.3 on Arch,
`undefined symbol: rl_trim_arg_from_keyseq`, before the daemon started). Every
staged program and library carries its own `$ORIGIN` RUNPATH instead
(`set_private_runpaths`, patchelf, on every host that runs the stager), which a
`ffi.load` by soname from LuaJIT searches too. A RUNPATH is not transitive, so a
file staged after that pass finds nothing. A library only one owned program
needs goes in `SQLITE3_ONLY_LIBRARIES`' `lib/sqlite3`. The asset is `ErgoptiPlus-x86_64.AppImage` (the catalogue rejects "linux" in
the name); installed AppImages never self-update, so a rename breaks no updater.
Action: keep the build in that container until the catalogue's LTS moves, then
raise `GLIBC_CEILING` and the image together.

GLib's own dependencies are not bundled either: `ldd` lists a whole closure,
so libmount, libblkid, libselinux, libffi, libpcre and libz reached through
libgio were staged with every seed, and on Ubuntu 26.04 the bundled 22.04
libmount made the host libgio fail (`MOUNT_2_40`) and the tray with it.
`recipient_dependencies` in the stager now leaves that closure to the host.
Action: never bundle what the host GLib loads itself. curl's brotli and zstd
are still bundled and are the first suspects if a host library misses a symbol.

glibc itself is not bundled: the daemon loads the host GTK, which needs the
host's own glibc, so a bundled loader would have to be newer than every host
library. Below the ceiling and on musl, AppRun (plain `/bin/sh`, since Alpine
has no bash) sources `libc-preflight.sh`, rendered by
`render-appimage-libc-preflight.cjs` from `GLIBC_CEILING` and the
`startup.linux_appimage_*` locale keys, which refuses in words with exit 69
(`getconf GNU_LIBC_VERSION` answers only on glibc). Action: never put a bash
construct before that `.` line.
`check-elf-glibc-ceiling.cjs` also refuses an executable that requests a program loader other
than `/lib64/ld-linux-x86-64.so.2` (a musl or Nix build) and any staged copy of libc, its
loader or `libnss_*` (names from the glibc group of `linux_appimage_recipient_libraries.json`).
musl hosts cannot run the image; only the CI install rows prove the distro matrix.
`tools/build/appimage-distro-sweep.sh <AppImage>` replays the musl refusal,
the old-glibc refusal and the desktop launch per distribution image. Action:
run it on every change to AppRun, the stager or the build image.
The AppImage deliberately does not bundle glibc or its loader (they must agree with the
host's GTK, GL and NSS modules): it is built on the oldest supported LTS and
`check-elf-needed-closure.cjs` refuses any ELF `NEEDED` entry that is neither in the image
nor on `_shared/updater/data/linux_appimage_recipient_libraries.json`. Action: a library the build
host links by accident is staged, or listed there with a reason, never ignored.

The catalogue's runner has GTK 3 but no libayatana, no StatusNotifier host and
no keyboard; its tray retry docks XEmbed icons into stalonetray. v1.0.3 held its
"keyboard access unavailable" tray correctly but exited because the tray
library was missing. The image therefore bundles libayatana-appindicator3 and
its non-GTK libraries (`TRAY_LIBRARIES` in `stage-linux-network-runtime.py`);
without a watcher the library falls back to an XEmbed GtkStatusIcon. The smoke
replays that check on a host without libayatana. Its tray pass left-clicks the
icon (libayatana's GtkStatusIcon fallback pops the menu on both buttons), then
right-clicks the same spot, which closes the grabbed override-redirect menu
before the screenshot; only a named visible window survives into it, so the
no-keyboard state opens an "Ergopti+" status window (`infra/input_access.lua`).
Action: read the catalogue's
full log (`gh run view <id> --repo AppImage/appimage.github.io --log`) before
trusting its "first error", which is only the first stderr line.

### project-linux-xkb-installer-runs-on-ergopti-python

The user XKB installer (`ergopti/linux/xkb_installation/user_layout_installer.py`)
runs on Ergopti's own Python, never the host's python3 (maintainer decision, 1
November): the python-build-standalone build of the shared managed Python
release, pinned by SHA-256 and size per machine and C library in
`_shared/core/network/data/linux_native_runtime.json` `managed_python` (the codegen refuses a
version, build or uv release that differs from
`_shared/ai/data/managed_python_release.json`). `modules/keymap/managed_python.lua`
asks once (owned dialog), downloads through the managed HTTP client, checks size
and digest, unpacks into `<root>.staging` and renames it into the versioned
folder under `ConfigPaths.data()/runtime/python/`, so a versioned folder only ever
holds a verified interpreter. A declined or failed download reports
`python_missing` with the reason. Action: a new Python consumer asks the layout
registry's `python` dependency; a probe that is not about Python injects it
(`run_layout_rows_live.lua`) instead of opening the consent dialog;
`tests/hardware/run_managed_python_live.lua` is the network proof.

### project-arch-recipe-repacks-the-release-tarball

`tools/build/PKGBUILD` is a template, not a from-source recipe (maintainer
decision, 1 November): it repacks the release tarball, which already carries
the private runtime in `linux/runtime`, pinned by the tarball's SHA-256.
`tools/build/render-arch-pkgbuild.cjs` fills the version (from the tarball's
build stamp, hyphen dropped so a prerelease sorts first in pacman), the tag and
the checksum; the Linux Build job renders it beside the tarball, Release
attaches `PKGBUILD` and `ergopti.install`, and the `smoke-arch-package` row
builds it with `makepkg` on Arch and installs it with pacman, which also proves
the declared dependency names. The tarball carries no build scripts, so the
recipe checks the stamp's commit line itself. Action: never build the pinned
sources in makepkg; a runtime change reaches Arch through the tarball.

### project-the-drift-guard-crashes-on-this-windows-box

When a cross-platform drift tool fails on Windows path/process semantics, use
the repository's supported wrapper and preserve the failure as a test fixture;
do not silently skip the guard.

### project-ci-deferrals-are-dated-exceptions

Every release-qualification deferral is a closed, dated, source-bound exception
file in `.github/ci/` (for example
`stable_v103_macos_native_qualification_exception.json` with
`STABLE_V103_SCOPE_IDS` in `tools/ci/dev-release-qualification.cjs`). A deferred
scope shows DEFERRED with `qualified: false` and never counts as a pass; expired
exceptions are not renewed without the maintainer. A deferred suite envelope
stands in only for the matrix rows that `deferrable_shards` of
`.github/linux-ci-coverage.json` lists, and only for that row's own
`shard_subjects`: the distribution rows of the Unit stage (every module group
but `integration`) and of the Integration stage (that group alone), which share
one container, one runner (`run-linux-distro-unit.sh <distro> unit|integration`)
and one log diagnostic (`tools/test/linux_distro_suite_diagnostic.py`), have no
receipt to defer them (and their containers have no Node): they always run and
record their own count, so a missing, duplicate or deferred distribution receipt
fails `linux-ok`. `linux-install-matrix.cjs` refuses a coverage manifest whose
Unit or Integration rows miss an archive distribution or defer one. Unsigned stable Windows
releases are a standing authorisation (`stable_windows_signing_exception.json`)
until SignPath signing is integrated.

### project-site-cname-is-a-tracked-file

The ergopti.fr custom domain lives in `static/CNAME` and is verified before each
Pages deployment, because a deployed artifact without it would drop the custom
domain.

### project-linux-owned-ollama-gets-the-desktop-proxy-as-https-proxy

The Ollama daemon Ergopti starts cannot evaluate a PAC, so a pull behind a
PAC-only network failed. `modules/llm/managed_ollama_proxy.lua` runs a stage in
the shared runtime repair before the daemon starts: the shared proxy policy
routes the registry URL, and only a `system` route calls the owned GIO lookup
(`adapters/system_proxy.lua`); the first usable selection becomes `HTTPS_PROXY`
of the daemon. A proxy the user exported wins over the PAC (the proxy override
wins over both); DIRECT and a
machine without a desktop proxy add nothing. A GIO lookup that fails or times
out (an unusable PAC: GIO names no finer step) sends that origin direct with one
WARNING naming `native_proxy_lookup` or `native_proxy_budget`, stages the shared
policy's `falls_back_direct` admits from `pac_unavailable_fallback`; a failure of
Ergopti's own helper child still refuses the start (`runtime_proxy_unavailable`).
Ollama has no failover, so the PAC list is walked before the start like a
browser does: a relay followed by another entry is kept only when a TCP connect
completes within `llm.managed_proxy_probe_timeout_ms` (1 s,
`adapters/tcp_probe.lua`), else the next entry is tried; the last entry is kept
unprobed. Action: give any new environment-driven client the same walk rather
than its first PAC entry.

### project-linux-ollama-runs-on-the-owned-port-only

Ergopti's Linux Ollama listens on `llm_ollama_owned_port` (11435), mirrored as
`infra/llm_bridge.lua` `OLLAMA_OWNED_PORT` and pinned to `defaults.json` by
`tools/test/test-linux-llm-defaults-single-source.cjs`. The engine origin feeds
the repair's serve address (`OLLAMA_HOST`) and its `/api/version` readiness
probe, so an origin on the stock port 11434 adopted a user's own daemon there;
`resolve_base_url` therefore refuses the stock port and `profiles.init` refuses
it as an override. The binary is only the per-user pinned runtime of
`ollama_install_resolver`, and a PATH `ollama` never makes the model page treat
Ollama as available. Linux has no saved port setting, so no key migrates. Never
point a test at 11434 to stand for Ergopti's own daemon:
`test_owned_ollama_coexistence.lua` holds a fake system daemon there.

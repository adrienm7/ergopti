# Linux recovery scenarios received in a real standalone installation (2026-11-11)

Proof for the TODO.md line **[PHYS-L]** of "Migration and update parity
follow-up" (the [recovery audit](../../platform-parity/2026-11-04-recovery/report.md),
`linux-updater` scope), under the maintainer decision of 2026-11-10
(`docs/memory/maintainer-decisions.md`: a container proof closes a Linux
check). Every file beside this one is a receipt the run printed.

## Environment

- The cloud sandbox kernel has no uinput, no KVM and no systemd PID 1, so the
  run used `tests/hardware/run_phys_vm.sh`: an Ubuntu 24.04 cloud VM under QEMU
  (TCG, an emulated CPU about 20 times slower than the host), kernel
  6.8.0-147-generic, systemd 255 as PID 1.
- The real `install.sh` ran as an unprivileged sudoer whose user manager was
  reachable (lingering), with the distribution's own packages: it enabled and
  started `ergopti-hotstrings.service`. The user manager then restarted, as a
  new login does, so the input groups install.sh granted applied.
- Xvfb and a uinput keyboard stand in for the desktop and the hardware. The
  unit's only change is a drop-in pinning `--device` to that keyboard, because
  the finder rightly skips uinput sources as synthetic.
- Input latency is measured on the daemon's own output keyboard: each key typed
  on the grabbed source is timed until the daemon re-emits it.

## How to run again

- On a host without uinput or systemd: `bash tests/hardware/run_phys_vm.sh <receipts>`
  from `static/ergopti_plus/linux` (needs qemu-system-x86_64, qemu-img,
  cloud-localds, ssh; the first install takes about 25 minutes under TCG).
- On a host with both (a GitHub-hosted Ubuntu runner): `sudo bash tests/hardware/phys_live_guest.sh`
  with the checkout subset at `$ERGOPTI_SRC`.
- `luajit tests/hardware/run_webkit_gc_signal.lua [--unreserved]` under any X
  server with lgi and WebKitGTK 4.1 (also in CI, desktop-webview shard).

## Results

| Scenario                                  | Receipt                                                    | Outcome                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| systemd restart and successor observation | `summary.txt` (systemd restart), `systemd-reload.txt`      | The reload tool read `completed`; the real user manager stopped and started the unit; a new MainPID inside the unit completed the request itself; the replaced daemon was gone; 40/40 keys flowed through the successor (p90 98 ms).                                                                                                                                                                                      |
| owned smoke deadline, responsive loop     | `smoke-deadline.log`, `summary.txt` (owned smoke deadline) | The installed async installer, against the installed root, with a candidate whose `--help` never returns: one callback after the deadline, "smoke failed; previous installation restored", the hung group gone, the tree byte-for-byte unchanged, no staging left. Its loop never stalled more than 226 ms during the smoke; the daemon re-emitted 300/300 keys meanwhile (p90 63 ms) and restarted on the restored tree. |
| relay restart and successor observation   | `summary.txt` (relay restart), `relay-reload.txt`          | A daemon started outside the unit took the detached relay; the first process was gone, the successor (outside the unit, the unit inactive) completed the request; 40/40 keys flowed through it.                                                                                                                                                                                                                           |
| reload with a WebView open                | `webkit_gc_signal.txt`                                     | Without the reservation, SIGUSR1 kills the WebView host (exit 139); with it, all three reach the daemon's callback and WebKit's collector holds signal 12.                                                                                                                                                                                                                                                                |

## Defects found and fixed

- **The ownership owner ran synchronously on the event loop** (85093f81): the
  async installer still ran the previous tree's `install/ownership.sh` through
  `os.execute`, 9 s natively on a real installed tree with the keyboard
  grabbed, and checked the deadline only afterwards (175 s against a 30 s
  budget in this VM). It now runs as an owned, deadline-admitted child, as the
  smoke does.
- **A reload request crashed a daemon with a WebView open** (44b2e10f):
  WebKitGTK's JavaScriptCore took SIGUSR1, the reload signal, for its
  collector; the first-run onboarding window was enough. Under systemd
  `Restart=on-failure` masked it (journal: `status=11/SEGV`, then a restart);
  outside systemd the daemon died. The daemon now sets `JSC_SIGNAL_FOR_GC=12`
  before anything loads WebKit.

## Reinstall over an older tree (fixed, eb443380)

A reinstall kept the files the older version shipped and the new one does not
(`install.sh` extracted over the tree), so the reinstalled tree failed
`Ownership.verify` against its own receipt (4 leftover files seen by
`phys_smoke_deadline.lua` on a reinstalled tree), and once it became
`<root>.old` the next update could not retire it. The installer now removes
each file the previous receipt owned and the new one does not, when its bytes
still match. `tests/hardware/phys_reinstall_guest.sh` (after
`phys_live_guest.sh`, same VM): `reinstall-summary.txt`, 6/6 checks, the
dropped file gone, the tree and a `<root>.old` copy both verified.

## Real-desktop receipts that ran nowhere before (7c29e091)

Run on Ubuntu 24.04 under Xvfb with at-spi2-core and GTK 3 (`python3.12` here,
whose GObject bindings match), and now in the desktop-webview CI shard:

| Harness                                      | Receipt                   | Outcome                                                                                                                                                     |
| -------------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tests/hardware/run_clipboard_owner.lua x11` | `clipboard_owner_x11.txt` | Text, HTML and a 300 kB binary target (INCR) served by the clipboard owner and read back byte for byte through xclip.                                       |
| `tests/hardware/run_llm_selection_focus.py`  | `llm_selection_focus.txt` | 31 AI text-destination cases on real GTK/AT-SPI with XTest output: correct controls receive the text; changed fields, changed windows and passwords refuse. |
| `tests/hardware/run_secure_focus_watch.py`   | `secure_focus_watch.txt`  | The resident privacy owner on owned GTK fields: ordinary, password and role-changing fields, source freshness and native cleanup.                           |

## Limits

- The install is driven by a tar-backed archive factory, not the authenticated
  download chain (`archive_transfer`), and not from the update window; the
  budget is calibrated from a timed ownership run on this CPU, not the
  production 180 s.
- The synchronous rollback verification after the deadline still holds the
  installer loop (`Ownership.verify`, about 0.25 s per call natively, 11.7 s
  under TCG); reported as `rollback_max_gap_ms`, not asserted.
- No physical keyboard, Wayland compositor or desktop panel is involved.

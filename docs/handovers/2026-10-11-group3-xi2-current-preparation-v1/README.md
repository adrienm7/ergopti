<!-- docs/handovers/2026-10-11-group3-xi2-current-preparation-v1/README.md -->

# Group 3: current Xi preparation and bounded receiving

This new sibling retains the private candidate on source
`c15a16cc9eee103b4132bcaf811ed890834f894c` plus **15 exact postimages**.
The patch is not adopted. Initial fix/Linux custody and actual current-tree
preimage receiving remain pending. Later Dev `acec284ec` is coordination
context supplied by the parent; it is not the native qualification epoch.
The older [348-member/14-path handover](../2026-10-11-group3-xi2-preparation/README.md)
remains byte-exact at its original `2c144060853239c9c416ea1a9c08030382ed2b1f` epoch.

Recover the exact current patch from
`evidence/current-c15/current-c15-fifteen-path.patch.txt` after checking the
transport and every member against `evidence-manifest.json`. Its SHA256 is
`8f5193cbda5ef1248988433b9b565f504b2c5fd3fa1cce774ca093e364a34308`.
The mandatory fifteenth path is `tools/test/fixtures/validation-curl/PINS.json`:
its `command_owner_sha256` must join the changed
`tools/build/stage-linux-network-runtime.py` source hash
`261a8202a99ddb80cc54595d846467eac4eaa3b91eefbba7186571e5709bd1e5`.
The old 14-path cut omits this source-identity join. It cannot substitute for
this candidate or its original receiving epoch.

The original selected V2 run is retained with its command, plan, terminal
receipt, gate results and complete raw log: **14 gates pass, two fail, exit 1**.
Linux units pass **13,102/0** across 520 modules. The failed gates are the
original window-family `/proc` prerequisite and real Nix CLI/store
prerequisite. Later builder/help passes do not turn this selected run green.
The raw log SHA256 is
`472c6e8415ea75437cbbc43087f7fa66571f2c581ae1e4cb1db92eaa3dd8c40d`.

Separate actual driver assembly, including its smoke checks, and AppDir
assembly with `--skip-appimage` each return 0 on the same c15+15 sources.
The full recorded census covers 4,774 current regular files; the previous
owned-output census covers 2,355. The independent read-only review receives
both censuses and archive hashes. Mutable payload archives and development
binaries are excluded from this handover; censuses cannot reconstruct them.
The staged `libXi.so.6` bytes match the original system `libXi.so.6.1.0` ELF,
SHA256 `8ca60a4e6a90bba494e601e03e792b2d440cced9985deca64431abbd78613adb`.
This establishes byte staging, not loader resolution, required exports,
XI execution or installed-package receiving.

Both actual staged `AppRun --help` and `usr/bin/ergopti --help` return 0,
with identical output and empty stderr. The original helper removes its named
Lua/LD/GIO/compiler-metadata overrides and inherits the recipient HOME;
there is no separate live-environment recorder. Actual help output reports
missing `lgi` and `GTK available: false`. CLI help therefore does not qualify
GTK, tray, desktop or X11/Wayland application startup. The helpers use an
ordinary validation subreaper without an explicit subprocess timeout;
full native child-family retirement and a hard deadline remain unqualified.

The archive retains exactly 30 finite inert `.txt` members, totaling 3,513,483
uncompressed source bytes: the original recovery capsule's five exact subjects,
its manifest, original selected command/plan/exit, bounded builder/help
receipts and raw outputs, both full censuses, and four independent-review
records. No payload archive or development binary is included. All members
are regular files with deterministic metadata. Regenerate or verify using
only the existing [owning generator](../2026-10-10-group3-continuation/generate_capsule.py),
passing the manifest and archive, plus `--evidence-root` after extraction.
Existing retained bytes must remain exact; do not execute retained helpers
into immutable receiving directories. Coordinate current custodians and check
actual target preimages before any product adoption.

AppImage creation/mount, package installation, other distributions and GUI
delivery remain unqualified. This preparation grants no original input epoch,
modifier/output custody, public simultaneous capability or physical delivery.
Item 93 and all existing transverse requirements stay open.

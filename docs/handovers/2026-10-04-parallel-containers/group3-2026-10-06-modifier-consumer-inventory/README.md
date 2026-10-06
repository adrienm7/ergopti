<!-- docs/handovers/2026-10-04-parallel-containers/group3-2026-10-06-modifier-consumer-inventory/README.md -->

# Inactive modifier-consumer inventory

This selection preserves the producer's nine frozen portable files (433,327 bytes) and two bounded independent-review receipts under `.txt`. Producer receipt: `e22aafd8169ed11844417daf610cdadfc1b2f7de2fdc19e4b020a500031217a9`. The collector changed no Root source, Git index or branch. Importing and committing these inert files changes Git state without admitting a product repair or native availability.

Independent review is CLEAR for this inventory only (`be41b528`); it does not accept a production repair. The original `facts.json.txt` retains its earlier review-requested status unchanged. The inventory is **partially red**. Both Lua ABIs recorded 17 PASS / 8 FAIL, including the unchanged original 14-case watchdog prefix and its previously failing overlap control. Seven additional failures identify remaining consumer defects, including an actual controlled TapHold ownership transfer that leaves a physical Shift release classified as an orphan. The tests use actual Hook/Injector/ComboEmitter/TapHold and reviewed Reader/Writer software with explicitly controlled syscall, layout, clock and event-loop providers. They allocate no kernel input/uinput descriptor, display, native command or libuv handle. Physical delivery remains false. Kernel and hardware validation were not run.

| Selection                          | Recorded per ABI         | Meaning                                               |
| ---------------------------------- | ------------------------ | ----------------------------------------------------- |
| Current consumers                  | 17 PASS / 8 FAIL, exit 1 | Diagnostic failures, not a feature completion.        |
| Skip-only-UP counterfactual        | 19 PASS / 6 FAIL, exit 1 | Repairing the old overlap alone leaves other defects. |
| Weakened temporary restoration     | 16 PASS / 9 FAIL, exit 1 | Weakening Writer receipts creates another regression. |
| Actual legacy TapHold module       | 26 PASS / 0 FAIL, exit 0 | Existing reentrant retirement behavior must remain.   |
| Indiscriminate reentry prohibition | 25 PASS / 1 FAIL, exit 1 | A blanket busy guard breaks the existing contract.    |

`frozen/README.md.txt` contains the producer's coherent broker design and limitations. No broker implementation is supplied. The existing 17-packet inactive handoff is an external dependency and is not duplicated. The producer's sibling snapshot, counterfactual source copies, runtime binaries and raw logs are excluded. Evidence digests and the closed recorded results remain in the frozen JSON artifacts.

## Verify this selection

From this directory:

```sh
sha256sum -c files.sha256
python3 verify_selection.py --manifest manifest.json
```

These are byte/status checks only. They do not execute the consumer controls or qualify native behavior. The original frozen JSON, Lua, Python and documentation must never be formatted or edited; only the normal wrapper files are formatter-owned.

## Reconstruct a private replay

Replaying is an explicit diagnostic action. Use a separate, new directory outside every repository checkout, prepared native Linux LuaJIT and Lua 5.4, Python 3, and the normal interpreter library environment. Read the frozen runner before execution. Its event-loop/syscall/layout ports are controlled; no native qualification follows from success.

Set `REPOSITORY` to the source checkout with the committed 17-packet handoff, `SELECTION` to this imported directory, `HARNESS_COPY` to a new private directory, and `REPLAY_DIRECTORY` to another new private directory. Materialize only the nine byte-checked files:

```sh
python3 - "$SELECTION" "$HARNESS_COPY" "$REPOSITORY" <<'PY'
from pathlib import Path
import hashlib
import json
import sys

selection = Path(sys.argv[1]).resolve()
private = Path(sys.argv[2]).resolve()
repository = Path(sys.argv[3]).resolve()
if private == repository or repository in private.parents:
    raise SystemExit("Private harness must be outside the repository")
manifest = json.loads((selection / "manifest.json").read_text())
private.mkdir(parents=True, exist_ok=False)
for row in manifest["files"]:
    if row["role"] != "producer_input":
        continue
    data = (selection / row["portable_path"]).read_bytes()
    if hashlib.sha256(data).hexdigest() != row["sha256"]:
        raise SystemExit("Frozen artifact differs")
    (private / row["original_name"]).write_bytes(data)
PY
python3 "$HARNESS_COPY/replay.py" "$REPOSITORY" "$REPLAY_DIRECTORY" "$LUAJIT_PATH" "$LUA54_PATH"
```

Run the selection verifier first. Keep the four directory/path variables distinct, and do not set them to a production configuration or an existing replay directory. The materialized `replay.py` refuses an existing work directory or one inside the repository. It checks all 1,904 pinned source files and every overlay/receipt before running finite diagnostic selections. A changed source pin requires a deliberate source-frame reconstruction and review; do not refresh hashes or expectations to force a replay. Script exit 0 means the stated red counts and the legacy 26/0 result were reproduced, not that the application passed.

The exact external dependencies are recorded in `manifest.json` and `frozen/source-pins.json.txt`:

- Committed inactive Writer transaction postimage `fc77df761890ecdc725b2962a78bac7bad898bc989b568b074e6b5d3e788b84a` and held-query Reader postimage `6844b07b2f89f9d3729ed610592165419f1769bb758d1745f6bb81693d8da1e1`.
- Six predecessor receipts: Writer `0cb1e695`, transaction `86515273`, Reader origin `f69b51fd`, slot identity `4cca79c2`, held query `bda58880`, and the deliberately red Hook witness `1685bc33`.
- The original watchdog prefix `a24127014db0ee5318e11059aca9692b958bbcee873ecd904e264deb9a92a8fb` and overlap assertion `7657524e5f5ef74c8005ebd3293aa997e21150b3e33ab9fd4a0c7717f5d6c9e0`.

The earlier handoff must stay at `docs/handovers/2026-10-04-parallel-containers/group3-2026-10-06-inactive-handoff` for the frozen replayer's exact paths. Source admission remains separate: coordinate Hook, Writer, Reader, TapHold, Injector, OutputTransaction, ComboEmitter, daemon and native XKB ownership before implementing the broker. Preserve unknown/legacy configuration and all original assertions. No UI, locale, schema or capability availability is enabled by this inventory.

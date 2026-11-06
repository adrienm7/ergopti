"""Exercise worker-archive custody without mutating real worker evidence."""

import argparse
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True


def main():
    """Accept one complete synthetic archive and reject six targeted mutations."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    campaign = Path(__file__).resolve().parents[1]
    checker = campaign / "check_custody.py"
    spec = importlib.util.spec_from_file_location("dead_keys_custody_controls", checker)
    target = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(target)
    results = []
    with tempfile.TemporaryDirectory(prefix="dead-keys-custody-controls-") as temporary:
        directory = Path(temporary)

        def reset():
            """Build only small identity fixtures, not fake runtime observations."""
            for role in target.ROLES:
                archive = directory / role
                archive.mkdir(exist_ok=True)
                for item in archive.iterdir():
                    item.unlink()
                for name in sorted(target.REQUIRED):
                    (archive / name).write_text(
                        target.AUDITED_SHA + "\n" if name.endswith(".md") else "{}\n"
                    )
                (archive / "probe.py").write_text("print('synthetic fixture')\n")
                files = [
                    {"path": item.name, "sha256": hashlib.sha256(item.read_bytes()).hexdigest()}
                    for item in sorted(archive.iterdir())
                ]
                (archive / "handoff.json").write_text(
                    json.dumps({"audited_sha": target.AUDITED_SHA, "files": files})
                )

        def reject(name, mutate, marker):
            """Require each independent bad boundary to fail for its stated reason."""
            reset()
            mutate()
            try:
                target.authenticate(directory)
            except ValueError as error:
                target.require(marker in str(error), name + ": wrong rejection boundary")
                results.append({"case": name, "outcome": "rejected", "marker": str(error)})
                return
            raise AssertionError("accepted " + name)

        reset()
        receipt = target.authenticate(directory)
        target.require(len(receipt["roles"]) == 4, "positive roles")
        target.require(sum(len(r["artifacts"]) for r in receipt["roles"]) == 20, "positive hashes")
        windows = directory / "windows"

        def edit_manifest(change):
            """Alter only the selected private envelope."""
            path = windows / "handoff.json"
            data = json.loads(path.read_text())
            change(data)
            path.write_text(json.dumps(data))

        reject(
            "changed-program",
            lambda: (windows / "probe.py").write_text("changed\n"),
            "artifact hash mismatch",
        )
        reject(
            "traversal",
            lambda: edit_manifest(lambda d: d["files"][0].update(path="../outside")),
            "noncanonical artifact path",
        )

        def same_byte_symlink():
            """Make a digest-equivalent alias that custody must still reject."""
            (windows / "probe.py").unlink()
            (windows / "probe.py").symlink_to(directory / "linux/probe.py")

        reject("same-byte-symlink", same_byte_symlink, "symlink artifact")
        reject(
            "unlisted-extra",
            lambda: (windows / "extra.txt").write_text("not reviewed\n"),
            "unlisted/missing",
        )
        reject(
            "wrong-pin",
            lambda: edit_manifest(lambda d: d.update(audited_sha="0" * 40)),
            "wrong handoff source pin",
        )

        def omitted_source():
            """Remove both entry and file, isolating required-role enforcement."""
            edit_manifest(
                lambda d: d.update(
                    files=[r for r in d["files"] if r["path"] != "source-receipts.json"]
                )
            )
            (windows / "source-receipts.json").unlink()

        reject("omitted-source-receipt", omitted_source, "missing required role artifacts")

        def format_case():
            """Create an explicit JSON-only alias, retaining exact original bytes."""
            reset()
            originals = directory / "validation/worker-originals"
            originals.mkdir(parents=True, exist_ok=True)
            old = json.dumps({"n": 1, "b": True}).encode()
            (originals / "coverage.json.txt").write_bytes(old)
            edit_manifest(
                lambda d: next(r for r in d["files"] if r["path"] == "coverage.json").update(
                    sha256=hashlib.sha256(old).hexdigest()
                )
            )
            current = json.dumps({"n": 1, "b": True}, indent="\t").encode() + b"\n"
            (windows / "coverage.json").write_bytes(current)
            item = {
                "role": "windows",
                "path": "coverage.json",
                "kind": "json-format",
                "original_copy": "validation/worker-originals/coverage.json.txt",
                "original_sha256": hashlib.sha256(old).hexdigest(),
                "current_sha256": hashlib.sha256(current).hexdigest(),
            }
            provenance = directory / "validation/worker-format-provenance.json"
            provenance.write_text(
                json.dumps({"audited_sha": target.AUDITED_SHA, "transforms": [item]})
            )
            return item, provenance

        item, provenance = format_case()
        formatted_receipt = target.authenticate(directory)
        target.require(formatted_receipt["format_provenance"] is not None, "format alias positive")

        def reject_alias(name, mutate, marker):
            """Require formatting provenance to preserve both values and identity."""
            item, provenance = format_case()
            mutate(item)
            provenance.write_text(
                json.dumps({"audited_sha": target.AUDITED_SHA, "transforms": [item]})
            )
            try:
                target.authenticate(directory)
            except ValueError as error:
                target.require(marker in str(error), name + ": wrong alias rejection")
                results.append({"case": name, "outcome": "rejected", "marker": str(error)})
                return
            raise AssertionError("accepted " + name)

        reject_alias(
            "formatted-byte-drift",
            lambda d: (windows / "coverage.json").write_text("{}"),
            "formatted artifact hash mismatch",
        )

        def changed_value(item, value):
            raw = json.dumps(value).encode()
            (windows / "coverage.json").write_bytes(raw)
            item["current_sha256"] = hashlib.sha256(raw).hexdigest()

        reject_alias(
            "formatted-value-change",
            lambda d: changed_value(d, {"n": 2, "b": True}),
            "JSON values/types changed",
        )
        reject_alias(
            "boolean-number-confusion",
            lambda d: changed_value(d, {"n": 1, "b": 1}),
            "JSON values/types changed",
        )

        def changed_original(item):
            raw = json.dumps({"n": 2, "b": False}).encode()
            (directory / item["original_copy"]).write_bytes(raw)
            (windows / "coverage.json").write_bytes(raw)
            item["original_sha256"] = item["current_sha256"] = hashlib.sha256(raw).hexdigest()

        reject_alias(
            "wrong-worker-original",
            changed_original,
            "worker hash differs from original format alias",
        )

        (directory / "validation/worker-format-provenance.json").unlink()

        def encoded_case():
            reset()
            raw = (windows / "probe.py").read_bytes()
            storage = "validation/worker-originals/probe.py.gz"
            file = directory / storage
            file.write_bytes(gzip.compress(raw, mtime=0))
            (windows / "probe.py").unlink()
            item = {
                "role": "windows",
                "path": "probe.py",
                "codec": "gzip",
                "storage": storage,
                "storage_sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
                "decoded_sha256": hashlib.sha256(raw).hexdigest(),
            }
            provenance = directory / "validation/worker-encoding-provenance.json"
            provenance.write_text(
                json.dumps({"audited_sha": target.AUDITED_SHA, "encodings": [item]})
            )
            return item, provenance

        encoded_case()
        target.authenticate(directory)
        for name, marker in [
            ("encoded-byte-drift", "encoded storage hash mismatch"),
            ("encoded-wrong-decoded", "decoded artifact hash mismatch"),
            ("unsupported-codec", "unsupported archive codec"),
            ("encoded-physical-collision", "encoded artifact physical collision"),
        ]:
            item, provenance = encoded_case()
            if name == "encoded-byte-drift":
                (directory / item["storage"]).write_bytes(b"wrong")
            elif name == "encoded-wrong-decoded":
                item["decoded_sha256"] = "0" * 64
            elif name == "unsupported-codec":
                item["codec"] = "unknown"
            else:
                (windows / "probe.py").write_text("physical collision")
            provenance.write_text(
                json.dumps({"audited_sha": target.AUDITED_SHA, "encodings": [item]})
            )
            try:
                target.authenticate(directory)
            except ValueError as error:
                target.require(marker in str(error), name + ": wrong rejection")
                results.append({"case": name, "outcome": "rejected", "marker": str(error)})
            else:
                raise AssertionError("accepted " + name)
    result = {
        "audited_sha": target.AUDITED_SHA,
        "qualification": "Synthetic identity controls only; no worker findings or dead-key behavior is inferred. Same-byte symlink, omitted entry/file and narrowly declared JSON-format cases isolate closed-role/value/type/byte guards.",
        "program": {
            "path": "check_custody.py",
            "sha256": hashlib.sha256(checker.read_bytes()).hexdigest(),
        },
        "control_program": {
            "path": "validation/check_custody_controls.py",
            "sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        },
        "positive_controls": 3,
        "positive_roles": 4,
        "positive_artifact_hashes": 20,
        "negative_controls": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent="\t") + "\n")
    print("Custody controls: 3 positive four-role archives; 14 targeted negatives rejected.")


if __name__ == "__main__":
    main()

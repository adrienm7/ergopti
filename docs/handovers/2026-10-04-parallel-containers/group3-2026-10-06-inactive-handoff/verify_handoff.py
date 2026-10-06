# docs/handovers/2026-10-04-parallel-containers/group3-2026-10-06-inactive-handoff/verify_handoff.py

"""Verify inactive continuation bytes and optional current repository preimages."""

import argparse
import hashlib
import json
import stat
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def local_path(root, relative):
    candidate = root / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise ValueError("Unsafe portable path")
    if not candidate.resolve().is_relative_to(root.resolve()):
        raise ValueError("Path escapes the handoff root")
    return candidate


def regular_state(path):
    """Treat only genuine absence as the preimage of a new source."""
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return "ABSENT"
    except OSError:
        return "UNREADABLE_DESTINATION"
    if stat.S_ISLNK(mode):
        return "OCCUPIED_SYMLINK"
    if not stat.S_ISREG(mode):
        return "OCCUPIED_NONREGULAR"
    return "REGULAR"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default="manifest.json")
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--packet")
    parser.add_argument("--require-preimage", action="store_true")
    args = parser.parse_args()
    manifest_path = Path(args.manifest).resolve()
    root = manifest_path.parent
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    errors = []
    if manifest.get("physical_delivery_available") is not False:
        errors.append("Archive must not claim physical delivery availability")
    if manifest.get("status") != "ARCHIVAL_ONLY_NOT_IMPLEMENTATION_OR_ADMISSION":
        errors.append("Archive must stay inactive")
    for relative, expected in manifest["files"].items():
        path = local_path(root, relative)
        if not relative.endswith(".txt"):
            errors.append("Frozen artifact has an active extension: " + relative)
        if regular_state(path) != "REGULAR":
            errors.append("Frozen artifact is missing or nonregular: " + relative)
            continue
        if any(
            root.joinpath(*Path(relative).parts[:index]).is_symlink()
            for index in range(1, len(Path(relative).parts))
        ):
            errors.append("Frozen artifact ancestor is a symlink: " + relative)
            continue
        raw = path.read_bytes()
        if digest(path) != expected["sha256"] or len(raw) != expected["bytes"]:
            errors.append("Frozen bytes differ: " + relative)
        if b"\r\n" in raw:
            errors.append("Frozen text has CRLF: " + relative)
        if relative.endswith(".ahk.txt") and not raw.startswith(b"\xef\xbb\xbf"):
            errors.append("AHK source lacks its original UTF-8 BOM: " + relative)
    ids = [packet["id"] for packet in manifest["packets"]]
    if len(ids) != len(set(ids)):
        errors.append("Duplicate packet identifiers")
    seen = set()
    for packet in manifest["packets"]:
        if not set(packet["requires_packets"]).issubset(seen):
            errors.append("Predecessor ordering is invalid: " + packet["id"])
        seen.add(packet["id"])
        for row in packet["source_paths"]:
            for role in ("pre", "post"):
                expected = row[role + "_sha256"]
                location = row.get(role + "image")
                if expected is not None:
                    if (
                        not location
                        or manifest["files"].get(location, {}).get("sha256") != expected
                    ):
                        errors.append(
                            "Missing exact source pair: " + packet["id"] + ":" + row["path"]
                        )
    report = {"frozen_files": len(manifest["files"]), "packets": len(ids), "errors": errors}
    if args.repo or args.packet:
        if not args.repo or not args.packet:
            parser.error("--repo and --packet must be specified together")
        selected = next((p for p in manifest["packets"] if p["id"] == args.packet), None)
        if selected is None:
            parser.error("Unknown packet identifier")
        states = []
        for row in selected["source_paths"]:
            path = local_path(args.repo, row["path"])
            kind = regular_state(path)
            actual = digest(path) if kind == "REGULAR" else None
            if kind not in ("REGULAR", "ABSENT"):
                state = kind
            elif any(
                args.repo.joinpath(*Path(row["path"]).parts[:index]).is_symlink()
                for index in range(1, len(Path(row["path"]).parts))
            ):
                state = "OCCUPIED_SYMLINK_ANCESTOR"
            elif actual == row["pre_sha256"]:
                state = "PREIMAGE_MATCH" if actual is not None else "EXPECTED_ABSENCE"
            elif actual == row["post_sha256"]:
                state = "ALREADY_POSTIMAGE"
            else:
                state = "MISMATCH"
            states.append({"path": row["path"], "state": state, "actual_sha256": actual})
            if state not in ("PREIMAGE_MATCH", "EXPECTED_ABSENCE", "ALREADY_POSTIMAGE") or (
                args.require_preimage and state == "ALREADY_POSTIMAGE"
            ):
                errors.append("Current source needs composition: " + row["path"])
        report["current_repository"] = str(args.repo)
        report["selected_packet"] = args.packet
        report["preimage_states"] = states
    print(json.dumps(report, indent=2, sort_keys=True))
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

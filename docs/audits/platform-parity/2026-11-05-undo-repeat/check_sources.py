"""Re-derive retained production-source claims from Git and the current checkout."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PIN = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"


def main():
    """Check every claimed file, retaining expected integration drift explicitly."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    campaign = Path(__file__).resolve().parent
    reviewed = {
        item["path"]: item["sha256"]
        for item in json.loads((campaign / "validation/implementation-files.json").read_text())
    }
    sources = []
    for name, field in [
        ("windows/source-contract-result.json", "source_receipts"),
        ("macos/source-hashes.json", "files"),
        ("linux/source-receipt.json", "sources"),
        ("shared/source-observation.json", "sources"),
        ("timing-followup/windows/source-contract.txt", "source_receipts"),
        ("timing-followup/macos/source-hashes.json", "files"),
        ("timing-followup/linux/receipt.json", "sources"),
        ("timing-followup/shared/source-receipt.json", "sources"),
    ]:
        document = json.loads((campaign / name).read_text())
        if document["audited_sha"] != PIN:
            raise ValueError(f"Wrong source pin: {name}")
        entries = document[field]
        if isinstance(entries, dict):
            entries = [{"path": path, "sha256": digest} for path, digest in entries.items()]
        for entry in entries:
            sources.append(dict(entry, receipt=name))
    if not sources:
        raise ValueError("Empty source claim set")
    results = []
    for claim in sources:
        relative = claim["path"]
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ValueError(f"Invalid source path: {relative}")
        pinned = subprocess.check_output(["git", "show", f"{PIN}:{relative}"], cwd=args.repository)
        if hashlib.sha256(pinned).hexdigest() != claim["sha256"]:
            raise ValueError(f"Pinned claim mismatch: {claim}")
        current = (args.repository / relative).read_bytes()
        current_digest = hashlib.sha256(current).hexdigest()
        matches = current_digest == claim["sha256"]
        reviewed_metadata = reviewed.get(relative) == current_digest
        if not matches and relative != "TODO.md" and not reviewed_metadata:
            raise ValueError(f"Current claimed owner changed: {relative}")
        results.append(
            dict(claim, current_matches=matches, matches_reviewed_metadata=reviewed_metadata)
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(
            {
                "audited_sha": PIN,
                "claims": len(results),
                "distinct_paths": len({claim["path"] for claim in results}),
                "qualification": "Claimed files only, not all transitive dependencies or whole-repository coverage. Expected metadata integration drift is listed explicitly.",
                "results": results,
            },
            indent=2,
        )
        + "\n"
    )
    print(f"Authenticated {len(results)} claims over {len({r['path'] for r in results})} paths")


if __name__ == "__main__":
    main()

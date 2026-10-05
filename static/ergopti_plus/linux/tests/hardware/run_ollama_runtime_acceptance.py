#!/usr/bin/env python3
"""Qualify explicit HTTPS runtime installation and real model inference.

This manual diagnostic uses production Lua/native owners under the existing
child subreaper. Only consent and WebKit presentation are scripted. Private raw
logs never enter uploaded evidence; successful qualification requires unchanged
sources, completed native receipts, and physical cleanup.
"""

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import tempfile


MODEL = "granite4:350m-h"
ARCHIVE_BYTES = 1198635318
ARCHIVE_SHA256 = "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb"


def digest(path):
    """Read complete native bytes, never infer a digest from its filename."""
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def canonical_model(node):
    """Require the independently captured catalogue identity."""
    if isinstance(node, dict):
        if (
            node.get("name") == "granite-4.0-h-350m"
            and node.get("urls", {}).get("ollama") == "https://ollama.com/library/granite4:350m-h"
        ):
            return True
        return any(canonical_model(value) for value in node.values())
    return isinstance(node, list) and any(canonical_model(value) for value in node)


def write_evidence(path, document):
    """Retain a bounded safe result even when native admission fails."""
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[5])
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--lua", choices=["luajit", "lua5.4"], default="luajit")
    parser.add_argument("--child-command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    repository = args.repository.resolve()
    hardware = repository / "static/ergopti_plus/linux/tests/hardware"
    if args.child_command is not None:
        spec = importlib.util.spec_from_file_location(
            "owned_subreaper", hardware / "run_native_subreaper.py"
        )
        owner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(owner)
        return owner.main(args.child_command, deadline_seconds=930)

    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    public = evidence / "ollama-runtime-acceptance.json"
    document = {
        "schema_version": 1,
        "passed": False,
        "status": "not_executed",
        "reason": "native_admission_pending",
        "model": MODEL,
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sha": os.getenv("GITHUB_SHA"),
        "interpreter": args.lua,
        "phase": "preflight",
        "native_executed": False,
        "scope": "actual Engine/Coordinator/EventLoop; daemon entrypoint and physical GUI excluded",
        "profile_scope": "private Ergopti XDG/config/data/models; inherited HOME retained; Ollama may create its ordinary ~/.ollama key",
        "external_fixture_ceiling_ms": 900000,
        "cleanup_ceiling_ms": 30000,
    }
    write_evidence(public, document)
    try:
        if (
            os.getenv("GITHUB_ACTIONS") == "true"
            and os.getenv("GITHUB_EVENT_NAME") != "workflow_dispatch"
        ):
            document.update(status="refused", reason="manual_workflow_dispatch_required")
            return 2
        assert sys.platform == "linux" and os.getuid() > 0, "ordinary Linux native user required"
        assert Path("/").stat().st_uid == 0, "trusted native root inode required"
        assert os.uname().machine in ("x86_64", "amd64"), (
            "frozen official amd64 expectations required"
        )
        catalogue = repository / "static/ergopti_plus/_shared/modules/llm/models.json"
        assert canonical_model(json.loads(catalogue.read_text())), (
            "canonical model identity required"
        )
        pins = json.loads(
            (repository / "static/ergopti_plus/_shared/modules/llm/ollama_release.json").read_text()
        )
        assert pins["version"] == "0.24.0" and pins["assets"]["linux-amd64"] == {
            "filename": "ollama-linux-amd64.tar.zst",
            "bytes": ARCHIVE_BYTES,
            "sha256": ARCHIVE_SHA256,
        }, "independently frozen official archive fields required"

        # HOME is trusted by the production resolver; /tmp and writable-by-others
        # ancestors deliberately remain refused. Never rewrite an existing path.
        parent = Path.home() / ".ergopti-runtime-acceptance"
        parent.mkdir(mode=0o700, exist_ok=True)
        identity = parent.lstat()
        assert stat.S_ISDIR(identity.st_mode) and identity.st_uid == os.getuid()
        assert identity.st_mode & 0o077 == 0, "private current-user profile parent required"
        root = Path(tempfile.mkdtemp(prefix="actual-", dir=parent))
        for name in ("config", "data", "state", "run", "models", "config/ergopti"):
            (root / name).mkdir(mode=0o700, parents=True, exist_ok=True)
        config = root / "config/ergopti/config.toml"
        config.write_text(
            '[llm]\nenabled = false\n[llm.models]\nselected = "ollama"\nollama = "granite4:350m-h"\n'
        )
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        environment = dict(
            os.environ,
            XDG_CONFIG_HOME=str(root / "config"),
            XDG_DATA_HOME=str(root / "data"),
            XDG_STATE_HOME=str(root / "state"),
            XDG_RUNTIME_DIR=str(root / "run"),
            OLLAMA_MODELS=str(root / "models"),
            ERGOPTI_MODEL_RECEIPT_DIR=str(root),
        )
        subjects = set((repository / "static/ergopti_plus/linux").rglob("*.lua"))
        subjects.update((repository / "static/ergopti_plus/_shared/lua").rglob("*.lua"))
        subjects.update((repository / "static/ergopti_plus/_shared/modules").rglob("*.json"))
        subjects.update((repository / "static/ergopti_plus/_shared/modules").rglob("*.toml"))
        subjects.update((repository / "static/ergopti_plus/_shared/data/locales").glob("*.json"))
        subjects.update([Path(__file__).resolve(), hardware / "run_native_subreaper.py"])

        def sources():
            return {str(path.relative_to(repository)): digest(path) for path in sorted(subjects)}

        before = sources()
        command = [
            sys.executable,
            str(Path(__file__).resolve()),
            "--repository",
            str(repository),
            "--evidence",
            str(evidence),
            "--lua",
            args.lua,
            "--child-command",
            args.lua,
            str(hardware / "run_ollama_runtime_acceptance.lua"),
            str(repository),
            str(port),
        ]
        document.update(
            actual_uid=os.getuid(),
            root_inode_uid=0,
            sources_before=before,
            status="running",
            reason=None,
            native_executed=True,
        )
        write_evidence(public, document)
        with (root / "native.private.log").open("wb") as raw:
            result = subprocess.run(
                command, env=environment, cwd=repository, stdout=raw, stderr=subprocess.STDOUT
            )
        text = (root / "native.private.log").read_text(errors="replace")
        after = sources()
        receipts = []
        for line in text.splitlines():
            if line.startswith("ACCEPTANCE_PHASE "):
                phase = line[len("ACCEPTANCE_PHASE ") :]
                if phase in {
                    "official-https-install",
                    "missing-model-preflight",
                    "explicit-model-pull",
                    "real-model-chat",
                    "terminal-physical-shutdown",
                }:
                    document["phase"] = phase
            elif line.startswith("{"):
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if (
                    isinstance(item, dict)
                    and item.get("passed") is True
                    and item.get("model") == MODEL
                ):
                    receipts.append(item)
        physical_zero = (
            text.splitlines().count("Native subreaper: 0 adopted descendants physically reaped")
            == 1
        )
        stable = before == after
        accepted = result.returncode == 0 and stable and physical_zero and len(receipts) == 1
        if accepted:
            receipt = receipts[0]
            accepted = (
                receipt.get("archive_sha256") == ARCHIVE_SHA256
                and receipt.get("archive_bytes") == ARCHIVE_BYTES
                and receipt.get("typed_version") == "0.24.0"
                and all(
                    type(receipt.get(key)) is int and receipt[key] == 1
                    for key in (
                        "explicit_binary_choices",
                        "explicit_model_choices",
                        "pull_dispatches",
                        "chat_dispatches",
                    )
                )
                and receipt.get("archive_http_settled") is True
                and receipt.get("pull_http_settled") is True
                and receipt.get("owned_serve_settled") is True
                and receipt.get("native_loop_retired") is True
                and type(receipt.get("inference_bytes")) is int
                and receipt["inference_bytes"] > 0
                and receipt.get("terminal_shutdown_requested") is True
                and receipt.get("event_loop_stop_before_ack") is False
                and type(receipt.get("shutdown_idle_polls")) is int
                and receipt["shutdown_idle_polls"] >= 0
            )
        document.update(
            passed=accepted,
            status="passed" if accepted else "failed",
            reason=None if accepted else "native_receipt_or_source_qualification_failed",
            child_status=result.returncode,
            sources_after=after,
            sources_unchanged=stable,
            zero_descendants=physical_zero,
            private_log_sha256=digest(root / "native.private.log"),
        )
        if accepted:
            # Upload only independently selected safe scalar fields, never a raw
            # receipt that could contain upstream signed URLs or model text.
            document["receipt"] = {
                key: receipts[0][key]
                for key in (
                    "archive_bytes",
                    "archive_sha256",
                    "typed_version",
                    "explicit_binary_choices",
                    "explicit_model_choices",
                    "pull_dispatches",
                    "chat_dispatches",
                    "inference_bytes",
                    "archive_http_settled",
                    "pull_http_settled",
                    "owned_serve_settled",
                    "native_loop_retired",
                    "terminal_shutdown_requested",
                    "event_loop_stop_before_ack",
                    "shutdown_idle_polls",
                )
            }
        answer = root / "inference.private.txt"
        if answer.is_file():
            document.update(inference_sha256=digest(answer), inference_bytes=answer.stat().st_size)
        return 0 if accepted else 1
    except Exception as error:
        document.update(
            passed=False,
            status="failed",
            reason="qualification_exception",
            exception_type=type(error).__name__,
        )
        return 1
    finally:
        document["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_evidence(public, document)
        print(
            json.dumps(
                {
                    "passed": document["passed"],
                    "status": document["status"],
                    "reason": document["reason"],
                    "phase": document["phase"],
                    "evidence": str(public),
                }
            )
        )


if __name__ == "__main__":
    sys.exit(main())

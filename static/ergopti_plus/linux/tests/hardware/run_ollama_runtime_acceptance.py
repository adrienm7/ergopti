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
import re
import socket
import stat
import subprocess
import sys
import tempfile


MODEL = "granite4:350m-h"
ARCHIVE_BYTES = 1198635318
ARCHIVE_SHA256 = "15c5f8d66ba06e0d3b4719df8868612dbd66e14e82760929bb3552e1657cdcdb"


WORK_PHASES = frozenset(
    {
        "official-https-install",
        "missing-model-preflight",
        "explicit-model-pull",
        "real-model-chat",
    }
)
CLEANUP_PHASE = "terminal-physical-shutdown"
FAILURE_REASONS = {
    "failed": frozenset(
        {"native_receipt_or_source_qualification_failed", "qualification_exception"}
    ),
    "refused": frozenset({"manual_workflow_dispatch_required"}),
}
EXCEPTION_TYPES = frozenset(
    {
        "AssertionError",
        "AttributeError",
        "CalledProcessError",
        "FileExistsError",
        "FileNotFoundError",
        "ImportError",
        "IndexError",
        "IsADirectoryError",
        "JSONDecodeError",
        "KeyError",
        "ModuleNotFoundError",
        "NotADirectoryError",
        "OSError",
        "OverflowError",
        "PermissionError",
        "RuntimeError",
        "TimeoutError",
        "TimeoutExpired",
        "TypeError",
        "UnicodeDecodeError",
        "UnicodeEncodeError",
        "UnicodeError",
        "ValueError",
    }
)


def acceptance_phases(text):
    """Retain literal work markers separately from the terminal cleanup marker.

    Unknown log content has no diagnostic authority. Once cleanup starts, later
    work markers cannot replace the operation that preceded cleanup.
    """
    if type(text) is not str:
        return None
    result = {"phase": "preflight", "work_phase": "preflight", "cleanup_phase": None}
    for line in text.splitlines():
        if not line.startswith("ACCEPTANCE_PHASE "):
            continue
        phase = line[len("ACCEPTANCE_PHASE ") :]
        if phase == CLEANUP_PHASE:
            result["phase"] = phase
            result["cleanup_phase"] = phase
        elif phase in WORK_PHASES and result["cleanup_phase"] is None:
            result["phase"] = phase
            result["work_phase"] = phase
    return result


def safe_failure_metadata(document):
    """Project only exact, bounded public failure values; refuse malformed input.

    Private paths, errors, receipts and source inventories are never selected or
    coerced. Booleans are not native exit statuses. Unknown exception names and
    diagnostic tokens cannot enter a workflow command.
    """
    if type(document) is not dict or document.get("passed") is not False:
        return None
    status = document.get("status")
    reason = document.get("reason")
    if type(status) is not str or status not in FAILURE_REASONS:
        return None
    if type(reason) is not str or reason not in FAILURE_REASONS[status]:
        return None
    phase = document.get("work_phase")
    if type(phase) is not str or (phase != "preflight" and phase not in WORK_PHASES):
        return None
    cleanup = document.get("cleanup_phase")
    if cleanup is not None and (type(cleanup) is not str or cleanup != CLEANUP_PHASE):
        return None
    child_status = document.get("child_status")
    if child_status is not None and (
        type(child_status) is not int or not -64 <= child_status <= 255
    ):
        return None
    zero = document.get("zero_descendants")
    stable = document.get("sources_unchanged")
    if (zero is not None and type(zero) is not bool) or (
        stable is not None and type(stable) is not bool
    ):
        return None
    exception = document.get("exception_type")
    if exception is not None and (type(exception) is not str or exception not in EXCEPTION_TYPES):
        return None
    if reason == "qualification_exception" and exception is None:
        return None
    if reason != "qualification_exception" and exception is not None:
        return None
    return {
        "phase": phase,
        "cleanup_phase": cleanup or "none",
        "status": status,
        "reason": reason,
        "child_status": "unknown" if child_status is None else child_status,
        "zero_descendants": "unknown" if zero is None else str(zero).lower(),
        "sources_unchanged": "unknown" if stable is None else str(stable).lower(),
        "exception_type": exception or "none",
    }


def failure_annotation(document):
    """Build one closed GitHub error command without reflecting private text."""
    metadata = safe_failure_metadata(document)
    if metadata is None:
        return None
    fields = " ".join(f"{key}={value}" for key, value in metadata.items())
    return "::error title=Ollama native acceptance::" + fields


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


def physical_receipt(text):
    """Require measured empty ownership, independently of reaped adoption count."""
    prefix = "Native subreaper closure: "
    markers = [line[len(prefix) :] for line in text.splitlines() if line.startswith(prefix)]
    if len(markers) != 1:
        return None

    def distinct_object(pairs):
        values = {}
        for key, value in pairs:
            if key in values:
                raise ValueError("duplicate physical receipt field")
            values[key] = value
        return values

    try:
        receipt = json.loads(markers[0], object_pairs_hook=distinct_object)
    except (TypeError, ValueError):
        return None
    if type(receipt) is not dict or set(receipt) != {"pending", "rescue", "adopted"}:
        return None
    if any(type(value) is not int or value < 0 for value in receipt.values()):
        return None
    if receipt["pending"] != 0 or receipt["rescue"] != 0:
        return None
    reaped = [
        int(match.group(1))
        for line in text.splitlines()
        if (
            match := re.fullmatch(
                r"Native subreaper: (\d+) adopted descendants physically reaped", line
            )
        )
    ]
    if len(reaped) != 1 or reaped[0] != receipt["adopted"]:
        return None
    return receipt


def build_and_run(repository, hardware, command):
    """Build the original helper and run Lua inside the existing subreaper child.

    The outer owner retains its original 930-second deadline over both stages.
    A pre-existing helper is preserved and admitted only against a freshly built
    byte-identical original producer output; no pathname is silently adopted.
    """
    assert len(command) == 4 and command[0] in ("luajit", "lua5.4")
    assert command[1] == str(hardware / "run_ollama_runtime_acceptance.lua")
    assert command[2] == str(repository) and 0 < int(command[3]) < 65536
    driver = repository / "static/ergopti_plus/linux"
    source_directory = driver / "native/archive_output"
    script = repository / "tools/build/build-linux-native-output.sh"
    inputs = [
        script,
        source_directory / "archive_publication.c",
        source_directory / "archive_publication.h",
        Path(__file__).resolve(),
        hardware / "run_native_subreaper.py",
        Path(command[1]),
    ]
    tools = [Path("/usr/bin/bash").resolve(strict=True), Path("/usr/bin/cc").resolve(strict=True)]
    for tool in tools:
        identity = tool.lstat()
        assert stat.S_ISREG(identity.st_mode) and identity.st_uid == 0
        assert identity.st_mode & 0o022 == 0 and os.access(tool, os.X_OK)
        with tool.open("rb") as binary:
            assert binary.read(4) == b"\x7fELF", "actual trusted native build tool required"

    def source_identity(path):
        value = path.lstat()
        assert stat.S_ISREG(value.st_mode), "ordinary native build source/tool required"
        return (value.st_dev, value.st_ino, value.st_uid, value.st_mode, digest(path))

    before = {str(path): source_identity(path) for path in inputs + tools}
    profile = Path(os.environ["ERGOPTI_MODEL_RECEIPT_DIR"])
    identity = profile.lstat()
    assert stat.S_ISDIR(identity.st_mode) and identity.st_uid == os.getuid()
    assert identity.st_mode & 0o077 == 0
    binary_directory = driver / "bin"
    binary_directory.mkdir(mode=0o755, exist_ok=True)
    identity = binary_directory.lstat()
    assert stat.S_ISDIR(identity.st_mode) and identity.st_uid == os.getuid()
    assert identity.st_mode & 0o022 == 0, "owned native helper directory required"
    directory_identity = (identity.st_dev, identity.st_ino, identity.st_uid, identity.st_mode)
    # Own fresh output on the publication filesystem, including separate HOME mounts.
    output = Path(tempfile.mkdtemp(prefix=".runtime-acceptance-native-", dir=binary_directory))
    subprocess.run(
        [
            str(tools[0]),
            str(script),
            "--source-directory",
            str(source_directory),
            "--output-directory",
            str(output),
        ],
        env=dict(os.environ, CC=str(tools[1])),
        check=True,
    )
    generated = output / "libergopti_archive_publication.so"

    def native_identity(path):
        value = path.lstat()
        assert stat.S_ISREG(value.st_mode) and value.st_uid == os.getuid()
        assert stat.S_IMODE(value.st_mode) == 0o755 and os.access(path, os.X_OK)
        with path.open("rb") as binary:
            assert binary.read(4) == b"\x7fELF", "actual native retained helper required"
        return (value.st_dev, value.st_ino, value.st_uid, value.st_mode, digest(path))

    generated_identity = native_identity(generated)
    assert before == {str(path): source_identity(path) for path in inputs + tools}
    identity = binary_directory.lstat()
    assert (
        identity.st_dev,
        identity.st_ino,
        identity.st_uid,
        identity.st_mode,
    ) == directory_identity
    installed = binary_directory / generated.name
    if not os.path.lexists(installed):
        os.link(generated, installed)  # Atomic no-replace publication of exact owned output.
    installed_identity = native_identity(installed)
    assert installed_identity[-1] == generated_identity[-1], (
        "existing native helper differs from fresh producer"
    )
    result = subprocess.run(command, cwd=repository)
    assert native_identity(generated) == generated_identity
    assert native_identity(installed) == installed_identity
    identity = binary_directory.lstat()
    assert (
        identity.st_dev,
        identity.st_ino,
        identity.st_uid,
        identity.st_mode,
    ) == directory_identity
    assert before == {str(path): source_identity(path) for path in inputs + tools}
    write_evidence(
        profile / "native-helper.private.json",
        {
            "schema_version": 1,
            "sources_unchanged": True,
            "build_inputs": before,
            "generated_sha256": generated_identity[-1],
            "installed_sha256": installed_identity[-1],
            "child_status": result.returncode,
            "scope": "original native helper build and Lua under existing subreaper deadline",
        },
    )
    return result.returncode


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[5])
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--lua", choices=["luajit", "lua5.4"], default="luajit")
    parser.add_argument("--child-command", nargs=argparse.REMAINDER)
    parser.add_argument("--build-and-run", nargs=argparse.REMAINDER)
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

    if args.build_and_run is not None:
        return build_and_run(repository, hardware, args.build_and_run)

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
        "work_phase": "preflight",
        "cleanup_phase": None,
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
        subjects.update(
            [
                Path(__file__).resolve(),
                hardware / "run_native_subreaper.py",
                repository / "tools/build/build-linux-native-output.sh",
                repository
                / "static/ergopti_plus/linux/native/archive_output/archive_publication.c",
                repository
                / "static/ergopti_plus/linux/native/archive_output/archive_publication.h",
            ]
        )

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
            sys.executable,
            str(Path(__file__).resolve()),
            "--repository",
            str(repository),
            "--evidence",
            str(evidence),
            "--build-and-run",
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
        document.update(acceptance_phases(text))
        after = sources()
        receipts = []
        for line in text.splitlines():
            if line.startswith("{"):
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
        closure = physical_receipt(text)
        physical_zero = closure is not None
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
            physical_closure=closure,
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
        annotation = failure_annotation(document)
        if annotation is not None:
            print(annotation)
        document["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_evidence(public, document)
        print(
            json.dumps(
                {
                    "passed": document["passed"],
                    "status": document["status"],
                    "reason": document["reason"],
                    "phase": document["phase"],
                    "work_phase": document["work_phase"],
                    "cleanup_phase": document["cleanup_phase"],
                    "evidence": str(public),
                }
            )
        )


if __name__ == "__main__":
    sys.exit(main())

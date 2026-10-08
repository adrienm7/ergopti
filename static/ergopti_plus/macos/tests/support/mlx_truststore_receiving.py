"""Run the actual emitted downloader over independent offline admission vectors."""

import atexit
import builtins
import contextlib
import io
import json
import os
import socket
import sys
import threading
import types
from unittest import mock


def receive(source, expected_exit_path, vector):
    events, exits = [], []
    original_import, original_open = builtins.__import__, builtins.open
    truststore = types.ModuleType("truststore")
    hub = types.ModuleType("huggingface_hub")

    def inject():
        events.append("activation")
        if vector["truststore"] == "refused":
            raise RuntimeError("controlled system trust activation refusal")

    if vector["truststore"] != "api_missing":
        truststore.inject_into_ssl = inject

    def snapshot_download(*args, **kwargs):
        events.append("snapshot")
        assert "activation" in events, "download requires prior trust activation"
        assert args == ("org/model",) and kwargs == {"max_workers": 8}

    hub.snapshot_download = snapshot_download

    def importing(name, *args, **kwargs):
        if name == "truststore":
            events.append("trust_import")
            if vector["truststore"] == "missing":
                raise ModuleNotFoundError("controlled truststore absence")
            return truststore
        if name == "huggingface_hub":
            events.append("hub_import")
            if vector["hub"] == "missing":
                raise ModuleNotFoundError("controlled hub absence")
            return hub
        return original_import(name, *args, **kwargs)

    class ExitWriter:
        def __init__(self, path):
            self.path = path

        def write(self, value):
            exits.append([self.path, int(value)])

    def exit_open(path, mode="r", *args, **kwargs):
        if mode == "w":
            events.append(["write_open", path])
            assert path == expected_exit_path, (
                "only exact independently captured exit receipt may be written"
            )
            return ExitWriter(path)
        assert "w" not in mode and "a" not in mode and "+" not in mode, (
            "only owned exit receipt may be written"
        )
        return original_open(path, mode, *args, **kwargs)

    class Watcher:
        def __init__(self, **kwargs):
            assert kwargs["daemon"] is True and callable(kwargs["target"])

        def start(self):
            events.append("watcher")

    def refuse_network(*args, **kwargs):
        raise AssertionError("offline regression must never perform native networking")

    output = io.StringIO()
    with contextlib.ExitStack() as stack:
        stack.enter_context(mock.patch.object(builtins, "__import__", importing))
        stack.enter_context(mock.patch.object(builtins, "open", exit_open))
        stack.enter_context(mock.patch.object(os, "setpgrp", lambda: None, create=True))
        stack.enter_context(mock.patch.object(os.path, "isdir", lambda path: False))
        stack.enter_context(mock.patch.object(threading, "Thread", Watcher))
        stack.enter_context(mock.patch.object(atexit, "register", lambda *args: None))
        stack.enter_context(mock.patch.object(atexit, "unregister", lambda *args: None))
        stack.enter_context(mock.patch.object(socket, "socket", refuse_network))
        stack.enter_context(mock.patch.object(socket, "create_connection", refuse_network))
        stack.enter_context(mock.patch.object(socket, "getaddrinfo", refuse_network))
        stack.enter_context(contextlib.redirect_stdout(output))
        stack.enter_context(contextlib.redirect_stderr(output))
        status = 0
        try:
            exec(compile(source, "actual_emitted_mlx_downloader.py", "exec"), {})
        except SystemExit as refusal:
            status = refusal.code

    prefix = vector["id"] + ": "
    assert status == vector["status"], prefix + "process verdict"
    assert exits == [[expected_exit_path, vector["status"]]], prefix + "exact existing exit receipt"
    assert [event for event in events if isinstance(event, list)] == [
        ["write_open", expected_exit_path]
    ], prefix + "all writes stay with exact owner"
    assert events.count("hub_import") == vector["hub_imports"], prefix + "hub import admission"
    assert events.count("snapshot") == vector["snapshots"], prefix + "download admission"
    assert events.count("watcher") == vector["watchers"], prefix + "watcher admission"
    if vector["status"]:
        assert "--- ERREUR DEPENDANCES ---" in output.getvalue(), (
            prefix + "existing dependency diagnostic"
        )
    else:
        assert events.index("activation") < events.index("hub_import") < events.index("snapshot")


def main():
    with open(sys.argv[1], encoding="utf-8") as emitted:
        packet = json.load(emitted)
    assert isinstance(packet["source"], str) and isinstance(packet["expected_exit_path"], str)
    assert packet["expected_exit_path"] == packet["log_path"] + ".exit"
    with open(sys.argv[2], encoding="utf-8") as corpus:
        vectors = json.load(corpus)
    assert len(vectors) == 5 and len({vector["id"] for vector in vectors}) == 5
    failures = []
    for vector in vectors:
        try:
            receive(packet["source"], packet["expected_exit_path"], vector)
        except Exception as refusal:
            failures.append({"id": vector["id"], "reason": str(refusal)})
    receipt = {
        "passed": len(vectors) - len(failures),
        "failed": len(failures),
        "ids": [vector["id"] for vector in vectors],
    }
    if failures:
        receipt["failures"] = failures
    print(json.dumps(receipt))
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()

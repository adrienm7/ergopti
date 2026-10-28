"""Own real rollover subprocesses through the existing SQLite fixture bridge."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
RUNTIME = (
    "healthy",
    "marker_open_refused",
    "marker_partial_write",
    "marker_close_refused_after_close",
    "old_stream_close_error_after_close",
    "unlink_refused",
    "pending_publication_refused",
    "reset_commit_refused",
    "terminal_publication_refused",
    "release_refused_after_terminal",
)
REJECT = (
    "old_identity_replaced",
    "old_identity_grown",
    "old_path_symlink",
    "nonprefix_marker_tail",
)
RESTART = RUNTIME + REJECT + ("ordinary_pending_append",)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    with Path(path).open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--lua", required=True)
    parser.add_argument("--case", required=True, choices=RESTART)
    parser.add_argument(
        "--strategy",
        required=True,
        choices=(
            "runtime",
            "restart",
            "authority_absent",
            "authority_unrelated",
            "sqlite_open_refusal",
        ),
    )
    parser.add_argument("--cache", required=True, choices=("cold", "warm"))
    parser.add_argument("--execution-directory", required=True)
    parser.add_argument("--fixture", required=True)
    options = parser.parse_args()
    if options.strategy == "runtime" and options.case not in RUNTIME:
        parser.error("Identity/nonprefix and ordinary-pending cells require restart")
    if (
        options.strategy in ("authority_absent", "authority_unrelated")
        and options.case != "release_refused_after_terminal"
    ):
        parser.error("Completion authority subcases require terminal release refusal")
    if options.strategy == "sqlite_open_refusal" and options.case != "unlink_refused":
        parser.error("Actual SQLite-open refusal requires a prepared retained journal")
    root = Path(options.root).resolve()
    output = Path(options.execution_directory).resolve()
    if output.exists():
        parser.error("Each invocation requires a new owned output directory")
    output.mkdir(mode=0o700)
    original_connect = sqlite3.connect
    original_popen = subprocess.Popen
    source = root / "tools/diagnostics/hs274_persistence_test.py"
    spec = importlib.util.spec_from_file_location("rollover_unmodified_sqlite_bridge", source)
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    bridge.ROOT = root
    waits, children, read_holders, observations = [], [], [], []
    active_phase = None
    busy_used = False

    class ActualBusyConnection:
        def __init__(self, connection, path):
            object.__setattr__(self, "connection", connection)
            object.__setattr__(self, "path", path)
            object.__setattr__(self, "reset_seen", False)

        def __getattr__(self, name):
            return getattr(self.connection, name)

        def __setattr__(self, name, value):
            if name == "row_factory":
                self.connection.row_factory = value
            else:
                object.__setattr__(self, name, value)

        def execute(self, sql, *parameters):
            nonlocal busy_used
            if sql.strip() == "BEGIN TRANSACTION;":
                self.reset_seen = False
            if sql.strip() == "UPDATE meta SET value='0' WHERE key='today_log_offset';":
                self.reset_seen = True
            if (
                options.case == "reset_commit_refused"
                and active_phase == "prepare"
                and self.reset_seen
                and sql.strip() == "COMMIT;"
                and not busy_used
            ):
                assert self.connection.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
                holder = original_connect(self.path, isolation_level=None, timeout=0)
                record = {
                    "phase": active_phase,
                    "real_reader_acquired": False,
                    "real_commit_refused": False,
                    "reader_closed": False,
                }
                read_holders.append(record)
                try:
                    holder.execute("BEGIN;")
                    record["visible_old_offset"] = holder.execute(
                        "SELECT value FROM meta WHERE key='today_log_offset'"
                    ).fetchone()[0]
                    record["real_reader_acquired"] = holder.in_transaction
                    self.connection.execute("PRAGMA busy_timeout=0;")
                    busy_used = True
                    try:
                        # This is the real SQLite COMMIT; no return value is fabricated.
                        return self.connection.execute(sql, *parameters)
                    except sqlite3.OperationalError as error:
                        record["real_commit_refused"] = True
                        record["actual_error"] = str(error)
                        raise
                finally:
                    holder.rollback()
                    holder.close()
                    record["reader_closed"] = True
            return self.connection.execute(sql, *parameters)

    def connect(path, *args, **kwargs):
        return ActualBusyConnection(original_connect(path, *args, **kwargs), path)

    class RecordingPopen(original_popen):
        def __init__(self, *args, **kwargs):
            kwargs["start_new_session"] = True
            super().__init__(*args, **kwargs)
            self.observed_phase = active_phase
            children.append({"pid": self.pid, "phase": active_phase})

        def wait(self, *args, **kwargs):
            value = super().wait(*args, **kwargs)
            waits.append(
                {
                    "pid": self.pid,
                    "phase": self.observed_phase,
                    "wait_returned": True,
                    "exit_code": value,
                    "at": time.time(),
                }
            )
            return value

    keys = (
        "ERGOPTI_PHYSICAL_SOURCE_ROOT",
        "ERGOPTI_ROLLOVER_CASE",
        "ERGOPTI_ROLLOVER_PHASE",
        "ERGOPTI_ROLLOVER_STRATEGY",
        "TZ",
    )
    previous_environment = {key: os.environ.get(key) for key in keys}
    final = {
        "qualified": False,
        "native_Cocoa": "UNRUN",
        "retries": 0,
        "observations": observations,
        "actual_waits": waits,
        "read_holders": read_holders,
    }
    owned = None

    def run(phase):
        nonlocal active_phase
        active_phase = phase
        os.environ["ERGOPTI_ROLLOVER_PHASE"] = phase
        before = len(waits)
        value = bridge.run_fixture(options.lua, str(owned), Path(options.fixture).resolve())
        assert len(waits) == before + 1 and waits[-1]["exit_code"] == 0
        assert value["case"] == options.case and value["phase"] == phase
        assert value["cleanup"]["sqlite_retired"] and value["cleanup"]["timers_retired"]
        assert value["cleanup"]["manager_stop_call_ok"] and value["cleanup"]["manager_stop"]
        observations.append(value)
        write_json(output / (phase + ".json"), value)
        return value

    try:
        sqlite3.connect = connect
        subprocess.Popen = RecordingPopen
        os.environ.update(
            {
                "ERGOPTI_PHYSICAL_SOURCE_ROOT": str(root),
                "ERGOPTI_ROLLOVER_CASE": options.case,
                "ERGOPTI_ROLLOVER_STRATEGY": options.strategy,
                "TZ": "UTC",
            }
        )
        owned = Path(tempfile.mkdtemp(prefix="owned-", dir=output))
        device = owned / "metrics/by_device/device"
        device.mkdir(parents=True, mode=0o700)
        cache_dir = owned / "ergopti_metrics/device"
        cache_dir.mkdir(parents=True, mode=0o700)
        write_json(
            device / "device.json",
            {
                "device_id": "device",
                "name": "Controlled fixture",
                "os": "darwin",
                "os_version": "fixture",
                "host_signature": "fixture-host-identity",
                "created_at": "2026-10-20 12:00:00.000",
                "schema_version": 1,
            },
        )
        prepared = run("prepare")
        journal, ledger = device / "today.log", device / "data.sql"
        if options.strategy == "sqlite_open_refusal":
            database = cache_dir / "db.sqlite"
            database.rename(cache_dir / "retained-cache.sqlite")
            database.mkdir(mode=0o700)
            before = journal.read_bytes()
            before_receipt = (device / "data.sql.append-journal.json").read_bytes()
            run("reject_boot")
            assert journal.read_bytes() == before
            assert (device / "data.sql.append-journal.json").read_bytes() == before_receipt
        elif options.case in REJECT:
            if options.case == "nonprefix_marker_tail":
                with ledger.open("ab") as stream:
                    stream.write(b"X")
                target, target_bytes = ledger, ledger.read_bytes()
            elif options.case == "old_identity_grown":
                with journal.open("ab") as stream:
                    stream.write(b"changed-owned-source\n")
                target, target_bytes = journal, journal.read_bytes()
            else:
                original_identity = journal.stat().st_ino
                journal.rename(device / "retained-old-journal")
                target = device / "owned-replacement"
                target.write_bytes(b"replacement-owned-source\n")
                target_bytes = target.read_bytes()
                if options.case == "old_path_symlink":
                    journal.symlink_to(target)
                else:
                    target.rename(journal)
                    target = journal
                    assert target.stat().st_ino != original_identity
            run("reject_boot")
            assert target.read_bytes() == target_bytes, (
                "Rejected recovery must preserve unowned bytes"
            )
        else:
            if options.cache == "cold":
                database = cache_dir / "db.sqlite"
                assert database.is_file() and not (cache_dir / "db.sqlite-journal").exists()
                # The prior child has actually exited; only its disposable cache is removed.
                database.unlink()
            run("cold_boot" if options.cache == "cold" else "warm_boot")
        if options.case == "reset_commit_refused":
            assert busy_used and len(read_holders) == 1
            assert all(
                read_holders[0][key]
                for key in ("real_reader_acquired", "real_commit_refused", "reader_closed")
            )
        final["qualified"] = True
    except BaseException as error:
        final["failure"] = {"type": type(error).__name__, "detail": str(error)}
        raise
    finally:
        sqlite3.connect = original_connect
        subprocess.Popen = original_popen
        for key, value in previous_environment.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        final.update(
            owned_directory=str(owned) if owned else None,
            children=children,
            finished_at=time.time(),
        )
        write_json(output / "terminal.json", final)


if __name__ == "__main__":
    main()

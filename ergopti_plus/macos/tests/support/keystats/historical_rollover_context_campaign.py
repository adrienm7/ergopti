"""Require healthy historical typing after cache loss or pending-outbox migration."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile


def run_campaign(root, lua, output, mode):
    fixture = (
        root / "static/ergopti_plus/macos/tests/support/keystats/cold_rollover_context_process.lua"
    )
    report = dict(verdict="UNVERIFIED", native_receipts=[], warm=None, cold=None)
    temporary = None

    def event(value):
        with (output / "native-events.jsonl").open("a") as stream:
            stream.write(json.dumps(value) + "\n")

    spec = importlib.util.spec_from_file_location(
        "cold_context_sqlite_bridge", root / "tools/diagnostics/hs274_persistence_test.py"
    )
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    bridge.ROOT = root
    os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"] = str(root)
    os.environ["TZ"] = "UTC"
    for key in ("LUA_INIT", "LUA_INIT_5_4", "LUA_PATH", "LUA_PATH_5_4"):
        os.environ.pop(key, None)

    base = dict(
        type="typing",
        app="Editor",
        title="Owned cold context regression",
        layout="azerty",
        is_fullscreen=False,
        in_meeting=False,
        mouse_clicks=0,
        mouse_scrolls=0,
        mouse_distance_px=0,
        pause_before_ms=0,
        battery_level=100,
        audio_volume=0,
        wpm=0,
    )
    payload = {
        "old": dict(
            base,
            timestamp="2026-10-20 23:59:59.900",
            text="x",
            rich_text="x",
            events=[["x", 0, {"s": False}]],
        ),
        "new": dict(
            base,
            timestamp="2026-10-21 00:00:00.100",
            text="y ",
            rich_text="y ",
            events=[["y", 0, {"s": False}], [" ", 100, {"s": False}]],
        ),
    }
    children, connections = [], []
    ordinary_popen, ordinary_connect = subprocess.Popen, sqlite3.connect

    class Child(ordinary_popen):
        def __init__(self, *args, **kwargs):
            kwargs["start_new_session"] = True
            super().__init__(*args, **kwargs)
            self.waited = False
            children.append(self)
            self.pgid, self.sid = os.getpgid(self.pid), os.getsid(self.pid)
            assert self.pgid == self.pid and self.sid == self.pid
            event(
                dict(
                    kind="native_child_started",
                    pid=self.pid,
                    pgid=self.pgid,
                    sid=self.sid,
                    argv=self.args,
                )
            )

        def wait(self, *args, **kwargs):
            status = super().wait(*args, **kwargs)
            self.waited = True
            event(dict(kind="native_actual_wait", pid=self.pid, exit_code=status))
            return status

    class Connection(sqlite3.Connection):
        def close(self):
            super().close()
            self.retired = True
            event(dict(kind="sqlite_actual_close"))

    def connect(*args, **kwargs):
        kwargs["factory"] = Connection
        connection = ordinary_connect(*args, **kwargs)
        connection.retired = False
        connections.append(connection)
        return connection

    def rows(path, sql):
        connection = connect(path, isolation_level=None)
        try:
            connection.row_factory = sqlite3.Row
            return [dict(row) for row in connection.execute(sql)]
        finally:
            connection.close()

    def group_absent(child):
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            return True
        return False

    def run(phase, owned):
        os.environ["ERGOPTI_COLD_NGRAM_PHASE"] = phase
        before = len(children)
        result = bridge.run_fixture(lua, str(owned), fixture)
        assert len(children) == before + 1
        child = children[-1]
        assert child.waited and child.returncode == 0 and group_absent(child)
        assert all(connection.retired for connection in connections)
        assert result["phase"] == phase
        cleanup = result["cleanup"]
        report["native_receipts"].append(
            dict(phase=phase, cleanup=cleanup, errors=result["errors"], warnings=result["warnings"])
        )
        for key in ("all_streams_closed", "timers_retired", "sqlite_retired", "manager_stop"):
            assert cleanup[key] is True, (phase, key, cleanup)
        assert result["errors"] == [], result["errors"]
        assert result["warnings"] == [], result["warnings"]
        event(dict(kind="phase_closed", phase=phase, pid=child.pid))
        return result

    def observation(result, today):
        value = result["first"]
        assert value == result["second"], "repeated ingest changed committed raw rows or metrics"
        assert value["offset"] == today.stat().st_size and value["offset"] > 0
        assert value["date"] == "2026-10-21"
        assert [row["id"] for row in value["raw"]] == [1, 2]
        for row, key in zip(value["raw"], ("old", "new")):
            expected = payload[key]
            for field, expected_field in (("ts", "timestamp"), ("app", "app"), ("text", "text")):
                assert row[field] == expected[expected_field]
            assert row["date"] == expected["timestamp"][:10]
            assert json.loads(row["events_json"]) == expected["events"]
        meta = {row["key"]: row["value"] for row in value["meta"]}
        assert meta["local_data_sql_outbox"] == ""
        assert int(meta["today_log_offset"]) == today.stat().st_size
        assert meta["today_log_date"] == "2026-10-21"

        def count(table, token, day="2026-10-21"):
            return sum(
                row["c"]
                for row in value[table]
                if row["date"] == day and row["app"] == "Editor" and row["token"] == token
            )

        assert count("chars", "x", "2026-10-20") == 1
        assert count("chars", "y") == 1 and count("chars", " ") == 1
        for day, expected in (("2026-10-20", 1), ("2026-10-21", 2)):
            assert sum(row["c"] for row in value["chars"] if row["date"] == day) == expected
        vector = dict(
            word_y=count("words", "y"),
            word_xy=count("words", "xy"),
            bigram_xy=count("bigrams", "xy"),
            bigram_y_space=count("bigrams", "y "),
            trigram_xy_space=count("trigrams", "xy "),
        )
        return value, vector

    healthy = dict(word_y=1, word_xy=0, bigram_xy=0, bigram_y_space=1, trigram_xy_space=0)

    subprocess.Popen, sqlite3.connect = Child, connect
    try:
        with tempfile.TemporaryDirectory(prefix="historical-canonical-", dir=output) as temporary:
            owned = Path(temporary)
            device = owned / "metrics/by_device/device"
            device.mkdir(parents=True)
            cache = owned / "ergopti_metrics/device/db.sqlite"
            cache.parent.mkdir(parents=True)
            identity = device / "device.json"
            identity.write_text(
                json.dumps(
                    dict(
                        device_id="device",
                        name="Controlled fixture",
                        os="darwin",
                        os_version="fixture",
                        host_signature="fixture-host-identity",
                        created_at="2026-10-20 12:00:00.000",
                        schema_version=1,
                    )
                )
            )
            payload_path = owned / "typing-payload.json"
            payload_path.write_text(json.dumps(payload))
            os.environ["ERGOPTI_COLD_NGRAM_PAYLOAD"] = str(payload_path)
            try:
                run("seed", owned)
                ledger, today = device / "data.sql", device / "today.log"
                meta = {
                    row["key"]: row["value"] for row in rows(cache, "SELECT key,value FROM meta")
                }
                assert (
                    json.loads(meta["ngram_ctx_json"]) == {} and meta["local_data_sql_outbox"] == ""
                )
                assert meta["today_log_offset"] == "0" and meta["today_log_date"] == "2026-10-21"
                raw = rows(cache, "SELECT text,events_json FROM events_typing ORDER BY id")
                assert len(raw) == 1 and raw[0]["text"] == "x"
                assert json.loads(raw[0]["events_json"]) == payload["old"]["events"]
                assert [json.loads(line) for line in today.read_text().splitlines()] == [
                    payload["new"]
                ]
                assert (
                    ledger.read_text().count("-- === day rollover 2026-10-20 -> 2026-10-21 ===")
                    == 1
                )
                assert payload["new"]["timestamp"] not in ledger.read_text()
                seed_ledger = ledger.read_bytes()
                sidecar = Path(str(ledger) + ".append-journal.json")
                seed_sidecar = sidecar.read_bytes()
                # Warm public bootstrap commits the new row AFTER the real rollover.
                warm_result = run("warm", owned)
                report["warm"] = warm_result
                warm, warm_vector = observation(warm_result, today)
                report["warm_vector"] = warm_vector
                assert warm_vector == healthy, "healthy committed rollover oracle failed"
                ledger_bytes = ledger.read_bytes()
                marker = b"-- === day rollover 2026-10-20 -> 2026-10-21 ==="
                marker_at = ledger_bytes.index(marker)
                assert ledger_bytes.count(marker) == 1 and b"Compacted by" not in ledger_bytes
                assert ledger_bytes.index(payload["old"]["timestamp"].encode()) < marker_at
                assert ledger_bytes.index(payload["new"]["timestamp"].encode()) > marker_at
                assert ledger_bytes.rfind(b"\nCOMMIT;\n") > marker_at
                assert len(warm["raw"]) == 2 and warm["offset"] == today.stat().st_size
                paths = [identity, ledger, Path(str(ledger) + ".append-journal.json"), today]
                snapshot_files = [
                    (path, path.read_bytes(), path.stat().st_dev, path.stat().st_ino)
                    for path in paths
                ]
                report["postwarm_canonical"] = [
                    dict(path=str(path), sha256=hashlib.sha256(data).hexdigest(), dev=dev, ino=ino)
                    for path, data, dev, ino in snapshot_files
                ]
                assert all(child.waited and group_absent(child) for child in children)
                assert all(connection.retired for connection in connections)
                for suffix in ("-journal", "-wal", "-shm"):
                    assert not Path(str(cache) + suffix).exists()
                for path, data, dev, ino in snapshot_files:
                    assert path.is_file() and not path.is_symlink() and path.read_bytes() == data
                    assert (path.stat().st_dev, path.stat().st_ino) == (dev, ino)
                if mode == "cold":
                    # Snapshot is AFTER the new raw row committed beyond the marker.
                    cache.unlink()
                    assert not cache.exists()
                else:
                    # Restore only owned source bytes, retaining the real committed raw cache.
                    # This is the state before the final append attempt.
                    pending_batch = ledger_bytes[len(seed_ledger) :]
                    assert pending_batch.startswith(b"\n-- === ingest batch ")
                    for path, data in ((ledger, seed_ledger), (sidecar, seed_sidecar)):
                        with path.open("r+b") as stream:
                            stream.write(data)
                            stream.truncate()
                    connection = connect(cache, isolation_level=None)
                    try:
                        connection.execute("BEGIN TRANSACTION")
                        connection.execute(
                            "UPDATE meta SET value=? WHERE key='local_data_sql_outbox'",
                            (pending_batch.decode(),),
                        )
                        connection.execute(
                            "UPDATE meta SET value='1' WHERE key='aggregate_cache_revision'"
                        )
                        connection.execute("COMMIT")
                    finally:
                        connection.close()
                    assert ledger.read_bytes() == seed_ledger
                    assert payload["new"]["timestamp"].encode() not in seed_ledger
                    assert all(connection.retired for connection in connections)
                cold_result = run("cold", owned)
                report["cold"] = cold_result
                cold, cold_vector = observation(cold_result, today)
                report["cold_vector"] = cold_vector
                before = cold_result["before_ingest"]
                assert before["raw"] == warm["raw"] and before["offset"] == warm["offset"]
                assert cold["raw"] == warm["raw"] and cold["chars"] == warm["chars"]
                for path, data, dev, ino in snapshot_files:
                    # Retrying the owned outbox publishes a fresh settled receipt.
                    # The actual ledger, identity and today bytes must still match.
                    if mode == "cold" or path != sidecar:
                        assert path.read_bytes() == data, (
                            "recovery modified canonical fixture bytes"
                        )
                    if path in (ledger, today):
                        assert (path.stat().st_dev, path.stat().st_ino) == (dev, ino)
                report["ledger_today_identity_bytes_preserved"] = True
                report["sidecar_bytes_preserved"] = (
                    sidecar.read_bytes()
                    == dict((path, data) for path, data, _, _ in snapshot_files)[sidecar]
                )
                report["ledger_today_inodes_preserved"] = True
                receipt = json.loads(sidecar.read_bytes())
                assert receipt["version"] == 1 and receipt["phase"] == "settled"
                assert receipt["path"] == str(ledger)
                assert (receipt["dev"], receipt["ino"]) == (
                    ledger.stat().st_dev,
                    ledger.stat().st_ino,
                )
                batch_bytes = receipt["batch"].encode()
                assert receipt["offset"] + len(batch_bytes) == ledger.stat().st_size
                assert ledger.read_bytes()[receipt["offset"] :] == batch_bytes
                assert cold_vector == healthy, (
                    "historical rollover replay bridged retired typing",
                    mode,
                    warm_vector,
                    cold_vector,
                )
                assert all(cold[key] == warm[key] for key in ("words", "bigrams", "trigrams")), (
                    "historical counts differ"
                )
                before_meta = {
                    row["key"]: row["value"] for row in cold_result["before_ingest"]["meta"]
                }
                warm_meta = {row["key"]: row["value"] for row in warm["meta"]}
                for key in ("today_log_offset", "today_log_date", "next_event_id"):
                    assert before_meta[key] == warm_meta[key], (
                        "rebuild changed raw cursor ownership",
                        mode,
                        key,
                    )
                assert json.loads(before_meta["ngram_ctx_json"]) == json.loads(
                    warm_meta["ngram_ctx_json"]
                ), ("rebuild did not persist the current generation context", mode)
                assert before["live_context"] == json.loads(before_meta["ngram_ctx_json"]), (
                    "live context differs from the acknowledged rebuilt context",
                    mode,
                )
                if mode == "outbox":
                    assert before_meta["local_data_sql_outbox"] == pending_batch.decode()
                    assert (
                        before_meta["aggregate_cache_revision"] == meta["aggregate_cache_revision"]
                    )
                report["verdict"] = "HEALTHY"
                assert len(children) == 3
            finally:
                cleanup_errors = []
                for child in children:
                    try:
                        if not group_absent(child):
                            os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)
                        assert group_absent(child), "owned child process group remains"
                    except BaseException as error:
                        cleanup_errors.append(repr(error))
                for connection in connections:
                    try:
                        if not connection.retired:
                            connection.close()
                    except BaseException as error:
                        cleanup_errors.append(repr(error))
                report["cleanup_errors"] = cleanup_errors
                assert all(child.waited and group_absent(child) for child in children)
                assert all(connection.retired for connection in connections)
                assert not cleanup_errors, cleanup_errors
        assert not Path(temporary).exists(), "owned fixture directory remains"
    except BaseException as error:
        report["error"] = repr(error)
        raise
    finally:
        subprocess.Popen, sqlite3.connect = ordinary_popen, ordinary_connect
        report["children"] = [
            dict(
                pid=child.pid,
                pgid=child.pgid,
                sid=child.sid,
                actual_wait_returned=child.waited,
                exit_code=child.returncode,
                group_absent=group_absent(child),
            )
            for child in children
        ]
        report["sqlite_connections"] = len(connections)
        report["sqlite_connections_closed"] = sum(connection.retired for connection in connections)
        report["temporary_removed"] = temporary is None or not Path(temporary).exists()
        report["SAFE"] = (
            all(child.waited and group_absent(child) for child in children)
            and all(connection.retired for connection in connections)
            and report["temporary_removed"]
            and not report.get("cleanup_errors")
            and len(report["native_receipts"]) == len(children)
            and all(
                all(
                    receipt["cleanup"].get(key) is True
                    for key in (
                        "all_streams_closed",
                        "timers_retired",
                        "sqlite_retired",
                        "manager_stop",
                    )
                )
                for receipt in report["native_receipts"]
            )
        )
        report["regression_passed"] = (
            report["verdict"] == "HEALTHY"
            and report["SAFE"]
            and len(children) == 3
            and all(child.returncode == 0 for child in children)
        )
        (output / "CAMPAIGN.json").write_text(json.dumps(report, indent=2) + "\n")
    assert report["regression_passed"], report


def main():
    root, lua = Path(sys.argv[1]).resolve(), sys.argv[2]
    mode = sys.argv[3]
    assert mode in ("cold", "outbox")
    with tempfile.TemporaryDirectory(prefix="ergopti-historical-rollover-") as directory:
        run_campaign(root, lua, Path(directory), mode)
    assert not Path(directory).exists(), "owned campaign directory remains"
    print("PASS: completed rollovers preserve independent historical typing")


if __name__ == "__main__":
    main()

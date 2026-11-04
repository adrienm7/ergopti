"""Compare healthy rollover with recovery of identical owned canonical files."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile


def main():
    root, lua = Path(sys.argv[1]).resolve(), sys.argv[2]
    fixture = Path(__file__).with_name("cold_rollover_context_process.lua")
    spec = importlib.util.spec_from_file_location(
        "cold_context_sqlite_bridge", root / "tools/diagnostics/hs274_persistence_test.py"
    )
    bridge = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bridge)
    bridge.ROOT = root
    os.environ["ERGOPTI_PHYSICAL_SOURCE_ROOT"] = str(root)
    os.environ["TZ"] = "UTC"
    for key in ("LUA_INIT", "LUA_INIT_5_4"):
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
            assert os.getpgid(self.pid) == self.pid and os.getsid(self.pid) == self.pid

        def wait(self, *args, **kwargs):
            status = super().wait(*args, **kwargs)
            self.waited = True
            return status

    class Connection(sqlite3.Connection):
        def close(self):
            super().close()
            self.retired = True

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
        for key in ("all_streams_closed", "timers_retired", "sqlite_retired", "manager_stop"):
            assert cleanup[key] is True, (phase, key, cleanup)
        assert result["errors"] == [], result["errors"]
        return result

    def oracle(result, today):
        before = result["before_ingest"]
        assert len(before["raw"]) == 1 and before["raw"][0]["text"] == "x"
        meta = {row["key"]: row["value"] for row in before["meta"]}
        assert json.loads(meta["ngram_ctx_json"]) == {}, "persisted retired context was revived"
        assert before["live_context"] == {}, "live retired context was revived"
        assert meta["today_log_offset"] == "0" and meta["today_log_date"] == "2026-10-21"
        observation = result["first"]
        assert observation == result["second"], "repeated ingest duplicated raw rows or metrics"
        assert observation["offset"] == today.stat().st_size
        assert observation["date"] == "2026-10-21"
        assert [row["id"] for row in observation["raw"]] == [1, 2]
        for row, key in zip(observation["raw"], ("old", "new")):
            expected = payload[key]
            for field, expected_field in (("ts", "timestamp"), ("app", "app"), ("text", "text")):
                assert row[field] == expected[expected_field]
            assert row["date"] == expected["timestamp"][:10]
            assert json.loads(row["events_json"]) == expected["events"]

        def count(table, token, day="2026-10-21"):
            return sum(
                row["c"]
                for row in observation[table]
                if row["date"] == day and row["app"] == "Editor" and row["token"] == token
            )

        assert count("words", "y") == 1 and count("words", "xy") == 0
        assert count("bigrams", "xy") == 0 and count("bigrams", "y ") == 1
        assert count("trigrams", "xy ") == 0
        assert count("chars", "x", "2026-10-20") == 1
        assert count("chars", "y") == 1 and count("chars", " ") == 1
        for day, expected in (("2026-10-20", 1), ("2026-10-21", 2)):
            assert sum(row["c"] for row in observation["chars"] if row["date"] == day) == expected
        return observation

    subprocess.Popen, sqlite3.connect = Child, connect
    try:
        with tempfile.TemporaryDirectory(prefix="ergopti-cold-context-") as temporary:
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
                paths = [identity, ledger, Path(str(ledger) + ".append-journal.json"), today, cache]
                snapshot = [
                    (path, path.read_bytes(), path.stat().st_dev, path.stat().st_ino)
                    for path in paths
                ]
                warm = oracle(run("warm", owned), today)
                # Every previous child has actually exited and every SQLite handle
                # closed before restoring this private, receipt-bound fixture.
                assert all(child.waited and group_absent(child) for child in children)
                assert all(connection.retired for connection in connections)
                for suffix in ("-journal", "-wal", "-shm"):
                    assert not Path(str(cache) + suffix).exists()
                for path, data, dev, ino in snapshot:
                    assert path.is_file() and not path.is_symlink()
                    if path in (ledger, today):
                        assert (path.stat().st_dev, path.stat().st_ino) == (dev, ino)
                    with path.open("r+b") as stream:
                        stream.write(data)
                        stream.truncate()
                    assert path.read_bytes() == data
                    if path in (ledger, today):
                        assert (path.stat().st_dev, path.stat().st_ino) == (dev, ino)
                cache.unlink()
                assert not cache.exists()
                for path, data, _, _ in snapshot[:-1]:
                    assert path.read_bytes() == data
                cold = oracle(run("cold", owned), today)
                assert cold == warm, "cache loss changed the healthy rollover observation"
                assert len(children) == 3
            finally:
                for child in children:
                    if not group_absent(child):
                        os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                    assert group_absent(child), "owned child process group remains"
                for connection in connections:
                    if not connection.retired:
                        connection.close()
                assert all(child.waited and group_absent(child) for child in children)
                assert all(connection.retired for connection in connections)
        assert not Path(temporary).exists(), "owned fixture directory remains"
    finally:
        subprocess.Popen, sqlite3.connect = ordinary_popen, ordinary_connect
    print("PASS: healthy and cold rollover preserve the same fresh context")


if __name__ == "__main__":
    main()

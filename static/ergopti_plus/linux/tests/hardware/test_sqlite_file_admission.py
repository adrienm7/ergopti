"""SQLite startup must classify native files without waiting on special paths."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


NATIVE_RUNTIME = None
NATIVE_CPATH = None


PROBE = """
local driver = arg[4]
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;'
  .. driver .. '/../_shared/lua/?.lua;' .. driver .. '/../_shared/lua/?/init.lua;' .. package.path
require('compat.utf8').install()
local mode, database, resource = arg[1], arg[2], arg[3]
local paths = require('infra.paths')
local shared = paths.shared
if mode == 'schema_fifo' then
  paths.shared = function(name)
    if name == 'data/db/schema.sql' then return resource end
    return shared(name)
  end
end
local writer = require('modules.keystats.sqlite_writer')
local refused = mode ~= 'absent' and mode ~= 'empty'
local selected = mode == 'nul_fifo' and (database .. string.char(0) .. 'suffix') or database
local opened = writer.open_db(selected)
if refused then
  assert(opened == false, 'special source must refuse database startup')
  assert(writer.get_db_path() == nil, 'refusal must release path admission')
  assert(writer.is_available() == false, 'refusal must not expose a store')
  paths.shared = shared
  database = database .. '.recovered'
  assert(writer.open_db(database), 'a refused special source must not poison the next open')
else
  assert(opened == true, 'regular and absent files must still admit actual SQLite startup')
end
assert(writer.exec_sql([[CREATE TABLE owned_probe (value TEXT); INSERT INTO owned_probe VALUES ('retained');]]))
assert(writer.query_rows('SELECT value FROM owned_probe;')[1] == 'retained')
writer.close_db()
assert(writer.open_db(database), 'the nonempty database must reopen without replacement')
assert(writer.query_rows('SELECT value FROM owned_probe;')[1] == 'retained')
writer.close_db()
local alias = database .. '.alias'
assert(require('luv').fs_symlink(database, alias))
assert(writer.open_db(alias), 'a regular-file symlink must retain native database identity')
assert(writer.query_rows('SELECT value FROM owned_probe;')[1] == 'retained')
writer.close_db()
io.write(refused and 'classified refusal\\n' or 'native admission\\n')
"""


class SqliteFileAdmissionTests(unittest.TestCase):
    """Run real writer startup in bounded independent Lua processes."""

    def run_writer(self, runtime, root, mode):
        driver = Path(__file__).resolve().parents[2]
        database = root / "metrics.sqlite"
        resource = root / "schema.sql"
        if mode in ("database_fifo", "nul_fifo"):
            os.mkfifo(database)
        elif mode == "schema_fifo":
            os.mkfifo(resource)
        elif mode == "fifo_symlink":
            os.mkfifo(resource)
            database.symlink_to(resource)
        elif mode == "directory":
            database.mkdir()
        elif mode == "empty":
            database.touch()
        elif mode == "unreadable":
            database.touch()
            database.chmod(0)
        script = root / "probe.lua"
        script.write_text(PROBE, encoding="utf-8")
        environment = dict(os.environ)
        # A suite row supplies its exact interpreter and admitted native ABI.
        # Standalone cross-ABI runs must not lend one runtime's paths to another.
        environment.pop("LUA_PATH", None)
        environment.pop("LUA_CPATH", None)
        if NATIVE_RUNTIME is not None and os.path.samefile(runtime, NATIVE_RUNTIME):
            environment["LUA_CPATH"] = NATIVE_CPATH
        return subprocess.run(
            [runtime, str(script), mode, str(database), str(resource), str(driver)],
            env=environment,
            cwd=driver,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_native_startup_admission_and_recovery(self):
        # A suite row replays only the interpreter it runs on: the distribution
        # and Ubuntu integration rows install no lua5.4. Run standalone, as the
        # platform-metrics E2E shard does, the file covers both ABIs.
        runtimes = (NATIVE_RUNTIME,) if NATIVE_RUNTIME is not None else ("luajit", "lua5.4")
        for runtime_name in runtimes:
            runtime = shutil.which(runtime_name)
            self.assertIsNotNone(runtime, "Native file admission requires " + runtime_name)
            for mode in (
                "database_fifo",
                "schema_fifo",
                "fifo_symlink",
                "nul_fifo",
                "directory",
                "unreadable",
                "absent",
                "empty",
            ):
                with (
                    self.subTest(runtime=runtime_name, mode=mode),
                    tempfile.TemporaryDirectory() as temporary,
                ):
                    result = self.run_writer(runtime, Path(temporary), mode)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    expected = (
                        "native admission" if mode in ("absent", "empty") else "classified refusal"
                    )
                    self.assertIn(expected, result.stdout)
                    print(
                        f"Native SQLite admission: runtime={runtime_name} mode={mode}", flush=True
                    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", help="Exact interpreter admitted by the calling suite row")
    parser.add_argument("--cpath", help="Native module search path admitted for that interpreter")
    arguments, remaining = parser.parse_known_args()
    if (arguments.runtime is None) != (arguments.cpath is None):
        parser.error("--runtime and --cpath must be supplied together")
    NATIVE_RUNTIME = shutil.which(arguments.runtime) if arguments.runtime is not None else None
    if arguments.runtime is not None and NATIVE_RUNTIME is None:
        parser.error("the admitted native runtime must be executable")
    NATIVE_CPATH = arguments.cpath
    unittest.main(argv=[sys.argv[0], *remaining])

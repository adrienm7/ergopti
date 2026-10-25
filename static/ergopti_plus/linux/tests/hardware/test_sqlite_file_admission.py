"""SQLite startup must classify native files without waiting on special paths."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


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
        # A LuaJIT runner exports its 5.1 module paths to children. Each native
        # ABI must use its own loader defaults instead of that inherited ABI.
        environment.pop("LUA_PATH", None)
        environment.pop("LUA_CPATH", None)
        return subprocess.run(
            [runtime, str(script), mode, str(database), str(resource), str(driver)],
            env=environment,
            cwd=driver,
            capture_output=True,
            text=True,
            timeout=5,
        )

    def test_native_startup_admission_and_recovery(self):
        for runtime_name in ("luajit", "lua5.4"):
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


if __name__ == "__main__":
    unittest.main()

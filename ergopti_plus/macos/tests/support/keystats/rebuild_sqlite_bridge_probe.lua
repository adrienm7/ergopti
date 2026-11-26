--- tests/support/keystats/rebuild_sqlite_bridge_probe.lua

--- ==============================================================================
--- MODULE: Real SQLite rebuild bridge probe
--- DESCRIPTION:
--- Exercises the Lua protocol against two real SQLite connections, a private
--- TEMP schema and an attached database. Backup progress is fixture controlled.
--- ==============================================================================

local root, temporary = assert(arg[1]), assert(arg[2])
local driver = root .. "/static/ergopti_plus/macos"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. root .. "/static/ergopti_plus/_shared/?.lua;" .. package.path
local json = require("core.text.engine.json")
local function request(message)
	message.kind = "request"
	assert(io.stdout:write(json.encode(message) .. "\n")); assert(io.stdout:flush())
	return assert(json.decode(assert(io.stdin:read("*l"))))
end
local sqlite = require("tests.support.keystats.rebuild_sqlite_bridge").new(request)
local stage = assert(sqlite.open(""))
local destination_path = temporary .. "/destination.sqlite"
local owner = assert(sqlite.open(destination_path))
local observer = assert(sqlite.open(destination_path))
assert(owner:exec("CREATE TABLE keep(v); INSERT INTO keep VALUES (7);") == sqlite.OK)
assert(stage:exec("CREATE TEMP TABLE built(v); INSERT INTO built VALUES (42);") == sqlite.OK)
assert(owner:exec("ATTACH DATABASE '' AS staged;") == sqlite.OK)
assert(request({ op = "configure", backup_pages = 300 }).ok)
local before = owner:nrows("SELECT total_changes() AS n;")().n
local backup = assert(sqlite.backup_init(owner, "staged", stage, "temp"))
assert(backup:step(128) == sqlite.OK)
assert(backup:step(128) == sqlite.OK)
assert(backup:step(128) == sqlite.DONE)
assert(backup:finish() == sqlite.OK)
assert(owner:nrows("SELECT total_changes() AS n;")().n == before)
assert(request({ op = "inject", operation = "exec", codes = { 10 } }).ok)
assert(owner:exec("DELETE FROM keep;") == 10)
local rows = owner:nrows("SELECT v FROM staged.built;")
assert(rows().v == 42 and rows() == nil)
assert(owner:exec("BEGIN IMMEDIATE; INSERT INTO keep SELECT v FROM staged.built; COMMIT;") == sqlite.OK)
local observed = observer:nrows("SELECT v FROM keep ORDER BY v;")
assert(observed().v == 7 and observed().v == 42 and observed() == nil)
assert(owner:exec("DETACH DATABASE staged;") == sqlite.OK)
assert(request({ op = "inject", operation = "finish", codes = { 10 } }).ok)
local pending = assert(sqlite.backup_init(owner, "main", stage, "temp"))
assert(pending:finish() == 10)
assert(not pcall(pending.finish, pending))
local extra = assert(sqlite.open(""))
assert(request({ op = "inject", operation = "close", codes = { 10 } }).ok)
assert(extra:close() == 10)
assert(not pcall(extra.close, extra))
assert(stage:close() == sqlite.OK)
assert(observer:close() == sqlite.OK)
assert(owner:close() == sqlite.OK)
assert(io.stdout:write(json.encode({ kind = "done", ok = true }) .. "\n")); assert(io.stdout:flush())

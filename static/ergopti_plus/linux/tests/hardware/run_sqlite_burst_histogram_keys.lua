--- tests/hardware/run_sqlite_burst_histogram_keys.lua
--- ==============================================================================
--- MODULE: Native SQLite Burst Histogram Keys (Linux)
--- DESCRIPTION:
--- Public supplied burst records use real SQLite and owned files. An independent
--- CLI reads json_valid and json_each/hex(key), proving key bytes and repeated
--- merge counts without the writer's JSON encoder or reader projection. Normal
--- collection uses numeric and 500+ labels; custom supplied labels exercise the
--- public writer boundary. NUL key projection is outside this regression.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local Shell = require("adapters.shell_runner")
local Writer = require("modules.keylogger.sqlite_writer")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-sqlite-burst-keys-XXXXXX"))
local database = root .. "/metrics.sqlite"
local checks, failures = 0, 0

local function check(name, body)
	checks = checks + 1
	local ok, reason = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(reason) .. "\n")
	end
end

local function hex(value)
	return (value:gsub(".", function(byte) return string.format("%02X", byte:byte()) end))
end

local function query(sql)
	local pipe = assert(io.popen("sqlite3 -batch -readonly " .. Shell.quote(database)
		.. " " .. Shell.quote(sql) .. " 2>/dev/null", "r"))
	local output = assert(pipe:read("*a"))
	pipe:close()
	return output
end

assert(Writer.open_db(database))
assert(Writer.register_device("owned-burst", "owned-burst", "linux", "", ""))
local cases = { 10, "500+", "owned\\bucket", "owned\\literal", 'quoted" clé',
	"LF\nCR\rtab\tcontrol\1\31", "apostrophe's" }
for index, key in ipairs(cases) do
	local app = "owned-key-" .. index
	local row = { date = "2000-01-01", app = app, count_total = 1, length_buckets = { [key] = 2.9 } }
	assert(Writer.upsert_burst("owned-burst", row), "first native fixture write refused")
	check("first supplied key " .. index .. " is valid JSON with exact native bytes", function()
		assert(query("SELECT json_valid(length_buckets_json) FROM agg_app_day_burst WHERE app='" .. app .. "';") == "1\n")
		assert(query("SELECT hex(key)||'|'||value FROM agg_app_day_burst,json_each(length_buckets_json) WHERE app='"
			.. app .. "';") == hex(tostring(key)) .. "|2\n", "native json_each changed the key or count")
	end)
	check("same supplied key " .. index .. " merges on a healthy second public write", function()
		assert(Writer.upsert_burst("owned-burst", row), "second public write refused")
		assert(query("SELECT hex(key)||'|'||value FROM agg_app_day_burst,json_each(length_buckets_json) WHERE app='"
			.. app .. "';") == hex(tostring(key)) .. "|4\n")
		assert(query("SELECT count_total FROM agg_app_day_burst WHERE app='" .. app .. "';") == "2\n")
		assert(row.length_buckets[key] == 2.9, "writer mutated caller counts")
	end)
end

for _, row in ipairs({ { date = "2000-01-01", app = "owned-missing" },
	{ date = "2000-01-01", app = "owned-empty", length_buckets = {} } }) do
	check(row.app .. " retains zero counters and the empty-object default", function()
		assert(Writer.upsert_burst("owned-burst", row))
		assert(query("SELECT count_total,max_cpm,max_chars,length_buckets_json,inter_delay_count,inter_delay_sum,inter_delay_sumsq"
			.. " FROM agg_app_day_burst WHERE app='" .. row.app .. "';") == "0|0.0|0|{}|0|0|0\n")
	end)
end

check("positive numeric counts retain filtering and flooring", function()
	assert(Writer.upsert_burst("owned-burst", { date = "2000-01-01", app = "owned-filter",
		length_buckets = { [10] = 2.9, ["500+"] = 1, small = 0.9, zero = 0,
			negative = -2, numeric_text = "3", boolean = true } }))
	assert(query("SELECT hex(key)||'|'||value FROM agg_app_day_burst,json_each(length_buckets_json)"
		.. " WHERE app='owned-filter' ORDER BY key;") == "3130|2\n3530302B|1\n736D616C6C|0\n")
end)

check("real SQLite statement refusal leaves the row unchanged and allows retry", function()
	assert(Writer.exec_sql("CREATE TRIGGER owned_refuse BEFORE UPDATE ON agg_app_day_burst"
		.. " WHEN NEW.app='owned-key-1' BEGIN SELECT RAISE(ABORT,'owned refusal'); END;"))
	local row = { date = "2000-01-01", app = "owned-key-1", count_total = 1, length_buckets = { [10] = 2 } }
	assert(Writer.upsert_burst("owned-burst", row) == false)
	assert(query("SELECT count_total,length_buckets_json FROM agg_app_day_burst WHERE app='owned-key-1';") == '2|{"10":4}\n')
	assert(Writer.exec_sql("DROP TRIGGER owned_refuse;"))
	assert(Writer.upsert_burst("owned-burst", row))
	assert(query("SELECT count_total,length_buckets_json FROM agg_app_day_burst WHERE app='owned-key-1';") == '3|{"10":6}\n')
end)

Writer.close_db()
for name in uv.fs_scandir_next, assert(uv.fs_scandir(root)) do assert(uv.fs_unlink(root .. "/" .. name)) end
assert(uv.fs_rmdir(root))
assert(checks == 18, "native histogram regression check floor changed")
print(string.format("Native SQLite burst histogram keys: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

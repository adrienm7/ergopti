--- tests/hardware/run_sqlite_ngram_source_maps.lua

--- ==============================================================================
--- MODULE: Native N-gram Source Map Accumulation Proof
--- DESCRIPTION:
--- Exercises public software synthetic output and actual SQLite Writer conflicts.
--- Literal source keys accumulate while scalar fields and input admission stay
--- unchanged. Optional snapshots support an independent readonly Python oracle.
--- Uses native libuv and the real monotonic clock; no physical collection claim.
--- ==============================================================================
local uv = require("luv")
require("compat.utf8").install()
local proof = arg[1]
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-source-map-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local K = require("modules.keylogger.keylogger")
local W = require("modules.keylogger.sqlite_writer")
local Clock = require("infra.monotonic")
local J = require("json")
local path, today = root .. "/metrics.sqlite", os.date("%Y-%m-%d")
K.init({ sqlite_path = path, log_dir = root .. "/logs" })
assert(K.is_enabled() and W.is_available())
local checks, failures = 0, 0
local function check(name, body)
	checks = checks + 1
	local ok, err = xpcall(body, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end
local function rows(sql) return assert(W.query_rows(sql)) end
local function source_map(app)
	return J.decode(assert(rows("SELECT esrc_json FROM ngram_chars WHERE app='" .. app .. "' AND token='x';")[1]))
end
local function synth(app, text, tag) K.record_synthetic_output(app, text, tag, math.floor(Clock.now_ms()), 0, 0) end
synth("owned-public", "xx", "extension")
K.flush()
check("first public synthetic batch admits arbitrary literal source label", function()
	local map = source_map("owned-public")
	assert(map.extension == 2)
	assert(rows("SELECT c,td,cd,e FROM ngram_chars WHERE app='owned-public' AND token='x';")[1] == "2|0|0|0")
end)
if proof then assert(W.exec_sql("VACUUM INTO '" .. proof .. "/first.sqlite';")) end
synth("owned-public", "x", "extension")
synth("owned-public", "x", "paste")
K.flush()
print("SQL public-second=" .. tostring(rows("SELECT c,td,cd,e,esrc_json FROM ngram_chars WHERE app='owned-public' AND token='x';")[1]))
check("second same-device token flush retains additive arbitrary source counters", function()
	local map = source_map("owned-public")
	assert(map.extension == 3 and map.paste == 1)
	assert(rows("SELECT c,td,cd,e FROM ngram_chars WHERE app='owned-public' AND token='x';")[1] == "4|0|0|0")
end)
check("actual raw event metadata retains all four source-tagged synthetic entries", function()
	local raw = rows("SELECT events_json FROM events_typing WHERE app='owned-public' ORDER BY id;")
	assert(#raw == 2)
	local first, second = J.decode(raw[1]), J.decode(raw[2])
	assert(#first == 2 and #second == 2)
	assert(first[1][1] == "x" and first[2][1] == "x" and first[1][3].st == "extension" and first[2][3].st == "extension")
	assert(second[1][1] == "x" and second[2][1] == "x" and second[1][3].st == "extension" and second[2][3].st == "paste")
	for _, batch in ipairs({ first, second }) do for _, event in ipairs(batch) do assert(event[3].s == 1) end end
end)
for _ = 1, 2 do
	for _, tag in ipairs({ "hotstring", "llm", "other" }) do synth("owned-recognized", "x", tag) end
	K.flush()
end
check("recognized hotstring llm other counters keep their additive public semantics", function()
	local map = source_map("owned-recognized")
	assert(map.hotstring == 2 and map.llm == 2 and map.other == 2)
	assert(rows("SELECT c FROM ngram_chars WHERE app='owned-recognized' AND token='x';")[1] == "6")
end)
K.on_keydown("x", math.floor(Clock.now_ms()), "owned-manual")
K.flush()
K.on_keydown("x", math.floor(Clock.now_ms()), "owned-manual")
K.flush()
check("manual none events do not invent synthetic attribution", function()
	local map = source_map("owned-manual")
	assert(map.none == nil and (map.hotstring or 0) == 0 and (map.llm or 0) == 0 and (map.other or 0) == 0)
	assert(rows("SELECT c FROM ngram_chars WHERE app='owned-manual' AND token='x';")[1] == "2")
end)
assert(W.register_device("owned-direct", "owned direct", "linux", "", ""))
assert(W.upsert_ngrams("owned-direct", "2000-01-01", "owned-direct", { x = { c = 4, td = 7, cd = 2, e = 1, sources = { extension = 2, hotstring = 1 } } }))
assert(W.upsert_ngrams("owned-direct", "2000-01-01", "owned-direct", { x = { c = 7, td = 13, cd = 3, e = 2, sources = { extension = 1, paste = 3, llm = 1, other = 2 } } }))
check("unrelated native c td cd e scalar contributions remain exact", function()
	assert(rows("SELECT c,td,cd,e FROM ngram_chars WHERE app='owned-direct' AND token='x';")[1] == "11|20|5|3")
end)
check("direct Writer merges arbitrary and recognized map contributions together", function()
	local map = source_map("owned-direct")
	assert(map.extension == 3 and map.paste == 3 and map.hotstring == 1 and map.llm == 1 and map.other == 2)
end)
assert(W.register_device("owned-second", "owned second", "linux", "", ""))
assert(W.upsert_ngrams("owned-second", "2000-01-01", "owned-direct", { x = { c = 5, sources = { extension = 4 } } }))
assert(W.upsert_ngrams("owned-direct", "1999-01-01", "owned-direct", { x = { c = 2, sources = { extension = 1 } } }))
check("other device and historical date remain independent healthy rows", function()
	assert(rows("SELECT c,json_extract(esrc_json,'$.extension') FROM ngram_chars WHERE device_id='owned-second';")[1] == "5|4")
	assert(rows("SELECT c,json_extract(esrc_json,'$.extension') FROM ngram_chars WHERE device_id='owned-direct' AND date='1999-01-01';")[1] == "2|1")
	assert(rows("SELECT SUM(c) FROM ngram_chars WHERE app='owned-direct' AND date='2000-01-01';")[1] == "16")
end)
assert(W.upsert_ngrams("owned-direct", today, "owned-string-input", { x = { c = 1, sources = { hotstring = "2", extension = "3" } } }))
check("incoming numeric-string source counts retain existing rejection", function()
	assert(next(source_map("owned-string-input")) == nil)
end)
assert(W.upsert_ngrams("owned-direct", today, "owned-legacy", { x = 1 }))
assert(W.exec_sql("UPDATE ngram_chars SET esrc_json='{\"hotstring\":\"2\",\"llm\":\"3\",\"other\":\"4\",\"extension\":\"5\"}' WHERE app='owned-legacy';"))
assert(W.upsert_ngrams("owned-direct", today, "owned-legacy", { x = { c = 1, sources = { hotstring = 1, llm = 2, other = 3, extension = 6 } } }))
check("stored recognized numeric strings keep SQLite additive numeric semantics", function()
	local map = source_map("owned-legacy")
	assert(map.hotstring == 3 and map.llm == 5 and map.other == 7)
end)
check("stored admitted extra-label numeric strings keep additive numeric semantics", function()
	assert(source_map("owned-legacy").extension == 11)
end)
local label = "addon.é'\""
for _ = 1, 2 do assert(W.upsert_ngrams("owned-direct", today, "owned-literal", { x = { c = 2, sources = { [label] = 2 } } })) end
check("quoted Unicode punctuation label remains one literal JSON object key", function()
	local map = source_map("owned-literal")
	assert(map[label] == 4 and map.addon == nil)
end)
if proof then assert(W.exec_sql("VACUUM INTO '" .. proof .. "/second.sqlite';")) end
W.close_db()
local function remove_owned(file_path)
	local stat = assert(uv.fs_lstat(file_path))
	if stat.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(file_path)) do remove_owned(file_path .. "/" .. name) end
		assert(uv.fs_rmdir(file_path))
	else assert(uv.fs_unlink(file_path)) end
end
remove_owned(root)
print(string.format("Native Writer source maps: %d checks, %d failures", checks, failures))
assert(checks == 12)
os.exit(failures == 0 and 0 or 1)

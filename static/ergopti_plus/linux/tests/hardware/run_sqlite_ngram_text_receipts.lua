--- tests/hardware/run_sqlite_ngram_text_receipts.lua
--- ==============================================================================
--- MODULE: Native Linux SQLite N-Gram Text Receipts
--- DESCRIPTION:
--- Runs the genuine synthetic-output, flush and range-projection caller chain
--- under private XDG roots. Every n-gram table retains distinct UTF-8 and NUL
--- tokens through the real SQLite CLI. No keyboard is required; database,
--- filesystem, process and projection adapters are real.
--- ==============================================================================

local uv = require("luv")
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-ngram-text-XXXXXX"))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
require("compat.utf8").install()
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local config = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(config:write("[metrics]\nenabled = true\n") and config:close())
local Keylogger = require("modules.keylogger.keylogger")
local Writer = require("modules.keylogger.sqlite_writer")
local Reader = require("modules.keylogger.sqlite_reader")
local database = root .. "/metrics.sqlite"
local today = os.date("%Y-%m-%d")
-- An elapsed 24 hours can still be today on a 25-hour local calendar day.
-- Keep the historical record independent of both the clock and Reader policy.
local historical_day = "2000-01-01"
assert(historical_day < today, "native fixture needs a distinct historical day")
local checks, failures = 0, 0
Keylogger.init({ sqlite_path = database, log_dir = root .. "/logs" })
assert(Keylogger.is_enabled(), "owned configuration must grant collection consent")

local function check(name, test)
	checks = checks + 1
	local ok, err = xpcall(test, debug.traceback)
	if ok then print("PASS " .. name) else
		failures = failures + 1
		io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
	end
end

check("real synthetic output survives flush and the public range payload", function()
	Keylogger.record_synthetic_output("owned-synthetic-app", "a\0b", "other", 1000)
	require("tests.support.sqlite_flush_native").flush(Keylogger)
	local rows = assert(Writer.query_rows("SELECT hex(token),c FROM ngram_chars WHERE app='owned-synthetic-app' ORDER BY hex(token);"))
	assert(table.concat(rows, ",") == "00|1,61|1,62|1", "real flush did not persist the exact original characters")
	local payload = Keylogger.get_range_payload(today, today, { "owned-synthetic-app" })
	local chars = assert(payload.today["owned-synthetic-app"]).c
	assert(chars["\0"] and chars["\0"].c == 1 and chars["\0"].o == 1,
		"range projection dropped the actual persisted synthetic NUL")
	assert(chars.a.c == 1 and chars.b.c == 1, "healthy synthetic characters changed")
end)

local tables = {
	{ "c", "ngram_chars" }, { "bg", "ngram_bigrams" }, { "tg", "ngram_trigrams" },
	{ "qg", "ngram_quadgrams" }, { "pg", "ngram_pentagrams" },
	{ "hx", "ngram_hexagrams" }, { "hp", "ngram_heptagrams" },
	{ "w", "ngram_words" }, { "w_bg", "ngram_word_bigrams" },
}
local tokens = { "a", "a\0b", "\0", "\0leading", "trailing\0", "été", "quote'\"\\\t\r\nline" }
local expected = {}
for index, token in ipairs(tokens) do
	expected[token] = { c = index + 1, td = 10 * index, cd = 1, e = index,
		sources = { hotstring = index, llm = 1, other = 2 } }
end
local function verify_tokens(actual)
	local count = 0
	for _ in pairs(actual) do count = count + 1 end
	assert(count == #tokens, "projection dropped or merged distinct native tokens")
	for token, wanted in pairs(expected) do
		local row = assert(actual[token], "projection changed a token's bytes")
		assert(row.c == wanted.c and row.t == wanted.td and row.e == wanted.e, "token counters changed")
		assert(row.hs == wanted.sources.hotstring and row.llm == 1 and row.o == 2, "source counters changed")
	end
end

for _, item in ipairs(tables) do
	local code, table_name = item[1], item[2]
	for _, date in ipairs({ historical_day, today }) do
		assert(Writer.upsert_ngrams("owned-ngram", date, "owned-token-app", expected, table_name))
	end
	check(table_name .. " retains original bytes in the actual database", function()
		local rows = assert(Writer.query_rows("SELECT hex(token),c FROM " .. table_name
			.. " WHERE app='owned-token-app' AND date='" .. today .. "' AND hex(token)='610062';"))
		assert(#rows == 1 and rows[1] == "610062|3", "native fixture did not retain the collision token")
	end)
	check(table_name .. " retains distinct NUL and UTF-8 tokens in range reads", function()
		verify_tokens(Reader.read_ngrams(database, historical_day, historical_day, { "owned-token-app" })[code])
	end)
	check(table_name .. " retains distinct tokens in the historical and today split", function()
		local split = Reader.read_range_split_today(database, historical_day, today, { "owned-token-app" })
		verify_tokens(split.historical[code])
		verify_tokens(assert(split.today["owned-token-app"])[code])
	end)
end

-- The CLI's JSON mode cuts raw TEXT at NUL: the application, title, layout and
-- destination columns must cross it quoted, as the n-gram tokens do.
local nul_app = "owned\0app"
local function nul_text(prefix, suffix) return "'" .. prefix .. "'||char(0)||'" .. suffix .. "'" end
assert(Writer.exec_sql(table.concat({
	"INSERT INTO agg_app_day (device_id,date,app,chars) VALUES ('owned-nul','" .. today .. "',"
		.. nul_text("owned", "app") .. ",3);",
	"INSERT INTO agg_app_day (device_id,date,app,chars) VALUES ('owned-nul','" .. today .. "','owned',5);",
	"INSERT INTO agg_app_day_titles (device_id,date,app,title,c,ms) VALUES ('owned-nul','" .. today .. "',"
		.. nul_text("owned", "app") .. "," .. nul_text("doc", "title") .. ",1,5);",
	"INSERT INTO agg_app_day_layouts (device_id,date,app,layout,count) VALUES ('owned-nul','" .. today .. "',"
		.. nul_text("owned", "app") .. "," .. nul_text("fr", "x") .. ",2);",
	"INSERT INTO agg_app_day_switches_to (device_id,date,app_from,app_to,count) VALUES ('owned-nul','" .. today .. "',"
		.. nul_text("owned", "app") .. "," .. nul_text("term", "inal") .. ",4);",
}, "\n")), "native NUL text fixture rows must insert")
assert(Writer.upsert_ngrams("owned-ngram", today, nul_app, expected, "ngram_chars"))
check("manifest keeps application, title, layout and destination bytes past a NUL", function()
	local manifest, complete = Reader.read_manifest(database, today, today, { nul_app, "owned" })
	assert(complete == true, "native projection must complete")
	local entry = assert(manifest[today][nul_app], "the complete application id keys the manifest")
	assert(entry.chars == 3 and manifest[today].owned.chars == 5, "a NUL-cut id merged two applications")
	assert(entry.titles["doc\0title"].c == 1 and entry.titles.doc == nil, "title bytes changed")
	assert(entry.layouts_seen["fr\0x"] == 2 and entry.layouts_seen.fr == nil, "layout bytes changed")
	assert(entry.switches_to["term\0inal"] == 4 and entry.switches_to.term == nil, "destination bytes changed")
end)
check("today's per-application split keeps the complete application id", function()
	local split = Reader.read_range_split_today(database, today, today, { nul_app })
	verify_tokens(assert(split.today[nul_app], "the complete application id keys today's n-grams").c)
	assert(split.today.owned == nil, "a NUL-cut id is another application")
end)

check("open-session record round-trips through the actual meta table", function()
	local encoded = '[{"date":"2000-01-01","app":"owned\\u0000app","session":[3,250],"burst":null}]'
	assert(Writer.upsert_open_walk("owned-open-walk", encoded) == true, "native record write refused")
	local read, ok = Writer.read_open_walk("owned-open-walk")
	assert(ok == true and read == encoded, "native record changed: " .. tostring(read))
	assert(Writer.upsert_open_walk("owned-open-walk", "[]") == true)
	assert(select(1, Writer.read_open_walk("owned-open-walk")) == "[]", "a replaced record must not keep the old value")
	local absent, absent_ok = Writer.read_open_walk("owned-no-record")
	assert(absent == nil and absent_ok == true, "a missing record is a proven absence")
end)

check("native empty range keeps every n-gram family empty", function()
	local empty = Reader.read_ngrams(database, today, today, { "owned-absent-app" })
	for _, item in ipairs(tables) do assert(next(empty[item[1]]) == nil) end
	local split = Reader.read_range_split_today(database, today, today, { "owned-absent-app" })
	assert(next(split.today) == nil)
end)

Writer.close_db()
local function remove_owned_tree(path)
	local attributes = assert(uv.fs_lstat(path))
	if attributes.type == "directory" then
		for name in uv.fs_scandir_next, assert(uv.fs_scandir(path)) do remove_owned_tree(path .. "/" .. name) end
		assert(uv.fs_rmdir(path))
	else
		assert(uv.fs_unlink(path))
	end
end
remove_owned_tree(root)
assert(checks == 32, "all nine n-gram families and public controls must execute")
print(string.format("Native SQLite n-gram text receipts: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

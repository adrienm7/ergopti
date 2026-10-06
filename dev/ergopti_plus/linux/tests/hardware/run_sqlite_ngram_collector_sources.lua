--- tests/hardware/run_sqlite_ngram_collector_sources.lua
--- ==============================================================================
--- MODULE: Native Ngram Collector Source Ingestion (Linux)
--- DESCRIPTION:
--- Preserve public software source labels through actual flush and SQLite reads.
--- ==============================================================================

local uv = require("luv")
require("compat.utf8").install()
local Json = require("json")
local root = assert(os.getenv("OWN_NGRAM_COLLECTOR_ROOT"))
assert(uv.fs_mkdir(root, 448))
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	assert(uv.os_setenv("XDG_" .. name .. "_HOME", root .. "/" .. name:lower()))
end
assert(uv.fs_mkdir(root .. "/config", 448))
assert(uv.fs_mkdir(root .. "/config/ergopti", 448))
local cfg = assert(io.open(root .. "/config/ergopti/config.toml", "w"))
assert(cfg:write("[metrics]\nenabled = true\n") and cfg:close())
local K = require("modules.keylogger.keylogger")
local W = require("modules.keylogger.sqlite_writer")
local R = require("modules.keylogger.sqlite_reader")
local Clock = require("infra.monotonic")
assert(Clock.backend() == "luv.hrtime")
local db = root .. "/metrics.sqlite"
K.init({ sqlite_path = db, log_dir = root .. "/logs" })
assert(K.is_enabled() and W.is_available())
local today = os.date("%Y-%m-%d")
-- These are supplied software API events stamped on the genuine native clock.
-- They neither open physical input devices nor claim injector/hardware coverage.
K.on_keydown("x", math.floor(Clock.now_ms()), "owned-collector")
K.on_keydown("x", math.floor(Clock.now_ms()), "owned-collector")
K.record_synthetic_output("owned-collector", "xxx", "case-transform", math.floor(Clock.now_ms()))
K.record_synthetic_output("owned-collector", "xx", "owned-extension", math.floor(Clock.now_ms()))
K.record_synthetic_output("owned-collector", "xx", "llm", math.floor(Clock.now_ms()))
K.record_synthetic_output("owned-collector", "x", "other", math.floor(Clock.now_ms()))
K.record_hotstring("owned-collector", "", "x", math.floor(Clock.now_ms()), "static", 0)
K.flush()
assert(today == os.date("%Y-%m-%d"), "fixture must not cross a local midnight")
-- The collector deliberately excludes synthetic words. This separate admitted
-- Writer row checks the shared Reader helper's additional word-family boundary.
assert(W.register_device("owned-word-device", "owned-word-device", "linux", "", "owned"))
assert(W.upsert_ngrams("owned-word-device", today, "owned-word", {
	owned = { c = 4, td = 0, cd = 0, e = 0,
		sources = { hotstring = 1, llm = 1, ["case-transform"] = 2, none = 20 } },
}, "ngram_words"))
local reader = R.read_ngrams(db, today, today, { "owned-collector" })
local split = R.read_range_split_today(db, today, today, { "owned-collector" })
local public_range = K.get_range_payload(today, today, { "owned-collector" })
local dashboard = K.get_dashboard_payload()
local words = R.read_ngrams(db, today, today, { "owned-word" })
local split_words = R.read_range_split_today(db, today, today, { "owned-word" })
local filtered = R.read_ngrams(db, today, today, { "absent-owned" })
local excluded = R.read_ngrams(db, "1900-01-01", "1900-01-01", { "owned-collector" })
assert(W.exec_sql("VACUUM INTO '" .. root .. "/accepted.sqlite';"))
local sqlite_version = assert(W.query_rows("SELECT sqlite_version();"))[1]
W.close_db()
print(Json.encode({ root = root, today = today, reader = reader, split = split,
	public_range = public_range, dashboard = dashboard, words = words,
	split_words = split_words, filtered = filtered, excluded = excluded,
	runtime = _VERSION, libuv = uv.version_string(), sqlite = sqlite_version }))

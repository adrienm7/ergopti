--- tests/hardware/run_sqlite_ngram_source_key_encoding.lua
--- ==============================================================================
--- MODULE: Native Ngram Source Key JSON Encoding (Linux)
--- DESCRIPTION:
--- Actual public software source labels survive valid JSON encoding and SQLite.
--- ==============================================================================

--- Native public supplied-software source label encoding regression.
local uv = require("luv")
require("compat.utf8").install()
local Json = require("json")
local root = assert(os.getenv("OWN_SOURCE_ESCAPE_ROOT"))
assert(uv.fs_mkdir(root, 448))
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
assert(Clock.backend() == "luv.hrtime")
local db = root .. "/metrics.sqlite"
K.init({ sqlite_path = db, log_dir = root .. "/logs" })
assert(K.is_enabled() and W.is_available())
local labels = {
	ordinary = "addon",
	quote = "addon.é'\"",
	escaped_tab = "addon\\t",
	invalid_escape = "addon\\q",
	newline = "addon\nline",
	tab = "addon\tfield",
	carriage_return = "addon\rfield",
}
for name, label in pairs(labels) do
	K.record_synthetic_output("owned-" .. name, "xx", label, math.floor(Clock.now_ms()))
end
K.on_keydown("x", math.floor(Clock.now_ms()), "owned-manual")
K.flush()
assert(W.exec_sql("VACUUM INTO '" .. root .. "/accepted.sqlite';"))
local sqlite_version = assert(W.query_rows("SELECT sqlite_version();"))[1]
W.close_db()
print(Json.encode({ root = root, labels = labels, runtime = _VERSION,
	libuv = uv.version_string(), sqlite = sqlite_version, clock = Clock.backend() }))

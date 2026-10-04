-- tools/diagnostics/hs274-persistence.lua
-- Production Mac persistence/rebuild with actual SQLite and adapted native ports.
local root, temporary, source_root = assert(arg[1]), assert(arg[2]), assert(arg[3])
local driver = source_root .. "/static/ergopti_plus/macos"
local shared = root .. "/static/ergopti_plus/_shared"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. root .. "/static/ergopti_plus/macos/?.lua;" .. shared .. "/lua/?.lua;" .. package.path
local json = require("json")
local function request(message)
	message.kind = "request"
	assert(io.stdout:write(json.encode(message) .. "\n")); assert(io.stdout:flush())
	local line = assert(io.stdin:read("*l"), "SQLite parent did not return a receipt")
	return assert(json.decode(line))
end
local sqlite = { OK = 0, DONE = 101 }
function sqlite.open(path)
	local opened = request({ op = "open", path = path })
	assert(opened.ok, opened.error)
	local identity, detail = opened.value, ""
	local database = {}
	local function call(operation, sql, values)
		local result = request({ op = operation, connection = identity, sql = sql, values = values })
		if not result.ok then detail = result.error; return nil end
		return result.value
	end
	function database:exec(sql) return call("exec", sql) or 1 end
	function database:errmsg() return detail end
	function database:close() return call("close") end
	function database:nrows(sql)
		local rows = assert(call("rows", sql), detail)
		local index = 0
		return function() index = index + 1; return rows[index] end
	end
	function database:prepare(sql)
		local values
		return { bind_values = function(_, ...) values = { ... } end,
			step = function() assert(call("bound", sql, values), detail); return sqlite.DONE end,
			finalize = function() return sqlite.OK end }
	end
	return database
end
local logs = {}
local logger = {}
for _, method in ipairs({ "trace", "debug", "info", "warn", "start", "done", "success" }) do
	logger[method] = function() end
end
function logger.error(_, message, ...) logs[#logs + 1] = string.format(message, ...) end
function logger.pcall(_, callback, ...) return pcall(callback, ...) end
local fs = {}
function fs.attributes(path, attribute)
	local response = request({ op = "stat", path = path })
	assert(response.ok, response.error)
	local stat = response.value
	if stat == false then return nil end
	local result = { mode = stat.type, size = stat.size }
	return attribute and result[attribute] or result
end
function fs.dir(path)
	local response = request({ op = "directory", path = path })
	assert(response.ok, response.error)
	local scan = { rows = response.value, index = 0 }
	return function(state) state.index = state.index + 1; return state.rows[state.index] end, scan
end
local function read(path)
	local file = io.open(path, "r")
	if not file then return nil end
	local body = file:read("*a"); file:close(); return body
end
local function write(path, body)
	local file = assert(io.open(path, "w")); assert(file:write(body)); assert(file:close()); return true
end
local timer = {}
function timer.new()
	local active = false
	return { start = function(self) active = true; return self end,
		stop = function() active = false; return true end,
		running = function() return active end }
end
function timer.absoluteTime() return math.floor(os.clock() * 1000000000) end
function timer.secondsSinceEpoch() return os.time() end
local file_system = { read = read, write = write,
	read_with_status = function(path) local value = read(path); return value, value and "ok" or "absent" end }
local function ports()
	_G.hs = { fs = fs, timer = timer, json = json,
		execute = function() return "physical-fixture-host" end,
		host = { localizedName = function() return "Fixture" end } }
	package.loaded["hs.fs"], package.loaded["hs.timer"] = fs, timer
	package.loaded["hs.json"], package.loaded["hs.sqlite3"] = json, sqlite
	package.loaded["infra.logger"], package.loaded["adapters.file_system"] = logger, file_system
	package.loaded["infra.paths"] = { shared = function(path) return shared .. "/" .. path end }
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	package.loaded["infra.text_utils"] = { shell_quote = function(value)
		return "'" .. value:gsub("'", "'\\''") .. "'"
	end }
	package.loaded["modules.keylogger.text_cipher"] = {}
	package.loaded["adapters.timer_scheduler"] = { after = function()
		return { committed = true, timer = {} }, true
	end, cancel = function(handle) handle.timer = nil; return true end, now = os.time }
	package.loaded["modules.keylogger.export"] = { init = function() end,
		sync_foreign_data_sql = function() return {} end, get_native_app_category = function() return "other" end }
end
local metrics = temporary .. "/metrics"
local identity = "physical-release-device"
local by_device = metrics .. "/by_device/" .. identity
for _, path in ipairs({ metrics, metrics .. "/by_device", by_device, temporary .. "/ergopti_metrics",
	temporary .. "/ergopti_metrics/" .. identity }) do assert(request({ op = "mkdir", path = path }).ok) end
write(by_device .. "/device.json", json.encode({ device_id = identity, host_signature = "physical-fixture-host",
	name = "Fixture", os = "darwin", os_version = "fixture", created_at = "2026-09-12 00:00:00.000" }))
local state = { LOG_DIR = metrics, today_idx = {}, manifest = {}, is_enabled = true }
ports()
local manager = require("modules.keylogger.log_manager")
assert(manager.init(state), table.concat(logs, "\n"))
local mode = require("modules.keylogger.physical_accounting_mode")
assert(mode.select_stream("fixture-owner"))
assert(mode.admit("fixture-owner", "capture-original", "complete"))
local original = { capture = "capture-original", device = "18446744073709551615", keycode = 53,
	app = "Original", timestamp = "2026-09-12 10:00:00.000" }
assert(manager.log_physical_press(original))
for _, duration in ipairs({ 0, 250, 251, 900 }) do
	original.hold_ms = duration
	assert(manager.log_physical_release(original))
end
assert(manager.log_physical_release({ capture = "capture-original", device = "42", keycode = 49,
	app = "Other", timestamp = "2026-09-12 11:00:00.000", hold_ms = 125 }))
original.capture, original.app, original.device, original.hold_ms = "changed", "Changed", "1", 99999
assert(not read(by_device .. "/today.log") or read(by_device .. "/today.log") == "",
	"Physical sink must transfer FIFO ownership before disk IO")
manager.ingest_once()
manager.ingest_once()
local database_path = temporary .. "/ergopti_metrics/" .. identity .. "/db.sqlite"
local function snapshot()
	local db = require("modules.keylogger.sqlite_writer").get_db()
	local result = { holds = {}, presses = {}, raw_releases = 0 }
	for row in db:nrows("SELECT date,app,keycode,sum_ms,count,max_ms,tap_count,hold_count FROM agg_app_day_kc_hold ORDER BY app,keycode") do
		result.holds[#result.holds + 1] = row
	end
	for row in db:nrows("SELECT keycode,c FROM ngram_keycodes ORDER BY keycode") do result.presses[#result.presses + 1] = row end
	for row in db:nrows("SELECT count(*) AS count FROM events_system WHERE action='physical_release'") do
		result.raw_releases = row.count
	end
	return result
end
local receipt = { runtime = "real SQLite; adapted macOS APIs", database = database_path, live = snapshot() }
for _, phase in ipairs({ "rebuild_one", "rebuild_two" }) do
	local db = require("modules.keylogger.sqlite_writer").get_db()
	-- Poison existing derived rows: retaining them or additively replaying raw
	-- events cannot satisfy the independent expected totals after cache init.
	assert(db:exec("UPDATE agg_app_day_kc_hold SET sum_ms=99999,count=99,max_ms=99999,tap_count=99,hold_count=99;") == sqlite.OK)
	assert(db:exec("UPDATE ngram_keycodes SET c=999;") == sqlite.OK)
	assert(db:exec("UPDATE meta SET value='0' WHERE key='aggregate_cache_revision';") == sqlite.OK)
	assert(manager.stop({ process_exit = true }))
	local reload = {}
	for name in pairs(package.loaded) do if name:match("^modules%.keylogger%.") then reload[#reload + 1] = name end end
	for _, name in ipairs(reload) do package.loaded[name] = nil end
	ports()
	manager = require("modules.keylogger.log_manager")
	assert(manager.init(state), table.concat(logs, "\n"))
	receipt[phase] = snapshot()
end
assert(#logs == 0, table.concat(logs, "\n"))
assert(manager.stop({ process_exit = true }))
receipt.kind = "done"
print(json.encode(receipt))

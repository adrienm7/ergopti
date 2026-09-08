-- tools/bench/macos-metrics/init.lua
-- Native reader benchmark. No driver startup, event taps, or personal data.

local source = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local json = require("hs.json")
local writer
local config
local errors = {}

local function run()
	config = assert(json.read(source .. "/bench-config.json"), "benchmark configuration missing")
	assert(type(config.repo_root) == "string" and type(config.output_dir) == "string")
	assert(hs.fs.attributes(config.output_dir, "mode") == "directory", "output directory missing")
	local driver = config.repo_root .. "/static/ergopti_plus/macos"
	local shared = config.repo_root .. "/static/ergopti_plus/_shared"
	package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
		.. shared .. "/lua/?.lua;" .. shared .. "/lua/?/init.lua;" .. package.path
	-- Isolate infrastructure only; SQLite, schema owner and projections stay real.
	local logger = {}
	for _, name in ipairs({ "start", "success", "info", "warn", "debug", "trace", "done" }) do
		logger[name] = function() end
	end
	logger.error = function() errors[#errors + 1] = "production reader/writer reported an error" end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.paths"] = { shared = function(relative) return shared .. "/" .. relative end }
	-- Aggregate-only fixture never invokes typed-text encryption or hardware IDs.
	package.loaded["modules.keylogger.text_cipher"] = setmetatable({}, {
		__index = function() error("unexpected text-cipher use in aggregate benchmark") end,
	})
	local sqlite = require("hs.sqlite3")
	local db_path = config.output_dir .. "/synthetic.sqlite"
	assert(not hs.fs.attributes(db_path), "refusing to reuse an existing database")
	writer = require("modules.keylogger.sqlite_writer")
	writer.init({ paths = { sqlite_path = db_path }, device_id = "benchmark-device",
		device_obj = { device_id = "benchmark-device", name = "Synthetic", os = "macos",
			os_version = "synthetic", host_signature = "synthetic", created_at = "2026-01-01T00:00:00Z" } })
	assert(writer.open_db(), "production schema initialization failed")
	local db = assert(writer.get_db())
	local function sql(statement)
		assert(db:exec(statement) == sqlite.OK, "synthetic SQL operation failed")
	end
	sql("BEGIN")
	for day = 1, 28 do
		for app = 1, 8 do
			sql(string.format("INSERT INTO agg_app_day(device_id,date,app,chars,time_ms) VALUES('benchmark-device','2026-01-%02d','Synthetic%d',100,60000)", day, app))
		end
	end
	sql("COMMIT")
	assert(writer.close_db(), "writer close refused")
	local reader = require("modules.keylogger.sqlite_reader")
	local samples = {}
	for iteration = 1, 11 do
		local started = hs.timer.absoluteTime()
		local manifest = reader.read_manifest(db_path, "2026-01-01", "2026-01-28")
		local elapsed = (hs.timer.absoluteTime() - started) / 1000000
		local count = 0
		for _, apps in pairs(manifest) do
			for _, row in pairs(apps) do
				count = count + 1
				assert(row.chars == 100 and row.time == 60000, "projection changed synthetic totals")
			end
		end
		assert(count == 224, "projection omitted synthetic date/application rows")
		assert(#errors == 0, "production query reported an error")
		samples[#samples + 1] = elapsed
	end
	return { status = "ok", runtime = "native Hammerspoon", rows = 224,
		manifest_ms = samples, first_sample = "first reader call, not cold filesystem",
		ui = "unmeasured", open_to_painted = "unmeasured",
		scope = "production schema writer and manifest reader; synthetic aggregate rows; no ingestion, range or WebView measurement" }
end

local ok, result = xpcall(run, debug.traceback)
if writer then
	local closed, receipt = pcall(writer.close_db)
	if not closed or receipt == false then ok, result = false, "native writer cleanup refused" end
end
if not ok then result = { status = "error", error = tostring(result), ui = "unmeasured" } end
if config and config.output_dir then
	assert(json.write(result, config.output_dir .. "/result.json", true, true), "result publication failed")
else
	error(result.error)
end
-- The launching job owns application shutdown and checks result.status.

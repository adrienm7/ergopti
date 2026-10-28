-- tests/unit/modules/keystats/storage/test_cache_survives_reboot.lua

--- ==============================================================================
--- MODULE: Regression - the metrics cache survives a reboot (L64)
--- DESCRIPTION:
--- db.sqlite lived in TMPDIR, which macOS empties at every reboot: the first
--- start after a reboot found a fresh cache, lost the saved today.log offset
--- with it and replayed the whole 320 MB ledger (138 s main-thread hold before
--- the replay was sliced). The cache now lives in the CACHE_DIR the caller
--- passes (~/Library/Caches/ergopti_plus/metrics in production). With TMPDIR
--- emptied, a start keeps the cache and its saved offset and replays nothing;
--- a cache an earlier version left in TMPDIR is moved once.
--- ==============================================================================

local helpers = require("tests.helpers")

local DEVICE_ID = "00000000-0000-4000-8000-0000000000b0"
local HOST_SIGNATURE = "TEST-HOST-CACHE-REBOOT"
local SAVED_OFFSET = 4242

--- Creates a directory tree with the host shell.
--- @param path string Absolute directory path.
local function mkdir_p(path)
	os.execute(string.format("mkdir -p '%s'", path))
end

--- Writes `content` at `path`.
local function write(path, content)
	local file = assert(io.open(path, "wb"))
	assert(file:write(content)); assert(file:close())
end

--- True when `path` names an existing file.
local function exists(path)
	local file = io.open(path, "rb")
	if file then file:close() end
	return file ~= nil
end

--- Runs one keystats start over an owned metrics root, cache root and TMPDIR.
--- @param root string Owned scratch root.
--- @param prepare function Receives the paths and seeds the scenario.
--- @return table observations
local function start(root, prepare)
	local metrics, cache, tmpdir = root .. "/metrics/", root .. "/cache", root .. "/tmp"
	local by_device = metrics .. "by_device/" .. DEVICE_ID .. "/"
	os.execute(string.format("rm -rf '%s'", root))
	for _, dir in ipairs({ by_device, cache, tmpdir }) do mkdir_p(dir) end
	write(by_device .. "device.json", string.format(
		"{\"device_id\":\"%s\",\"name\":\"Test\",\"os\":\"darwin\",\"os_version\":\"14\","
		.. "\"host_signature\":\"%s\",\"created_at\":\"2026-10-28 00:00:00.000\",\"schema_version\":1}",
		DEVICE_ID, HOST_SIGNATURE))
	local paths = { cache = cache .. "/" .. DEVICE_ID .. "/db.sqlite",
		legacy = tmpdir .. "/ergopti_metrics/" .. DEVICE_ID .. "/db.sqlite" }
	prepare(paths)

	local seen = { exec = {}, rotation_offset = nil, opened = nil }
	local db = {
		exec = function(_, sql) seen.exec[#seen.exec + 1] = sql; return 0 end,
		errmsg = function() return "" end,
		nrows = function(_, sql)
			local rows = {}
			if sql:find("key='today_log_offset'", 1, true) then rows = { { value = tostring(SAVED_OFFSET) } }
			elseif sql:find("key='today_log_date'", 1, true) then rows = { { value = "2026-10-28" } }
			elseif sql:find("key='aggregate_cache_revision'", 1, true) then rows = { { value = "2" } }
			elseif sql:find("key='ngram_ctx_json'", 1, true) then rows = { { value = "{}" } } end
			local index = 0
			return function() index = index + 1; return rows[index] end
		end,
	}
	package.loaded["infra.logger"] = nil
	helpers.load_with_stubs("infra.logger")
	package.loaded["infra.timings"] = { ms = function() return 1000 end, sec = function() return 1 end,
		count = function() return 4096 end }
	package.loaded["modules.keystats.sqlite_writer"] = {
		SYNCHRONOUS_PRAGMA = "PRAGMA synchronous = FULL;",
		init = function(options) seen.opened = options.paths.sqlite_path end,
		open_db = function() return true end, close_db = function() return true end,
		get_db = function() return db end, build_inserts = function() return {} end,
		get_next_event_id = function() return 1 end, set_next_event_id = function() end,
		persist_next_event_id = function() return true end,
	}
	package.loaded["modules.keystats.aggregator"] = {
		init = function() end, set_device_id = function() end, get_device_id = function() return nil end,
		reset_batch = function() end, reset_ngram_ctx = function() end, get_ngram_ctx = function() return {} end,
		set_ngram_ctx = function() end, flush = function() return true end,
	}
	package.loaded["modules.keystats.export"] = { init = function() end, cleanup = function() return true end,
		sync_foreign_data_sql = function() return {} end }
	package.loaded["adapters.ledger_append"] = { recover = function() return true end, cleanup = function() return true end }
	package.loaded["modules.keystats.rotation"] = {
		init = function(options) seen.rotation_offset = options.today_log_offset end,
		is_initialized = function() return seen.rotation_offset ~= nil end,
		set_offset = function(value) seen.rotation_offset = value end,
		read_new_entries = function() return {}, 0, "eof" end, cleanup = function() return true end,
	}
	local actual_getenv = os.getenv
	os.getenv = function(key)
		if key == "TMPDIR" then return tmpdir end
		return actual_getenv(key)
	end
	local ok, err = pcall(function()
		local LM = helpers.load_with_stubs("modules.keystats.log_manager", {
			execute = function(cmd)
				if cmd:find("ioreg", 1, true) then return HOST_SIGNATURE end
				local dir = cmd:match("mkdir %-p '(.-)'")
				if dir then mkdir_p(dir) end
				return "", true, "exit", 0
			end,
		})
		hs.fs.__set_entries(metrics .. "by_device/", { ".", "..", DEVICE_ID })
		seen.initialized = LM.init({ LOG_DIR = metrics, CACHE_DIR = cache, buffer_events = {}, rich_chunks = {},
			today_idx = {}, manifest = {} })
		seen.recovering = LM.is_recovering()
		pcall(LM.stop, { process_exit = true })
	end)
	os.getenv = actual_getenv
	seen.cache_exists, seen.legacy_exists = exists(paths.cache), exists(paths.legacy)
	seen.paths = paths
	assert(ok, err)
	return seen
end

--- True when any executed statement starts a ledger replay.
local function replay_started(seen)
	for _, sql in ipairs(seen.exec) do
		if sql:find("local_ledger_replay", 1, true) then return true end
	end
	return false
end

helpers.describe("keystats cache location: a reboot keeps the cache (L64)", function()
	local root = helpers.driver_root() .. "tests/scratch_test_dir/cache_survives_reboot"

	helpers.it("with TMPDIR emptied by a reboot, the cache and its offset stay and nothing replays", function()
		local seen = start(root, function(paths)
			mkdir_p(paths.cache:match("^(.*)/"))
			write(paths.cache, "existing cache")
		end)
		helpers.assert_true(seen.initialized ~= false, "the start must succeed")
		helpers.assert_eq(seen.opened, seen.paths.cache, "the cache must live in CACHE_DIR, not in TMPDIR")
		helpers.assert_true(seen.cache_exists, "the existing cache must be kept")
		helpers.assert_true(not replay_started(seen), "an existing cache must not replay the ledger")
		helpers.assert_true(not seen.recovering, "no recovery may start for a current cache")
		helpers.assert_eq(seen.rotation_offset, SAVED_OFFSET, "today.log resumes at the saved offset")
	end)

	helpers.it("moves a cache an earlier version left in TMPDIR, without a replay", function()
		local seen = start(root, function(paths)
			mkdir_p(paths.legacy:match("^(.*)/"))
			write(paths.legacy, "legacy cache")
		end)
		helpers.assert_true(seen.cache_exists and not seen.legacy_exists, "the TMPDIR cache must be moved")
		helpers.assert_true(not replay_started(seen), "a moved cache must not replay the ledger")
		helpers.assert_eq(seen.rotation_offset, SAVED_OFFSET)
	end)

	helpers.it("a cache lost with no TMPDIR copy replays, in the bounded recovery", function()
		local seen = start(root, function() end)
		helpers.assert_true(replay_started(seen), "a missing cache must schedule the ledger replay")
	end)

	helpers.it("the production cache root is the user's Caches folder, from config_paths alone", function()
		package.loaded["infra.config_paths"] = nil
		local ConfigPaths = helpers.load_with_stubs("infra.config_paths")
		local home = os.getenv("HOME")
		helpers.assert_eq(ConfigPaths.metrics_cache_dir(),
			home:gsub("/$", "") .. "/Library/Caches/ergopti_plus/metrics")
		package.loaded["infra.config_paths"] = nil
		local src = helpers.read_driver_source("Central shared-state table passed by reference to all sub-modules")
		helpers.assert_true(src:find('CACHE_DIR = require("infra.config_paths").metrics_cache_dir()', 1, true) ~= nil,
			"the keystats core state must take its cache root from config_paths")
	end)

	os.execute(string.format("rm -rf '%s'", root))
end)

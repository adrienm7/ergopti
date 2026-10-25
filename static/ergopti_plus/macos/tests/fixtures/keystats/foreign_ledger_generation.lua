--- tests/fixtures/keystats/foreign_ledger_generation.lua

--- ==============================================================================
--- MODULE: Physical Foreign Ledger Import Fixture
--- DESCRIPTION:
--- Runs the production importer with native filesystem reads, a real SQLite
--- bridge, and independent incremental SHA-256 supplied by Python's hashlib.
--- ==============================================================================

local root, temporary = assert(arg[3]), assert(arg[2])
local driver = root .. "/static/ergopti_plus/macos"
-- Interpreter wrappers can inject host Lua modules before this fixture starts.
-- Physical replay must remain runnable with only the repository's Lua sources.
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?.lua;"
	.. root .. "/static/ergopti_plus/_shared/lua/?/init.lua"
package.cpath = ""

local Json, Helpers = require("json"), require("tests.helpers")
local RunloopTimers = require("tests.support.runloop_timers")

local function rpc(message)
	message.kind = "request"
	assert(io.stdout:write(Json.encode(message) .. "\n")); assert(io.stdout:flush())
	return assert(Json.decode_lossless(assert(io.stdin:read("*l"))))
end

local function request(message)
	local response = rpc(message)
	assert(response.ok, response.error)
	return response.value
end

--- Translate real stat facts to the native attributes shape without add-ons.
local function physical_attributes(path, key)
	local observed = request({ op = "stat", path = path })
	if observed == false then return nil end
	local attributes = { mode = observed.type, size = observed.size }
	if key ~= nil then return attributes[key] end
	return attributes
end

--- Preserve the native iterator/state contract over a real physical listing.
local function physical_directory(path)
	local names = { ".", ".." }
	for _, name in ipairs(request({ op = "directory", path = path })) do names[#names + 1] = name end
	local owner = { names = names, index = 0 }
	local function next_name(state)
		assert(state == owner, "physical directory iterator requires its exact native state")
		state.index = state.index + 1
		return state.names[state.index]
	end
	return next_name, owner
end

local function new_hash(algorithm)
	assert(algorithm == "SHA256")
	local context = { identity = request({ op = "sha256_new" }) }
	function context:append(bytes)
		local hex = bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end)
		assert(request({ op = "sha256_append", digest = self.identity, hex = hex }))
		return self
	end
	function context:finish()
		self.digest = request({ op = "sha256_finish", digest = self.identity })
		return self
	end
	function context:value() return self.digest end
	return context
end

local identity = request({ op = "open", path = temporary .. "/cache.sqlite" })
local db = { last_error = "" }
function db:exec(sql)
	local response = rpc({ op = "exec", connection = identity, sql = sql })
	self.last_error = response.error or ""
	return response.ok and response.value or 1
end
function db:nrows(sql)
	local rows = request({ op = "rows", connection = identity, sql = sql })
	for _, row in ipairs(rows) do
		for key, value in pairs(row) do if Json.is_null(value) then row[key] = nil end end
	end
	local index = 0
	return function() index = index + 1; return rows[index] end
end
function db:prepare(sql)
	local statement = {}
	function statement:bind_values(...) self.values = { ... }; return 0 end
	function statement:step()
		local response = rpc({ op = "bound", connection = identity, sql = sql, values = self.values })
		db.last_error = response.error or ""
		return response.ok and 101 or 1
	end
	function statement:finalize() return 0 end
	return statement
end
function db:errmsg() return self.last_error end

local receipt
Helpers.with_stub_scope({ "infra.logger", "infra.fs_dir", "modules.keystats.export" }, function()
	local runloop = RunloopTimers.create()
	package.loaded["infra.logger"] = Helpers.make_logger_stub()
	package.loaded["infra.fs_dir"] = nil
	local export = Helpers.load_with_stubs("modules.keystats.export", {
		fs = { attributes = physical_attributes, dir = physical_directory }, hash = { new = new_hash }, timer = runloop.api,
	})
	export.init({ paths = { metrics_dir = temporary .. "/metrics/" }, device_id = "local",
		get_db = function() return db end })
	local replacement = temporary .. "/replacement.sql"
	local interleaved = physical_attributes(replacement) ~= nil
	local imported, turns, generations = {}, 0, 0
	repeat
		turns = turns + 1
		imported = assert(export.sync_foreign_data_sql())
		if interleaved and turns == 1 then
			assert(request({ op = "replace", source = replacement,
				path = temporary .. "/metrics/by_device/foreign/data.sql" }))
		end
		runloop.drain()
		if #imported > 0 then generations = generations + 1 end
	until generations == (interleaved and 2 or 1) or turns == 64
	if export.cleanup then assert(export.cleanup()) end
	receipt = { kind = "done", imported = imported, turns = turns, generations = generations,
		module_paths = { lua = package.path, native = package.cpath, lfs_loaded = package.loaded["lfs"] ~= nil },
		rows = request({ op = "rows", connection = identity,
			sql = "SELECT id,action FROM events_system ORDER BY id" }),
		watermark = request({ op = "rows", connection = identity,
			sql = "SELECT imported_data_sql_size,imported_data_sql_sha256 FROM devices WHERE device_id='foreign'" }) }
end)
assert(request({ op = "close", connection = identity }) == 0)
assert(io.stdout:write(Json.encode(receipt) .. "\n")); assert(io.stdout:flush())

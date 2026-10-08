--- tests/unit/platform/remap/test_runtime_inert_admission.lua

--- ==============================================================================
--- MODULE: Unsupported Native Runtime Admission
--- DESCRIPTION:
--- Fixed real configuration files preserve consent while unavailable runtime
--- intent refuses shared effects. Portable native ports prove admission only.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'
local OWNED_OFF = '[karabiner]\nruntime = "owned"\nintegration_enabled = false\n[future]\nrevision = 29\n'
local SHARED = '[karabiner]\nintegration_enabled = true\n[future]\nrevision = 29\n'
local SHARED_OFF = '[karabiner]\nintegration_enabled = false\n[future]\nrevision = 29\n'

--- Loads the real A3 reader before an observable native owner is constructed.
--- @param source string Fixed original configuration bytes.
--- @param body function Receives facade, effects, lease port and source reader.
local function with_source(source, body, declaration)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
	local declaration_path
	if declaration then
		declaration_path = os.tmpname()
		local stream = assert(io.open(declaration_path, "wb")); assert(stream:write(declaration)); assert(stream:close())
	end
	local ok, err = pcall(function()
		helpers.with_stub_scope({ "infra.paths", "platform.remap.scope_layer" }, function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ skip_init = true, real_user_config_path = path })
			local declaration_paths, original_shared
			calls.declaration_resolves = 0
			if declaration_path then
				-- The fixture captured the real reader before replacing its public
				-- facade. Bind that reader's actual path port, not a later stub.
				local function captured(fn, expected)
					for index = 1, 20 do
						local name, value = debug.getupvalue(fn, index)
						if name == expected then return value end
					end
					error("the genuine reader port was not found: " .. expected, 0)
				end
				local reader = captured(require("platform.remap.config").load_user_config, "RealConfig")
				declaration_paths = captured(captured(reader.load_user_config, "runtime_setting"), "Paths")
				original_shared = declaration_paths.shared
				declaration_paths.shared = function(relative)
					if relative == "platform/remap/runtime_setting.json" then
						calls.declaration_resolves = calls.declaration_resolves + 1
						return declaration_path
					end
					return original_shared(relative)
				end
			end
			local lease = require("platform.remap.lease_controller")
			local status = lease.status
			lease.is_initialized = function() return calls.lease_init > 0 end
			lease.status = function()
				if calls.lease_init == 0 then return "uninitialized", { phase = "uninitialized" } end
				return status()
			end
			calls.expand, calls.scope_imports = 0, 0
			package.loaded["platform.remap.scope_layer"] = { import = function()
				calls.scope_imports = calls.scope_imports + 1
				return nil
			end }
			local initialized = remap.init({ expand_path = function(value)
				calls.expand = calls.expand + 1
				return value
			end })
			local function read()
				local stream = assert(io.open(path, "rb"))
				local bytes = assert(stream:read("*a")); assert(stream:close()); return bytes
			end
			local body_ok, body_err = pcall(body, remap, calls, lease, read, initialized, path)
			if declaration_paths then declaration_paths.shared = original_shared end
			if not body_ok then error(body_err, 0) end
		end)
		end)
	end)
	if declaration_path then os.remove(declaration_path) end
	os.remove(path)
	if not ok then error(err, 0) end
end

--- Checks every observable acquisition and persistent shared effect stays absent.
--- @param calls table Recorded actual facade effects under native ports.
local function no_shared_effects(calls)
	for _, name in ipairs({ "lease_init", "expand", "start", "start_paused", "build", "deploy",
		"execute", "save", "lease_bound_starts", "input_source_watchers", "wizard_runs", "scope_imports" }) do
		helpers.assert_eq(calls[name], 0, name .. " must remain unacquired")
	end
	helpers.assert_eq(#calls.rule_removals, 0)
	helpers.assert_eq(#calls.legacy_removals, 0)
	helpers.assert_eq(#calls.first_run_timers, 0)
end

--- Retains an existing settings owner with a genuinely nonterminal phase.
--- @param remap table Actual manager with its existing debt introspector.
local function hold_settings(remap)
	for index = 1, 20 do
		local name = debug.getupvalue(remap.settings_pending, index)
		if name == "_bulk_settings_transaction" then
			debug.setupvalue(remap.settings_pending, index, { label = "Fixed held candidate", phase = "candidate-persistence" })
			helpers.assert_true(remap.settings_pending())
			return
		end
	end
	error("the genuine existing settings owner was not found", 0)
end

helpers.describe("constructor admitted controller query ports", function()
	local function genuine_controller()
		return assert(loadfile(helpers.driver_root() .. "platform/remap/lease_controller.lua"))()
	end
	for _, during_config in ipairs({ false, true }) do
		helpers.it("refuses genuine acquired state hidden by substituted ports during config " .. tostring(during_config), function()
			with_source(OWNED, function()
				local actual = genuine_controller()
				local original_initialized, original_status = actual.is_initialized, actual.status
				local phase, snapshot = original_status()
				helpers.assert_eq(phase, "uninitialized")
				local function substitute()
					actual.init()
					helpers.assert_eq(original_initialized(), true, "actual retained controller owns initialized state")
					actual.is_initialized = function() return false end
					actual.status = function() return phase, snapshot end
				end
				package.loaded["platform.remap.lease_controller"] = actual
				local remap = helpers.load_with_stubs("platform.remap")
				local config = require("platform.remap.config")
				local original_load = config.load_user_config
				local callback_ran = false
				if during_config then
					config.load_user_config = function(...)
						local results = table.pack(original_load(...))
						substitute()
						callback_ran = true
						return table.unpack(results, 1, results.n)
					end
				end
				local initialized = remap.init({ expand_path = function()
					error("owned intent must not expand a shared output path")
				end })
				config.load_user_config = original_load
				helpers.assert_eq(initialized, true, "settings lifecycle succeeds independently of custody")
				helpers.assert_eq(callback_ran, during_config, "genuine config callback executed only for selected cut")
				if not during_config then substitute() end
				local completed
				remap.pause(function(ok) completed = ok end)
				helpers.assert_eq(original_initialized(), true)
				helpers.assert_eq(completed == true, false, "substituted public ports cannot erase retained native custody")
			end)
		end)
	end
end)
return true

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

helpers.describe("unsupported native runtime settings lifecycle", function()
	for _, control in ipairs({ { bytes = OWNED, consent = true }, { bytes = OWNED_OFF, consent = false } }) do
		helpers.it("loads owned intent without shared effects with consent " .. tostring(control.consent), function()
			with_source(control.bytes, function(remap, calls, _, read, initialized)
				helpers.assert_true(initialized, "settings load must not abort ordinary boot")
				helpers.assert_eq(remap.get_enabled(), control.consent)
				no_shared_effects(calls)
				helpers.assert_eq(read(), control.bytes)
				helpers.assert_eq(type(remap.get_runtime), "function")
				helpers.assert_eq(remap.get_runtime(), "owned")
				helpers.assert_eq(remap.shared_runtime_selected(), false)
				helpers.assert_eq(remap.runtime_unavailable_reason(), "runtime-unavailable")
				helpers.assert_eq(remap.guardian_state(), control.consent and "unavailable" or "not_used")
			end)
		end)
	end
	helpers.it("keeps a future admitted backend unavailable instead of substituting shared", function()
		local declaration = [[{"$schema":"./runtime_setting.schema.json","path":"karabiner.runtime","file":"config_karabiner.toml","owner":"platform.remap.config","platforms":["hs"],"type":"enum","enum_values":["shared","owned","future"],"default":"shared","recommended":"shared","description_key":"menu.global.karabiner_runtime","unavailable_key":"menu.global.karabiner_runtime_unavailable"}]]
		with_source('[karabiner]\nruntime = "future"\nintegration_enabled = true\n', function(remap, calls, _, _, initialized)
			helpers.assert_true(initialized)
			helpers.assert_true(calls.declaration_resolves > 0, "real admitted declaration callback executed")
			no_shared_effects(calls)
			helpers.assert_eq(remap.get_runtime(), "future")
			helpers.assert_eq(remap.shared_runtime_selected(), false)
		end, declaration)
	end)
	for _, control in ipairs({ { bytes = SHARED, consent = true }, { bytes = SHARED_OFF, consent = false } }) do
		helpers.it("preserves actual declared shared default with consent " .. tostring(control.consent), function()
			with_source(control.bytes, function(remap, calls, _, read, initialized)
				helpers.assert_true(initialized)
				helpers.assert_eq(remap.get_enabled(), control.consent)
				helpers.assert_eq(calls.lease_init, 1)
				helpers.assert_eq(calls.expand, os.getenv("ERGOPTI_KARABINER_OUT") and 0 or 1)
				helpers.assert_eq(calls.input_source_watchers, 1)
				helpers.assert_eq(#calls.rule_removals, control.consent and 0 or 1)
				helpers.assert_eq(read(), control.bytes)
				helpers.assert_eq(type(remap.get_runtime), "function")
				helpers.assert_eq(remap.get_runtime(), "shared")
				helpers.assert_true(remap.shared_runtime_selected())
				helpers.assert_nil(remap.runtime_unavailable_reason())
			end)
		end)
	end
	for _, control in ipairs({
		{ name = "regenerate", run = function(m, done) return m.regenerate(done) end },
		{ name = "enable", run = function(m, done) return m.set_enabled(true, done) end },
		{ name = "disable", run = function(m, done) return m.set_enabled(false, done) end },
		{ name = "remove", run = function(m, done) return m.remove_from_karabiner(done) end },
		{ name = "legacy removal", run = function(m, done) return m.remove_legacy_rules(done, {}) end },
		{ name = "guardian settings", run = function(m, done) return m.open_guardian_settings(done) end },
		{ name = "scalar settings", run = function(m) return m.set_tap_hold_timeout(201) end },
		{ name = "bulk clear", run = function(m, done) return m.clear_all_bindings(done) end },
		{ name = "bulk recommendation", run = function(m, done) return m.reset_to_defaults(done) end },
		{ name = "scope import", run = function(m, done) return m.apply_scope({ scope = "tap_holds",
			mode = "recommended", backup_path = "/unavailable-runtime-backup" }, done) end },
	}) do
		helpers.it("refuses direct " .. control.name .. " for unavailable owned intent", function()
			with_source(OWNED, function(remap, calls, _, read)
				local completed
				local result = control.run(remap, function(ok) completed = ok end)
				helpers.assert_eq(result, false)
				if control.name ~= "scalar settings" then helpers.assert_eq(completed, false) end
				no_shared_effects(calls)
				helpers.assert_eq(read(), OWNED)
			end)
		end)
	end
	for _, name in ipairs({ "pause", "resume", "stop_lease" }) do
		helpers.it("acknowledges " .. name .. " only for actual never-acquired controller", function()
			with_source(OWNED, function(remap, calls)
				local completed
				helpers.assert_true(remap[name](function(ok) completed = ok end))
				helpers.assert_eq(completed, true)
				helpers.assert_eq(calls.stop, 0)
				no_shared_effects(calls)
			end)
		end)
	end
	for _, name in ipairs({ "pause", "resume", "stop_lease", "revoke" }) do
		helpers.it("retains unacknowledged settings debt at inert " .. name, function()
			with_source(OWNED, function(remap, calls)
				hold_settings(remap)
				local completed
				local callback = function(ok) completed = ok end
				local accepted
				if name == "revoke" then accepted = remap.revoke("fixed held source", callback)
				else accepted = remap[name](callback) end
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(completed, false)
				helpers.assert_true(remap.settings_pending())
				helpers.assert_eq(calls.stop, 0)
				no_shared_effects(calls)
			end)
		end)
	end
	for _, name in ipairs({ "pause", "resume" }) do
		helpers.it("holds " .. name .. " when controller custody is unknown", function()
			with_source(OWNED, function(remap, calls, lease)
				lease.is_initialized = function() error("fixed unreadable custody") end
				local completed
				helpers.assert_eq(remap[name](function(ok) completed = ok end), false)
				helpers.assert_eq(completed, false)
				no_shared_effects(calls)
			end)
		end)
	end
	for _, name in ipairs({ "stop_lease", "revoke" }) do
		helpers.it("preserves real initialized controller fence at inert " .. name, function()
			with_source(OWNED, function(remap, calls, lease)
				lease.is_initialized = function() return true end
				lease.status = function() return "active", { phase = "active", token = "foreign-existing-token" } end
				local completed
				local callback = function(ok) completed = ok end
				local accepted
				if name == "revoke" then accepted = remap.revoke("fixed existing custody", callback)
				else accepted = remap[name](callback) end
				helpers.assert_true(accepted)
				helpers.assert_eq(calls.stop, 1)
				helpers.assert_nil(completed, "accepted stop must not publish terminal success")
				calls.finish_stop(false, "fixed fence failure")
				helpers.assert_eq(completed, false)
				no_shared_effects(calls)
			end)
		end)
	end
	for _, succeeds in ipairs({ true, false }) do
		helpers.it("preserves loaded installer settlement " .. tostring(succeeds) .. " at inert revoke", function()
			with_source(OWNED, function(remap, calls)
				calls.onboarding_stop_succeeds = succeeds
				local completed
				local accepted = remap.revoke("fixed installer custody", function(ok) completed = ok end)
				helpers.assert_eq(accepted, succeeds)
				helpers.assert_eq(completed, succeeds)
				helpers.assert_eq(calls.onboarding_stop_attempts, 1)
				helpers.assert_eq(calls.stop, 0)
				no_shared_effects(calls)
			end)
		end)
	end
	for _, shared in ipairs({ false, true }) do
		helpers.it("actual main boot deploy admits shared selection " .. tostring(shared), function()
			local source = assert(helpers.read_driver_unit("✅ Hammerspoon boot SUCCESSFUL."))
			local start = assert(source:find('pcall(function()\n\tif type(karabiner) == "table"', 1, true))
			local finish = assert(source:find('\nend)', start, true))
			local deploys = 0
			local env = setmetatable({ karabiner = { get_enabled = function() return true end,
				shared_runtime_selected = function() return shared end,
				regenerate = function() deploys = deploys + 1 end }, Logger = { info = function() end }, LOG = "fixed boot" }, { __index = _G })
			assert(load(source:sub(start, finish + 4), "actual boot deploy", "t", env))()
			helpers.assert_eq(deploys, shared and 1 or 0)
		end)
	end
end)

return true

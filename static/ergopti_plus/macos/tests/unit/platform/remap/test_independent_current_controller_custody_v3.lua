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

helpers.describe("independent current controller custody before facade capture", function()
 local function genuine_controller()
  return assert(loadfile(helpers.driver_root() .. "platform/remap/lease_controller.lua"))()
 end
 local function current_facade(actual)
  package.loaded["platform.remap.lease_controller"] = actual
  local fresh = helpers.load_with_stubs("platform.remap")
  helpers.assert_eq(fresh.init({ expand_path = function() error("owned intent must not expand a shared output path") end }), true, "genuine owned reader initializes settings only")
  helpers.assert_eq(fresh.get_runtime(), "owned")
  return fresh
 end
 helpers.it("healthy genuine current controller is bound before facade initialization", function()
  with_source(OWNED, function(_, calls)
   local actual = genuine_controller()
   local remap = current_facade(actual)
   helpers.assert_eq(actual.is_initialized(), false)
   local completed
   helpers.assert_eq(remap.pause(function(ok) completed = ok end), true)
   helpers.assert_eq(completed, true)
   helpers.assert_eq(actual.is_initialized(), false)
   helpers.assert_eq(calls.stop, 0)
  end)
 end)
 for _, operation in ipairs({ "pause", "stop_lease", "revoke", "teardown_local" }) do
  helpers.it("genuine current module replacement refuses " .. operation .. " old-instance terminal result", function()
   with_source(OWNED, function(_, calls)
    local original = genuine_controller()
    local remap = current_facade(original)
    local successor = genuine_controller()
    successor.init()
    helpers.assert_eq(successor.is_initialized(), true)
    helpers.assert_eq(original.is_initialized(), false)
    package.loaded["platform.remap.lease_controller"] = successor
    local completed
    local function done(ok) completed = ok end
    local accepted
    if operation == "revoke" then accepted = remap.revoke("independent current replacement", done)
    elseif operation == "teardown_local" then accepted = remap.teardown_local()
    else accepted = remap[operation](done) end
    helpers.assert_eq(successor.is_initialized(), true, "genuine successor retains initialized custody")
    if operation == "teardown_local" then
     helpers.assert_eq(accepted, false, "old-controller teardown must retain original local settings")
     helpers.assert_eq(remap.get_runtime(), "owned")
    else
     helpers.assert_eq(completed == true, false, "old-controller absence cannot settle current custody")
    end
   end)
  end)
 end
 helpers.it("initially bound status callback cannot substitute final getter after actual acquisition", function()
  with_source(OWNED, function(_, calls)
   local actual = genuine_controller()
   local original_status, original_initialized = actual.status, actual.is_initialized
   local status_called = false
   actual.status = function()
    local phase, snapshot = original_status()
    actual.init()
    helpers.assert_eq(original_initialized(), true)
    actual.is_initialized = function() return false end
    status_called = true
    return phase, snapshot
   end
   local remap = current_facade(actual)
   local completed
   remap.pause(function(ok) completed = ok end)
   helpers.assert_eq(status_called, true, "initially retained observation callback executed")
   helpers.assert_eq(original_initialized(), true, "actual original controller now owns state")
   helpers.assert_eq(completed == true, false, "a replaced final getter cannot mint terminal absence")
  end)
 end)
end)
return true

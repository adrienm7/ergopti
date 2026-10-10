--- tests/support/runtime_recovery_fixture.lua

--- ==============================================================================
--- MODULE: Native Inert Runtime Recovery Fixture
--- DESCRIPTION:
--- Reuses transaction observers while loading the actual original controller and
--- local owner sources. Only disposable host ports are doubled; no source loader,
--- successful native receipt, STOPPED or installed runtime is fabricated.
--- ==============================================================================

local M = {}
local helpers = require("tests.helpers")
local transaction_fixture = require("tests.support.remap_transaction_fixture")

--- Runs the existing fixture over genuine native owner constructors.
--- @param body function Receives the ordinary transaction fixture.
--- @param options table|nil Explicit pre-construction negative injections.
--- @return ... Body results.
function M.with_fixture(body, options)
	options = options or {}
	return helpers.with_stub_scope({ "adapters.input_source_broker" }, function()
		return transaction_fixture(function(fixture)
			local loader = helpers.load_with_stubs
			helpers.load_with_stubs = function(name, ...)
				if name ~= "platform.remap" then return loader(name, ...) end
				local original_require, handed_off = require, false
				_G.require = function(request, ...)
					if request == name and not handed_off then
						handed_off = true
						-- The transaction fixture's timer table omits the native recurring
						-- constructor. These disposable methods never access the host.
						if type(hs.timer.new) ~= "function" then
							hs.timer.new = function(delay, callback)
								local active = false
								local timer = { delay = delay, callback = callback }
								function timer:start() active = true; return self end
								function timer:stop() active = false; return self end
								function timer:running() return active end
								return timer
							end
						end
						package.loaded["adapters.input_source_broker"] = nil
						for _, owner in ipairs({ "platform.remap.lease_controller",
							"platform.remap.watchers", "platform.remap.ke_lifecycle" }) do
							package.loaded[owner] = nil
							local actual = original_require(owner)
							if options.counterfeit_controller and owner == "platform.remap.lease_controller" then
								actual.status = function() return "uninitialized", { phase = "uninitialized" } end
							elseif options.input_only_issuer and owner == "platform.remap.watchers" then
								actual.inert_remap_teardown_admission = actual.input_source_teardown_admission
							end
						end
						-- Genuine unsupported inert boot loads no installer. The existing
						-- fixture's observable installer model grants no native authority.
						package.loaded["platform.remap.onboarding"] = nil
					end
					return original_require(request, ...)
				end
				local result = table.pack(pcall(loader, name, ...))
				_G.require = original_require
				if not result[1] then error(result[2], 0) end
				return table.unpack(result, 2, result.n)
			end
			local result = table.pack(pcall(body, fixture))
			helpers.load_with_stubs = loader
			if not result[1] then error(result[2], 0) end
			return table.unpack(result, 2, result.n)
		end)
	end)
end

--- Loads the real A3 reader before an observable native owner is constructed.
--- @param source string Fixed original configuration bytes.
--- @param body function Receives facade, effects, lease port and source reader.
function M.with_source(source, body, declaration, options)
	local path = os.tmpname()
	local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
	local declaration_path
	if declaration then
		declaration_path = os.tmpname()
		local stream = assert(io.open(declaration_path, "wb")); assert(stream:write(declaration)); assert(stream:close())
	end
	local ok, err = pcall(function()
		helpers.with_stub_scope({ "infra.paths", "platform.remap.scope_layer" }, function()
		M.with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ skip_init = true, real_user_config_path = path })
			local declaration_paths, original_shared
			calls.declaration_resolves = 0
			if declaration_path then
				-- The real-source fixture publishes the genuine configuration owner.
				-- Bind that reader's actual path port before initializing the manager.
				local function captured(fn, expected)
					for index = 1, 20 do
						local name, value = debug.getupvalue(fn, index)
						if name == expected then return value end
					end
					error("the genuine reader port was not found: " .. expected, 0)
				end
				local reader = require("platform.remap.config")
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
		end, options)
		end)
	end)
	if declaration_path then os.remove(declaration_path) end
	os.remove(path)
	if not ok then error(err, 0) end
end

--- Retains an existing settings owner with a genuinely nonterminal phase.
--- @param remap table Actual manager with its existing debt introspector.
function M.hold_settings(remap)
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


--- Requires completed exact inert-local teardown, never lease-request admission.
function M.settled_scope(remap)
	local callback_ok, callback_reason
	helpers.assert_eq(remap.stop_lease(function(ok, reason)
		callback_ok, callback_reason = ok, reason
	end), true)
	helpers.assert_eq(callback_ok, true)
	helpers.assert_eq(callback_reason, "runtime-not-acquired")
	helpers.assert_eq(remap.teardown_local(), true)
	local scope = remap.runtime_recovery_admission()
	helpers.assert_eq(type(scope), "table")
	helpers.assert_eq(scope.current(), true)
	return scope
end

return M

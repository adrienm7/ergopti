--- tests/unit/ui/test_program_provider_picker.lua

--- Session and cleanup receipts for the production shared helper and Linux bridge.
local helpers = require("tests.helpers")
local SCALAR = '{"version":1,"executable":"/private/tool","arguments":["two words",""]}'

local function isolated(body)
	local saved = {}
	for key, value in pairs(package.loaded) do saved[key] = value end
	local ok, failure = xpcall(body, debug.traceback)
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	if not ok then error(failure, 0) end
end

local function shared(body)
	isolated(function()
		package.loaded.program_provider_picker = nil
		body(require("program_provider_picker"))
	end)
end

local function owner(options)
	options = options or {}
	local state = { discoveries = 0, resolutions = 0, invalidations = 0, retired = false }
	state.discover = function()
		state.discoveries = state.discoveries + 1
		if options.discover then return options.discover(state) end
		return { choices = { { key = "opaque-choice", label = "Reviewed provider" } } }
	end
	state.resolve = function(key, arguments)
		state.resolutions = state.resolutions + 1
		if options.resolve then return options.resolve(state, key, arguments) end
		if state.retired or key ~= "opaque-choice" then return nil end
		return SCALAR
	end
	state.invalidate = function()
		state.invalidations = state.invalidations + 1
		if options.invalidate then return options.invalidate(state) end
		state.retired = true
		return true
	end
	return state
end

helpers.describe("Program provider picker shared ownership", function()
	for _, mode in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("retains refused retirement until exact acknowledgement: " .. mode, function()
			shared(function(Picker)
				local released, creates = false, 0
				local first = owner({ invalidate = function(state)
					if released then state.retired = true; return true end
					if mode == "throw" then error("PRIVATE cleanup exception") end
					if mode == "nil" then return nil end
					return mode == "truthy" and 1 or false
				end })
				local adapter = { create = function() creates = creates + 1; return creates == 1 and first or owner() end }
				local initial = Picker.capture(adapter)
				Picker.close(initial)
				helpers.assert_eq(Picker.confirm(initial, "run_program", { providerKey = "opaque-choice" }), false)
				local blocked = Picker.capture(adapter)
				helpers.assert_eq(blocked.packet.unavailable, true)
				helpers.assert_eq(creates, 1, "cleanup debt must precede successor construction")
				local manual, value = Picker.confirm(blocked, "run_program", { parameter = SCALAR })
				helpers.assert_true(manual)
				helpers.assert_eq(value, SCALAR, "unavailable discovery retains the manual path")
				released = true
				local retry = Picker.capture(adapter)
				helpers.assert_eq(creates, 2)
				helpers.assert_true(first.retired)
				helpers.assert_eq(retry.packet.choices[1].key, "opaque-choice")
				Picker.close(retry)
			end)
		end)
	end
	for _, mode in ipairs({ "throw", "nil" }) do
		helpers.it("keeps failed-discovery cleanup debt before another factory: " .. mode, function()
			shared(function(Picker)
				local released, creates = false, 0
				local first = owner({ discover = function()
					if mode == "throw" then error("PRIVATE enumeration exception") end
					return nil
				end, invalidate = function() return released end })
				local adapter = { create = function() creates = creates + 1; return creates == 1 and first or owner() end }
				helpers.assert_eq(Picker.capture(adapter).packet.unavailable, true)
				helpers.assert_eq(Picker.capture(adapter).packet.unavailable, true)
				helpers.assert_eq(creates, 1)
				released = true
				local next_owner = Picker.capture(adapter)
				helpers.assert_eq(creates, 2)
				Picker.close(next_owner)
			end)
		end)
	end
	helpers.it("refuses an owner without its mandatory retirement port before discovery", function()
		shared(function(Picker)
			local broken = owner(); broken.invalidate = nil
			helpers.assert_eq(Picker.capture({ create = function() return broken end }).packet.unavailable, true)
			helpers.assert_eq(broken.discoveries, 0)
		end)
	end)
	for _, boundary in ipairs({ "factory", "discovery" }) do
		helpers.it("cannot construct an overlapping discovery owner during " .. boundary, function()
			shared(function(Picker)
				local nested, extra = nil, 0
				local function reenter()
					nested = Picker.capture({ create = function() extra = extra + 1; return owner() end })
				end
				local first = owner({ discover = function()
					if boundary == "discovery" then reenter() end
					return { choices = {} }
				end })
				local state = Picker.capture({ create = function()
					if boundary == "factory" then reenter() end
					return first
				end })
				helpers.assert_eq(extra, 0)
				helpers.assert_eq(nested.packet.unavailable, true)
				helpers.assert_eq(state.owner, first)
				Picker.close(state)
			end)
		end)
	end
	helpers.it("publishes retirement debt and revokes choices before native invalidation can reenter", function()
		shared(function(Picker)
			local state, nested, extra, old_admitted
			extra = 0
			local first = owner({ invalidate = function()
				old_admitted = Picker.confirm(state, "run_program", { providerKey = "opaque-choice" })
				nested = Picker.capture({ create = function() extra = extra + 1; return owner() end })
				return false
			end })
			state = Picker.capture({ create = function() return first end })
			helpers.assert_eq(Picker.close(state), false)
			helpers.assert_eq(old_admitted, false)
			helpers.assert_eq(extra, 0)
			helpers.assert_eq(nested.packet.unavailable, true)
			first.invalidate = function() return true end
			local recovered = Picker.capture({ create = function() extra = extra + 1; return owner() end })
			helpers.assert_eq(extra, 1)
			Picker.close(recovered)
		end)
	end)
end)

local function bridge_fixture(body)
	isolated(function()
		local f = { owners = {}, calls = {}, scripts = {}, visible = false, hide_refused = false }
		package.loaded.program_provider_picker = nil
		package.loaded["ui.action_picker.bridge"] = nil
		package.loaded["logger.shim"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["adapters.program_providers"] = { create = function()
			local state = owner(); f.owners[#f.owners + 1] = state; return state
		end }
		package.loaded["ui.webview_manager"] = {
			show = function() f.visible = true; return true end,
			hide = function() if f.hide_refused then return false end; f.visible = false; return true end,
			is_visible = function() return f.visible end,
			eval_js = function(_, script) f.scripts[#f.scripts + 1] = script; return true end,
		}
		f.bridge = require("ui.action_picker.bridge")
		function f.open(callback)
			return f.bridge.open({ items = {} }, callback or function(id, _, parameter)
				f.calls[#f.calls + 1] = { id, parameter }; return true
			end)
		end
		function f.confirm(extra)
			local message = extra or { action = "confirm", id = "run_program", providerKey = "opaque-choice", programArguments = {} }
			return f.bridge.on_message(message, {})
		end
		body(f)
	end)
end

helpers.describe("Production Linux program provider picker sessions", function()
	helpers.it("delivers the resolved scalar to the existing confirmation path then invalidates", function()
		bridge_fixture(function(f)
			helpers.assert_true(f.open())
			helpers.assert_eq(f.bridge.build_init_payload({ items = {} }).programProviders.choices[1].key, "opaque-choice")
			f.confirm()
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			helpers.assert_true(f.owners[1].retired)
			helpers.assert_eq(f.bridge.is_open(), false)
		end)
	end)
	helpers.it("cannot deliver an old binding after resolver-driven picker replacement", function()
		bridge_fixture(function(f)
			local old, replacement = 0, 0
			helpers.assert_true(f.open(function() old = old + 1; return true end))
			f.owners[1].resolve = function()
				helpers.assert_true(f.open(function() replacement = replacement + 1; return true end))
				return SCALAR
			end
			f.confirm()
			helpers.assert_eq(old, 0)
			helpers.assert_eq(replacement, 0)
			helpers.assert_true(f.bridge.is_open())
			f.confirm()
			helpers.assert_eq(replacement, 1)
		end)
	end)
	helpers.it("contains recursive provider confirmation before durable callback delivery", function()
		bridge_fixture(function(f)
			helpers.assert_true(f.open())
			local resolutions = 0
			f.owners[1].resolve = function()
				resolutions = resolutions + 1
				if resolutions == 1 then f.confirm() end
				return SCALAR
			end
			f.confirm()
			helpers.assert_eq(resolutions, 1)
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	helpers.it("keeps the exact provider alive when native hide refuses", function()
		bridge_fixture(function(f)
			helpers.assert_true(f.open(function() return false end))
			f.hide_refused = true
			f.bridge.on_message({ action = "cancel" }, {})
			helpers.assert_eq(f.owners[1].invalidations, 0)
			helpers.assert_eq(f.open(), false)
			helpers.assert_eq(#f.owners, 1)
			f.hide_refused = false
			f.bridge.on_message({ action = "cancel" }, {})
			helpers.assert_true(f.owners[1].retired)
		end)
	end)
	for _, invalid in ipairs({ true, 0, "", "foreign-choice" }) do
		helpers.it("refuses malformed or foreign opaque choices without callback: " .. tostring(invalid), function()
			bridge_fixture(function(f)
				helpers.assert_true(f.open())
				f.confirm({ action = "confirm", id = "run_program", providerKey = invalid })
				helpers.assert_eq(#f.calls, 0)
				helpers.assert_true(f.bridge.is_open())
				helpers.assert_eq(f.scripts[#f.scripts], "programProviderRefused()")
			end)
		end)
	end
	helpers.it("keeps manual confirmation working when discovery is unavailable", function()
		bridge_fixture(function(f)
			package.loaded["adapters.program_providers"] = { create = function() return nil end }
			helpers.assert_true(f.open())
			f.confirm({ action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
		end)
	end)
end)

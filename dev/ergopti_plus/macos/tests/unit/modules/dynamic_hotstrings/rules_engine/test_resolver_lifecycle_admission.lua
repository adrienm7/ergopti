--- tests/unit/modules/dynamic_hotstrings/rules_engine/test_resolver_lifecycle_admission.lua

--- ==============================================================================
--- MODULE: Dynamic Resolver Lifecycle Admission
--- DESCRIPTION:
--- Drives the real keymap, shared matcher, rules shim, expander and synthetic
--- ledger. A resolver may change its own lifecycle or configuration before it
--- returns; that stale value must never acquire replacement or preview ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local MAGIC = utf8.char(0x2605)

--- Supplies a physical key with the native accessors the real tap consumes.
--- @param char string Physical text.
--- @return table event
local function physical_event(char)
	local event = hs.eventtap.event.newKeyEvent({}, 0, true)
	event.getCharacters = function() return char end
	event.getKeyCode = function() return 0 end
	event.getFlags = function() return {} end
	event.getType = function() return hs.eventtap.event.types.keyDown end
	event.getProperty = function(_, property)
		return property == hs.eventtap.event.properties.eventSourceUnixProcessID and 99991 or 0
	end
	return event
end

--- Runs one coherent production stack and restores every require-time singleton.
--- @param scenario function Receives the stack and observed callback registrations.
local function with_stack(scenario)
	local prior_hs, prior_modules = _G.hs, {}
	for name, value in pairs(package.loaded) do prior_modules[name] = value end
	local km, rules
	local ok, err = xpcall(function()
		for name in pairs(package.loaded) do
			if name:match("^modules%.") or name:match("^adapters%.") or name:match("^infra%.")
				or name:match("^ui%.") or name:match("^logger%.") or name == "dynamic_hotstrings" then
				package.loaded[name] = nil
			end
		end
		km = helpers.load_with_stubs("modules.keymap")
		local observed = { interceptors = {}, providers = {}, physical = 0 }
		for method, records in pairs({ register_interceptor = observed.interceptors,
			register_preview_provider = observed.providers }) do
			local register = km[method]
			km[method] = function(callback)
				records[#records + 1] = callback
				return register(callback)
			end
		end
		rules = require("modules.dynamic_hotstrings.rules_engine")
		helpers.assert_true(rules.start(km))
		helpers.assert_true(km.enable_group("dynamichotstrings") ~= false)
		helpers.assert_true(km.enable_section("dynamichotstrings", "date") ~= false)
		km.register_interceptor(function() observed.physical = observed.physical + 1 end)
		local function watcher()
			return { start = function(self) return self end, stop = function(self) return self end }
		end
		local app = { pid = function() return 99991 end, name = function() return "Test Editor" end,
			newWatcher = watcher }
		local window = { id = function() return 17 end, title = function() return "Document" end,
			application = function() return app end, newWatcher = watcher }
		hs.window.focusedWindow = function() return window end
		helpers.assert_true(km.start())
		local tap
		for _, candidate in ipairs(hs.eventtap.__taps) do
			if candidate.types[1] == hs.eventtap.event.types.keyDown then tap = candidate; break end
		end
		helpers.assert_not_nil(tap)
		tap.fn(physical_event("z"))
		tap.fn(physical_event("z"))
		helpers.assert_eq(observed.physical, 2, "the native fixture must reach the real keymap buffer")
		scenario({ keymap = km, rules = rules, observed = observed, tap = tap,
			synthetic = require("adapters.synthetic_input") })
	end, debug.traceback)
	if rules then pcall(rules.stop) end
	if km then pcall(km.stop, true) end
	for name in pairs(package.loaded) do if prior_modules[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(prior_modules) do package.loaded[name] = value end
	_G.hs = prior_hs
	if not ok then error(err, 0) end
end

--- Invokes an already-delivered interceptor under the real callback collector.
--- @param fixture table Production stack.
--- @param callback function Exact retained rules callback.
--- @return any consumed
--- @return table|nil events
local function deliver_retained(fixture, callback)
	fixture.synthetic.enter_callback()
	local result = callback(physical_event(MAGIC), "zz", { chars = MAGIC, flags = {} })
	return fixture.synthetic.leave_callback(result == "consume")
end

helpers.describe("dynamic resolver ownership after callback execution", function()
	helpers.it("emits a healthy resolver through the real keymap (resolver-lifecycle-positive)", function()
		with_stack(function(fixture)
			helpers.assert_true(fixture.rules.add_rule("zz", "date", function() return "STALE" end))
			local consumed, events = fixture.tap.fn(physical_event(MAGIC))
			helpers.assert_true(consumed)
			helpers.assert_eq(#events, 14, "two deletions and five text pairs form one replacement")
			for _, event in ipairs(events) do
				local tag = event:getProperty(hs.eventtap.event.properties.eventSourceUserData)
				local metadata = fixture.synthetic.lookup_tag(tag)
				helpers.assert_true(metadata and metadata.owned)
				helpers.assert_eq(metadata.owner, "dynamic")
			end
		end)
	end)

	local mutations = {
		{ "disable-group", function(f) return f.keymap.disable_group("dynamichotstrings") end },
		{ "disable-section", function(f) return f.keymap.disable_section("dynamichotstrings", "date") end },
		{ "change-trigger", function(f) return f.rules.set_trigger_char(":") end },
		{ "replace-data", function(f) return f.rules.inject_data({}, MAGIC) end },
		{ "roundtrip-group", function(f)
			local disabled = f.keymap.disable_group("dynamichotstrings")
			local enabled = f.keymap.enable_group("dynamichotstrings")
			return disabled == true and enabled == true
		end },
	}
	for _, mutation in ipairs(mutations) do
		helpers.it("rejects a resolver after " .. mutation[1] .. " (resolver-lifecycle-" .. mutation[1] .. ")", function()
			with_stack(function(fixture)
				local mutation_result
				helpers.assert_true(fixture.rules.add_rule("zz", "date", function()
					mutation_result = mutation[2](fixture)
					return "STALE"
				end))
				local consumed, events = fixture.tap.fn(physical_event(MAGIC))
				helpers.assert_eq(mutation_result, true, "the lifecycle transition must actually commit")
				helpers.assert_eq(consumed, false, "revoked resolution must preserve the physical key")
				helpers.assert_nil(events, "revoked resolution must construct no synthetic replacement")
			end)
		end)
	end

	helpers.it("cannot inject an old result into a restarted owner (resolver-lifecycle-restart)", function()
		with_stack(function(fixture)
			local old_callback = fixture.observed.interceptors[1]
			local transitions = {}
			helpers.assert_true(fixture.rules.add_rule("zz", "date", function()
				transitions.stopped = fixture.rules.stop()
				transitions.started = fixture.rules.start(fixture.keymap)
				transitions.registered = fixture.rules.add_rule("zz", "date", function() return "FRESH" end)
				return "STALE"
			end))
			local consumed, events = deliver_retained(fixture, old_callback)
			helpers.assert_eq(transitions.stopped, true)
			helpers.assert_eq(transitions.started, true)
			helpers.assert_eq(transitions.registered, true)
			helpers.assert_eq(consumed, false)
			helpers.assert_nil(events, "the predecessor cannot acquire the successor's output port")
			local live_callback = fixture.observed.interceptors[#fixture.observed.interceptors]
			consumed, events = deliver_retained(fixture, live_callback)
			helpers.assert_true(consumed, "the successor must retain normal expansion admission")
			helpers.assert_eq(#events, 14)
		end)
	end)

	helpers.it("does not publish a preview resolved across stop (resolver-lifecycle-preview-stop)", function()
		with_stack(function(fixture)
			local stopped
			helpers.assert_true(fixture.rules.add_rule("zz", "date", function()
				stopped = fixture.rules.stop()
				return "STALE"
			end))
			local value, token = fixture.observed.providers[1]("zz")
			helpers.assert_eq(stopped, true)
			helpers.assert_nil(value)
			helpers.assert_nil(token, "retired resolution cannot mint a new visible-action lease")
		end)
	end)
end)

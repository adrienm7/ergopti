--- tests/unit/modules/hotstrings/test_dynamic_multibyte_trigger.lua

--- ==============================================================================
--- MODULE: Dynamic Hotstrings with the Canonical Multibyte Trigger
--- DESCRIPTION:
--- Drives the real Linux manager with the shipped `★` trigger. Lua substring
--- indexes are bytes, so removing or comparing one trailing byte cannot represent
--- this one-codepoint, three-byte trigger.
--- ==============================================================================

local helpers = require("tests.helpers")
local restore_family_preferences = require("tests.support.dynamic_hotstrings_fixture").install()


--- Runs one body with an observable injector and restores the package cache.
--- @param body function Receives manager, captured injections, and shared engine.
local function with_manager(body)
	local saved_manager = package.loaded["modules.dynamic_hotstrings.manager"]
	local saved_engine = package.loaded["dynamic_hotstrings"]
	local saved_injector = package.loaded["modules.hotstrings.injector"]
	package.loaded["modules.dynamic_hotstrings.manager"] = nil
	package.loaded["dynamic_hotstrings"] = nil

	local injections = {}
	package.loaded["modules.hotstrings.injector"] = {
		inject = function(count, text)
			injections[#injections + 1] = { count = count, text = text }
			return { ok = true }
		end,
	}

	local ok, err = xpcall(function()
		local manager = require("modules.dynamic_hotstrings.manager")
		manager.init({ personal_info_path = "/definitely/missing/personal_info.toml" })
		manager.set_enabled(true)
		body(manager, injections, require("dynamic_hotstrings"))
	end, debug.traceback)

	package.loaded["modules.hotstrings.injector"] = saved_injector
	package.loaded["dynamic_hotstrings"] = saved_engine
	package.loaded["modules.dynamic_hotstrings.manager"] = saved_manager
	if not ok then error(err, 0) end
end


helpers.describe("dynamic hotstrings: multibyte trigger", function()
	helpers.it("fires and previews through the shipped star trigger", function()
		with_manager(function(manager, injections)
			helpers.assert_not_nil(manager.preview("td★", true),
				"the tooltip must resolve the same canonical trigger as the fire path")
			local fired, event = manager.on_trigger("td★", "★", true)
			helpers.assert_true(fired == true,
				"the shipped three-byte trigger must fire as one screen character")
			helpers.assert_eq(#injections, 1)
			helpers.assert_eq(injections[1].count, 3,
				"two suffix codepoints plus one trigger codepoint must be deleted")
			helpers.assert_eq(event.backspace_count, 3)
			helpers.assert_eq(event.trigger, "td★")
		end)
	end)

	helpers.it("rejects a non-magic character passed by the daemon", function()
		with_manager(function(manager, injections)
			local fired, event = manager.on_trigger("tdx", "x")
			helpers.assert_true(fired == false,
				"the daemon passes every live character; only the configured magic key may open matching")
			helpers.assert_true(event == nil, "a rejected ordinary character must publish no expansion event")
			helpers.assert_eq(#injections, 0, "tdx must not inject the td date expansion")
		end)
	end)

	helpers.it("rejects an explicitly malformed or multi-codepoint trigger", function()
		local manager = helpers.load_module("modules.dynamic_hotstrings.manager")
		helpers.assert_true(manager.init({
			trigger_char = "ab",
			personal_info_path = "/definitely/missing/personal_info.toml",
		}) == false, "invalid configured triggers must fail closed rather than reuse a prior default")
		helpers.assert_true(manager.is_enabled() == false)
	end)
end)


require("test.dynamic_word_boundary_contract")(helpers)

local function daemon_source()
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
	local source = file:read("*a")
	file:close()
	return source
end

helpers.describe("Linux owned unknown-context reset boundaries", function()
	helpers.it("four actual reset prefixes cannot donate a beginning-of-word grant", function()
		local retained = require("dynamic_hotstrings")
		local retained_rules = retained.get_rules()
		local completed, failure = xpcall(function()
			with_manager(function(_, _, Dynamic)
				local source = daemon_source()
				local Core = require("hotstring_engine")
				Dynamic.reset_rules()
				Dynamic.register_date_rules("★")
				local count = 0
				for _, marker in ipairs({ "on_text_injected = function()", "reset_text = function()",
					"on_block = function()", "process_lifecycle.onFocusChange(function(appName, windowTitle)" }) do
					local start = assert(source:find(marker, 1, true), "actual callback must exist") + #marker
					local prefix = assert(source:sub(start):match("^(.-engine:reset%b())"), "callback reset must exist")
					local compile = loadstring or load
					local callback = assert(compile("return function(engine)\nlocal _undoable, _last_offered, tooltip_preview, llm_overlay\n"
						.. prefix .. "\nend", "@actual-unknown-reset-prefix"))()
					local engine = Core.new()
					helpers.assert_true(engine:load_mappings({ { trigger = "date", replacement = "owned-result", is_word = true } }))
					engine:reset(false)
					callback(engine)
					helpers.assert_eq(engine:buffer_starts_at_word_boundary(), false, marker)
					for _, character in ipairs({ "d", "a", "t", "e" }) do engine:on_char(character) end
					local ordinary = engine:candidates()
					helpers.assert_eq(#ordinary, 1, "ordinary preview retains its explanatory blocked row")
					helpers.assert_eq(ordinary[1].blocked, true, "ordinary matcher also retains the unknown context")
					helpers.assert_eq(ordinary[1].fires, false)
					helpers.assert_nil(Dynamic.match_buffer(engine:current_buffer(), "dynamic", nil,
						engine:buffer_starts_at_word_boundary()), "dynamic matcher consumes the same exact boundary")
					count = count + 1
				end
				helpers.assert_eq(count, 4)
				Dynamic.reset_rules()
			end)
		end, debug.traceback)
		helpers.assert_true(rawequal(package.loaded["dynamic_hotstrings"], retained), "the exact prior module owner must survive")
		helpers.assert_true(rawequal(retained.get_rules(), retained_rules), "the exact prior rule array must survive")
		if not completed then error(failure, 0) end
	end)
end)

helpers.describe("Linux builtin dynamic word-start owners", function()
	helpers.it("the actual daemon captures boundary with its buffer before prediction callbacks", function()
		with_manager(function(manager, injections)
			local source = daemon_source()
			local first = assert(source:find("if prediction_engine or (dyn_hotstrings and dyn_hotstrings.is_enabled()) then", 1, true))
			local last = assert(source:find("\n\n\n\tend\n\ton_char", first, true))
			local slice = source:sub(first, last - 1)
			local compile = loadstring or load
			local actor = assert(compile("return function(engine, prediction_engine, dyn_hotstrings, keylogger)\n"
				.. "local ch, app_id, tooltip_preview, result, now_ms = '★', 'owned-fixture', nil, nil, 0\n"
				.. slice .. "\nend", "@actual-dynamic-daemon-parent"))()
			local engine = require("hotstring_engine").new()
			engine:reset(false)
			for _, character in ipairs({ "d", "a", "t", "e", "★" }) do engine:on_char(character) end
			local predicted, recorded = 0, 0
			actor(engine, { on_char = function(_, buffer)
				predicted = predicted + 1
				helpers.assert_eq(buffer, "date★")
				engine:reset(true)
			end }, manager, { record_hotstring = function() recorded = recorded + 1 end })
			helpers.assert_eq(predicted, 1)
			helpers.assert_eq(#injections, 0, "the captured unknown buffer must not borrow a later boundary")
			helpers.assert_eq(recorded, 0)
		end)
	end)
	helpers.it("rejects update in the actual manager preview and firing paths", function()
		with_manager(function(manager, injections, Engine)
			local calls = 0
			for _, rule in ipairs(Engine.get_rules()) do
				local original = rule.resolver
				rule.resolver = function() calls = calls + 1; return original() end
			end
			helpers.assert_nil(manager.preview("update★", true))
			local fired, event = manager.on_trigger("update★", "★", true)
			helpers.assert_eq(fired, false)
			helpers.assert_nil(event)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(#injections, 0)
		end)
	end)
	helpers.it("uses the retained engine boundary through full magic-key buffers", function()
		with_manager(function(manager, injections)
			local engine = require("hotstring_engine").new()
			engine:reset(false)
			for _, char in ipairs({ "d", "a", "t", "e", "★" }) do engine:on_char(char) end
			local buffer = engine:current_buffer()
			local boundary = engine:buffer_starts_at_word_boundary()
			helpers.assert_eq(buffer, "date★")
			helpers.assert_eq(boundary, false)
			helpers.assert_nil(manager.preview(buffer, boundary))
			helpers.assert_eq(manager.on_trigger(buffer, "★", boundary), false)
			helpers.assert_eq(#injections, 0)
			engine:reset(true)
			for _, char in ipairs({ "d", "a", "t", "e", "★" }) do engine:on_char(char) end
			helpers.assert_not_nil(manager.preview(engine:current_buffer(), engine:buffer_starts_at_word_boundary()))
			helpers.assert_eq(manager.on_trigger(engine:current_buffer(), "★", engine:buffer_starts_at_word_boundary()), true)
			helpers.assert_eq(#injections, 1)
		end)
	end)
	helpers.it("keeps every personal prefix under the genuine ordinary matcher gate", function()
		local Prefix = require("modules.dynamic_hotstrings.prefix_rules")
		local Core = require("hotstring_engine")
		local entries = Prefix.build({ phone_number = "0612345678", phone_number_clean = "06 12 34 56 78",
			social_security_number = "1 99 99 99 999 999 99", iban = "FR00 0000 0000 0000" }, function() return true end)
		local count = 0
		for _, entry in ipairs(entries) do
			count = count + 1
			helpers.assert_true(entry.is_word == true)
			local mapping = { trigger = entry.trigger, match_mode = "exact", is_word = entry.is_word }
			helpers.assert_not_nil(Core.decide(mapping, "owned-result", entry.trigger, nil, true))
			helpers.assert_nil(Core.decide(mapping, "owned-result", entry.trigger, nil, false))
			for _, previous in ipairs({ "x", "1", "_", "é", "@" }) do
				helpers.assert_nil(Core.decide(mapping, "owned-result", entry.trigger, previous, true))
			end
		end
		helpers.assert_eq(count, 10)
	end)
end)

restore_family_preferences()

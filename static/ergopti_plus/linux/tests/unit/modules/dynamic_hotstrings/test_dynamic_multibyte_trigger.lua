--- tests/unit/modules/dynamic_hotstrings/test_dynamic_multibyte_trigger.lua

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
			local fired, event = require("tests.support.dynamic_hotstrings_fixture").trigger(manager, "td★", "★", true)
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
			local fired, event = require("tests.support.dynamic_hotstrings_fixture").trigger(manager, "tdx", "x")
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
				local gate_clears, wrap_clears = 0, 0
				local privacy_owners = { end_wrap_selection = function() gate_clears = gate_clears + 1 end }
				local wrap_on_type = { end_selection_window = function() wrap_clears = wrap_clears + 1 end }
				for _, marker in ipairs({ "on_text_injected = function()", "reset_text = function()",
					"on_block = function()", "process_lifecycle.onFocusChange(function(appName, windowTitle)" }) do
					local start = assert(source:find(marker, 1, true), "actual callback must exist") + #marker
					local prefix = assert(source:sub(start):match("^(.-engine:reset%b())"), "callback reset must exist")
					local compile = loadstring or load
					local callback = assert(compile("return function(engine, privacy_owners, wrap_on_type)\nlocal keystats = require(\"modules.keystats.keystats\")\nlocal _undoable, _last_offered, tooltip_preview, llm_overlay\n"
						.. prefix .. "\nend", "@actual-unknown-reset-prefix"))()
					local engine = Core.new()
					helpers.assert_true(engine:load_mappings({ { trigger = "date", replacement = "owned-result", is_word = true } }))
					engine:reset(false)
					callback(engine, privacy_owners, wrap_on_type)
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
				helpers.assert_true(gate_clears >= 1, "the actual capture-gate prefix must revoke its wrap owner")
				helpers.assert_true(wrap_clears >= 1, "the actual focus prefix must close its selection window")
				Dynamic.reset_rules()
			end)
		end, debug.traceback)
		helpers.assert_true(rawequal(package.loaded["dynamic_hotstrings"], retained), "the exact prior module owner must survive")
		helpers.assert_true(rawequal(retained.get_rules(), retained_rules), "the exact prior rule array must survive")
		if not completed then error(failure, 0) end
	end)
end)

-- unknown-context-resets: a pause, an uncommitted output, a replaced selection,
-- an undo, a typed action result and lost input all leave the caret after text
-- this engine never buffered. A plain reset declared a word start there, so
-- "adn" restored by Undo followed by "dt★" fired the date inside the word.
local UNKNOWN_CONTEXT_MARKERS = {
	"reset = function()",
	"if remaining >= 1 then",
	"invalidated = true",
	"local result = injector.inject(0, text, false, nil, publication)",
	"onDesync = function()",
}

-- Plain resets are reserved for genuine word starts: an idle pause, a
-- final_result expansion and a consumed dynamic trigger.
-- The idle pause starts its word through engine:reset_after_pause(), which
-- keeps an empty line it knows of (the next test checks that call).
local BOUNDARY_RESET_CONTEXTS = {
	"if result.final_result then",
	"Dynamic expansion consumed the trigger",
}

helpers.describe("Linux reviewed unknown-context resets (unknown-context-resets)", function()
	helpers.it("each reviewed daemon reset leaves the next word start unknown", function()
		local source = daemon_source()
		local Core = require("hotstring_engine")
		local compile = loadstring or load
		local count = 0
		for _, marker in ipairs(UNKNOWN_CONTEXT_MARKERS) do
			local first = source:find(marker, 1, true)
			helpers.assert_true(first ~= nil, "reviewed reset site must exist: " .. marker)
			helpers.assert_nil(source:find(marker, first + 1, true), "reviewed marker must be unique: " .. marker)
			local prefix = assert(source:sub(first + #marker):match("^(.-engine:reset%b())"), "site must reset: " .. marker)
			local callback = assert(compile("return function(engine, injector, Logger)\n"
				.. "local keystats = require(\"modules.keystats.keystats\")\n"
				.. "local _undoable, _last_offered, tooltip_preview, llm_overlay, prediction_engine\n"
				.. "local LOG, undo, text, publication = \"fixture\", { trigger = \"adn\" }, \"owned\", {}\n"
				-- The marker line itself is not part of the prefix: seed what it bound.
				.. "local remaining, result = 3, { ok = true }\n"
				.. prefix .. "\nend", "@reviewed-unknown-reset-prefix"))()
			local engine = Core.new()
			helpers.assert_true(engine:load_mappings({ { trigger = "dt", replacement = "owned-date",
				is_word = true, auto_expand = true } }))
			-- Positive control: the same mapping fires from a genuine word start.
			engine:reset(true)
			engine:on_char("d")
			helpers.assert_not_nil(engine:on_char("t"), "the control mapping fires at a known word start")
			engine:reset(true)
			callback(engine, { inject = function() return { ok = true } end }, { info = function() end })
			helpers.assert_eq(engine:buffer_starts_at_word_boundary(), false, marker)
			engine:on_char("d")
			helpers.assert_nil(engine:on_char("t"), "no word-start mapping fires after " .. marker)
			count = count + 1
		end
		helpers.assert_eq(count, #UNKNOWN_CONTEXT_MARKERS)
	end)

	helpers.it("every daemon reset names whether a word starts", function()
		local source = daemon_source()
		local plain, explicit = 0, 0
		local position = 1
		while true do
			local first, last, argument = source:find("engine:reset(%b())", position)
			if not first then break end
			position = last + 1
			local inner = argument:sub(2, -2)
			if inner == "" then
				local context = source:sub(math.max(1, first - 600), first)
				local allowed = false
				for _, marker in ipairs(BOUNDARY_RESET_CONTEXTS) do
					if context:find(marker, 1, true) then allowed = true end
				end
				helpers.assert_true(allowed, "a plain reset outside a known word start, near byte " .. first)
				plain = plain + 1
			else
				helpers.assert_true(inner == "false" or inner == "at_word_start",
					"a reset argument must be false or the click setting, got " .. inner)
				explicit = explicit + 1
			end
		end
		helpers.assert_eq(plain, #BOUNDARY_RESET_CONTEXTS, "each genuine word-start reset is accounted for")
		local idle = source:find("if WordReset.observe_key(now_ms) then", 1, true)
		local pause = source:find("if engine:reset_after_pause() then", 1, true)
		helpers.assert_true(idle ~= nil and pause ~= nil and idle < pause,
			"the idle pause starts a word through the engine (bs-word-start)")
		helpers.assert_true(explicit >= #UNKNOWN_CONTEXT_MARKERS, "the reviewed sites pass an explicit boundary")
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
			local actor = assert(compile("return function(engine, prediction_engine, dyn_hotstrings, keystats)\n"
				.. "local ch, app_id, tooltip_preview, result, now_ms = '★', 'owned-fixture', nil, nil, 0\n"
				.. "local opts = { dry_run = false }\n"
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
			local fired, event = require("tests.support.dynamic_hotstrings_fixture").trigger(manager, "update★", "★", true)
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
			helpers.assert_eq(require("tests.support.dynamic_hotstrings_fixture").trigger(manager, buffer, "★", boundary), false)
			helpers.assert_eq(#injections, 0)
			engine:reset(true)
			for _, char in ipairs({ "d", "a", "t", "e", "★" }) do engine:on_char(char) end
			helpers.assert_not_nil(manager.preview(engine:current_buffer(), engine:buffer_starts_at_word_boundary()))
			helpers.assert_eq(require("tests.support.dynamic_hotstrings_fixture").trigger(manager, engine:current_buffer(), "★", engine:buffer_starts_at_word_boundary()), true)
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

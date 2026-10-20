--- tests/unit/modules/dynamic_hotstrings/test_dynamic_destination.lua

--- ==============================================================================
--- MODULE: Single-Field Dynamic Expansion Destination
--- DESCRIPTION:
--- Drives the original Main callback, dynamic manager and native input consumers
--- with official software fixtures. A retired field cannot receive an expansion
--- after metrics, prediction or the injector's erase-settle boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local root = helpers.driver_root()

--- Exercises one isolated real manager and input/output session.
--- @param family string Personal or date rule family.
--- @param change string Stable, retirement boundary or missing-owner contract.
--- @param route string Static comparison or dynamic fallback.
local function run_case(family, change, route)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local previous_rules = saved.dynamic_hotstrings and saved.dynamic_hotstrings.get_rules()
	for name in pairs(saved) do
		if name:match("^modules%.") or name:match("^adapters%.") or name:match("^infra%.")
			or name:match("^platform%.") or name == "logger.shim" or name == "dynamic_hotstrings" then
			package.loaded[name] = nil
		end
	end
	local restore_preferences, injector, capture
	local path = os.tmpname()
	local file = assert(io.open(path, "wb"))
	assert(file:write('[info]\nfirst_name = "ok"\n[letters]\np = "first_name"\n')); assert(file:close())
	local completed, detail = pcall(function()
		require("tests.support.text_owner_fixture").with(function(guard, state, _, policy, watch)
			local fixture = require("tests.support.dynamic_hotstrings_fixture")
			local preference_path
			restore_preferences, preference_path = fixture.route()
			local paths = require("infra.config_paths")
			local original_config = paths.config
			paths.config = function(name)
				if name == "config.toml" then return preference_path end
				return original_config(name)
			end
			local dynamic = helpers.load_module("modules.dynamic_hotstrings.manager")
			assert(dynamic.init({ trigger_char = "★", personal_info_path = path }))
			assert(dynamic.set_enabled(true)); fixture.prefer_families(dynamic)
			local repeat_key = helpers.load_module("modules.hotstrings.repeat_key")
			assert(repeat_key.set_enabled(false))
			local trigger = family == "date" and "dt★" or "@p★"
			local replacement = assert(dynamic.preview(trigger, true))
			local text_by_code = { [30] = "@", [25] = "p", [32] = "d", [20] = "t", [43] = "★",
				[24] = "o", [37] = "k", [53] = "/" }
			local plan = { o = { keycode = 24, mods = {} }, k = { keycode = 37, mods = {} },
				["/"] = { keycode = 53, mods = {} } }
			for digit = 0, 9 do
				local code = digit == 0 and 11 or digit + 1
				text_by_code[code] = tostring(digit); plan[tostring(digit)] = { keycode = code, mods = {} }
			end
			local symbols = {}
			for code, text in pairs(text_by_code) do symbols[code + 8] = text end
			capture = helpers.load_module("adapters.xkb_capture")
			capture._set_backend({ create = function() return {} end, destroy = function() end,
				capture_group = function() return 0 end,
				key_sym = function(_, code)
					local text = symbols[code]; return text == "★" and 0x1002605 or text and text:byte() or 0
				end,
				key_utf8 = function(_, code) return symbols[code] or "" end,
				sym_utf8 = function(_, symbol)
					return symbol == 0x1002605 and "★" or symbol > 0 and string.char(symbol) or ""
				end,
				update_key = function() end, compose_feed = function() end,
				compose_status = function() return "nothing" end, compose_utf8 = function() end,
				compose_reset = function() end, inverse = function() return plan end,
			})
			assert(capture.load("controlled actual XKB adapter", "C"))
			local documents = { ["/field/original"] = "", ["/field/successor"] = "SAFE" }
			local moved, commits, callback, characters = false, 0, nil, {}
			local function retire()
				if moved then return end
				moved = true; state.path = "/field/successor"; watch.barrier()
				helpers.assert_true(guard.blocks_text(), "the original guard must observe the successor field")
			end
			require("tests.support.input_owner_fixture").with_session({ capture = capture, keys = {}, position_bits = true,
				on_char = function(char, ...)
					characters[#characters + 1] = char; return callback(char, ...)
				end,
				after_sync = function(_, code, value)
					if value ~= 1 then return end
					local text = documents[state.path]
					if code == 14 then
						local last = 0
						for position in text:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do last = position end
						text = last > 0 and text:sub(1, last - 1) or text
					else text = text .. (text_by_code[code] or "") end
					documents[state.path] = text
				end,
			}, function(session)
				assert(session.hook.set_remapper(nil))
				local layout = helpers.load_module("adapters.keyboard_layout")
				layout._set_table_for_test(plan)
				injector = helpers.load_module("modules.hotstrings.injector")
				injector._set_uinput(session.writer)
				local source_file = assert(io.open(root .. "/modules/hotstrings/injector.lua", "rb"))
				local settle = assert(tonumber(source_file:read("*a"):match("local INTER_PHASE_DELAY_MS = (%d+)")))
				assert(source_file:close())
				injector._set_nanosleep_for_test(function(seconds)
					if change == "settle" and seconds == settle / 1000 then retire() end
				end)
				if change == "absent" or change == "deferred" then
					local destination = change == "deferred" and assert(guard.capture_text_owner()) or nil
					if destination then retire() end
					local fired, event = dynamic.on_trigger(trigger, "★", true, destination)
					helpers.assert_eq(fired, false, "missing or retired publication must refuse the single-field API")
					helpers.assert_nil(event)
					helpers.assert_eq(#session.rows, 0, "refusal must precede any authored key")
				else
					local engine_mod = require("modules.hotstrings.engine")
					local engine = engine_mod.new()
					local mappings = dynamic.prefix_mappings()
					if route == "static" then
						mappings[#mappings + 1] = { auto_expand = true, trigger = trigger,
							replacement = replacement, group = "owned-static" }
					end
					engine:load_mappings(mappings)
					local scripts = require("modules.shortcuts.script_actions").new({ reset = function() engine:reset() end,
						reload = function() error("unexpected reload") end, quit = function() error("unexpected quit") end })
					local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
					logger.set_sink(function() end)
					local metrics = setmetatable({ on_keydown = function(char)
						if change == "metrics" and char == "★" then retire() end
					end, record_hotstring = function() commits = commits + 1 end }, { __index = policy })
					local environment = setmetatable({ secure_focus_guard = guard, script_actions = scripts,
						Monotonic = require("infra.monotonic"), WordReset = require("modules.hotstrings.word_reset"),
						terminators_mod = require("keymap.terminators"), RepeatKey = repeat_key,
						MagicKey = require("modules.hotstrings.magic_key"), opts = { dry_run = false },
						_cached_app_id = "owned-editor", keylogger = metrics, engine_mod = engine_mod,
						engine = engine, dyn_hotstrings = dynamic, injector = injector, Logger = logger,
						prediction_engine = change == "prediction" and { on_char = function(char)
							if char == "★" then retire() end
						end } or nil,
					}, { __index = _G })
					local main_file = assert(io.open(root .. "/ergopti_hotstrings.lua", "rb"))
					local source = main_file:read("*a"); assert(main_file:close())
					local first = assert(source:find("\tlocal function handle_char(", 1, true))
					local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
					local body = "local _undoable; local _last_offered; local on_char; "
						.. source:sub(first, last - 1) .. "\non_char=handle_char; return handle_char"
					local compiled
					if loadstring then compiled = assert(loadstring(body)); setfenv(compiled, environment)
					else compiled = assert(load(body, "original Main handle_char", "t", environment)) end
					callback = require("infra.input_capture_gate").new().guard(compiled())
					local codes = family == "date" and { 32, 20, 43 } or { 30, 25, 43 }
					for index, code in ipairs(codes) do
						session.edge("a", code, 1, 1000 + index * 10)
						session.edge("a", code, 0, 1001 + index * 10)
					end
					helpers.assert_eq(table.concat(characters), trigger, "original Reader and Hook must deliver the trigger")
					helpers.assert_eq(moved, change ~= "stable", "the chosen callback or settle boundary must execute")
					if change == "stable" then
						helpers.assert_eq(documents["/field/original"], replacement)
						helpers.assert_eq(commits, 1)
					else
						helpers.assert_eq(commits, 0, "failed publication cannot record an expansion")
						if route ~= "static" then helpers.assert_eq(engine:current_buffer(), trigger) end
					end
				end
				local held = {}
				for _, row in ipairs(session.rows) do
					if row[2] == 1 then held[row[1]] = true elseif row[2] == 0 then held[row[1]] = nil end
				end
				helpers.assert_nil(next(held), "every authored key must receive its release")
				helpers.assert_eq(documents["/field/successor"], "SAFE", "the successor field must remain unchanged")
			end)
			paths.config = original_config
		end)
	end)
	if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
	if capture then capture._reset_backend() end
	if restore_preferences then restore_preferences() end
	os.remove(path)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if previous_rules then
		helpers.assert_true(rawequal(saved.dynamic_hotstrings.get_rules(), previous_rules),
			"the prior shared rule owner must remain unchanged")
	end
	if not completed then error(detail, 0) end
end

helpers.describe("single-field dynamic expansions retain their original destination", function()
	for _, family in ipairs({ "personal", "date" }) do
		for _, change in ipairs({ "stable", "settle", "metrics", "prediction", "absent", "deferred" }) do
			helpers.it("dynamic-destination " .. family .. " " .. change, function()
				run_case(family, change, "dynamic")
			end)
		end
	end
	for _, change in ipairs({ "stable", "settle" }) do
		helpers.it("dynamic-destination static comparison " .. change, function()
			run_case("personal", change, "static")
		end)
	end
end)

--- tests/unit/modules/shortcuts/test_tap_keys_canonical.lua

--- Exercises canonical assignment loading, sparse publication and save baselines.
local helpers = require("tests.helpers")
local Codec = require("toml_codec")

local function with_fixture(source, body)
	local names = { "adapters.file_system", "adapters.storage", "infra.preferences",
		"infra.config_paths", "infra.paths", "modules.shortcuts.tap_keys" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local control = { content = source, writes = 0 }
	local ok, err = pcall(function()
		helpers.load_with_stubs("infra.preferences")
		package.loaded["adapters.storage"] = setmetatable({}, { __index = function()
			return function() error("canonical assignments must not consult legacy storage") end
		end })
		package.loaded["infra.config_paths"] = { get = function(name)
			assert(name == "ConfigTomlPath"); return "config"
		end }
		package.loaded["infra.paths"] = { shared = function(rel) return helpers.shared(rel) end }
		package.loaded["adapters.file_system"] = {
			read = function(path)
				local file = assert(io.open(path, "rb")); local value = file:read("*a"); file:close(); return value
			end,
			read_with_status = function() return control.content, control.unreadable and "error" or (control.content and "ok" or "absent") end,
			write = function() error("conditional publication required") end,
			write_if_unchanged = function(_, candidate, expected)
				if control.refuse then return false end
				if control.before_write then control.before_write(candidate) end
				if expected.content ~= control.content then return false end
				control.content, control.writes = candidate, control.writes + 1; return true
			end,
		}
		package.loaded["infra.preferences"], package.loaded["modules.shortcuts.tap_keys"] = nil, nil
		local preferences = require("infra.preferences")
		preferences.load("config")
		local taps = require("modules.shortcuts.tap_keys")
		local assignable = function(action) return action == "send_text" or action == "screen_capture" end
		body(taps, preferences, control, assignable)
	end)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("canonical macOS tap-key assignments", function()
	helpers.it("loads canonical choices and never activates legacy storage on absent config", function()
		with_fixture('[shortcuts.tap_keys]\nnumber_row_left = "send_text"\nforeign = "screen_capture"\n', function(taps, _, control, valid)
			taps.load(valid)
			helpers.assert_eq(taps.decide(50), "send_text")
			local marks = {}
			taps.mark_config_reads(Codec.decode(control.content), function(...) marks[table.concat({ ... }, ".")] = true end)
			helpers.assert_eq(marks["shortcuts.tap_keys.number_row_left"], true)
			helpers.assert_nil(marks["shortcuts.tap_keys.foreign"])
			local scan = require("config_unused_keys").find_in_source(control.content,
				require("ui.menu.unused_keys_cleanup").collect)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "foreign")
			control.content = nil
			taps._reset(); taps.load(valid)
			helpers.assert_nil(taps.decide(50))
			helpers.assert_eq(control.writes, 0)
		end)
	end)

	helpers.it("publishes sparse assignments and advances the ordinary preference baseline", function()
		with_fixture('[shortcuts.tap_keys]\nforeign = "keep"\n[other]\nvalue = 7\n', function(taps, preferences, control, valid)
			taps.load(valid)
			helpers.assert_eq(taps.set_action("number_row_left", "send_text", valid), true)
			helpers.assert_eq(Codec.decode(control.content).shortcuts.tap_keys.number_row_left, "send_text")
			helpers.assert_eq(preferences.save("config", { shortcuts = false }, {}, {}), true)
			helpers.assert_eq(taps.set_action("number_row_left", "none", valid), true)
			local decoded = Codec.decode(control.content)
			helpers.assert_nil(decoded.shortcuts.tap_keys.number_row_left)
			helpers.assert_eq(decoded.shortcuts.tap_keys.foreign, "keep")
			helpers.assert_eq(decoded.other.value, 7)
		end)
	end)

	helpers.it("preserves inline neighbors and refuses failed writes without changing dispatch", function()
		with_fixture('[shortcuts]\ntap_keys = { number_row_left = "send_text", foreign = "keep" }\nfuture = 9\n', function(taps, preferences, control, valid)
			taps.load(valid)
			local before = control.content
			control.refuse = true
			helpers.assert_eq(taps.set_action("number_row_left", "screen_capture", valid), false)
			helpers.assert_eq(taps.decide(50), "send_text")
			helpers.assert_eq(control.content, before)
			control.refuse = false
			helpers.assert_eq(taps.set_action("number_row_left", "none", valid), true)
			local decoded = Codec.decode(control.content)
			helpers.assert_nil(decoded.shortcuts.tap_keys.number_row_left)
			helpers.assert_eq(decoded.shortcuts.tap_keys.foreign, "keep")
			helpers.assert_eq(decoded.shortcuts.future, 9)
			helpers.assert_eq(preferences.save("config", { shortcuts = false }, {}, {}), true)
		end)
	end)

	helpers.it("publishes existing root inline scalar assignments with exact source and fresh dispatch receipts", function()
		local before = 'shortcuts = { tap_keys = { number_row_left = "send_text", foreign = "keep" } }\n'
		local changed = 'shortcuts = { tap_keys = { number_row_left = "screen_capture", foreign = "keep" } }\n'
		local removed = 'shortcuts = { tap_keys = { foreign = "keep" } }\n'
		with_fixture(before, function(taps, preferences, control, valid)
			taps.load(valid)
			local baseline = preferences.source_snapshot("config")
			control.refuse = true
			helpers.assert_eq(taps.set_action("number_row_left", "screen_capture", valid), false)
			helpers.assert_eq(control.content, before)
			helpers.assert_eq(control.writes, 0)
			helpers.assert_eq(taps.decide(50), "send_text")
			helpers.assert_eq(preferences.source_snapshot("config"), baseline)
			control.refuse = false
			helpers.assert_eq(taps.set_action("number_row_left", "screen_capture", valid), true)
			helpers.assert_eq(control.content, changed)
			helpers.assert_eq(control.writes, 1)
			helpers.assert_eq(preferences.source_snapshot("config").content, changed)
			for _, code in ipairs({ 50, 10 }) do
				local action, binding = taps.decide(code)
				helpers.assert_eq(action, "screen_capture")
				helpers.assert_eq(binding, "tap_key__number_row_left")
			end
			package.loaded["modules.shortcuts.tap_keys"] = nil
			local fresh = require("modules.shortcuts.tap_keys")
			fresh.load(valid)
			helpers.assert_eq(fresh.get_action("number_row_left"), "screen_capture")
			helpers.assert_eq(fresh.decide(50), "screen_capture")
			helpers.assert_eq(fresh.set_action("number_row_left", "none", valid), true)
			helpers.assert_eq(control.content, removed)
			helpers.assert_eq(control.writes, 2)
			helpers.assert_eq(preferences.source_snapshot("config").content, removed)
			package.loaded["modules.shortcuts.tap_keys"] = nil
			local restarted = require("modules.shortcuts.tap_keys")
			restarted.load(valid)
			helpers.assert_eq(restarted.get_action("number_row_left"), "none")
			for _, code in ipairs({ 50, 10 }) do
				local action, binding = restarted.decide(code)
				helpers.assert_nil(action); helpers.assert_nil(binding)
			end
		end)
	end)

	helpers.it("retains loaded dispatch on unreadable malformed and externally changed sources", function()
		for _, failure in ipairs({ "unreadable", "malformed", "external" }) do
			with_fixture('[shortcuts.tap_keys]\nnumber_row_left = "send_text"\n', function(taps, preferences, control, valid)
				taps.load(valid)
				local baseline = preferences.source_snapshot("config")
				if failure == "unreadable" then control.unreadable = true
				elseif failure == "malformed" then control.content = "[broken"
				else control.content = control.content .. "foreign = 42\n" end
				helpers.assert_eq(taps.set_action("number_row_left", "none", valid), false)
				helpers.assert_eq(control.writes, 0)
				helpers.assert_eq(taps.decide(50), "send_text")
				helpers.assert_eq(preferences.source_snapshot("config").content, baseline.content)
				if failure ~= "external" then helpers.assert_throws(function() taps.load(valid) end) end
				helpers.assert_eq(taps.decide(50), "send_text")
			end)
		end
	end)

	helpers.it("rejects baseline changes and nested assignments during conditional publication", function()
		with_fixture('[shortcuts.tap_keys]\nnumber_row_left = "send_text"\n', function(taps, preferences, control, valid)
			taps.load(valid)
			local source = preferences.source_snapshot("config")
			control.before_write = function(candidate)
				helpers.assert_eq(taps.set_action("number_row_left", "none", valid), false)
				helpers.assert_eq(preferences.save("config", {}, {}, {}), false)
				helpers.assert_eq(preferences.replace_source("config", source, { status = "ok", content = candidate }), false)
				helpers.assert_eq(preferences.adopt_cleanup("config", source.content, candidate), false)
				local failure = helpers.assert_throws(function() preferences.load("config") end)
				helpers.assert_contains(failure, "preference publication is still active")
			end
			helpers.assert_eq(taps.set_action("number_row_left", "screen_capture", valid), true)
			helpers.assert_eq(control.writes, 1)
			helpers.assert_eq(taps.decide(50), "screen_capture")
			helpers.assert_eq(preferences.source_snapshot("config").content, control.content)
		end)
	end)
end)

helpers.describe("tap-key scope candidate application", function()
	helpers.it("applies and compensates exact memory choices without publishing the config source", function()
		with_fixture('[shortcuts.tap_keys]\nnumber_row_left = "send_text"\n', function(taps, _, control, valid)
			taps.load(valid)
			local source = control.content
			helpers.assert_eq(taps.apply_configuration({ shortcuts = { tap_keys = { number_row_right_1 = "screen_capture" } } }, valid), true)
			helpers.assert_eq(taps.get_action("number_row_left"), "none")
			helpers.assert_eq(taps.get_action("number_row_right_1"), "screen_capture")
			helpers.assert_eq(taps.apply_configuration(Codec.decode(source), valid), true)
			helpers.assert_eq(taps.get_action("number_row_left"), "send_text")
			helpers.assert_eq(taps.get_action("number_row_right_1"), "none")
			helpers.assert_eq(control.content, source)
			helpers.assert_eq(control.writes, 0)
		end)
	end)

	helpers.it("refuses invalid owned leaves without changing any current assignment", function()
		with_fixture('[shortcuts.tap_keys]\nnumber_row_left = "send_text"\n', function(taps, _, control, valid)
			taps.load(valid)
			helpers.assert_eq(taps.apply_configuration({ shortcuts = { tap_keys = { number_row_left = "unknown_action" } } }, valid), false)
			helpers.assert_eq(taps.get_action("number_row_left"), "send_text")
			helpers.assert_eq(taps.apply_configuration({ shortcuts = { tap_keys = false } }, valid), false)
			helpers.assert_eq(control.writes, 0)
		end)
	end)
end)

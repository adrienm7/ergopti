--- tests/unit/modules/hotstrings/test_word_reset.lua

--- ==============================================================================
--- MODULE: Word Reset — Unit Tests (Linux)
--- DESCRIPTION:
--- When the hotstring buffer forgets the current word: after a pause without
--- typing (`hotstrings.idle_reset_seconds`) and on a pointer click
--- (`hotstrings.click_resets_word`). Before these settings the buffer kept the
--- last word forever and a click reset it at an unknown position, so the first
--- word typed after a pause or a click never fired a word-start hotstring.
---
--- Covered: the shared pause rule, the settings owner (defaults, validation,
--- sparse persistence, outdated values) of the pause, click, arrow, shortcut
--- and tap-hold leaves, the keystroke stamp, the free-entry parser, the menu's
--- choice row with its free entry, and the daemon wiring. What an arrow, a
--- shortcut or a tap-hold does to a typed word is test_word_reset_events.lua.
--- ==============================================================================

local helpers = require("tests.helpers")

local Engine = require("hotstring_engine")




-- =================================================================
-- =================================================================
-- ======= 1/ The shared pause rule ================================
-- =================================================================
-- =================================================================

helpers.describe("word reset: the shared pause rule", function()
	helpers.it("word reset, starts a new word once the pause reaches the delay", function()
		helpers.assert_true(Engine.idle_resets_word(1000, 4000, 3, 0), "exactly the delay starts a word")
		helpers.assert_true(Engine.idle_resets_word(1000, 9000, 3, 0))
		helpers.assert_eq(Engine.idle_resets_word(1000, 3999, 3, 0), false, "a shorter pause keeps the word")
		helpers.assert_true(Engine.idle_resets_word(0, 1500, 1.5, 0), "a fractional delay is honoured")
	end)

	helpers.it("word reset, never resets with a delay of 0 or before the first keystroke", function()
		helpers.assert_eq(Engine.idle_resets_word(0, 1e9, 0, 0), false, "0 disables the reset")
		helpers.assert_eq(Engine.idle_resets_word(nil, 1e9, 3, 0), false, "no previous key, no pause")
	end)

	helpers.it("word reset, takes the clock resolution off the measured gap", function()
		helpers.assert_eq(Engine.idle_resets_word(5999, 7000, 1, 1000), false,
			"two keys across a whole-second turnover are no pause")
		helpers.assert_true(Engine.idle_resets_word(5000, 7000, 1, 1000), "a provable pause still resets")
	end)

	helpers.it("word reset, refuses an invalid delay or resolution loudly", function()
		for _, bad in ipairs({ -1, 0 / 0, math.huge, "3", false }) do
			local ok, err = pcall(Engine.idle_resets_word, 0, 1, bad, 0)
			helpers.assert_eq(ok, false, tostring(bad))
			helpers.assert_true(tostring(err):find("idle delay", 1, true) ~= nil, "names the delay: " .. tostring(bad))
		end
		for _, bad in ipairs({ -1, false }) do
			local ok, err = pcall(Engine.idle_resets_word, 0, 1, 3, bad or nil)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("clock resolution", 1, true) ~= nil, "names the resolution")
		end
	end)

	helpers.it("word reset, validates a configured delay", function()
		for _, good in ipairs({ 0, 1, 2.5, 3600 }) do helpers.assert_true(Engine.valid_idle_reset_seconds(good)) end
		for _, bad in ipairs({ -0.1, 0 / 0, math.huge, "3", true }) do
			helpers.assert_eq(Engine.valid_idle_reset_seconds(bad), false, tostring(bad))
		end
		helpers.assert_eq(Engine.valid_idle_reset_seconds(nil), false)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 2/ The settings owner ===================================
-- =================================================================
-- =================================================================

--- Runs the owner over an exclusive config file and an isolated module cache.
--- @param source string|nil Configuration bytes.
--- @param body function body(subject, controls, path, reload, sandbox)
local function with_settings(source, body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Writer = require("toml_codec.writer")
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local original = Writer.batch_write
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local controls = {}
			package.loaded["infra.config_paths"] = { config = function() return path end }
			Writer.batch_write = function(target, operations, files, expected)
				if controls.refuse then return false, "injected publication refusal" end
				return original(target, operations, files, expected)
			end
			local function reload()
				package.loaded["modules.hotstrings.word_reset"] = nil
				return require("modules.hotstrings.word_reset")
			end
			body(reload(), controls, path, reload, Sandbox)
		end)
	end)
	Writer.batch_write = original
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

-- The boolean leaves, each with its getter, setter and toggle of the same name.
local SWITCHES = { "click_resets_word", "arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word" }

helpers.describe("word reset: the settings", function()
	helpers.it("word reset, reads the manifest defaults from an empty configuration", function()
		with_settings(nil, function(subject)
			local Manifest = require("infra.manifest_reader")
			helpers.assert_eq(subject.idle_seconds(), 3, "a pause of 3 s starts a new word by default")
			helpers.assert_eq(subject.click_resets_word(), true, "a click starts a new word by default")
			for _, key in ipairs(SWITCHES) do
				local default = Manifest.default_for("hotstrings." .. key)
				helpers.assert_eq(type(default), "boolean", key .. " has a manifest default")
				helpers.assert_eq(subject[key](), default, key .. " reads the manifest default")
			end
			helpers.assert_eq(subject.arrow_resets_word(), true, "an arrow starts a new word by default")
			helpers.assert_eq(subject.shortcut_resets_word(), true, "a shortcut starts a new word by default")
			helpers.assert_eq(subject.tap_hold_resets_word(), true, "a tap-hold command starts a new word by default")
		end)
	end)

	helpers.it("word reset, reads stored values, 0 included", function()
		with_settings("[hotstrings]\nidle_reset_seconds = 0\nclick_resets_word = false\narrow_resets_word = false\n"
			.. "shortcut_resets_word = false\ntap_hold_resets_word = false\n", function(subject)
			helpers.assert_eq(subject.idle_seconds(), 0)
			for _, key in ipairs(SWITCHES) do helpers.assert_eq(subject[key](), false, key) end
		end)
	end)

	helpers.it("word reset, persists, reloads and toggles every switch on its own", function()
		with_settings('[hotstrings]\nunknown = "keep"\n', function(subject, _, path, reload, sandbox)
			local Codec = require("toml_codec")
			for _, key in ipairs(SWITCHES) do
				helpers.assert_true(subject["set_" .. key](false), key .. " is persisted")
				local stored = Codec.decode(sandbox.read_bytes(path)).hotstrings
				helpers.assert_eq(stored[key], false, key .. " is written")
				helpers.assert_eq(stored.unknown, "keep", "a neighbour survives " .. key)
			end
			local fresh = reload()
			for _, key in ipairs(SWITCHES) do helpers.assert_eq(fresh[key](), false, key .. " reads back") end
			for _, key in ipairs(SWITCHES) do
				helpers.assert_true(fresh["toggle_" .. key](), key .. " toggles")
				helpers.assert_eq(fresh[key](), true)
				helpers.assert_eq(Codec.decode(sandbox.read_bytes(path)).hotstrings[key], nil,
					key .. ": the default is written as an absent leaf")
			end
			for _, key in ipairs(SWITCHES) do
				helpers.assert_eq(fresh["set_" .. key]("no"), false, key .. " refuses a non-boolean")
			end
		end)
	end)

	helpers.it("word reset, persists both leaves sparsely, keeping neighbours", function()
		with_settings('[hotstrings]\nunknown = "keep"\n', function(subject, _, path, reload, sandbox)
			helpers.assert_true(subject.set_idle_seconds(7.5))
			helpers.assert_true(subject.set_click_resets_word(false))
			local config = require("toml_codec").decode(sandbox.read_bytes(path))
			helpers.assert_eq(config.hotstrings.idle_reset_seconds, 7.5)
			helpers.assert_eq(config.hotstrings.click_resets_word, false)
			helpers.assert_eq(config.hotstrings.unknown, "keep")
			local fresh = reload()
			helpers.assert_eq(fresh.idle_seconds(), 7.5)
			helpers.assert_eq(fresh.click_resets_word(), false)
			helpers.assert_true(fresh.toggle_click_resets_word())
			helpers.assert_eq(require("toml_codec").decode(sandbox.read_bytes(path)).hotstrings.click_resets_word, nil,
				"the default is written as an absent leaf")
		end)
	end)

	helpers.it("word reset, refuses an invalid value and keeps the source when publication refuses", function()
		local source = "[hotstrings]\nidle_reset_seconds = 5\n"
		with_settings(source, function(subject, controls, path, _, sandbox)
			helpers.assert_eq(subject.set_idle_seconds(-1), false)
			helpers.assert_eq(subject.set_idle_seconds("3"), false)
			helpers.assert_eq(subject.set_click_resets_word("yes"), false)
			controls.refuse = true
			helpers.assert_eq(subject.set_idle_seconds(1), false)
			helpers.assert_eq(sandbox.read_bytes(path), source)
			helpers.assert_eq(subject.idle_seconds(), 5, "the runtime keeps the published value")
		end)
	end)

	helpers.it("word reset, reads an outdated value as the default with one warning", function()
		with_settings('[hotstrings]\nidle_reset_seconds = -2\nclick_resets_word = "no"\narrow_resets_word = 1\n'
			.. 'shortcut_resets_word = "off"\ntap_hold_resets_word = []\n', function(subject)
			require("config_outdated").reset_for_tests()
			local reported = require("config_outdated").collect_reports(function()
				helpers.assert_eq(subject.idle_seconds(), 3)
				for _, key in ipairs(SWITCHES) do helpers.assert_eq(subject[key](), true, key .. " falls back") end
			end)
			helpers.assert_eq(reported, {
				["hotstrings.idle_reset_seconds"] = true, ["hotstrings.click_resets_word"] = true,
				["hotstrings.arrow_resets_word"] = true, ["hotstrings.shortcut_resets_word"] = true,
				["hotstrings.tap_hold_resets_word"] = true })
		end)
	end)

	helpers.it("word reset, marks every leaf as read for the cleanup", function()
		with_settings("[hotstrings]\nidle_reset_seconds = 2\nclick_resets_word = false\narrow_resets_word = false\n"
			.. "shortcut_resets_word = false\ntap_hold_resets_word = false\n", function(_, _, path)
			local consumed = { ["hotstrings.idle_reset_seconds"] = true }
			for _, key in ipairs(SWITCHES) do consumed["hotstrings." .. key] = true end
			package.loaded["ui.menu.unused_keys_cleanup"] = nil
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			for _, key in ipairs(scan.keys) do
				local dotted = table.concat(key.path, ".")
				helpers.assert_true(not consumed[dotted], "a consumed leaf is never offered for removal: " .. dotted)
			end
		end)
	end)

	helpers.it("word reset, adopts and restores a scope candidate", function()
		with_settings(nil, function(subject)
			local before = subject.snapshot()
			helpers.assert_true(subject.adopt_configuration({ hotstrings = { idle_reset_seconds = 10, click_resets_word = false,
				arrow_resets_word = false, shortcut_resets_word = false, tap_hold_resets_word = false } }))
			helpers.assert_eq(subject.idle_seconds(), 10)
			for _, key in ipairs(SWITCHES) do helpers.assert_eq(subject[key](), false, key .. " adopted") end
			helpers.assert_true(subject.restore_configuration(before))
			helpers.assert_eq(subject.idle_seconds(), 3)
			for _, key in ipairs(SWITCHES) do helpers.assert_eq(subject[key](), true, key .. " restored") end
			helpers.assert_eq(subject.restore_configuration({ idle_seconds = -1, click_resets_word = true,
				arrow_resets_word = true, shortcut_resets_word = true, tap_hold_resets_word = true }), false)
			local incomplete = subject.snapshot()
			incomplete.tap_hold_resets_word = nil
			helpers.assert_eq(subject.restore_configuration(incomplete), false, "a snapshot missing a switch is refused")
		end)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 3/ The keystroke stamp and the free entry ===============
-- =================================================================
-- =================================================================

helpers.describe("word reset: the input path", function()
	helpers.it("word reset, resets after the configured pause, measured from the previous key", function()
		with_settings("[hotstrings]\nidle_reset_seconds = 2\n", function(_, _, _, reload)
			-- An exact clock, so the vectors do not depend on the host's backend.
			package.loaded["infra.monotonic"] = { resolution_ms = function() return 0 end }
			local subject = reload()
			helpers.assert_eq(subject.observe_key(10000), false, "the first key has no pause before it")
			helpers.assert_eq(subject.observe_key(11000), false)
			helpers.assert_eq(subject.observe_key(12999), false, "each key restarts the measure")
			helpers.assert_true(subject.observe_key(15000), "a 2 s pause starts a new word")
			helpers.assert_eq(subject.observe_key(15100), false)
		end)
	end)

	helpers.it("word reset, never resets when the delay is 0", function()
		with_settings("[hotstrings]\nidle_reset_seconds = 0\n", function(subject)
			subject.observe_key(0)
			helpers.assert_eq(subject.observe_key(1e9), false)
		end)
	end)

	helpers.it("word reset, parses a free entry with a decimal point or comma", function()
		with_settings(nil, function(subject)
			helpers.assert_eq(subject.parse_seconds(" 4 "), 4)
			helpers.assert_eq(subject.parse_seconds("1,5"), 1.5)
			helpers.assert_eq(subject.parse_seconds("0.25"), 0.25)
			helpers.assert_eq(subject.parse_seconds("0"), 0)
			for _, bad in ipairs({ "", "-1", "abc", "1e3", "inf", "nan", "1.2.3" }) do
				helpers.assert_nil(subject.parse_seconds(bad), bad)
			end
			helpers.assert_nil(subject.parse_seconds(nil))
		end)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 4/ The menu row =========================================
-- =================================================================
-- =================================================================

helpers.describe("word reset: the menu's choice and free entry", function()
	local i18n = require("infra.i18n")
	local function row_for(current, calls)
		local Menu = require("infra.manifest_menu")
		return Menu.choice_row("hotstrings_params_group", "idle_reset", {
			idle_reset = function(value) calls[#calls + 1] = value; return true end,
			idle_reset_custom = function() calls[#calls + 1] = "custom"; return true end,
		}, { ["hotstrings.idle_reset_seconds"] = function() return current end })
	end

	helpers.it("word reset, lists the presets, then a free entry, ticking the current preset", function()
		local calls = {}
		local row = row_for(3, calls)
		helpers.assert_not_nil(row, "the declared choice renders")
		local labels, ticked = {}, nil
		for _, item in ipairs(row.items) do
			if not item.separator then
				labels[#labels + 1] = item.label
				if item.checked then ticked = item.label end
			end
		end
		helpers.assert_eq(#labels, 7, "six presets and the free entry")
		helpers.assert_eq(labels[1], i18n.get("menu.hotstrings.idle_reset_off"))
		helpers.assert_eq(labels[4], "3 " .. i18n.get("menu.hotstrings.idle_reset_unit"))
		helpers.assert_eq(labels[7], i18n.get("menu.hotstrings.idle_reset_custom"))
		helpers.assert_eq(ticked, labels[4])
		helpers.assert_true(row.items[#row.items - 1].separator, "a separator sets the free entry apart")
		row.items[2].action()
		row.items[#row.items].action()
		helpers.assert_eq(calls, { 1, "custom" })
	end)

	helpers.it("word reset, ticks the free entry and names a free value with its unit", function()
		local row = row_for(4.5, {})
		local last = row.items[#row.items]
		helpers.assert_true(last.checked, "a value outside the presets ticks the free entry")
		for index = 1, #row.items - 2 do helpers.assert_true(not row.items[index].checked) end
		helpers.assert_contains(row.label, "4.5 " .. i18n.get("menu.hotstrings.idle_reset_unit"))
	end)

	helpers.it("word reset, refuses the row when the free entry has no owner", function()
		local Menu = require("infra.manifest_menu")
		helpers.assert_nil(Menu.choice_row("hotstrings_params_group", "idle_reset",
			{ idle_reset = function() return true end },
			{ ["hotstrings.idle_reset_seconds"] = function() return 3 end }))
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 5/ The daemon wiring ====================================
-- =================================================================
-- =================================================================

helpers.describe("word reset: the daemon wiring", function()
	local function source(rel)
		local f = assert(io.open(helpers.driver_root() .. "/" .. rel, "rb"))
		local text = f:read("*a")
		f:close()
		return text
	end

	helpers.it("word reset, resets the engine after an idle pause before feeding the character", function()
		local text = source("ergopti_hotstrings.lua")
		local idle = text:find("if WordReset.observe_key(now_ms) then", 1, true)
		local feed = text:find("local result = engine:on_char(ch, {", 1, true)
		helpers.assert_true(idle ~= nil and feed ~= nil and idle < feed, "the idle check precedes the engine feed")
		helpers.assert_contains(text:sub(idle, feed), "engine:reset()")
	end)

	helpers.it("word reset, resets the engine on a click at the configured boundary", function()
		local text = source("ergopti_hotstrings.lua")
		local click = text:find("local function on_click()", 1, true)
		helpers.assert_true(click ~= nil)
		local body = text:sub(click, text:find("\n\tend\n", click, true))
		helpers.assert_contains(body, "engine:reset(at_word_start)")
		helpers.assert_contains(body, "WordReset.click_resets_word()")
		helpers.assert_contains(text, "onClick = on_click,")
	end)

	helpers.it("word reset, hands every control key but a one-character Backspace to the options", function()
		local text = source("ergopti_hotstrings.lua")
		local start = text:find("local function handle_control(key_name, detail)", 1, true)
		helpers.assert_true(start ~= nil)
		local body = text:sub(start, text:find("\n\tend\n", start, true))
		helpers.assert_contains(body, "effect = WordReset.apply_control(engine, key_name, detail)")
		helpers.assert_true(not body:find("engine:reset(key_name", 1, true),
			"no control key resets the engine around the options")
	end)

	helpers.it("word reset, tells the engine of each tap-hold command the catalogue runs", function()
		local text = source("ergopti_hotstrings.lua")
		local start = text:find("execute_action = function(action, binding)", 1, true)
		helpers.assert_true(start ~= nil)
		local body = text:sub(start, text:find("\n\t\tend,\n", start, true))
		local run = body:find("action_catalogue.execute_action(action, binding)", 1, true)
		local told = body:find("WordReset.apply_tap_action(engine, binding)", 1, true)
		helpers.assert_true(run ~= nil and told ~= nil and run < told, "the command runs, then the word follows the option")
	end)

	helpers.it("word reset, gives each new switch its menu command and checked state", function()
		local text = source("ui/menu/menu_builder.lua")
		for _, key in ipairs({ "arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word" }) do
			helpers.assert_contains(text, 'params_ctx.commands["' .. key .. '"]')
			helpers.assert_contains(text, "WordReset.toggle_" .. key .. "()")
			helpers.assert_contains(text, 'params_ctx.state_getters["hotstrings_' .. key .. '"]')
			helpers.assert_contains(text, "return WordReset." .. key .. "()")
		end
	end)

	helpers.it("word reset, lets the Hotstrings scope adopt and restore both leaves", function()
		local text = source("infra/hotstrings_scope.lua")
		helpers.assert_contains(text, "WordReset.adopt_configuration(decoded)")
		helpers.assert_contains(text, "WordReset.restore_configuration(snapshot.word_reset)")
		helpers.assert_contains(text, 'word_reset = require("modules.hotstrings.word_reset")')
	end)
end)

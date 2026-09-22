--- tests/unit/ui/test_unused_keys_cleanup.lua

--- ==============================================================================
--- MODULE: Unused Configuration Key Cleanup (Linux)
--- DESCRIPTION:
--- The "Clean up unused settings…" row was Windows-only: Linux read the keys it
--- used and never listed the rest, and its TOML writer merges every save back
--- in, so a stale key stayed in config.toml forever. These tests run the shared
--- contract with the Linux readers, then prove the rule is exactly the
--- readers': the cleaned file loads to the same driver state, and every key
--- left behind changes that state when removed alone. They also pin the tray
--- row and its zenity dialogs.
--- ==============================================================================

local helpers   = require("tests.helpers")
local Contract  = require("test.config_unused_keys_contract")
local Engine    = require("config_unused_keys")
local TomlCodec = require("toml_codec")

local Sandbox = Contract.sandbox

-- Every used value differs from what its absence yields, so removing any one
-- of them visibly changes the driver state.
local SHORTCUTS_NON_DEFAULT = not require("infra.manifest_reader").default_for("shortcuts.enabled")

-- One key of each shape the Linux readers take, and seven they never read,
-- including [script].onboarding_done: the wizard writes it and no Linux code
-- reads it back.
local FIXTURE = table.concat({
	"[script]",
	"onboarding_done = true",
	"",
	"[hotstrings]",
	"enabled = false",
	"trigger_char = \"★\"",
	"stale_toggle = false",
	"",
	"[metrics]",
	"enabled = true",
	"metrics_encrypt = 0",
	"",
	"[gestures]",
	"enabled = true",
	"tap_3 = \"open_url\"",
	"not_a_slot = \"none\"",
	"",
	"[gesture_parameters]",
	"tap_3__open_url = \"https://example.com\"",
	"broken = \"x\"",
	"",
	"[linux.gestures]",
	"swipe_3_up = \"open_url\"",
	"",
	"[shortcuts]",
	"enabled = " .. tostring(SHORTCUTS_NON_DEFAULT),
	"chatgpt_url = \"https://chat.example\"",
	"",
	"[stale.section]",
	"label = \"old\"",
	"",
}, "\n")

local EXPECTED = {
	"script.onboarding_done=section",
	"hotstrings.stale_toggle=leaf",
	"metrics.metrics_encrypt=leaf",
	"gestures.not_a_slot=leaf",
	"gesture_parameters.broken=leaf",
	"shortcuts.chatgpt_url=leaf",
	"stale.section.label=section",
}

local SURVIVORS = {
	{ { "hotstrings", "trigger_char" }, "★" },
	{ { "metrics", "enabled" }, true },
	{ { "gestures", "tap_3" }, "open_url" },
	{ { "gesture_parameters", "tap_3__open_url" }, "https://example.com" },
	{ { "linux", "gestures", "swipe_3_up" }, "open_url" },
	{ { "shortcuts", "enabled" }, SHORTCUTS_NON_DEFAULT },
}

local Cleanup = helpers.load_module("ui.menu.unused_keys_cleanup")

Contract.register(helpers, {
	driver = "linux",
	collect = Cleanup.collect,
	fixture = FIXTURE,
	expected = EXPECTED,
	survivors = SURVIVORS,
})





-- ===========================================
-- ===========================================
-- ======= 1/ The Readers' Own Verdict =======
-- ===========================================
-- ===========================================

--- Everything the Linux readers derive from a config file. Each manager is
--- loaded fresh so no state survives from the previous file, and the gesture
--- master switch is observed without starting the touch reader.
--- @param path string
--- @return table
local function driver_state(path)
	local gestures = helpers.load_module("modules.gestures.manager")
	local enable_requested = false
	gestures.enable = function() enable_requested = true end
	gestures.init({ persist = true, config_path = path })
	local actions = {}
	for slot in pairs(gestures.DEFAULT_GESTURES) do actions[slot] = gestures.get_action(slot) end

	local shortcuts = helpers.load_module("modules.shortcuts.manager")
	shortcuts.init({ persist = true, config_path = path })

	local decoded = TomlCodec.decode(Sandbox.read_bytes(path))
	return {
		actions = actions,
		parameter = gestures.get_action_parameter("tap_3", "open_url"),
		gestures_enabled = enable_requested,
		shortcuts_enabled = shortcuts.is_enabled(),
		answers = require("ui.onboarding.bridge")._answers_from_config(decoded, ""),
	}
end

helpers.describe("unused keys (linux): the rule is exactly the readers'", function()
	helpers.it("unused keys: the cleaned file loads to the same driver state", function()
		Sandbox.with_config(FIXTURE, function(path)
			local before = driver_state(path)
			local keys = Cleanup.find(path).keys
			helpers.assert_eq(#keys, #EXPECTED)
			local result = Engine.remove({ path = path, keys = keys, stamp = Sandbox.STAMP })
			helpers.assert_eq(result.status, "removed")
			helpers.assert_eq(driver_state(path), before,
				"a removed key must be one no Linux reader takes")
		end)
	end)

	helpers.it("unused keys: every key left behind changes the driver state when removed", function()
		local scan = Engine.scan_records(FIXTURE)
		local offered = {}
		for _, id in ipairs(EXPECTED) do offered[id:match("^(.-)=")] = true end
		local checked = 0
		for _, record in ipairs(scan.records) do
			if record.addressable and not offered[record.section .. "." .. record.key] then
				Sandbox.with_config(FIXTURE, function(path)
					local before = driver_state(path)
					local without = Engine.remove_from_source(FIXTURE, {
						{ section = record.section, key = record.key, kind = "leaf" },
					})
					Sandbox.write_bytes(path, without)
					helpers.assert_true(not helpers.deep_equal(driver_state(path), before),
						"[" .. record.section .. "] " .. record.key
							.. " is kept by the cleanup, so a reader must take it")
				end)
				checked = checked + 1
			end
		end
		helpers.assert_eq(checked, #SURVIVORS + 2,
			"every used record of the fixture must be exercised")
	end)

	helpers.it("unused keys: a malformed shortcut switch is read (it fails closed), so it is kept", function()
		local scan = Engine.find_in_source("[shortcuts]\nenabled = \"yes\"\n", Cleanup.collect)
		helpers.assert_eq(#scan.keys, 0)
	end)

	helpers.it("unused keys: an invalid gesture parameter is ignored by the loader and offered", function()
		local scan = Engine.find_in_source(
			"[gesture_parameters]\ntap_3__open_url = \"not a url\"\n", Cleanup.collect)
		helpers.assert_eq(#scan.keys, 1)
		helpers.assert_eq(scan.keys[1].key, "tap_3__open_url")
	end)
end)





-- =======================================
-- =======================================
-- ======= 2/ Menu Row And Dialogs =======
-- =======================================
-- =======================================

--- Finds a rendered row by title anywhere in the tray tree.
--- @param items table
--- @param title string
--- @return table|nil
local function find_row(items, title)
	for _, item in ipairs(items or {}) do
		if item.title == title or item.label == title then return item end
		local found = find_row(item.menu or item.submenu or item.items, title)
		if found then return found end
	end
	return nil
end

--- Runs fn with os.execute recording every command. The zenity probe finds
--- the binary; every other command exits with `status`.
--- @param status any Exit status of the dialog commands.
--- @param fn function
--- @return table commands
local function with_execute(status, fn)
	local real = os.execute
	local commands = {}
	os.execute = function(command)
		commands[#commands + 1] = tostring(command)
		if tostring(command):find("command -v zenity", 1, true) then return 0 end
		return status
	end
	local ok, err = pcall(fn)
	os.execute = real
	if not ok then error(err, 0) end
	return commands
end

helpers.describe("unused keys (linux): tray wiring", function()
	helpers.it("unused keys: the Global actions submenu offers the row and hands it the zenity dialogs", function()
		local previous = package.loaded["ui.menu.unused_keys_cleanup"]
		local captured
		package.loaded["ui.menu.unused_keys_cleanup"] = {
			run_from_menu = function(deps) captured = deps; return true end,
		}
		local ok, err = pcall(function()
			local mb = helpers.load_module("ui.menu.menu_builder")
			local i18n = require("infra.i18n")
			local label = i18n.get("menu.global.clean_unused_keys")
			local row = find_row(mb.build({ _version = "test", on_quit = function() end }), label)
			helpers.assert_true(row ~= nil, "the cleanup row must be in Global actions on Linux")
			local fn = row.fn or row.action
			helpers.assert_eq(type(fn), "function")
			fn()
			helpers.assert_true(type(captured) == "table" and type(captured.dialogs) == "table",
				"the row must run the cleanup with this tray's dialogs")

			-- LuaJIT reports success as the NUMBER 0.
			local answer
			local commands = with_execute(0, function()
				answer = captured.dialogs.confirm("Title", "[a] k = \"<x & y>\"")
			end)
			helpers.assert_eq(answer, true)
			local question = commands[#commands]
			helpers.assert_true(question:find("zenity --question", 1, true) ~= nil, question)
			helpers.assert_true(question:find("&lt;x &amp; y&gt;", 1, true) ~= nil,
				"zenity reads --text as markup: a value holding < or & must be escaped")
			helpers.assert_true(question:find(i18n.get("button.remove"), 1, true) ~= nil)

			commands = with_execute(1, function() answer = captured.dialogs.confirm("T", "x") end)
			helpers.assert_eq(answer, false, "Cancel is a No")

			commands = with_execute(0, function() captured.dialogs.inform("Done", "ok") end)
			helpers.assert_true(commands[1]:find("zenity --info", 1, true) ~= nil, commands[1])
			commands = with_execute(0, function() captured.dialogs.fail("Failed", "why") end)
			helpers.assert_true(commands[1]:find("zenity --error --title=", 1, true) ~= nil, commands[1])
		end)
		package.loaded["ui.menu.unused_keys_cleanup"] = previous
		if not ok then error(err, 0) end
	end)

	helpers.it("unused keys: without zenity nobody is asked and nothing is removed", function()
		Sandbox.with_config(FIXTURE, function(path)
			local completed = Cleanup.run_from_menu({
				path = path, stamp = Sandbox.STAMP,
				get_text = function(key) return key end,
				dialogs = {
					confirm = function() return nil end,
					inform = function() error("nothing to report") end,
					fail = function() end,
				},
			})
			helpers.assert_eq(completed, false)
			helpers.assert_eq(Sandbox.read_bytes(path), FIXTURE)
		end)
	end)

	helpers.it("unused keys: a confirmed tray cleanup removes the keys and keeps a backup", function()
		Sandbox.with_config(FIXTURE, function(path)
			local shown = {}
			local completed = Cleanup.run_from_menu({
				path = path, stamp = Sandbox.STAMP,
				get_text = function(key) return key end,
				dialogs = {
					confirm = function() return true end,
					inform = function(_, text) shown[#shown + 1] = text end,
					fail = function() error("no failure expected") end,
				},
			})
			helpers.assert_true(completed)
			helpers.assert_eq(shown, { "dialog.unused_keys.done" })
			helpers.assert_eq(Sandbox.read_bytes(Engine.backup_path(path, Sandbox.STAMP)), FIXTURE)
			helpers.assert_eq(#Cleanup.find(path).keys, 0)
		end)
	end)

	helpers.it("unused keys: the tray action refuses to run without dialogs", function()
		helpers.assert_throws(function() Cleanup.run_from_menu({}) end)
	end)
end)

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
--- row and its cleanup WebView.
--- ==============================================================================

local helpers   = require("tests.helpers")
local Contract  = require("test.config_unused_keys_contract")
local Engine    = require("config_unused_keys")
local TomlCodec = require("toml_codec")

local Sandbox = Contract.sandbox

-- Every used value differs from what its absence yields, so removing any one
-- of them visibly changes the driver state.
local SHORTCUTS_NON_DEFAULT = not require("infra.manifest_reader").default_for("shortcuts.enabled")

-- The update channel the user subscribed to: a registry channel other than the
-- installed build's, which is what the updater follows when the key is absent.
local SUBSCRIBED_NON_DEFAULT = (function()
	local updater = require("modules.updater.manager")
	for _, id in ipairs(updater.CHANNELS.ids()) do
		if id ~= updater.installed_channel() then return id end
	end
	error("the update channel registry must declare a second channel")
end)()

-- One key of each shape the Linux readers take, and six they never read.
-- Linux has no hotstring master switch: the setup wizard asks per section.
local FIXTURE = table.concat({
	"[hotstrings]",
	"enabled = false",
	"trigger_char = \"§\"",
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
	"[updater]",
	"channel = \"" .. SUBSCRIBED_NON_DEFAULT .. "\"",
	"",
	"[stale.section]",
	"label = \"old\"",
	"",
}, "\n")

local EXPECTED = {
	"hotstrings.enabled=leaf",
	"hotstrings.stale_toggle=leaf",
	"metrics.metrics_encrypt=leaf",
	"gestures.not_a_slot=leaf",
	"gesture_parameters.broken=leaf",
	"stale.section.label=section",
}

local SURVIVORS = {
	{ { "hotstrings", "trigger_char" }, "§" },
	{ { "metrics", "enabled" }, true },
	{ { "gestures", "tap_3" }, "open_url" },
	{ { "gesture_parameters", "tap_3__open_url" }, "https://example.com" },
	{ { "linux", "gestures", "swipe_3_up" }, "open_url" },
	{ { "shortcuts", "enabled" }, SHORTCUTS_NON_DEFAULT },
	{ { "shortcuts", "chatgpt_url" }, "https://chat.example" },
	{ { "updater", "channel" }, SUBSCRIBED_NON_DEFAULT },
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

	-- The updater reads the subscribed channel at init; its background checks
	-- stop at once, and the previous module comes back so no suite shares this one.
	local previous_updater = package.loaded["modules.updater.manager"]
	local updater = helpers.load_module("modules.updater.manager")
	local ok_updater, updater_err = pcall(function()
		updater.init({ config_path = path })
		updater.stop_background_checks()
	end)
	local update_channel = updater.get_channel()
	package.loaded["modules.updater.manager"] = previous_updater
	if not ok_updater then error(updater_err, 0) end

	local paths = require("infra.config_paths")
	local previous_config, previous_chatgpt = paths.config, package.loaded["modules.shortcuts.chatgpt"]
	local previous_preferences = package.loaded["infra.hotstring_preferences"]
	local previous_magic_key = package.loaded["modules.hotstrings.magic_key"]
	paths.config = function(name)
		helpers.assert_eq(name, "config.toml")
		return path
	end
	local ok_url, chatgpt_url = pcall(function()
		return helpers.load_module("modules.shortcuts.chatgpt").get_url()
	end)
	-- The magic key is read from config.toml by the hotstring preferences, not
	-- by the setup wizard, which leaves the Linux trigger to the tray.
	package.loaded["infra.hotstring_preferences"] = nil
	local ok_key, magic_key = pcall(function()
		return helpers.load_module("modules.hotstrings.magic_key").get()
	end)
	paths.config, package.loaded["modules.shortcuts.chatgpt"] = previous_config, previous_chatgpt
	package.loaded["infra.hotstring_preferences"] = previous_preferences
	package.loaded["modules.hotstrings.magic_key"] = previous_magic_key
	if not ok_url then error(chatgpt_url, 0) end
	if not ok_key then error(magic_key, 0) end

	local decoded = TomlCodec.decode(Sandbox.read_bytes(path))
	return {
		actions = actions,
		parameter = gestures.get_action_parameter("tap_3", "open_url"),
		gestures_enabled = enable_requested,
		shortcuts_enabled = shortcuts.is_enabled(),
		chatgpt_url = chatgpt_url,
		magic_key = magic_key,
		update_channel = update_channel,
		wizard = require("ui.onboarding.bridge").config_values(decoded),
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
		helpers.assert_eq(checked, #SURVIVORS + 1,
			"every used record of the fixture must be exercised")
	end)

	helpers.it("unused keys: a malformed shortcut switch is read (it fails closed), so it is kept", function()
		local scan = Engine.find_in_source("[shortcuts]\nenabled = \"yes\"\n", Cleanup.collect)
		helpers.assert_eq(#scan.keys, 0)
	end)

	helpers.it("unused keys: the subscribed update channel is read, an unknown one is offered", function()
		local kept = Engine.find_in_source("[updater]\nchannel = \"" .. SUBSCRIBED_NON_DEFAULT .. "\"\n",
			Cleanup.collect)
		helpers.assert_eq(#kept.keys, 0, "the updater reads its channel from config.toml")
		-- An alias is resolved by the registry, so it is read like the id it names.
		local alias = "stable"
		helpers.assert_true(require("modules.updater.manager").CHANNELS.resolve(alias) ~= nil,
			"the registry must still declare the '" .. alias .. "' alias")
		helpers.assert_eq(#Engine.find_in_source("[updater]\nchannel = \"" .. alias .. "\"\n",
			Cleanup.collect).keys, 0, "an alias of a registry channel is read")
		local unknown = Engine.find_in_source("[updater]\nchannel = \"no_such_channel\"\n", Cleanup.collect)
		helpers.assert_eq(#unknown.keys, 1, "a channel outside the registry is ignored by the updater")
		helpers.assert_eq(unknown.keys[1].key, "channel")
	end)

	helpers.it("unused keys: live bindings are kept, retired actions are offered (config-outdated-shortcuts)",
		function()
			local source = table.concat({
				"[gestures]",
				"swipe_3_up = \"open_url\"",
				"tap_3 = \"retired_action_xyz\"",
				"",
				"[shortcuts.keyboard]",
				"ctrl_k = \"select_line\"",
				"ctrl_j = \"retired_action_xyz\"",
				"",
				"[shortcuts.tap_keys]",
				"number_row_left = \"retired_action_xyz\"",
				"",
			}, "\n")
			local offered = {}
			for _, key in ipairs(Engine.find_in_source(source, Cleanup.collect).keys) do
				offered[#offered + 1] = key.section .. "." .. key.key
			end
			table.sort(offered)
			-- ctrl_k is a live binding: offering it would delete the user's shortcut.
			helpers.assert_eq(offered, {
				"gestures.tap_3", "shortcuts.keyboard.ctrl_j", "shortcuts.tap_keys.number_row_left",
			})

			-- The Shortcuts scope resolves the same document instead of refusing it.
			local decoded = TomlCodec.decode(source)
			local keyboard = require("modules.shortcuts.keyboard_shortcuts").configuration_candidate(decoded)
			helpers.assert_eq(keyboard.assignments.ctrl_k, "select_line")
			helpers.assert_nil(keyboard.assignments.ctrl_j)
			local tap = require("modules.shortcuts.tap_keys").configuration_candidate(decoded)
			helpers.assert_eq(tap.assignments.number_row_left, "none")
		end)

	helpers.it("unused keys: what the readers warn about is exactly what is offered (config-outdated-warned-offered)",
		function()
			-- Unknown gesture slots and invalid parameters were offered but never
			-- warned about; an invalid AI value was warned about but never offered
			-- (and a wrong-typed one made every AI preference read raise).
			local source = table.concat({
				"[gestures]",
				"enabled = true",
				"not_a_slot = \"none\"",
				"tap_3 = 5",
				"",
				"[gesture_parameters]",
				"broken = \"x\"",
				"tap_3__open_url = \"not a url\"",
				"",
				"[llm]",
				"enabled = true",
				"",
				"[llm.trigger]",
				"debounce_ms = \"fast\"",
				"",
				"[llm.generation]",
				"temperature = 99",
				"",
			}, "\n")
			local scan
			local reported = require("config_outdated").collect_reports(function()
				scan = Engine.find_in_source(source, Cleanup.collect)
			end)
			local offered, warned = {}, {}
			for _, key in ipairs(scan.keys) do offered[#offered + 1] = key.section .. "." .. key.key end
			for path in pairs(reported) do warned[#warned + 1] = path end
			table.sort(offered)
			table.sort(warned)
			helpers.assert_eq(offered, { "gesture_parameters.broken", "gesture_parameters.tap_3__open_url",
				"gestures.not_a_slot", "gestures.tap_3", "llm.generation.temperature", "llm.trigger.debounce_ms" })
			helpers.assert_eq(warned, offered)

			-- The wrong-typed AI leaf is read as absent; its neighbours still read.
			Sandbox.with_config(source, function(path)
				local paths = require("infra.config_paths")
				local previous_config, previous_preferences = paths.config, package.loaded["infra.llm_preferences"]
				paths.config = function() return path end
				package.loaded["infra.llm_preferences"] = nil
				local ok, err = pcall(function()
					local preferences = require("infra.llm_preferences")
					helpers.assert_eq(preferences.get("llm.enabled", nil), true)
					helpers.assert_nil(preferences.get("llm.trigger.debounce_ms", nil))
				end)
				paths.config, package.loaded["infra.llm_preferences"] = previous_config, previous_preferences
				if not ok then error(err, 0) end
			end)
		end)

	helpers.it("unused keys: an outdated inline-table member is offered and cut alone (config-outdated-inline)",
		function()
			local source = "[shortcuts]\ntap_keys = { number_row_left = \"retired_action_xyz\", "
				.. "number_row_right_1 = \"none\" }\n"
			Sandbox.with_config(source, function(path)
				local before = driver_state(path)
				local keys = Cleanup.find(path).keys
				helpers.assert_eq(#keys, 1)
				helpers.assert_eq({ keys[1].section, keys[1].key }, { "shortcuts.tap_keys", "number_row_left" })
				local result = Engine.remove({ path = path, keys = keys, stamp = Sandbox.STAMP })
				helpers.assert_eq(result.status, "removed")
				helpers.assert_eq(Sandbox.read_bytes(path),
					"[shortcuts]\ntap_keys = { number_row_right_1 = \"none\" }\n")
				-- The setup wizard shows the raw stale value; every runtime reader
				-- already ignored it.
				local after = driver_state(path)
				before.wizard, after.wizard = nil, nil
				helpers.assert_eq(after, before, "the live member keeps its value")
				helpers.assert_eq(#Cleanup.find(path).keys, 0)
			end)
		end)

	helpers.it("unused keys: an old-shape hotstring choice is offered, not fatal (config-outdated-hotstrings)",
		function()
			-- One retired pack in a legacy spelling used to raise in the choice
			-- decoder: every hotstring went off and the cleanup could list nothing.
			local source = table.concat({
				"[hotstrings.groups]",
				"retired_pack = \"on\"",
				"",
				"[stale.section]",
				"label = \"old\"",
				"",
			}, "\n")
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(scan.status, "ok")
			local offered = {}
			for _, key in ipairs(scan.keys) do offered[#offered + 1] = key.section .. "." .. key.key end
			table.sort(offered)
			helpers.assert_eq(offered, { "hotstrings.groups.retired_pack", "stale.section.label" })
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

--- Keeps the existing engine refusal and backup proofs after UI replacement.
local function run_engine_cleanup(deps)
	return Engine.run({
		path = deps.path, collect = Cleanup.collect, stamp = deps.stamp,
		get_text = deps.get_text, confirm = deps.dialogs.confirm,
		inform = deps.dialogs.inform, fail = deps.dialogs.fail,
	})
end

helpers.describe("unused keys (linux): tray wiring", function()
	helpers.it("unused keys: the Configuration submenu opens the cleanup host without native dialogs", function()
		local previous, called = package.loaded["ui.menu.unused_keys_cleanup"], false
		package.loaded["ui.menu.unused_keys_cleanup"] = {
			run_from_menu = function(deps) helpers.assert_eq(deps, nil); called = true; return true end,
		}
		local ok, detail = pcall(function()
			local mb = helpers.load_module("ui.menu.menu_builder")
			local label = require("infra.i18n").get("menu.global.clean_unused_keys")
			local row = find_row(mb.build({ _version = "test", on_quit = function() end }), label)
			helpers.assert_true(row ~= nil, "the Configuration menu must expose cleanup")
			local callback = row.fn or row.action
			helpers.assert_eq(type(callback), "function")
			callback()
			helpers.assert_eq(called, true)
		end)
		package.loaded["ui.menu.unused_keys_cleanup"] = previous
		if not ok then error(detail, 0) end
	end)

	helpers.it("unused keys: the engine refuses an unavailable confirmation without modifying the file", function()
		Sandbox.with_config(FIXTURE, function(path)
			local completed = run_engine_cleanup({
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

	helpers.it("unused keys: a confirmed engine cleanup removes the keys and keeps a backup", function()
		Sandbox.with_config(FIXTURE, function(path)
			local shown = {}
			local completed = run_engine_cleanup({
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

	helpers.it("unused keys: the menu forwards trusted ownership and reports a refused WebView", function()
		local captured
		local opened = Cleanup.run_from_menu({ path = "/trusted/config.toml",
			host = { open = function(options) captured = options; return false end },
		})
		helpers.assert_eq(opened, false)
		helpers.assert_eq(captured.path, "/trusted/config.toml")
		helpers.assert_eq(captured.collect, Cleanup.collect)
	end)
end)

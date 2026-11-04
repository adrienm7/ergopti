--- tests/unit/infra/preferences/test_pause_layout_preferences.lua

--- ==============================================================================
--- MODULE: Pause Layout Preferences Tests
--- DESCRIPTION:
--- The three [layout] settings of the automatic layout switch are Linux
--- config.toml leaves: absent means the manifest default, a layout id survives
--- a write and a read, a legacy boolean target is outdated, and the unused-key
--- cleanup no longer offers them for removal.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.pause_layout_preferences" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function(name)
				helpers.assert_eq(name, "config.toml")
				return path
			end }
			package.loaded["infra.pause_layout_preferences"] = nil
			body(require("infra.pause_layout_preferences"), path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

local Contract = require("test.pause_switch_policy_contract")
Contract.run_manifest(helpers, require("infra.manifest_reader"))

helpers.describe("pause layout preferences", function()
	helpers.it("reads the manifest defaults from a configuration without the settings", function()
		with_config("[layout]\ndirect_access_digits = \"native\"\n", function(Preferences)
			local settings = Preferences.settings()
			helpers.assert_eq(settings.enabled, false)
			helpers.assert_eq(settings.on_pause, "")
			helpers.assert_eq(settings.on_resume, "")
		end)
	end)

	helpers.it("writes and rereads a layout id and the switch, keeping unrelated leaves", function()
		with_config("[layout]\nfuture = 7\n", function(Preferences, path)
			helpers.assert_true(Preferences.set("enabled", true))
			helpers.assert_true(Preferences.set("on_pause", "xkb:fr"))
			helpers.assert_true(Preferences.set("on_resume", "xkb:fr+ergopti"))
			local layout = Codec.decode(Sandbox.read_bytes(path)).layout
			helpers.assert_eq(layout.pause_switch_enabled, true)
			helpers.assert_eq(layout.on_pause, "xkb:fr")
			helpers.assert_eq(layout.on_resume, "xkb:fr+ergopti")
			helpers.assert_eq(layout.future, 7)
			local settings = Preferences.settings()
			helpers.assert_eq(settings.on_pause, "xkb:fr")
			-- « No change » is the default: a sparse write deletes the key.
			helpers.assert_true(Preferences.set("on_pause", ""))
			helpers.assert_nil(Codec.decode(Sandbox.read_bytes(path)).layout.on_pause)
		end)
	end)

	helpers.it("refuses a value its setting cannot hold without writing", function()
		with_config("[layout]\n", function(Preferences, path)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(Preferences.set("on_pause", false), false)
			helpers.assert_eq(Preferences.set("enabled", "yes"), false)
			helpers.assert_eq(Preferences.set("on_quit", "x"), false, "a quit has no setting of its own")
			helpers.assert_eq(Sandbox.read_bytes(path), before)
		end)
	end)

	helpers.it("reads a legacy boolean target and a text switch as their defaults", function()
		with_config("[layout]\npause_switch_enabled = \"true\"\non_pause = false\non_resume = \"xkb:us\"\n",
			function(Preferences)
				local settings = Preferences.settings()
				helpers.assert_eq(settings.enabled, false)
				helpers.assert_eq(settings.on_pause, "")
				helpers.assert_eq(settings.on_resume, "xkb:us")
			end)
	end)

	helpers.it("keeps the three settings out of the unused-key cleanup", function()
		with_config("[layout]\npause_switch_enabled = true\non_pause = \"xkb:fr\"\non_resume = \"\"\nfuture = 1\n",
			function(_, path)
				local scan = require("ui.menu.unused_keys_cleanup").find(path)
				helpers.assert_eq(scan.status, "ok")
				helpers.assert_eq(#scan.keys, 1)
				helpers.assert_eq(scan.keys[1].key, "future")
			end)
	end)
end)

return true

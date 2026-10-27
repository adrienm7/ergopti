--- tests/unit/infra/preferences/test_number_row_preferences.lua

--- ==============================================================================
--- MODULE: Number Row Preferences Tests
--- DESCRIPTION:
--- The two number-row leaves of [layout] in config.toml: absent means the manifest
--- default, a choice survives a write and a read, a value of another shape is
--- outdated for that leaf alone, and the unused-key cleanup no longer offers
--- them for removal.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Codec = require("toml_codec")

local function with_config(source, body)
	Sandbox.with_config(source, function(path)
		local names = { "infra.config_paths", "infra.number_row_preferences" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local ok, err = pcall(function()
			package.loaded["infra.config_paths"] = { config = function(name)
				helpers.assert_eq(name, "config.toml")
				return path
			end }
			package.loaded["infra.number_row_preferences"] = nil
			body(require("infra.number_row_preferences"), path)
		end)
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("number row preferences", function()
	helpers.it("reads the manifest defaults from a configuration without the settings", function()
		with_config("[layout]\nfuture = 1\n", function(Preferences)
			local settings = Preferences.settings()
			helpers.assert_eq(settings.order, "native")
			helpers.assert_eq(settings.edges, false)
		end)
	end)

	helpers.it("writes and rereads the ordering and the edge keys, keeping unrelated leaves", function()
		with_config("[layout]\nfuture = 7\n", function(Preferences, path)
			helpers.assert_true(Preferences.set("order", "symbols"))
			helpers.assert_true(Preferences.set("edges", true))
			local layout = Codec.decode(Sandbox.read_bytes(path)).layout
			helpers.assert_eq(layout.direct_access_digits, "symbols")
			helpers.assert_eq(layout.number_row_reorder_edges, true)
			helpers.assert_eq(layout.future, 7)
			helpers.assert_eq(Preferences.settings().order, "symbols")
			-- A value equal to its default deletes the key.
			helpers.assert_true(Preferences.set("order", "native"))
			helpers.assert_nil(Codec.decode(Sandbox.read_bytes(path)).layout.direct_access_digits)
		end)
	end)

	helpers.it("refuses a value its setting cannot hold without writing", function()
		with_config("[layout]\n", function(Preferences, path)
			local before = Sandbox.read_bytes(path)
			helpers.assert_eq(Preferences.set("order", "both"), false)
			helpers.assert_eq(Preferences.set("edges", "yes"), false)
			helpers.assert_eq(Preferences.set("size", 3), false)
			helpers.assert_eq(Sandbox.read_bytes(path), before)
		end)
	end)

	helpers.it("reads a value of the wrong shape as its default", function()
		with_config("[layout]\ndirect_access_digits = true\nnumber_row_reorder_edges = \"yes\"\n", function(Preferences)
			local settings = Preferences.settings()
			helpers.assert_eq(settings.order, "native")
			helpers.assert_eq(settings.edges, false)
		end)
	end)

	helpers.it("keeps the two settings out of the unused-key cleanup", function()
		with_config("[layout]\ndirect_access_digits = \"digits\"\nnumber_row_reorder_edges = true\nfuture = 1\n",
			function(_, path)
				local scan = require("ui.menu.unused_keys_cleanup").find(path)
				helpers.assert_eq(scan.status, "ok")
				helpers.assert_eq(#scan.keys, 1)
				helpers.assert_eq(scan.keys[1].key, "future")
			end)
	end)
end)

return true
